#Requires -RunAsAdministrator
[CmdletBinding()]
param([switch]$TrustLocalCertificate, [switch]$Resume, [switch]$DeferStart)
$env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules')
if ($PSVersionTable.PSEdition -eq 'Core') { $env:PSModulePath += ';' + [IO.Path]::Combine($env:SystemRoot, 'System32\WindowsPowerShell\v1.0\Modules') }
$ErrorActionPreference = 'Stop'
try {
    if (!$TrustLocalCertificate) { throw 'Pass -TrustLocalCertificate after reviewing the dedicated driver certificate trust.' }
    . (Join-Path $PSScriptRoot 'transport\State-Security.ps1')
    $lightingCommon = Join-Path $PSScriptRoot 'scripts\Package-Common.ps1'
    if (!(Test-Path -LiteralPath $lightingCommon)) { $lightingCommon = Join-Path $PSScriptRoot 'installer\scripts\Package-Common.ps1' }
    . $lightingCommon
    $lightingState = Join-Path $env:ProgramData 'RoyalDynamicLighting'
    $lightingDriverReceipt = Join-Path $lightingState 'transport-install.json'
    $lightingReboot = [bool]$DeferStart
    if (!(Test-Path -LiteralPath $lightingDriverReceipt)) {
        $lightingDriverOutput = @(& (Join-Path $PSScriptRoot 'transport\Install-Driver.ps1') -TrustLocalCertificate)
        foreach ($lightingItem in $lightingDriverOutput) {
            if ($lightingItem.Operation -eq 'InstallDriver') { $lightingReboot = $lightingReboot -or $lightingItem.RebootRequired }
            else { Write-Output $lightingItem }
        }
    }
    Assert-RoyalStateAcl $lightingState
    Assert-RoyalStateAcl $lightingDriverReceipt
    $lightingDriver = Get-Content -LiteralPath $lightingDriverReceipt -Raw | ConvertFrom-Json
    $lightingDevice = @(Get-CimInstance Win32_PnPEntity -Filter "PNPDeviceID LIKE 'ROOT%'" -OperationTimeoutSec 15 |
        Where-Object { $_.PNPDeviceID -eq $lightingDriver.instanceId -and $_.HardwareID -contains 'Root\WinUHid' })
    if ($lightingDevice.Count -ne 1) { throw 'The recorded virtual HID driver is absent. Retry the installer to recover its owned partial installation.' }
    if ($lightingDevice[0].ConfigManagerErrorCode -eq 14) { $lightingReboot = $true }
    elseif ($lightingDevice[0].ConfigManagerErrorCode -ne 0) {
        throw "Virtual HID device failed to start (Device Manager code $($lightingDevice[0].ConfigManagerErrorCode))."
    }
    & (Join-Path $PSScriptRoot 'Install-App.ps1') -Resume:$Resume -DeferStart:$lightingReboot
    if ($lightingReboot) {
        Write-Output 'Setup requires a Windows restart. The installed startup task will start the adapter after restart.'
        exit 3010
    }
    Write-Output 'Setup complete. Windows Dynamic Lighting can now discover the running adapter.'
    exit 0
} catch {
    Write-Output ($_ | Out-String)
    exit 1
}
