#Requires -RunAsAdministrator
$env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules')
if ($PSVersionTable.PSEdition -eq 'Core') { $env:PSModulePath += ';' + [IO.Path]::Combine($env:SystemRoot, 'System32\WindowsPowerShell\v1.0\Modules') }
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'transport\State-Security.ps1')
$lightingCommon = Join-Path $PSScriptRoot 'scripts\Package-Common.ps1'
if (!(Test-Path -LiteralPath $lightingCommon)) { $lightingCommon = Join-Path $PSScriptRoot 'installer\scripts\Package-Common.ps1' }
. $lightingCommon
$lightingPaths = Get-RoyalPackagePaths $PSScriptRoot
$lightingTarget = $lightingPaths.AppRoot
$lightingState = $lightingPaths.StateRoot
$lightingReceipt = Join-Path $lightingState 'app-install.json'
Assert-RoyalPlainPath $lightingReceipt
if (!(Test-Path -LiteralPath $lightingReceipt)) {
    if ((Test-Path -LiteralPath $lightingTarget) -or (Get-ScheduledTask -TaskName 'RoyalDynamicLighting' -TaskPath '\' -ErrorAction SilentlyContinue)) {
        throw 'Application files or task exist without an ownership receipt; refusing to remove them.'
    }
    Write-Output 'The adapter application is already removed.'
    return
}
Assert-RoyalStateAcl $lightingState
Assert-RoyalStateAcl $lightingReceipt
$lightingInstall = Get-Content -LiteralPath $lightingReceipt -Raw | ConvertFrom-Json
if ($lightingInstall.installPath -ne $lightingTarget -or $lightingInstall.taskName -ne 'RoyalDynamicLighting') { throw 'Installation record does not match the expected application.' }
if (Test-Path -LiteralPath $lightingTarget) { Assert-RoyalStateAcl $lightingTarget }
Stop-RoyalTask $lightingTarget $lightingState
$lightingTask = Get-ScheduledTask -TaskName 'RoyalDynamicLighting' -TaskPath '\' -ErrorAction SilentlyContinue
if ($lightingTask) {
    Assert-RoyalTask $lightingTask $lightingTarget $lightingState
    Unregister-ScheduledTask -TaskName 'RoyalDynamicLighting' -TaskPath '\' -Confirm:$false
}
# Fixed target was checked against its secured receipt. Installer support lives
# in a separate directory and is outside this recursive deletion.
if (Test-Path -LiteralPath $lightingTarget) {
    Assert-RoyalPlainPath $lightingTarget
    if ($lightingTarget -ne [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'RoyalDynamicLighting'))) { throw 'Unexpected removal target.' }
    Remove-Item -LiteralPath $lightingTarget -Recurse -Force
}
Remove-Item -LiteralPath $lightingReceipt
Write-Output 'Removed the adapter application and startup task. Configuration and diagnostic logs were preserved.'
