#Requires -RunAsAdministrator
[CmdletBinding()]
param()
# Avoid inheriting incompatible PowerShell 7 or user modules from the launcher.
if ($PSVersionTable.PSEdition -eq 'Desktop') { $env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules') }
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'State-Security.ps1')
$stateDir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'RoyalDynamicLighting'
$statePath = Join-Path $stateDir 'transport-install.json'
Assert-RoyalPlainPath $statePath
if (!(Test-Path -LiteralPath $statePath)) { throw 'No recorded installation. Refusing to remove unowned devices or certificates.' }
Assert-RoyalStateAcl $stateDir
Assert-RoyalStateAcl $statePath
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
$originalInstanceId = $state.instanceId
$originalPublishedInf = $state.publishedInf
$rebootRequired = $false
$deviceSetup = Join-Path $PSScriptRoot 'native\RoyalDeviceSetup.exe'
$devcon = Join-Path $PSScriptRoot 'packages\wdk\c\tools\10.0.26100.0\x64\devcon.exe'
$useDeviceSetup = Test-Path -LiteralPath $deviceSetup
function Save-State {
    Assert-RoyalStateAcl $stateDir
    Assert-RoyalStateAcl $statePath
    $state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
}
if ($state.instanceId) {
    if ($state.instanceId -notmatch '^ROOT\\(?:WINUHID|SYSTEM)\\[0-9A-F]+$') { throw 'Invalid recorded device ID.' }
    $hardwareIds = @((Get-PnpDeviceProperty -InstanceId $state.instanceId -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction SilentlyContinue).Data | Where-Object { $_ })
    if ($hardwareIds.Count -and $hardwareIds -notcontains 'Root\WinUHid') { throw 'Recorded device no longer identifies as WinUHid.' }
    if ($useDeviceSetup) {
        & $deviceSetup remove $state.instanceId
        $removeCode = $LASTEXITCODE
        if ($removeCode -notin @(0,3010)) { throw "Device removal failed (exit $removeCode); leaving package and certificate trust intact." }
        $rebootRequired = $removeCode -eq 3010
    } elseif ($hardwareIds.Count) {
        if (!(Test-Path -LiteralPath $devcon)) { throw "Missing device setup helper: $deviceSetup" }
        & $devcon remove "@$($state.instanceId)"
        $removeCode = $LASTEXITCODE
        if ($removeCode -notin @(0,1)) { throw 'Device removal failed; leaving package and certificate trust intact.' }
        $rebootRequired = $removeCode -eq 1
    }
    $state.instanceId = $null
    Save-State
}
if ($state.publishedInf) {
    if ($state.publishedInf -notmatch '^oem[0-9]+\.inf$') { throw 'Invalid published INF name.' }
    $publishedInfPath = Join-Path (Join-Path ([Environment]::GetFolderPath('Windows')) 'INF') $state.publishedInf
    # Older workspace receipts predate packageAdded and own their package.
    # The new helper explicitly distinguishes an already staged package.
    $ownsPackage = !$state.PSObject.Properties['packageAdded'] -or [bool]$state.packageAdded
    if ($ownsPackage -and (Test-Path -LiteralPath $publishedInfPath)) {
        & (Join-Path ([Environment]::GetFolderPath('System')) 'pnputil.exe') /delete-driver $state.publishedInf
        $packageCode = $LASTEXITCODE
        if ($packageCode -notin @(0,3010)) { throw "Driver package removal failed (exit $packageCode); leaving certificate trust intact." }
        $rebootRequired = $rebootRequired -or $packageCode -eq 3010
    } elseif (!$ownsPackage) {
        Write-Output "Preserving pre-existing driver package $($state.publishedInf)."
    }
    $state.publishedInf = $null
    Save-State
}
if ($state.thumbprint -notmatch '^[0-9A-F]{40}$') { throw 'Invalid recorded certificate thumbprint.' }
if ($state.publisherAdded -and (Test-Path -LiteralPath "Cert:\LocalMachine\TrustedPublisher\$($state.thumbprint)")) {
    Remove-Item -LiteralPath "Cert:\LocalMachine\TrustedPublisher\$($state.thumbprint)"
}
if ($state.rootAdded -and (Test-Path -LiteralPath "Cert:\LocalMachine\Root\$($state.thumbprint)")) {
    Remove-Item -LiteralPath "Cert:\LocalMachine\Root\$($state.thumbprint)"
}
Remove-Item -LiteralPath $statePath
Write-Output 'Removed the recorded WinUHid device/package and only the certificate trust entries added by this installer.'
[pscustomobject]@{ Operation = 'UninstallDriver'; RebootRequired = [bool]$rebootRequired; InstanceId = $originalInstanceId; PublishedInf = $originalPublishedInf }
