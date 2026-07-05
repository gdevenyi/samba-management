<#
.SYNOPSIS
    Map network drives based on AD group membership at user logon.

.DESCRIPTION
    Reads a drive mapping configuration file (map-drives.ini) and maps
    network drives to drive letters based on the current user's group
    membership in Active Directory.

    Place this script in a GPO logon script or startup folder.
    The configuration file (map-drives.ini) should be in the same directory.

.PARAMETER ConfigFile
    Path to the drive mapping configuration file (default: map-drives.ini
    in the script directory).

.CONFIGURATION
    map-drives.ini format:

    [GroupMapping]
    Domain Users = \\dc01\public, Z:
    Finance = \\dc01\finance, F:
    DevOps = \\dc01\devops, D:

    Each line: <AD Group Name> = <UNC path>, <drive letter>:

.EXAMPLE
    .\map-drives.ps1
    .\map-drives.ps1 -ConfigFile \\dc01\netlogon\map-drives.ini
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$ConfigFile
)

# SilentlyContinue because missing shares or offline DCs should not
# produce error popups during user logon.
$ErrorActionPreference = 'SilentlyContinue'

# Default to map-drives.ini in the same directory as this script.
# $PSScriptRoot is automatically set by PowerShell and resolves correctly
# even when the script is launched from a UNC path (e.g., netlogon share).
if (-not $ConfigFile) {
    $ConfigFile = Join-Path $PSScriptRoot 'map-drives.ini'
}

if (-not (Test-Path $ConfigFile)) {
    Write-Host "Drive mapping config not found: $ConfigFile" -ForegroundColor Yellow
    return
}

# ---------------------------------------------------------------------------
# Enumerate the current user's AD group memberships from the Windows
# security token.  Falls back to `whoami /groups` if the .NET method
# fails (e.g., in constrained environments).
# ---------------------------------------------------------------------------
function Get-UserGroups {
    $groups = @()
    try {
        # WindowsIdentity.Groups returns SIDs; we translate each to an
        # NTAccount name and strip the DOMAIN\ prefix to get the bare
        # group name that matches the INI file entries.
        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        foreach ($group in $currentUser.Groups) {
            $groupObj = $group.Translate([System.Security.Principal.NTAccount])
            $groupName = $groupObj.Value.Split('\')[-1]
            $groups += $groupName
        }
    } catch {
        # Fallback: parse CSV output from whoami (less reliable but
        # works when .NET identity translation fails).
        $groups = @(whoami /groups /fo csv 2>$null | ConvertFrom-Csv | ForEach-Object { $_.'Group Name'.Split('\')[-1] })
    }
    return $groups
}

# ---------------------------------------------------------------------------
# Map a single drive letter to a UNC path.
# Disconnects any existing mapping first to avoid conflicts (e.g., if the
# user previously mapped the same letter to a different path).
# Uses /persistent:no so the mapping is session-only and won't cause
# errors if the share is unavailable at next logon.
# ---------------------------------------------------------------------------
function Map-DriveIfAvailable {
    param(
        [string]$DriveLetter,
        [string]$UncPath
    )

    $drive = "${DriveLetter}"
    try {
        # Disconnect existing mapping for this drive letter if present.
        $existing = Get-PSDrive -Name $drive.TrimEnd(':') -ErrorAction SilentlyContinue
        if ($existing) {
            net use "${drive}" /delete /y 2>$null | Out-Null
        }

        # Map the drive.  /persistent:no means it won't be restored on
        # next logon (the logon script handles that each time).
        $result = net use "${drive}" "${UncPath}" /persistent:no 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "  Mapped ${drive} -> ${UncPath}" -ForegroundColor Green
        } else {
            Write-Host "  Failed to map ${drive} -> ${UncPath}: $result" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "  Error mapping ${drive}: $_" -ForegroundColor Yellow
    }
}

Write-Host "=== Mapping Network Drives ===" -ForegroundColor Cyan

$userGroups = Get-UserGroups
if ($userGroups.Count -eq 0) {
    Write-Host "Could not determine group membership." -ForegroundColor Yellow
    return
}

# ---------------------------------------------------------------------------
# Parse the INI file: only lines under [GroupMapping] are processed.
# Format:  GroupName = \\server\share, X:
# ---------------------------------------------------------------------------
$content = Get-Content $ConfigFile -ErrorAction SilentlyContinue
$inMapping = $false

foreach ($line in $content) {
    $line = $line.Trim()

    # Track whether we're inside the [GroupMapping] section.
    if ($line -eq '[GroupMapping]') {
        $inMapping = $true
        continue
    }

    # Any other section header ends the mapping section.
    if ($line.StartsWith('[') -and $line.EndsWith(']')) {
        $inMapping = $false
        continue
    }

    # '#' and ';' both start comments (';' is the INI-file convention).
    if (-not $inMapping -or [string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#') -or $line.StartsWith(';')) {
        continue
    }

    # Split on first '=' only (UNC paths may contain = in theory).
    $parts = $line -split '=', 2
    if ($parts.Count -ne 2) { continue }

    $groupName = $parts[0].Trim()
    $mapping = $parts[1].Trim()

    # Split "UNC, drive:" on the comma.
    $mapParts = $mapping -split ',', 2
    if ($mapParts.Count -ne 2) { continue }

    $uncPath = $mapParts[0].Trim()
    $driveLetter = $mapParts[1].Trim()

    # Only map drives for groups the current user is actually a member of.
    if ($userGroups -contains $groupName) {
        Write-Host "Group '${groupName}' matched -> ${driveLetter}" -ForegroundColor Cyan
        Map-DriveIfAvailable -DriveLetter $driveLetter -UncPath $uncPath
    }
}

Write-Host "=== Drive Mapping Complete ===" -ForegroundColor Cyan
