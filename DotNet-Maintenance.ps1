# ============================================================
# .NET | SDK | ASP.NET | NETCore | Desktop Runtime | Detect, Update and Cleanup
#
# Platform-independent .NET servicing
# Windows PowerShell 5.1
# Run As: SYSTEM
#
# Purpose:
#   - Detect installed .NET 5/6/7/8/9/10 SDKs and shared runtimes.
#   - Service BOTH x64 and x86 installations.
#   - Update SDKs only within an already-installed SDK feature band.
#       Example: 9.0.308 -> 9.0.317
#       Example: 8.0.421 -> 8.0.424
#   - Re-detect runtimes after SDK servicing.
#   - Update installed runtime families to the latest patch for that major.
#   - After the replacement is verified, remove superseded patch-level
#     shared runtimes from the same major version.
#   - Do NOT install a new .NET major version.
#   - Do NOT move SDKs to a different feature band.
#   - Do NOT remove targeting packs, AppHost packs, SDK feature bands,
#     workloads, or unrelated .NET components.
#   - Do NOT use dotnet-install.ps1, Add-AppxPackage, or WinGet.
#
# Runtime families:
#   Microsoft.NETCore.App
#   Microsoft.AspNetCore.App
#   Microsoft.WindowsDesktop.App
#
# Installer metadata:
#   https://builds.dotnet.microsoft.com/dotnet/release-metadata/releases-index.json
#
# Recommended execution settings:
#   Language: PowerShell
#   Run As: SYSTEM
# ============================================================

$ErrorActionPreference = "Continue"

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

$SupportedMajors = @(5, 6, 7, 8, 9, 10)

$ReleaseIndexUrl = `
    "https://builds.dotnet.microsoft.com/dotnet/release-metadata/releases-index.json"

$TempRoot = Join-Path `
    $env:TEMP `
    "DotNet-MachineScope"


$LogRoot = "C:\ProgramData\DotNetMaintenance\Logs"
$LogFile = Join-Path $LogRoot "DotNet-SDK-Runtime-Update.log"
$TranscriptStarted = $false

$StateRoot = "C:\ProgramData\DotNetMaintenance\State"
$RebootMarkerFile = Join-Path $StateRoot "DotNet-SDK-Runtime-RebootPending.json"
$PreviousRunRebootPending = $false

$Architectures = @(
    [PSCustomObject]@{
        Name = "x64"
        Rid  = "win-x64"
        Root = Join-Path $env:ProgramFiles "dotnet"
    }
)

if (${env:ProgramFiles(x86)}) {
    $Architectures += [PSCustomObject]@{
        Name = "x86"
        Rid  = "win-x86"
        Root = Join-Path ${env:ProgramFiles(x86)} "dotnet"
    }
}

# ------------------------------------------------------------
# Result tracking
# ------------------------------------------------------------

$DetectedSdks       = @()
$UpdatedSdks        = @()
$CurrentSdks        = @()

$DetectedHostingBundles = @()
$UpdatedHostingBundles  = @()
$CurrentHostingBundles  = @()

$DetectedFamilies   = @()
$UpdatedFamilies    = @()
$CurrentFamilies    = @()
$RemovedRuntimes    = @()
$PendingRebootRuntimes = @()

$FailedItems        = @()
$EOLItems           = @()
$RebootRequired     = $false

$ReleaseDataCache   = @{}

# ============================================================
# FUNCTIONS
# ============================================================

function Write-Section {

    param (
        [Parameter(Mandatory = $true)]
        [string]$Title
    )

    Write-Host ""
    Write-Host "============================================================"
    Write-Host $Title
    Write-Host "============================================================"
    Write-Host ""
}


function Add-Failure {

    param (
        [Parameter(Mandatory = $true)]
        [string]$Item,

        [Parameter(Mandatory = $true)]
        [string]$Reason,

        [AllowNull()]
        $ExitCode = $null
    )

    $script:FailedItems += [PSCustomObject]@{
        Item     = $Item
        Reason   = $Reason
        ExitCode = $ExitCode
    }
}


function Get-DotNetPath {

    param (
        [Parameter(Mandatory = $true)]
        $Architecture
    )

    $Path = Join-Path $Architecture.Root "dotnet.exe"

    if (Test-Path $Path) {
        return $Path
    }

    return $null
}


function Get-FeatureBand {

    param (
        [Parameter(Mandatory = $true)]
        [version]$Version
    )

    return ([math]::Floor($Version.Build / 100) * 100)
}


function Get-SdkInventory {

    param (
        [Parameter(Mandatory = $true)]
        $Architecture
    )

    $Inventory = @()
    $DotNet = Get-DotNetPath -Architecture $Architecture

    if (-not $DotNet) {
        return $Inventory
    }

    try {

        $Output = & $DotNet --list-sdks 2>&1

        if ($LASTEXITCODE -ne 0) {
            return $Inventory
        }

        foreach ($Line in $Output) {

            $Text = [string]$Line

            if ($Text -match '^(\d+)\.(\d+)\.(\d+)\s+\[') {

                try {
                    $Version = [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
                }
                catch {
                    continue
                }

                if ($Version.Major -notin $script:SupportedMajors) {
                    continue
                }

                $FeatureBand = Get-FeatureBand -Version $Version

                $Inventory += [PSCustomObject]@{
                    Architecture = $Architecture.Name
                    Rid          = $Architecture.Rid
                    Root         = $Architecture.Root
                    Version      = $Version.ToString()
                    Major        = $Version.Major
                    Minor        = $Version.Minor
                    Build        = $Version.Build
                    FeatureBand  = $FeatureBand
                    BandName     = "$($Version.Major).$($Version.Minor).$FeatureBand"
                }
            }
        }
    }
    catch {
        return $Inventory
    }

    return $Inventory |
        Group-Object Architecture, Version |
        ForEach-Object { $_.Group | Select-Object -First 1 } |
        Sort-Object Architecture, Major, Minor, FeatureBand, {
            [version]$_.Version
        }
}


function Get-RuntimeInventoryFromFolders {

    param (
        [Parameter(Mandatory = $true)]
        $Architecture
    )

    $Inventory = @()

    $Families = @(
        @{
            Family = "Microsoft.NETCore.App"
            Path   = Join-Path $Architecture.Root "shared\Microsoft.NETCore.App"
        },
        @{
            Family = "Microsoft.AspNetCore.App"
            Path   = Join-Path $Architecture.Root "shared\Microsoft.AspNetCore.App"
        },
        @{
            Family = "Microsoft.WindowsDesktop.App"
            Path   = Join-Path $Architecture.Root "shared\Microsoft.WindowsDesktop.App"
        }
    )

    foreach ($FamilyInfo in $Families) {

        if (-not (Test-Path $FamilyInfo.Path)) {
            continue
        }

        $VersionDirectories = Get-ChildItem `
            -Path $FamilyInfo.Path `
            -Directory `
            -ErrorAction SilentlyContinue

        foreach ($Directory in $VersionDirectories) {

            try {
                $Version = [version]$Directory.Name
            }
            catch {
                continue
            }

            if ($Version.Major -notin $script:SupportedMajors) {
                continue
            }

            $Inventory += [PSCustomObject]@{
                Architecture = $Architecture.Name
                Rid          = $Architecture.Rid
                Root         = $Architecture.Root
                Family       = $FamilyInfo.Family
                Major        = $Version.Major
                Minor        = $Version.Minor
                Patch        = $Version.Build
                Version      = $Directory.Name
                Path         = $Directory.FullName
            }
        }
    }

    return $Inventory |
        Sort-Object Architecture, Family, Major, Minor, Patch
}


