#Requires -RunAsAdministrator
[CmdletBinding()]
param([switch]$TrustLocalCertificate)
# Setup may inherit PowerShell 7's module path through a non-PowerShell host.
# Select this Windows PowerShell runtime's built-ins before any module autoload.
if ($PSVersionTable.PSEdition -eq 'Desktop') { $env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules') }
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'State-Security.ps1')
if (!$TrustLocalCertificate) {
    throw 'Installation requires explicitly passing -TrustLocalCertificate to trust the package code-signing certificate in LocalMachine Root and TrustedPublisher.'
}
$driver = Join-Path $PSScriptRoot 'driver'
$deviceSetup = Join-Path $PSScriptRoot 'native\RoyalDeviceSetup.exe'
$devcon = Join-Path $PSScriptRoot 'packages\wdk\c\tools\10.0.26100.0\x64\devcon.exe'
$useDeviceSetup = Test-Path -LiteralPath $deviceSetup
$stateDir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'RoyalDynamicLighting'
$statePath = Join-Path $stateDir 'transport-install.json'
Assert-RoyalPlainPath $statePath
if (Test-Path -LiteralPath $statePath) { throw "Installation metadata already exists: $statePath" }
function Get-WinUHidDevices {
    # SetupAPI creates ROOT\SYSTEM\NNNN instances; identify them by hardware ID,
    # not by the enumerator-generated instance path. Query the root devices in
    # one bounded CIM operation rather than one PnP property query per device.
    Get-CimInstance -ClassName Win32_PnPEntity -Filter "PNPDeviceID LIKE 'ROOT%'" -Property PNPDeviceID,HardwareID -OperationTimeoutSec 15 -ErrorAction Stop |
        Where-Object { @($_.HardwareID) -contains 'Root\WinUHid' } |
        ForEach-Object { [pscustomobject]@{ InstanceId = $_.PNPDeviceID } }
}
Write-Output 'Checking for an existing WinUHid root enumerator.'
$existing = @(Get-WinUHidDevices)
if ($existing.Count) { throw 'A WinUHid enumerator already exists. Reuse or review that installation; this script will not replace it.' }
Write-Output 'Verifying signed driver package hashes and certificates.'
& (Join-Path $PSScriptRoot 'Verify-Package.ps1') -DriverDirectory $driver -Verbose
$certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 "$driver\RoyalDynamicLighting.cer"
if (!$useDeviceSetup -and !(Test-Path -LiteralPath $devcon)) { throw "Missing device setup helper: $deviceSetup" }
$state = [ordered]@{ instanceId = $null; publishedInf = $null; packageAdded = !$useDeviceSetup; thumbprint = $certificate.Thumbprint; rootAdded = $false; publisherAdded = $false; rebootRequired = $false; installedAt = (Get-Date).ToUniversalTime().ToString('o') }
Write-Output 'Creating the protected installation receipt.'
New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
Set-RoyalStateAcl $stateDir $true
# Secure the owner and ACL before recording any state. Ordinary users can read
# the receipt, but cannot edit its privileged uninstall instructions or DACL.
Assert-RoyalPlainPath $statePath
New-Item -ItemType File -Path $statePath -ErrorAction Stop | Out-Null
Set-RoyalStateAcl $statePath $false
# Persist changes as they happen so the uninstall script can reverse a partial install.
function Save-State {
    Assert-RoyalStateAcl $stateDir
    Assert-RoyalStateAcl $statePath
    $state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
}
Save-State
Write-Output 'Installing the approved local signing certificate trust.'
foreach ($entry in @(@{ store='Root'; key='rootAdded' }, @{ store='TrustedPublisher'; key='publisherAdded' })) {
    if (!(Test-Path -LiteralPath "Cert:\LocalMachine\$($entry.store)\$($certificate.Thumbprint)")) {
        Import-Certificate -FilePath "$driver\RoyalDynamicLighting.cer" -CertStoreLocation "Cert:\LocalMachine\$($entry.store)" | Out-Null
        $state[$entry.key] = $true
        Save-State
    }
}
Write-Output 'Creating the virtual HID enumerator and installing its UMDF driver.'
if ($useDeviceSetup) {
    $deviceOutput = @(& $deviceSetup install "$driver\WinUHidDriver.inf")
    $installCode = $LASTEXITCODE
    foreach ($line in $deviceOutput) {
        Write-Output $line
        if ($line -match '^PublishedInf=(oem[0-9]+\.inf)$') { $state.publishedInf = $Matches[1] }
        if ($line -match '^PackageAdded=([01])$') { $state.packageAdded = $Matches[1] -eq '1' }
    }
    Save-State
} else {
    # Legacy development workspace only. The redistributable installer ships
    # the original RoyalDeviceSetup helper, never the WDK's DevCon binary.
    & $devcon install "$driver\WinUHidDriver.inf" 'Root\WinUHid'
    $installCode = $LASTEXITCODE
}
$successCodes = if ($useDeviceSetup) { @(0,3010) } else { @(0,1) }
$state.rebootRequired = ($installCode -eq $(if ($useDeviceSetup) { 3010 } else { 1 }))
Save-State
Write-Output "Device setup returned $installCode; reading the installed device identity."
$created = @(Get-WinUHidDevices)
if ($created.Count -eq 1) {
    $state.instanceId = $created[0].InstanceId
    $boundInf = (Get-PnpDeviceProperty -InstanceId $state.instanceId -KeyName 'DEVPKEY_Device_DriverInfPath' -ErrorAction SilentlyContinue).Data
    if (!$state.publishedInf) { $state.publishedInf = $boundInf }
    Save-State
    if ($boundInf -and $boundInf -ne $state.publishedInf) { throw 'The device bound to a different driver package. Run Uninstall-Driver.ps1 to remove the recorded changes.' }
}
if ($installCode -notin $successCodes -or $created.Count -ne 1) { throw "Driver installation failed (exit $installCode). Run Uninstall-Driver.ps1 to remove recorded changes." }
if (!$state.publishedInf -or $state.publishedInf -notmatch '^oem[0-9]+\.inf$') {
    throw 'The installed driver package identity could not be recorded. Run Uninstall-Driver.ps1 to remove recorded changes.'
}
if ($state.rebootRequired) { Write-Output 'Windows reports that a restart is required.' }
Write-Output "Installed $($state.instanceId). Boot security settings were not changed."
[pscustomobject]@{ Operation = 'InstallDriver'; RebootRequired = [bool]$state.rebootRequired; InstanceId = $state.instanceId; PublishedInf = $state.publishedInf }
