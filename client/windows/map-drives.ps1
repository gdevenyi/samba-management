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

$ErrorActionPreference = 'SilentlyContinue'

if (-not $ConfigFile) {
    $ConfigFile = Join-Path $PSScriptRoot 'map-drives.ini'
}

if (-not (Test-Path $ConfigFile)) {
    Write-Host "Drive mapping config not found: $ConfigFile" -ForegroundColor Yellow
    return
}

function Get-UserGroups {
    $groups = @()
    try {
        $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        foreach ($group in $currentUser.Groups) {
            $groupObj = $group.Translate([System.Security.Principal.NTAccount])
            $groupName = $groupObj.Value.Split('\')[-1]
            $groups += $groupName
        }
    } catch {
        $groups = @(whoami /groups /fo csv 2>$null | ConvertFrom-Csv | ForEach-Object { $_.'Group Name'.Split('\')[-1] })
    }
    return $groups
}

function Map-DriveIfAvailable {
    param(
        [string]$DriveLetter,
        [string]$UncPath
    )

    $drive = "${DriveLetter}"
    try {
        $existing = Get-PSDrive -Name $drive.TrimEnd(':') -ErrorAction SilentlyContinue
        if ($existing) {
            net use "${drive}" /delete /y 2>$null | Out-Null
        }

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

$content = Get-Content $ConfigFile -ErrorAction SilentlyContinue
$inMapping = $false

foreach ($line in $content) {
    $line = $line.Trim()

    if ($line -eq '[GroupMapping]') {
        $inMapping = $true
        continue
    }

    if ($line.StartsWith('[') -and $line.EndsWith(']')) {
        $inMapping = $false
        continue
    }

    if (-not $inMapping -or [string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
        continue
    }

    $parts = $line -split '=', 2
    if ($parts.Count -ne 2) { continue }

    $groupName = $parts[0].Trim()
    $mapping = $parts[1].Trim()

    $mapParts = $mapping -split ',', 2
    if ($mapParts.Count -ne 2) { continue }

    $uncPath = $mapParts[0].Trim()
    $driveLetter = $mapParts[1].Trim()

    if ($userGroups -contains $groupName) {
        Write-Host "Group '${groupName}' matched -> ${driveLetter}" -ForegroundColor Cyan
        Map-DriveIfAvailable -DriveLetter $driveLetter -UncPath $uncPath
    }
}

Write-Host "=== Drive Mapping Complete ===" -ForegroundColor Cyan