function Get-RuntimeInventory {

    param (
        [Parameter(Mandatory = $true)]
        $Architecture
    )

    $DotNet = Get-DotNetPath -Architecture $Architecture

    if ($DotNet) {

        try {

            $Output = & $DotNet --list-runtimes 2>&1
            $ExitCode = $LASTEXITCODE

            if ($ExitCode -eq 0) {

                $Inventory = @()

                foreach ($Line in $Output) {

                    $Text = [string]$Line

                    if (
                        $Text -match `
                        '^(Microsoft\.NETCore\.App|Microsoft\.AspNetCore\.App|Microsoft\.WindowsDesktop\.App)\s+(\d+)\.(\d+)\.(\d+)'
                    ) {

                        $Family = $Matches[1]
                        $Major  = [int]$Matches[2]
                        $Minor  = [int]$Matches[3]
                        $Patch  = [int]$Matches[4]

                        if ($Major -in $script:SupportedMajors) {

                            $Inventory += [PSCustomObject]@{
                                Architecture = $Architecture.Name
                                Rid          = $Architecture.Rid
                                Root         = $Architecture.Root
                                Family       = $Family
                                Major        = $Major
                                Minor        = $Minor
                                Patch        = $Patch
                                Version      = "$Major.$Minor.$Patch"
                                Path         = Join-Path `
                                    $Architecture.Root `
                                    "shared\$Family\$Major.$Minor.$Patch"
                            }
                        }
                    }
                }

                if ($Inventory.Count -gt 0) {

                    return $Inventory |
                        Group-Object Architecture, Family, Version |
                        ForEach-Object {
                            $_.Group | Select-Object -First 1
                        } |
                        Sort-Object Architecture, Family, Major, Minor, Patch
                }
            }
        }
        catch {
            # Fall through to folder detection.
        }
    }

    return @(Get-RuntimeInventoryFromFolders -Architecture $Architecture)
}


function Get-AllRuntimeInventory {

    $Inventory = @()

    foreach ($Architecture in $script:Architectures) {
        $Inventory += @(Get-RuntimeInventory -Architecture $Architecture)
    }

    return $Inventory |
        Sort-Object Architecture, Family, Major, Minor, Patch
}


function Get-AllSdkInventory {

    $Inventory = @()

    foreach ($Architecture in $script:Architectures) {
        $Inventory += @(Get-SdkInventory -Architecture $Architecture)
    }

    return $Inventory |
        Sort-Object Architecture, Major, Minor, FeatureBand, {
            [version]$_.Version
        }
}


function Get-ReleaseChannels {

    try {

        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.SecurityProtocolType]::Tls12

        Write-Host "Downloading current Microsoft .NET release metadata..."

        $Response = Invoke-RestMethod `
            -Uri $script:ReleaseIndexUrl `
            -UseBasicParsing `
            -ErrorAction Stop

        if (-not $Response.'releases-index') {
            throw "Microsoft release metadata did not contain releases-index."
        }

        return $Response.'releases-index'
    }
    catch {

        Write-Host ""
        Write-Host "ERROR: Unable to retrieve Microsoft .NET release metadata."
        Write-Host $_.Exception.Message

        return $null
    }
}


function Get-ChannelInfo {

    param (
        [Parameter(Mandatory = $true)]
        [array]$ReleaseChannels,

        [Parameter(Mandatory = $true)]
        [int]$Major,

        [int]$Minor = 0
    )

    $Channel = "$Major.$Minor"

    return $ReleaseChannels |
        Where-Object {
            $_.'channel-version' -eq $Channel
        } |
        Select-Object -First 1
}


function Get-ReleaseData {

    param (
        [Parameter(Mandatory = $true)]
        $ChannelInfo
    )

    $Url = [string]$ChannelInfo.'releases.json'

    if (-not $Url) {
        return $null
    }

    if ($script:ReleaseDataCache.ContainsKey($Url)) {
        return $script:ReleaseDataCache[$Url]
    }

    try {

        Write-Host "Retrieving release data:"
        Write-Host "  $Url"

        $Data = Invoke-RestMethod `
            -Uri $Url `
            -UseBasicParsing `
            -ErrorAction Stop

        $script:ReleaseDataCache[$Url] = $Data

        return $Data
    }
    catch {

        Write-Host "ERROR: Unable to retrieve channel release data."
        Write-Host $_.Exception.Message

        return $null
    }
}


function Get-LatestSdkInFeatureBand {

    param (
        [Parameter(Mandatory = $true)]
        $ReleaseData,

        [Parameter(Mandatory = $true)]
        $InstalledSdk,

        [Parameter(Mandatory = $true)]
        [string]$Rid
    )

    $Candidates = @()

    foreach ($Release in @($ReleaseData.releases)) {

        foreach ($Sdk in @($Release.sdks)) {

            if (-not $Sdk.version) {
                continue
            }

            try {
                $SdkVersion = [version]$Sdk.version
            }
            catch {
                continue
            }

            $SdkBand = Get-FeatureBand -Version $SdkVersion

            if (
                $SdkVersion.Major -ne $InstalledSdk.Major -or
                $SdkVersion.Minor -ne $InstalledSdk.Minor -or
                $SdkBand -ne $InstalledSdk.FeatureBand
            ) {
                continue
            }

            $Installer = @($Sdk.files) |
                Where-Object {
                    $_.rid -eq $Rid -and
                    $_.name -match '\.exe$'
                } |
                Select-Object -First 1

            if (-not $Installer) {
                continue
            }

            $Candidates += [PSCustomObject]@{
                Version     = $SdkVersion
                VersionText = [string]$Sdk.version
                Url         = [string]$Installer.url
                FileName    = [string]$Installer.name
            }
        }
    }

    return $Candidates |
        Sort-Object Version -Descending |
        Select-Object -First 1
}


function Get-RuntimeInstallerDetails {

    param (
        [Parameter(Mandatory = $true)]
        [string]$Family,

        [Parameter(Mandatory = $true)]
        [string]$Version,

        [Parameter(Mandatory = $true)]
        [string]$Rid
    )

    switch ($Family) {

        "Microsoft.NETCore.App" {

            return [PSCustomObject]@{
                DisplayName = ".NET Runtime"
                FileName    = "dotnet-runtime-$Version-$Rid.exe"
                Url         = "https://builds.dotnet.microsoft.com/dotnet/Runtime/$Version/dotnet-runtime-$Version-$Rid.exe"
            }
        }

        "Microsoft.AspNetCore.App" {

            return [PSCustomObject]@{
                DisplayName = "ASP.NET Core Runtime"
                FileName    = "aspnetcore-runtime-$Version-$Rid.exe"
                Url         = "https://builds.dotnet.microsoft.com/dotnet/aspnetcore/Runtime/$Version/aspnetcore-runtime-$Version-$Rid.exe"
            }
        }

        "Microsoft.WindowsDesktop.App" {

            return [PSCustomObject]@{
                DisplayName = "Windows Desktop Runtime"
                FileName    = "windowsdesktop-runtime-$Version-$Rid.exe"
                Url         = "https://builds.dotnet.microsoft.com/dotnet/WindowsDesktop/$Version/windowsdesktop-runtime-$Version-$Rid.exe"
            }
        }
    }

    return $null
}


function Get-HostingBundleInventory {

    $Inventory = @()

    foreach ($Entry in @(Get-UninstallEntries)) {

        if (-not $Entry.DisplayName) {
            continue
        }

        $Name = [string]$Entry.DisplayName

        if (
            $Name -notmatch '(?i)ASP\.NET Core.*Hosting Bundle' -and
            $Name -notmatch '(?i)\.NET.*Windows Server Hosting'
        ) {
            continue
        }

        $VersionText = $null

        if ($Name -match '(\d+)\.(\d+)\.(\d+)') {
            $VersionText = "$($Matches[1]).$($Matches[2]).$($Matches[3])"
        }
        elseif ($Entry.DisplayVersion -match '^(\d+)\.(\d+)\.(\d+)') {
            $VersionText = "$($Matches[1]).$($Matches[2]).$($Matches[3])"
        }

        if (-not $VersionText) {
            continue
        }

        try {
            $Version = [version]$VersionText
        }
        catch {
            continue
        }

        if ($Version.Major -notin $script:SupportedMajors) {
            continue
        }

        $Inventory += [PSCustomObject]@{
            DisplayName     = $Name
            Version         = $Version.ToString()
            Major           = $Version.Major
            Minor           = $Version.Minor
            Patch           = $Version.Build
            UninstallString = [string]$Entry.UninstallString
            PSChildName     = [string]$Entry.PSChildName
        }
    }

    return $Inventory |
        Group-Object DisplayName, Version |
        ForEach-Object {
            $_.Group | Select-Object -First 1
        } |
        Sort-Object Major, Minor, Patch
}


function Get-HostingBundleInstallerFromReleaseData {

    param (
        [Parameter(Mandatory = $true)]
        $ReleaseData,

        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    foreach ($Release in @($ReleaseData.releases)) {

        $ReleaseVersion = [string]$Release.'release-version'
        $AspNetVersion = $null

        if ($Release.'aspnetcore-runtime') {
            $AspNetVersion = [string]$Release.'aspnetcore-runtime'.version
        }

        if (
            $ReleaseVersion -ne $Version -and
            $AspNetVersion -ne $Version
        ) {
            continue
        }

        try {
            $Json = $Release | ConvertTo-Json -Depth 20 -Compress
        }
        catch {
            continue
        }

        $UrlMatch = [regex]::Match(
            $Json,
            'https://[^"]*dotnet-hosting[^"]*win\.exe',
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )

        if (-not $UrlMatch.Success) {
            continue
        }

        $Url = $UrlMatch.Value -replace '\\u0026', '&'

        return [PSCustomObject]@{
            Version  = $Version
            Url      = $Url
            FileName = Split-Path $Url -Leaf
        }
    }

    return $null
}


function Invoke-HostingBundleInstall {

    param (
        [Parameter(Mandatory = $true)]
        [string]$InstallerPath,

        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    try {

        Write-Host ""
        Write-Host "  Installing ASP.NET Core Hosting Bundle $Version..."
        Write-Host "  Context: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        Write-Host "  Installer: $InstallerPath"
        Write-Host "  Existing Major.Minor Hosting Bundle options will be preserved by the installer."

        $Process = Start-Process `
            -FilePath $InstallerPath `
            -ArgumentList @(
                "/install",
                "/quiet",
                "/norestart"
            ) `
            -Wait `
            -PassThru `
            -ErrorAction Stop

        $ExitCode = $Process.ExitCode

        Write-Host "  Installer exit code: $ExitCode"

        if ($ExitCode -eq 0) {

            return [PSCustomObject]@{
                Success        = $true
                RebootRequired = $false
                ExitCode       = $ExitCode
            }
        }

        if ($ExitCode -eq 3010) {

            return [PSCustomObject]@{
                Success        = $true
                RebootRequired = $true
                ExitCode       = $ExitCode
            }
        }

        return [PSCustomObject]@{
            Success        = $false
            RebootRequired = $false
            ExitCode       = $ExitCode
        }
    }
    catch {

        Write-Host "  ERROR: Hosting Bundle installer execution failed."
        Write-Host "  $($_.Exception.Message)"

        return [PSCustomObject]@{
            Success        = $false
            RebootRequired = $false
            ExitCode       = -1
        }
    }
}


function Test-UrlAvailable {

    param (
        [Parameter(Mandatory = $true)]
        [string]$Url
    )

    try {

        $Request = [System.Net.HttpWebRequest]::Create($Url)
        $Request.Method = "HEAD"
        $Request.AllowAutoRedirect = $true
        $Request.Timeout = 30000
        $Request.UserAgent = "DotNet-MachineScope"

        $Response = $Request.GetResponse()
        $StatusCode = [int]$Response.StatusCode
        $Response.Close()

        return ($StatusCode -ge 200 -and $StatusCode -lt 400)
    }
    catch {
        return $false
    }
}


function Invoke-Download {

    param (
        [Parameter(Mandatory = $true)]
        [string]$Url,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    try {

        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.SecurityProtocolType]::Tls12

        Write-Host "  Downloading:"
        Write-Host "  $Url"

        Invoke-WebRequest `
            -Uri $Url `
            -OutFile $Destination `
            -UseBasicParsing `
            -ErrorAction Stop

        if (-not (Test-Path $Destination)) {
            throw "Download completed but the installer file was not created."
        }

        $File = Get-Item $Destination

        if ($File.Length -lt 1MB) {
            throw "Downloaded file is unexpectedly small: $($File.Length) bytes."
        }

        Write-Host "  Downloaded: $([math]::Round($File.Length / 1MB, 2)) MB"

        return $true
    }
    catch {

        Write-Host "  ERROR: Download failed."
        Write-Host "  $($_.Exception.Message)"

        return $false
    }
}


function Invoke-DotNetExeInstall {

    param (
        [Parameter(Mandatory = $true)]
        [string]$InstallerPath,

        [Parameter(Mandatory = $true)]
        [string]$DisplayName,

        [Parameter(Mandatory = $true)]
        [string]$Version
    )

    try {

        Write-Host ""
        Write-Host "  Installing $DisplayName $Version machine-wide..."
        Write-Host "  Context: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
        Write-Host "  Installer: $InstallerPath"

        $Process = Start-Process `
            -FilePath $InstallerPath `
            -ArgumentList @(
                "/install",
                "/quiet",
                "/norestart"
            ) `
            -Wait `
            -PassThru `
            -ErrorAction Stop

        $ExitCode = $Process.ExitCode

        Write-Host "  Installer exit code: $ExitCode"

        if ($ExitCode -eq 0) {

            return [PSCustomObject]@{
                Success        = $true
                RebootRequired = $false
                ExitCode       = $ExitCode
            }
        }

        if ($ExitCode -eq 3010) {

            return [PSCustomObject]@{
                Success        = $true
                RebootRequired = $true
                ExitCode       = $ExitCode
            }
        }

        return [PSCustomObject]@{
            Success        = $false
            RebootRequired = $false
            ExitCode       = $ExitCode
        }
    }
    catch {

        Write-Host "  ERROR: Installer execution failed."
        Write-Host "  $($_.Exception.Message)"

        return [PSCustomObject]@{
            Success        = $false
            RebootRequired = $false
            ExitCode       = -1
        }
    }
}


function Get-HighestInstalledRuntime {

    param (
        [Parameter(Mandatory = $true)]
        [array]$Inventory,

        [Parameter(Mandatory = $true)]
        [string]$Architecture,

        [Parameter(Mandatory = $true)]
        [string]$Family,

        [Parameter(Mandatory = $true)]
        [int]$Major
    )

    $Match = $Inventory |
        Where-Object {
            $_.Architecture -eq $Architecture -and
            $_.Family -eq $Family -and
            $_.Major -eq $Major
        } |
        Sort-Object {
            [version]$_.Version
        } -Descending |
        Select-Object -First 1

    if ($Match) {
        return $Match.Version
    }

    return $null
}


function Get-UninstallEntries {

    $Roots = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )

    $Entries = @()

    foreach ($Root in $Roots) {

        $Entries += Get-ItemProperty `
            $Root `
            -ErrorAction SilentlyContinue
    }

    return $Entries
}


function Test-MachineRuntimeRegistration {

    param (
        [Parameter(Mandatory = $true)]
        [string]$Family,

        [Parameter(Mandatory = $true)]
        [string]$Version,

        [Parameter(Mandatory = $true)]
        [ValidateSet("x64", "x86")]
        [string]$Architecture
    )

    $EscapedVersion = [regex]::Escape($Version)
    $EscapedArch = [regex]::Escape($Architecture)

    switch ($Family) {

        "Microsoft.NETCore.App" {
            $Patterns = @(
                "^Microsoft \.NET Runtime - $EscapedVersion \($EscapedArch\)$"
            )
        }

        "Microsoft.AspNetCore.App" {
            $Patterns = @(
                "^Microsoft ASP\.NET Core $EscapedVersion Shared Framework \($EscapedArch\)$",
                "^Microsoft ASP\.NET Core $EscapedVersion - Shared Framework \($EscapedArch\)$"
            )
        }

        "Microsoft.WindowsDesktop.App" {
            $Patterns = @(
                "^Microsoft Windows Desktop Runtime - $EscapedVersion \($EscapedArch\)$"
            )
        }

        default {
            return $false
        }
    }

    $Entries = @(Get-UninstallEntries)

    foreach ($Entry in $Entries) {

        foreach ($Pattern in $Patterns) {

            if ($Entry.DisplayName -match $Pattern) {
                return $true
            }
        }
    }

    return $false
}


function Get-RuntimeBundleEntries {

    param (
        [Parameter(Mandatory = $true)]
        [string]$Family,

        [Parameter(Mandatory = $true)]
        [string]$Version,

        [Parameter(Mandatory = $true)]
        [ValidateSet("x64", "x86")]
        [string]$Architecture
    )

    $EscapedVersion = [regex]::Escape($Version)
    $EscapedArch = [regex]::Escape($Architecture)

    switch ($Family) {

        "Microsoft.NETCore.App" {
            $Patterns = @(
                "^Microsoft \.NET Runtime - $EscapedVersion \($EscapedArch\)$"
            )
        }

        "Microsoft.AspNetCore.App" {
            $Patterns = @(
                "^Microsoft ASP\.NET Core $EscapedVersion Shared Framework \($EscapedArch\)$",
                "^Microsoft ASP\.NET Core $EscapedVersion - Shared Framework \($EscapedArch\)$"
            )
        }

        "Microsoft.WindowsDesktop.App" {
            $Patterns = @(
                "^Microsoft Windows Desktop Runtime - $EscapedVersion \($EscapedArch\)$"
            )
        }

        default {
            return @()
        }
    }

    $BundleMatches = @()

    foreach ($Entry in @(Get-UninstallEntries)) {

        if (-not $Entry.DisplayName) {
            continue
        }

        $NameMatched = $false

        foreach ($Pattern in $Patterns) {

            if ([string]$Entry.DisplayName -match $Pattern) {
                $NameMatched = $true
                break
            }
        }

        if (-not $NameMatched) {
            continue
        }

        $UninstallString = [string]$Entry.UninstallString
        $QuietUninstallString = [string]$Entry.QuietUninstallString

        # WiX/Burn bundle registrations typically have a non-MSI uninstall
        # command and may expose Bundle* registry values. Exclude MSI child
        # packages because those are handled separately.
        $LooksLikeMsi = (
            $UninstallString -match '(?i)\bmsiexec(?:\.exe)?\b' -or
            $QuietUninstallString -match '(?i)\bmsiexec(?:\.exe)?\b'
        )

        if ($LooksLikeMsi) {
            continue
        }

        $HasBundleEvidence = (
            -not [string]::IsNullOrWhiteSpace($QuietUninstallString) -or
            -not [string]::IsNullOrWhiteSpace($UninstallString) -or
            $null -ne $Entry.BundleProviderKey -or
            $null -ne $Entry.BundleVersion
        )

        if (-not $HasBundleEvidence) {
            continue
        }

        $BundleMatches += [PSCustomObject]@{
            DisplayName          = [string]$Entry.DisplayName
            DisplayVersion       = [string]$Entry.DisplayVersion
            PSChildName          = [string]$Entry.PSChildName
            QuietUninstallString = $QuietUninstallString
            UninstallString      = $UninstallString
        }
    }

    return @(
        $BundleMatches |
            Sort-Object DisplayName, DisplayVersion, PSChildName -Unique
    )
}


function Split-ExecutableCommandLine {

    param (
        [Parameter(Mandatory = $true)]
        [string]$CommandLine
    )

    $CommandLine = $CommandLine.Trim()

    if ($CommandLine -match '^"([^"]+)"\s*(.*)$') {

        return [PSCustomObject]@{
            FilePath  = $Matches[1]
            Arguments = $Matches[2]
        }
    }

    if ($CommandLine -match '^(\S+)\s*(.*)$') {

        return [PSCustomObject]@{
            FilePath  = $Matches[1]
            Arguments = $Matches[2]
        }
    }

    return $null
}


function Invoke-RuntimeBundleUninstall {

    param (
        [Parameter(Mandatory = $true)]
        $BundleEntry
    )

    $CommandLine = $null

    if (-not [string]::IsNullOrWhiteSpace($BundleEntry.QuietUninstallString)) {
        $CommandLine = [string]$BundleEntry.QuietUninstallString
    }
    elseif (-not [string]::IsNullOrWhiteSpace($BundleEntry.UninstallString)) {
        $CommandLine = [string]$BundleEntry.UninstallString
    }

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {

        return [PSCustomObject]@{
            Success        = $false
            RebootRequired = $false
            ExitCode       = -1
            Reason         = "Bundle uninstall command was empty."
        }
    }

    $Parsed = Split-ExecutableCommandLine -CommandLine $CommandLine

    if (-not $Parsed) {

        return [PSCustomObject]@{
            Success        = $false
            RebootRequired = $false
            ExitCode       = -1
            Reason         = "Unable to parse bundle uninstall command."
        }
    }

    $FilePath = [string]$Parsed.FilePath
    $Arguments = [string]$Parsed.Arguments

    # Ensure silent/non-restarting behaviour for known .NET EXE bundles.
    if ($FilePath -match '(?i)\.exe$') {

        if ($Arguments -notmatch '(?i)(^|\s)/(quiet|q)(\s|$)') {
            $Arguments = "$Arguments /quiet".Trim()
        }

        if ($Arguments -notmatch '(?i)(^|\s)/norestart(\s|$)') {
            $Arguments = "$Arguments /norestart".Trim()
        }
    }

    Write-Host "  Uninstalling registered .NET bundle:"
    Write-Host "  $($BundleEntry.DisplayName)"
    Write-Host "  Version: $($BundleEntry.DisplayVersion)"
    Write-Host "  Command: `"$FilePath`" $Arguments"

    try {

        $Process = Start-Process `
            -FilePath $FilePath `
            -ArgumentList $Arguments `
            -Wait `
            -PassThru `
            -ErrorAction Stop

        $ExitCode = $Process.ExitCode

        Write-Host "  Bundle exit code: $ExitCode"

        if ($ExitCode -eq 0) {

            return [PSCustomObject]@{
                Success        = $true
                RebootRequired = $false
                ExitCode       = $ExitCode
                Reason         = $null
            }
        }

        if ($ExitCode -eq 3010) {

            return [PSCustomObject]@{
                Success        = $true
                RebootRequired = $true
                ExitCode       = $ExitCode
                Reason         = $null
            }
        }

        return [PSCustomObject]@{
            Success        = $false
            RebootRequired = $false
            ExitCode       = $ExitCode
            Reason         = "Bundle uninstaller returned a failure exit code."
        }
    }
    catch {

        Write-Host "  ERROR: Bundle uninstall failed."
        Write-Host "  $($_.Exception.Message)"

        return [PSCustomObject]@{
            Success        = $false
            RebootRequired = $false
            ExitCode       = -1
            Reason         = $_.Exception.Message
        }
    }
}


function Get-RuntimeMsiEntries {

    param (
        [Parameter(Mandatory = $true)]
        [string]$Family,

        [Parameter(Mandatory = $true)]
        [string]$Version,

        [Parameter(Mandatory = $true)]
        [ValidateSet("x64", "x86")]
        [string]$Architecture
    )

    $EscapedVersion = [regex]::Escape($Version)
    $EscapedArch = [regex]::Escape($Architecture)

    switch ($Family) {

        "Microsoft.NETCore.App" {
            $Patterns = @(
                "^Microsoft \.NET Runtime - $EscapedVersion \($EscapedArch\)$"
            )
        }

        "Microsoft.AspNetCore.App" {
            $Patterns = @(
                "^Microsoft ASP\.NET Core $EscapedVersion Shared Framework \($EscapedArch\)$",
                "^Microsoft ASP\.NET Core $EscapedVersion - Shared Framework \($EscapedArch\)$"
            )
        }

        "Microsoft.WindowsDesktop.App" {
            $Patterns = @(
                "^Microsoft Windows Desktop Runtime - $EscapedVersion \($EscapedArch\)$"
            )
        }

        default {
            return @()
        }
    }

    # IMPORTANT:
    # Do not use a variable named $Matches here. $Matches is an automatic
    # PowerShell variable populated by the -match operator and would overwrite
    # our collection during regex evaluation.
    $MsiMatches = @()

    foreach ($Entry in @(Get-UninstallEntries)) {

        if (-not $Entry.DisplayName) {
            continue
        }

        $NameMatched = $false

        foreach ($Pattern in $Patterns) {

            if ($Entry.DisplayName -match $Pattern) {
                $NameMatched = $true
                break
            }
        }

        if (-not $NameMatched) {
            continue
        }

        $ProductCode = [string]$Entry.PSChildName
        $UninstallString = [string]$Entry.UninstallString

        if (
            $ProductCode -match '^\{[0-9A-Fa-f-]{36}\}$' -and
            $UninstallString -match '(?i)msiexec'
        ) {

            $MsiMatches += [PSCustomObject]@{
                DisplayName = [string]$Entry.DisplayName
                ProductCode = $ProductCode
                Uninstall   = $UninstallString
            }
        }
    }

    return @(
        $MsiMatches |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace($_.ProductCode)
            } |
            Sort-Object ProductCode -Unique
    )
}


function Invoke-MsiUninstall {

    param (
        [Parameter(Mandatory = $true)]
        [string]$ProductCode,

        [Parameter(Mandatory = $true)]
        [string]$DisplayName
    )

    try {

        Write-Host "  Uninstalling:"
        Write-Host "  $DisplayName"
        Write-Host "  Product code: $ProductCode"

        $Process = Start-Process `
            -FilePath "msiexec.exe" `
            -ArgumentList "/x $ProductCode /qn /norestart" `
            -Wait `
            -PassThru `
            -ErrorAction Stop

        $ExitCode = $Process.ExitCode

        Write-Host "  MSI exit code: $ExitCode"

        if ($ExitCode -in @(0, 1605)) {

            return [PSCustomObject]@{
                Success        = $true
                RebootRequired = $false
                ExitCode       = $ExitCode
            }
        }

        if ($ExitCode -eq 3010) {

            return [PSCustomObject]@{
                Success        = $true
                RebootRequired = $true
                ExitCode       = $ExitCode
            }
        }

        return [PSCustomObject]@{
            Success        = $false
            RebootRequired = $false
            ExitCode       = $ExitCode
        }
    }
    catch {

        return [PSCustomObject]@{
            Success        = $false
            RebootRequired = $false
            ExitCode       = -1
        }
    }
}


function Get-SystemBootTime {

    try {

        return (
            Get-CimInstance `
                -ClassName Win32_OperatingSystem `
                -ErrorAction Stop
        ).LastBootUpTime
    }
    catch {

        try {
            return (Get-WmiObject Win32_OperatingSystem -ErrorAction Stop).ConvertToDateTime(
                (Get-WmiObject Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
            )
        }
        catch {
            return $null
        }
    }
}


function Set-DotNetRebootMarker {

    param (
        [string]$Reason = ".NET servicing returned reboot required."
    )

    try {

        if (-not (Test-Path $script:StateRoot)) {

            New-Item `
                -Path $script:StateRoot `
                -ItemType Directory `
                -Force `
                -ErrorAction Stop |
                Out-Null
        }

        $BootTime = Get-SystemBootTime

        $State = [PSCustomObject]@{
            CreatedAt = (Get-Date).ToString("o")
            BootTime  = if ($BootTime) { $BootTime.ToString("o") } else { $null }
            Reason    = $Reason
        }

        $State |
            ConvertTo-Json |
            Set-Content `
                -Path $script:RebootMarkerFile `
                -Encoding UTF8 `
                -Force

        Write-Host "Reboot marker written:"
        Write-Host "  $script:RebootMarkerFile"
    }
    catch {

        Write-Host "WARNING: Unable to write .NET reboot marker."
        Write-Host $_.Exception.Message
    }
}


function Test-DotNetPreviousRunRebootPending {

    if (-not (Test-Path $script:RebootMarkerFile)) {
        return $false
    }

    try {

        $State = Get-Content `
            -Path $script:RebootMarkerFile `
            -Raw `
            -ErrorAction Stop |
            ConvertFrom-Json

        $CurrentBoot = Get-SystemBootTime

        if (
            $State.BootTime -and
            $CurrentBoot
        ) {

            $MarkerBoot = [datetime]$State.BootTime

            if (
                [math]::Abs(
                    ($CurrentBoot - $MarkerBoot).TotalSeconds
                ) -lt 5
            ) {

                return $true
            }

            # Boot time changed, so the requested reboot has happened.
            Remove-Item `
                -Path $script:RebootMarkerFile `
                -Force `
                -ErrorAction SilentlyContinue

            return $false
        }

        # If boot time cannot be established, preserve the marker rather than
        # falsely declaring the reboot complete.
        return $true
    }
    catch {

        Write-Host "WARNING: Unable to evaluate .NET reboot marker."
        Write-Host $_.Exception.Message

        return $false
    }
}


function Start-DotNetTranscript {

    try {

        if (-not (Test-Path $script:LogRoot)) {

            New-Item `
                -Path $script:LogRoot `
                -ItemType Directory `
                -Force `
                -ErrorAction Stop |
                Out-Null
        }

        Start-Transcript `
            -Path $script:LogFile `
            -Append `
            -Force `
            -ErrorAction Stop |
            Out-Null

        $script:TranscriptStarted = $true

        Write-Host "Persistent log:"
        Write-Host "  $script:LogFile"
        Write-Host ""
    }
    catch {

        $script:TranscriptStarted = $false

        Write-Host "WARNING:"
        Write-Host "Unable to start persistent transcript logging."
        Write-Host $_.Exception.Message
        Write-Host ""
    }
}


function Stop-DotNetTranscript {

    if (-not $script:TranscriptStarted) {
        return
    }

    try {

        Write-Host ""
        Write-Host "Persistent log:"
        Write-Host "  $script:LogFile"

        Stop-Transcript `
            -ErrorAction SilentlyContinue |
            Out-Null
    }
    catch {
        # Do not change the servicing result because transcript shutdown failed.
    }
    finally {
        $script:TranscriptStarted = $false
    }
}


# ============================================================
# START
# ============================================================

Start-DotNetTranscript

$PreviousRunRebootPending = Test-DotNetPreviousRunRebootPending

Write-Section `
    ".NET SDK and Runtime Machine-Scope Detection and Update"

Write-Host "Run started:"
Write-Host "  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
Write-Host ""

Write-Host "Execution context:"
Write-Host "  User: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Host "  PowerShell: $($PSVersionTable.PSVersion)"
Write-Host "  OS: $([Environment]::OSVersion.VersionString)"
Write-Host "  Previous .NET run pending reboot: $PreviousRunRebootPending"
Write-Host ""

if (
    [System.Security.Principal.WindowsIdentity]::GetCurrent().Name `
    -ne "NT AUTHORITY\SYSTEM"
) {

    Write-Host "WARNING:"
    Write-Host "This script is intended to run as NT AUTHORITY\SYSTEM."
    Write-Host "Interactive execution may trigger UAC prompts from Microsoft installers."
    Write-Host ""
}


# ============================================================
# TEMP DIRECTORY
# ============================================================

if (Test-Path $TempRoot) {

    Remove-Item `
        $TempRoot `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue
}

New-Item `
    -Path $TempRoot `
    -ItemType Directory `
    -Force |
    Out-Null


# ============================================================
# RELEASE METADATA
# ============================================================

Write-Section `
    "Retrieving Latest Microsoft .NET Versions"

$ReleaseChannels = @(Get-ReleaseChannels)

if ($ReleaseChannels.Count -eq 0) {

    Write-Host "RESULT: FAILURE"

    Remove-Item `
        $TempRoot `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue

    Stop-DotNetTranscript


    exit 1
}


# ============================================================
# INITIAL INVENTORY
# ============================================================

Write-Section `
    "Initial .NET SDK Inventory"

$InitialSdkInventory = @(Get-AllSdkInventory)

if ($InitialSdkInventory.Count -eq 0) {

    Write-Host "No supported .NET SDKs were detected."
}
else {

    foreach ($Sdk in $InitialSdkInventory) {

        Write-Host `
            "$($Sdk.Architecture) | SDK $($Sdk.Version) | Feature band $($Sdk.BandName)xx"
    }
}


Write-Section `
    "Initial .NET Runtime Inventory"

$InitialRuntimeInventory = @(Get-AllRuntimeInventory)

if ($InitialRuntimeInventory.Count -eq 0) {

    Write-Host "No supported .NET shared runtimes were detected."
}
else {

    foreach ($Runtime in $InitialRuntimeInventory) {

        Write-Host `
            "$($Runtime.Architecture) | $($Runtime.Family) $($Runtime.Version)"
    }
}

if (
    $InitialSdkInventory.Count -eq 0 -and
    $InitialRuntimeInventory.Count -eq 0
) {

    Write-Host ""
    Write-Host "Nothing to service."
    Write-Host "RESULT: SUCCESS"

    Remove-Item `
        $TempRoot `
        -Recurse `
        -Force `
        -ErrorAction SilentlyContinue

    Stop-DotNetTranscript


    exit 0
}


# ============================================================
# PHASE 1 - SERVICE SDK FEATURE BANDS
# ============================================================

Write-Section `
    "Phase 1 - Servicing Installed .NET SDK Feature Bands"

$SdkGroups = $InitialSdkInventory |
    Group-Object Architecture, Major, Minor, FeatureBand

foreach ($Group in $SdkGroups) {

    $InstalledInBand = $Group.Group |
        Sort-Object {
            [version]$_.Version
        } -Descending

    $CurrentSdk = $InstalledInBand |
        Select-Object -First 1

    $DisplayKey = `
        "$($CurrentSdk.Architecture) SDK $($CurrentSdk.BandName)xx"

    $DetectedSdks += $DisplayKey

    Write-Section `
        "Checking $DisplayKey"

    Write-Host "Installed:       $($CurrentSdk.Version)"
    Write-Host "Feature band:    $($CurrentSdk.BandName)xx"
    Write-Host "Architecture:    $($CurrentSdk.Architecture)"

    $ChannelInfo = Get-ChannelInfo `
        -ReleaseChannels $ReleaseChannels `
        -Major $CurrentSdk.Major `
        -Minor $CurrentSdk.Minor

    if (-not $ChannelInfo) {

        Add-Failure `
            -Item $DisplayKey `
            -Reason "Release metadata for $($CurrentSdk.Major).$($CurrentSdk.Minor) was not found."

        continue
    }

    $SupportPhase = [string]$ChannelInfo.'support-phase'
    $EolDate = [string]$ChannelInfo.'eol-date'

    Write-Host "Support phase:   $SupportPhase"

    if ($EolDate) {
        Write-Host "EOL date:        $EolDate"
    }

    if ($SupportPhase -eq "eol") {

        Write-Host "Lifecycle:       END OF SUPPORT"
        $EOLItems += $DisplayKey
    }
    else {

        Write-Host "Lifecycle:       Supported / servicing"
    }

    $ReleaseData = Get-ReleaseData `
        -ChannelInfo $ChannelInfo

    if (-not $ReleaseData) {

        Add-Failure `
            -Item $DisplayKey `
            -Reason "Unable to retrieve detailed release metadata."

        continue
    }

    $LatestSdk = Get-LatestSdkInFeatureBand `
        -ReleaseData $ReleaseData `
        -InstalledSdk $CurrentSdk `
        -Rid $CurrentSdk.Rid

    if (-not $LatestSdk) {

        Add-Failure `
            -Item $DisplayKey `
            -Reason "No Windows EXE SDK release was found in the installed feature band."

        continue
    }

    Write-Host "Latest in band:  $($LatestSdk.VersionText)"

    if (
        [version]$CurrentSdk.Version -ge
        [version]$LatestSdk.VersionText
    ) {

        Write-Host ""
        Write-Host "Result: ALREADY CURRENT"

        $CurrentSdks += $DisplayKey
        continue
    }

    Write-Host ""
    Write-Host "SDK update available:"
    Write-Host "  $($CurrentSdk.Version) -> $($LatestSdk.VersionText)"

    if (-not (Test-UrlAvailable -Url $LatestSdk.Url)) {

        Add-Failure `
            -Item $DisplayKey `
            -Reason "Microsoft SDK installer URL was unavailable."

        continue
    }

    $InstallerPath = Join-Path `
        $TempRoot `
        "$($CurrentSdk.Architecture)-$($LatestSdk.FileName)"

    if (
        -not (
            Invoke-Download `
                -Url $LatestSdk.Url `
                -Destination $InstallerPath
        )
    ) {

        Add-Failure `
            -Item $DisplayKey `
            -Reason "SDK installer download failed."

        continue
    }

    $InstallResult = Invoke-DotNetExeInstall `
        -InstallerPath $InstallerPath `
        -DisplayName ".NET SDK [$($CurrentSdk.Architecture)]" `
        -Version $LatestSdk.VersionText

    if (-not $InstallResult.Success) {

        Add-Failure `
            -Item $DisplayKey `
            -Reason "Official SDK EXE installer failed." `
            -ExitCode $InstallResult.ExitCode

        continue
    }

    if ($InstallResult.RebootRequired) {
        $RebootRequired = $true
        Set-DotNetRebootMarker `
            -Reason ".NET installer returned 3010 during servicing."
    }

    Start-Sleep -Seconds 2

    $ArchitectureObject = $Architectures |
        Where-Object {
            $_.Name -eq $CurrentSdk.Architecture
        } |
        Select-Object -First 1

    $AfterSdkInventory = @(
        Get-SdkInventory `
            -Architecture $ArchitectureObject
    )

    $ExpectedSdk = $AfterSdkInventory |
        Where-Object {
            $_.Version -eq $LatestSdk.VersionText
        } |
        Select-Object -First 1

    if ($ExpectedSdk) {

        Write-Host ""
        Write-Host "Verification: SUCCESS"
        Write-Host "$($LatestSdk.VersionText) is installed."

        $UpdatedSdks += `
            "$DisplayKey | $($CurrentSdk.Version) -> $($LatestSdk.VersionText)"
    }
    else {

        Add-Failure `
            -Item $DisplayKey `
            -Reason "Expected SDK $($LatestSdk.VersionText) was not detected after installation." `
            -ExitCode $InstallResult.ExitCode
    }
}


