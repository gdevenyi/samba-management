<#
.SYNOPSIS
    Join a Windows computer to a Samba Active Directory domain.

.DESCRIPTION
    Configures DNS to point to the Samba domain controller and joins
    the computer to the AD domain using domain credentials.

.PARAMETER Domain
    The AD DNS domain name (e.g., example.internal).

.PARAMETER DcIp
    The IP address of the Samba domain controller.

.PARAMETER AdminUser
    The domain administrator username (default: Administrator).

.PARAMETER AdminPassword
    The domain administrator password. If omitted, you will be prompted.

.EXAMPLE
    .\join-domain.ps1 -Domain example.internal -DcIp 10.0.0.1
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$Domain,

    [Parameter(Mandatory=$true)]
    [string]$DcIp,

    [Parameter(Mandatory=$false)]
    [string]$AdminUser = 'Administrator',

    [Parameter(Mandatory=$false)]
    [string]$AdminPassword
)

# Stop on first error to avoid partial domain-join state.
$ErrorActionPreference = 'Stop'

Write-Host "=== Samba AD Domain Join ===" -ForegroundColor Cyan
Write-Host "Domain: $Domain"
Write-Host "DC IP:  $DcIp"
Write-Host ""

# --- Step 1: Configure DNS ---
# Point the network adapter(s) at the Samba DC so the client can resolve
# AD SRV records and domain controllers via DNS.  This must happen before
# the join attempt.
Write-Host "[1/3] Configuring DNS..." -ForegroundColor Yellow
$adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
foreach ($adapter in $adapters) {
    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $DcIp
    Write-Host "  Set DNS for adapter: $($adapter.Name)"
}

# Set the primary DNS suffix so single-label names resolve correctly
# within the AD domain.
$dnsSuffix = $Domain
Set-DnsClientGlobalSetting -SuffixSearchList @($dnsSuffix)
Write-Host "  Set DNS suffix search list: $dnsSuffix"

Write-Host ""
Write-Host "[2/3] Joining domain..." -ForegroundColor Yellow

# Handle credentials: if a password was passed as a parameter, convert it
# to a SecureString.  Otherwise prompt the user interactively via the
# standard Windows credential dialog (Get-Credential).
# SECURITY: the password is never written to disk or logged.
if ($AdminPassword) {
    $securePassword = ConvertTo-SecureString $AdminPassword -AsPlainText -Force
} else {
    $credential = Get-Credential -UserName "${AdminUser}@${Domain}" -Message "Enter domain administrator credentials"
    $securePassword = $credential.Password
    $AdminUser = $credential.UserName.Split('@')[0]
}

$credential = New-Object System.Management.Automation.PSCredential("${AdminUser}@${Domain}", $securePassword)

try {
    # JoinWithNewName: allows the computer to be renamed during join.
    # AccountCreate: creates a computer object in AD if one doesn't exist.
    Add-Computer -DomainName $Domain -Credential $credential -Options JoinWithNewName,AccountCreate -Force
    Write-Host "  Successfully joined domain: $Domain" -ForegroundColor Green
} catch {
    Write-Host "  ERROR: Failed to join domain: $_" -ForegroundColor Red
    exit 1
}

# --- Step 3: Enable the domain firewall profile ---
# Once joined, the Windows Firewall domain profile should be active to
# enforce AD-appropriate rules (e.g., SMB inbound from the domain).
Write-Host ""
Write-Host "[3/3] Enabling Windows Firewall domain profile..." -ForegroundColor Yellow
Set-NetFirewallProfile -Profile Domain -Enabled True

Write-Host ""
Write-Host "=== Domain Join Complete ===" -ForegroundColor Green
Write-Host "A restart is required to complete the process."
$restart = Read-Host "Restart now? (Y/n)"
if ($restart -ne 'n' -and $restart -ne 'N') {
    Restart-Computer -Force
}