# ============================================================
# PHASE 2 - SERVICE INSTALLED ASP.NET CORE HOSTING BUNDLES
#
# The Hosting Bundle can own/reference both x64 and x86
# .NET/ASP.NET shared runtimes. Service it before attempting
# to remove superseded runtime MSIs.
# ============================================================

Write-Section `
    "Phase 2 - Servicing Installed ASP.NET Core Hosting Bundles"

$HostingBundleInventory = @(Get-HostingBundleInventory)

if ($HostingBundleInventory.Count -eq 0) {

    Write-Host "No ASP.NET Core Hosting Bundles were detected."
}
else {

    $HostingGroups = $HostingBundleInventory |
        Group-Object Major, Minor

    foreach ($Group in $HostingGroups) {

        $CurrentBundle = $Group.Group |
            Sort-Object {
                [version]$_.Version
            } -Descending |
            Select-Object -First 1

        $DisplayKey = `
            "ASP.NET Core Hosting Bundle $($CurrentBundle.Major).$($CurrentBundle.Minor)"

        $DetectedHostingBundles += $DisplayKey

        Write-Section `
            "Checking $DisplayKey"

        Write-Host "Installed high:  $($CurrentBundle.Version)"

        $ChannelInfo = Get-ChannelInfo `
            -ReleaseChannels $ReleaseChannels `
            -Major $CurrentBundle.Major `
            -Minor $CurrentBundle.Minor

        if (-not $ChannelInfo) {

            Add-Failure `
                -Item $DisplayKey `
                -Reason "Release metadata for $($CurrentBundle.Major).$($CurrentBundle.Minor) was not found."

            continue
        }

        $LatestVersion = [string]$ChannelInfo.'latest-runtime'

        Write-Host "Latest:          $LatestVersion"

        if (-not $LatestVersion) {

            Add-Failure `
                -Item $DisplayKey `
                -Reason "latest-runtime was missing from Microsoft metadata."

            continue
        }

        if (
            [version]$CurrentBundle.Version -ge
            [version]$LatestVersion
        ) {

            Write-Host ""
            Write-Host "Result: ALREADY CURRENT"

            $CurrentHostingBundles += $DisplayKey
            continue
        }

        $ReleaseData = Get-ReleaseData `
            -ChannelInfo $ChannelInfo

        if (-not $ReleaseData) {

            Add-Failure `
                -Item $DisplayKey `
                -Reason "Unable to retrieve detailed release metadata for Hosting Bundle."

            continue
        }

        $HostingInstaller = Get-HostingBundleInstallerFromReleaseData `
            -ReleaseData $ReleaseData `
            -Version $LatestVersion

        if (-not $HostingInstaller) {

            Add-Failure `
                -Item $DisplayKey `
                -Reason "Hosting Bundle installer URL was not found in Microsoft release metadata."

            continue
        }

        Write-Host ""
        Write-Host "Hosting Bundle update available:"
        Write-Host "  $($CurrentBundle.Version) -> $LatestVersion"

        if (-not (Test-UrlAvailable -Url $HostingInstaller.Url)) {

            Add-Failure `
                -Item $DisplayKey `
                -Reason "Microsoft Hosting Bundle installer URL was unavailable."

            continue
        }

        $InstallerPath = Join-Path `
            $TempRoot `
            $HostingInstaller.FileName

        if (
            -not (
                Invoke-Download `
                    -Url $HostingInstaller.Url `
                    -Destination $InstallerPath
            )
        ) {

            Add-Failure `
                -Item $DisplayKey `
                -Reason "Hosting Bundle installer download failed."

            continue
        }

        $InstallResult = Invoke-HostingBundleInstall `
            -InstallerPath $InstallerPath `
            -Version $LatestVersion

        if (-not $InstallResult.Success) {

            Add-Failure `
                -Item $DisplayKey `
                -Reason "Official Hosting Bundle EXE installer failed." `
                -ExitCode $InstallResult.ExitCode

            continue
        }

        if ($InstallResult.RebootRequired) {
            $RebootRequired = $true
        }

        Start-Sleep -Seconds 2

        $AfterHostingInventory = @(Get-HostingBundleInventory)

        $LatestBundle = $AfterHostingInventory |
            Where-Object {
                $_.Major -eq $CurrentBundle.Major -and
                $_.Minor -eq $CurrentBundle.Minor -and
                [version]$_.Version -ge [version]$LatestVersion
            } |
            Select-Object -First 1

        if ($LatestBundle) {

            Write-Host ""
            Write-Host "Verification: SUCCESS"
            Write-Host "Hosting Bundle $LatestVersion is installed."

            $UpdatedHostingBundles += `
                "$DisplayKey | $($CurrentBundle.Version) -> $LatestVersion"
        }
        else {

            Add-Failure `
                -Item $DisplayKey `
                -Reason "Expected Hosting Bundle $LatestVersion was not detected after installation." `
                -ExitCode $InstallResult.ExitCode
        }
    }
}


# ============================================================
# PHASE 3 - RE-DETECT RUNTIMES AFTER SDK/HOSTING SERVICING
# ============================================================

Write-Section `
    "Phase 3 - Runtime Inventory After SDK/Hosting Servicing"

$RuntimeInventory = @(Get-AllRuntimeInventory)

if ($RuntimeInventory.Count -eq 0) {

    Write-Host "No supported .NET shared runtimes were detected after SDK servicing."
}
else {

    foreach ($Runtime in $RuntimeInventory) {

        Write-Host `
            "$($Runtime.Architecture) | $($Runtime.Family) $($Runtime.Version)"
    }
}


# ============================================================
# PHASE 4 - SERVICE RUNTIME FAMILIES
# ============================================================

Write-Section `
    "Phase 4 - Servicing Installed Runtime Families"

$RuntimeGroups = $RuntimeInventory |
    Group-Object Architecture, Family, Major

foreach ($Group in $RuntimeGroups) {

    $Sample = $Group.Group |
        Select-Object -First 1

    $Major = [int]$Sample.Major

    $DisplayKey = `
        "$($Sample.Architecture) | $($Sample.Family) $Major"

    $DetectedFamilies += $DisplayKey

    $ChannelInfo = Get-ChannelInfo `
        -ReleaseChannels $ReleaseChannels `
        -Major $Major `
        -Minor $Sample.Minor

    if (-not $ChannelInfo) {

        Add-Failure `
            -Item $DisplayKey `
            -Reason "Release metadata for $Major.$($Sample.Minor) was not found."

        continue
    }

    $LatestVersion = [string]$ChannelInfo.'latest-runtime'
    $SupportPhase = [string]$ChannelInfo.'support-phase'
    $EolDate = [string]$ChannelInfo.'eol-date'

    Write-Section `
        "Checking $DisplayKey"

    $CurrentHighest = Get-HighestInstalledRuntime `
        -Inventory $RuntimeInventory `
        -Architecture $Sample.Architecture `
        -Family $Sample.Family `
        -Major $Major

    Write-Host "Family:          $($Sample.Family)"
    Write-Host "Architecture:    $($Sample.Architecture)"
    Write-Host "Installed high:  $CurrentHighest"
    Write-Host "Latest:          $LatestVersion"
    Write-Host "Support phase:   $SupportPhase"

    if ($EolDate) {
        Write-Host "EOL date:        $EolDate"
    }

    if ($SupportPhase -eq "eol") {

        Write-Host "Lifecycle:       END OF SUPPORT"
        $EOLItems += $DisplayKey
    }
    else {

        Write-Host "Lifecycle:       Supported / servicing"
    }

    if (-not $LatestVersion) {

        Add-Failure `
            -Item $DisplayKey `
            -Reason "latest-runtime was missing from Microsoft metadata."

        continue
    }

    $Details = Get-RuntimeInstallerDetails `
        -Family $Sample.Family `
        -Version $LatestVersion `
        -Rid $Sample.Rid

    if (-not $Details) {
        continue
    }

    $LatestInstalled = (
        $CurrentHighest -and
        ([version]$CurrentHighest -ge [version]$LatestVersion)
    )

    $MachineRegistered = Test-MachineRuntimeRegistration `
        -Family $Sample.Family `
        -Version $LatestVersion `
        -Architecture $Sample.Architecture

    Write-Host "Machine registered: $MachineRegistered"

    if ($LatestInstalled -and $MachineRegistered) {

        Write-Host ""
        Write-Host "Result: ALREADY CURRENT"
        Write-Host "No runtime installer execution required."

        $CurrentFamilies += $DisplayKey
        continue
    }

    if ($LatestInstalled -and -not $MachineRegistered) {

        Write-Host ""
        Write-Host "Latest runtime is active, but machine-wide registration"
        Write-Host "is missing. Running the official EXE to repair registration."
    }
    else {

        Write-Host ""
        Write-Host "A newer servicing release is available."
    }

    Write-Host ""
    Write-Host "Validating Microsoft installer URL..."

    if (-not (Test-UrlAvailable -Url $Details.Url)) {

        Add-Failure `
            -Item $DisplayKey `
            -Reason "Microsoft runtime installer URL was unavailable."

        continue
    }

    $InstallerPath = Join-Path `
        $TempRoot `
        "$($Sample.Architecture)-$($Details.FileName)"

    if (
        -not (
            Invoke-Download `
                -Url $Details.Url `
                -Destination $InstallerPath
        )
    ) {

        Add-Failure `
            -Item $DisplayKey `
            -Reason "Runtime installer download failed."

        continue
    }

    $InstallResult = Invoke-DotNetExeInstall `
        -InstallerPath $InstallerPath `
        -DisplayName "$($Details.DisplayName) [$($Sample.Architecture)]" `
        -Version $LatestVersion

    if (-not $InstallResult.Success) {

        Add-Failure `
            -Item $DisplayKey `
            -Reason "Official runtime EXE installer failed." `
            -ExitCode $InstallResult.ExitCode

        continue
    }

    if ($InstallResult.RebootRequired) {
        $RebootRequired = $true
        Set-DotNetRebootMarker `
            -Reason ".NET installer returned 3010 during servicing."
    }

    Start-Sleep -Seconds 2

    $ArchitectureObject = $Architectures |
        Where-Object {
            $_.Name -eq $Sample.Architecture
        } |
        Select-Object -First 1

    $AfterInstallInventory = @(
        Get-RuntimeInventory `
            -Architecture $ArchitectureObject
    )

    $HighestAfter = Get-HighestInstalledRuntime `
        -Inventory $AfterInstallInventory `
        -Architecture $Sample.Architecture `
        -Family $Sample.Family `
        -Major $Major

    Write-Host ""
    Write-Host "Highest version after install: $HighestAfter"

    if (
        $HighestAfter -and
        ([version]$HighestAfter -ge [version]$LatestVersion)
    ) {

        Write-Host "Verification: SUCCESS"

        if (
            $CurrentHighest -and
            ([version]$CurrentHighest -ge [version]$LatestVersion)
        ) {

            $CurrentFamilies += $DisplayKey
        }
        else {

            $UpdatedFamilies += `
                "$DisplayKey | $CurrentHighest -> $LatestVersion"
        }
    }
    else {

        Add-Failure `
            -Item $DisplayKey `
            -Reason "Expected runtime $LatestVersion was not detected after installation." `
            -ExitCode $InstallResult.ExitCode
    }
}


# ============================================================
# PHASE 5 - REMOVE SUPERSEDED PATCH-LEVEL SHARED RUNTIMES
# ============================================================

Write-Section `
    "Phase 5 - Removing Superseded Shared Runtime Patches"

$BeforeCleanupInventory = @(Get-AllRuntimeInventory)

$CleanupGroups = $BeforeCleanupInventory |
    Group-Object Architecture, Family, Major

foreach ($Group in $CleanupGroups) {

    $Sample = $Group.Group |
        Select-Object -First 1

    $ChannelInfo = Get-ChannelInfo `
        -ReleaseChannels $ReleaseChannels `
        -Major $Sample.Major `
        -Minor $Sample.Minor

    if (-not $ChannelInfo) {
        continue
    }

    $LatestVersion = [string]$ChannelInfo.'latest-runtime'

    if (-not $LatestVersion) {
        continue
    }

    $LatestExists = $Group.Group |
        Where-Object {
            [version]$_.Version -ge [version]$LatestVersion
        } |
        Select-Object -First 1

    if (-not $LatestExists) {

        Write-Host "Skipping cleanup for:"
        Write-Host "  $($Sample.Architecture) | $($Sample.Family) $($Sample.Major)"
        Write-Host "  Reason: latest replacement $LatestVersion is not verified."
        continue
    }

    $OlderVersions = $Group.Group |
        Where-Object {
            [version]$_.Version -lt [version]$LatestVersion
        } |
        Sort-Object {
            [version]$_.Version
        }

    foreach ($OldRuntime in $OlderVersions) {

        $CleanupKey = `
            "$($OldRuntime.Architecture) | $($OldRuntime.Family) $($OldRuntime.Version)"

        Write-Host ""
        Write-Host "Superseded runtime detected:"
        Write-Host "  $CleanupKey"
        Write-Host "  Replacement verified: $LatestVersion"

        # First remove the parent standalone .NET EXE bundle when present.
        # The bundle owns/ref-counts its nested MSI packages. Removing only an
        # MSI child can return success while leaving the runtime installed.
        $BundleEntries = @(
            Get-RuntimeBundleEntries `
                -Family $OldRuntime.Family `
                -Version $OldRuntime.Version `
                -Architecture $OldRuntime.Architecture
        )

        foreach ($BundleEntry in $BundleEntries) {

            $BundleResult = Invoke-RuntimeBundleUninstall `
                -BundleEntry $BundleEntry

            if ($BundleResult.RebootRequired) {

                $RebootRequired = $true

                Set-DotNetRebootMarker `
                    -Reason ".NET runtime bundle cleanup returned 3010."
            }

            if (-not $BundleResult.Success) {

                Add-Failure `
                    -Item $CleanupKey `
                    -Reason "Superseded runtime bundle uninstall failed." `
                    -ExitCode $BundleResult.ExitCode
            }
        }

        if ($BundleEntries.Count -gt 0) {

            Start-Sleep -Seconds 2

            $ArchitectureObject = $Architectures |
                Where-Object {
                    $_.Name -eq $OldRuntime.Architecture
                } |
                Select-Object -First 1

            $AfterBundleInventory = @(
                Get-RuntimeInventory `
                    -Architecture $ArchitectureObject
            )

            $StillPresentAfterBundle = $AfterBundleInventory |
                Where-Object {
                    $_.Family -eq $OldRuntime.Family -and
                    $_.Version -eq $OldRuntime.Version
                } |
                Select-Object -First 1

            if (-not $StillPresentAfterBundle) {

                Write-Host "  Runtime removed successfully by parent bundle."
                $RemovedRuntimes += $CleanupKey
                continue
            }

            Write-Host "  Runtime still present after bundle uninstall."
            Write-Host "  Checking nested MSI registration..."
        }

        # Fallback for MSI-only installations.
        $MsiEntries = @(
            Get-RuntimeMsiEntries `
                -Family $OldRuntime.Family `
                -Version $OldRuntime.Version `
                -Architecture $OldRuntime.Architecture
        )

        if ($MsiEntries.Count -eq 0) {

            Write-Host "  No matching runtime MSI registration was found."
            Write-Host "  Re-checking during final verification."
            continue
        }

        foreach ($Entry in $MsiEntries) {

            if ([string]::IsNullOrWhiteSpace([string]$Entry.ProductCode)) {

                Add-Failure `
                    -Item $CleanupKey `
                    -Reason "Matching runtime MSI entry had an empty product code."

                continue
            }

            $RemoveResult = Invoke-MsiUninstall `
                -ProductCode ([string]$Entry.ProductCode) `
                -DisplayName ([string]$Entry.DisplayName)

            if ($RemoveResult.RebootRequired) {

                $RebootRequired = $true

                Set-DotNetRebootMarker `
                    -Reason ".NET MSI cleanup returned 3010."
            }

            if (-not $RemoveResult.Success) {

                Add-Failure `
                    -Item $CleanupKey `
                    -Reason "Superseded runtime MSI uninstall failed." `
                    -ExitCode $RemoveResult.ExitCode
            }
        }
    }
}


# ============================================================
# FINAL VERIFICATION
# ============================================================

Write-Section `
    "Final ASP.NET Core Hosting Bundle Inventory"

$FinalHostingBundleInventory = @(Get-HostingBundleInventory)

if ($FinalHostingBundleInventory.Count -eq 0) {

    Write-Host "No ASP.NET Core Hosting Bundles detected."
}
else {

    foreach ($Bundle in $FinalHostingBundleInventory) {

        Write-Host `
            "$($Bundle.DisplayName) | $($Bundle.Version)"
    }
}


Write-Section `
    "Final .NET SDK Inventory"

$FinalSdkInventory = @(Get-AllSdkInventory)

if ($FinalSdkInventory.Count -eq 0) {

    Write-Host "No supported SDKs detected."
}
else {

    foreach ($Sdk in $FinalSdkInventory) {

        Write-Host `
            "$($Sdk.Architecture) | SDK $($Sdk.Version) | Feature band $($Sdk.BandName)xx"
    }
}


Write-Section `
    "Final .NET Runtime Inventory"

$FinalRuntimeInventory = @(Get-AllRuntimeInventory)

if ($FinalRuntimeInventory.Count -eq 0) {

    Write-Host "No supported shared runtimes detected."
}
else {

    foreach ($Runtime in $FinalRuntimeInventory) {

        Write-Host `
            "$($Runtime.Architecture) | $($Runtime.Family) $($Runtime.Version)"
    }
}


# ============================================================
# VERIFY SUPERSEDED RUNTIMES ARE GONE
# ============================================================

Write-Section `
    "Superseded Runtime Verification"

$FinalRuntimeGroups = $FinalRuntimeInventory |
    Group-Object Architecture, Family, Major

$SupersededRemaining = @()

foreach ($Group in $FinalRuntimeGroups) {

    $Sample = $Group.Group |
        Select-Object -First 1

    $ChannelInfo = Get-ChannelInfo `
        -ReleaseChannels $ReleaseChannels `
        -Major $Sample.Major `
        -Minor $Sample.Minor

    if (-not $ChannelInfo) {
        continue
    }

    $LatestVersion = [string]$ChannelInfo.'latest-runtime'

    if (-not $LatestVersion) {
        continue
    }

    $Old = $Group.Group |
        Where-Object {
            [version]$_.Version -lt [version]$LatestVersion
        }

    foreach ($Runtime in $Old) {

        $RuntimeKey = `
            "$($Runtime.Architecture) | $($Runtime.Family) $($Runtime.Version)"

        # If servicing returned 3010 and the old runtime no longer has an MSI
        # registration, Windows has normally scheduled the old payload for
        # removal during reboot. Do not mark the servicing operation as failed yet.
        $OldMsiEntries = @(
            Get-RuntimeMsiEntries `
                -Family $Runtime.Family `
                -Version $Runtime.Version `
                -Architecture $Runtime.Architecture
        )

        if (
            (
                $script:RebootRequired -or
                $script:PreviousRunRebootPending
            ) -and
            $OldMsiEntries.Count -eq 0
        ) {

            $PendingRebootRuntimes += $Runtime

            Write-Host `
                "PENDING REBOOT: $RuntimeKey remains on disk but has no MSI registration."

            continue
        }

        $SupersededRemaining += $Runtime

        Add-Failure `
            -Item $RuntimeKey `
            -Reason "Superseded runtime remains installed after servicing. Latest is $LatestVersion."
    }
}

if (
    $SupersededRemaining.Count -eq 0 -and
    $PendingRebootRuntimes.Count -eq 0
) {

    Write-Host "No superseded patch-level shared runtimes remain."
}
else {

    foreach ($Runtime in $PendingRebootRuntimes) {

        Write-Host `
            "PENDING REBOOT: $($Runtime.Architecture) | $($Runtime.Family) $($Runtime.Version)"
    }

    foreach ($Runtime in $SupersededRemaining) {

        Write-Host `
            "WARNING: $($Runtime.Architecture) | $($Runtime.Family) $($Runtime.Version) remains installed."
    }
}


# ============================================================
# MACHINE-WIDE INSTALLER REGISTRATION
# ============================================================

Write-Section `
    "Machine-Wide .NET Installer Registration"

$RegisteredDotNet = @(Get-UninstallEntries) |
    Where-Object {
        $_.DisplayName -match `
            '^Microsoft (\.NET Runtime|Windows Desktop Runtime|ASP\.NET Core|\.NET SDK).*'
    } |
    Select-Object `
        DisplayName,
        DisplayVersion,
        Publisher |
    Sort-Object DisplayName, DisplayVersion -Unique

if ($RegisteredDotNet) {

    foreach ($Entry in $RegisteredDotNet) {

        Write-Host `
            "$($Entry.DisplayName) | $($Entry.DisplayVersion)"
    }
}
else {

    Write-Host "No matching .NET runtime/SDK uninstall entries were found."
}


# ============================================================
# SUMMARY
# ============================================================

Write-Section `
    "Servicing Summary"

Write-Host "Detected SDK feature bands: $($DetectedSdks.Count)"

foreach ($Item in $DetectedSdks) {
    Write-Host "  $Item"
}

Write-Host ""
Write-Host "SDK feature bands updated: $($UpdatedSdks.Count)"

foreach ($Item in $UpdatedSdks) {
    Write-Host "  $Item"
}

Write-Host ""
Write-Host "SDK feature bands already current: $($CurrentSdks.Count)"

foreach ($Item in $CurrentSdks) {
    Write-Host "  $Item"
}

Write-Host ""
Write-Host "Detected Hosting Bundle families: $($DetectedHostingBundles.Count)"

foreach ($Item in $DetectedHostingBundles) {
    Write-Host "  $Item"
}

Write-Host ""
Write-Host "Hosting Bundles updated: $($UpdatedHostingBundles.Count)"

foreach ($Item in $UpdatedHostingBundles) {
    Write-Host "  $Item"
}

Write-Host ""
Write-Host "Hosting Bundles already current: $($CurrentHostingBundles.Count)"

foreach ($Item in $CurrentHostingBundles) {
    Write-Host "  $Item"
}

Write-Host ""
Write-Host "Detected runtime families: $($DetectedFamilies.Count)"

foreach ($Item in $DetectedFamilies) {
    Write-Host "  $Item"
}

Write-Host ""
Write-Host "Runtime families updated: $($UpdatedFamilies.Count)"

foreach ($Item in $UpdatedFamilies) {
    Write-Host "  $Item"
}

Write-Host ""
Write-Host "Runtime families already current / registration repaired: $($CurrentFamilies.Count)"

foreach ($Item in $CurrentFamilies) {
    Write-Host "  $Item"
}

Write-Host ""
Write-Host "End-of-support items: $($EOLItems.Count)"

foreach ($Item in ($EOLItems | Sort-Object -Unique)) {
    Write-Host "  WARNING: $Item"
}

Write-Host ""
Write-Host "Superseded runtimes removed during cleanup: $($RemovedRuntimes.Count)"

foreach ($Item in ($RemovedRuntimes | Sort-Object -Unique)) {
    Write-Host "  $Item"
}

Write-Host ""
Write-Host "Superseded runtimes pending reboot: $($PendingRebootRuntimes.Count)"

foreach ($Runtime in $PendingRebootRuntimes) {
    Write-Host "  $($Runtime.Architecture) | $($Runtime.Family) $($Runtime.Version)"
}

Write-Host ""
Write-Host "Superseded runtimes remaining after reboot is not pending: $($SupersededRemaining.Count)"

Write-Host ""
Write-Host "Failed: $($FailedItems.Count)"

foreach ($Failure in $FailedItems) {

    Write-Host "  $($Failure.Item)"
    Write-Host "    Reason: $($Failure.Reason)"

    if ($null -ne $Failure.ExitCode) {
        Write-Host "    Exit code: $($Failure.ExitCode)"
    }
}

$EffectiveRebootRequired = (
    $RebootRequired -or
    $PreviousRunRebootPending
)

Write-Host ""
Write-Host "Reboot required: $EffectiveRebootRequired"


# ============================================================
# CLEANUP
# ============================================================

Remove-Item `
    $TempRoot `
    -Recurse `
    -Force `
    -ErrorAction SilentlyContinue


# ============================================================
# EXIT CODE
# ============================================================

Write-Host ""
Write-Host "============================================================"

if ($FailedItems.Count -gt 0) {

    Write-Host "RESULT: FAILURE"
    Write-Host "One or more .NET servicing or cleanup operations failed."

    Stop-DotNetTranscript


    exit 1
}

Write-Host "RESULT: SUCCESS"

if ($EOLItems.Count -gt 0) {

    Write-Host ""
    Write-Host "WARNING:"
    Write-Host "One or more end-of-support .NET major versions remain installed."
}

if ($EffectiveRebootRequired) {

    Write-Host ""
    Write-Host "WARNING:"

    if ($RebootRequired) {
        Write-Host "One or more installers returned 3010 during this run."
    }
    elseif ($PreviousRunRebootPending) {
        Write-Host "A previous .NET servicing run requested a reboot."
    }

    Write-Host "A reboot is required to complete servicing."

    if ($PendingRebootRuntimes.Count -gt 0) {

        Write-Host ""
        Write-Host "The following superseded runtimes are pending removal at reboot:"

        foreach ($Runtime in $PendingRebootRuntimes) {
            Write-Host "  $($Runtime.Architecture) | $($Runtime.Family) $($Runtime.Version)"
        }
    }
}

Write-Host ""
Write-Host ".NET SDK and runtime machine-wide servicing completed successfully."

Stop-DotNetTranscript


exit 0