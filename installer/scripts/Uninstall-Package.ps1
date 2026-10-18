[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PackageRoot)
$env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules')
if ($PSVersionTable.PSEdition -eq 'Core') { $env:PSModulePath += ';' + [IO.Path]::Combine($env:SystemRoot, 'System32\WindowsPowerShell\v1.0\Modules') }
$ErrorActionPreference = 'Stop'
$lightingTranscript = $false
$lightingExitCode = 1
try {
    . (Join-Path $PSScriptRoot 'Package-Common.ps1')
    $lightingPaths = Get-RoyalPackagePaths $PackageRoot
    . (Join-Path $lightingPaths.PackageRoot 'transport\State-Security.ps1')
    Assert-RoyalAdministrator
    if ($lightingPaths.PackageRoot -ne $lightingPaths.SupportRoot) { throw 'Uninstall must run from the permanent support directory.' }
    Assert-RoyalTrustedDirectory $lightingPaths.SupportRoot
    $lightingSnapshot = Get-RoyalPackageSnapshot $lightingPaths -SkipConfigurationValidation
    $lightingJournal = $lightingSnapshot.Journal
    if ($null -eq $lightingJournal) {
        if ($lightingSnapshot.HasApp -or $lightingSnapshot.HasDriver) { throw 'No package ownership journal exists; manual installation will not be removed.' }
        Write-Output 'No application or driver changes were recorded. Installer support files can be removed.'
        exit 0
    }
    if ($lightingJournal.schemaVersion -ne 1 -or $lightingJournal.packageId -ne $script:RoyalPackageId -or $lightingJournal.supportRoot -ne $lightingPaths.SupportRoot) {
        throw 'Installation ownership journal does not match this package.'
    }
    if (($lightingSnapshot.HasApp -and !$lightingJournal.appOwned) -or ($lightingSnapshot.HasDriver -and !$lightingJournal.driverOwned)) { throw 'Refusing to remove unowned application or driver state.' }
    $lightingSetupLog = Join-Path $lightingPaths.StateRoot 'setup.log'
    if (!(Test-Path -LiteralPath $lightingSetupLog)) { New-RoyalProtectedFile $lightingSetupLog }
    Start-Transcript -LiteralPath $lightingSetupLog -Append | Out-Null
    $lightingTranscript = $true
    $lightingJournalPath = Join-Path $lightingPaths.StateRoot 'package-install.json'
    $lightingJournal.status = 'uninstalling'
    Write-RoyalProtectedJson $lightingJournalPath $lightingJournal
    if ($lightingSnapshot.HasApp) {
        $lightingCode = Invoke-RoyalPowerShell (Join-Path $PackageRoot 'Uninstall-App.ps1')
        if ($lightingCode -ne 0) { throw 'Application cleanup failed. The driver and installer support files have been retained.' }
    }
    $lightingReboot = $false
    if (Test-Path -LiteralPath (Join-Path $lightingPaths.StateRoot 'transport-install.json')) {
        $lightingRemoval = @(& (Join-Path $PackageRoot 'transport\Uninstall-Driver.ps1'))
        foreach ($lightingItem in $lightingRemoval) {
            if ($lightingItem.Operation -eq 'UninstallDriver') { $lightingReboot = $lightingReboot -or $lightingItem.RebootRequired }
            else { Write-Output $lightingItem }
        }
    }
    Remove-Item -LiteralPath $lightingJournalPath
    Write-Output 'Owned application, task, and virtual driver removed. Configuration, logs, PawnIO, and Visual C++ runtimes were preserved.'
    $lightingExitCode = if ($lightingReboot) { 3010 } else { 0 }
} catch {
    Write-Output ($_ | Out-String)
    $lightingExitCode = 1
} finally {
    if ($lightingTranscript) { Stop-Transcript | Out-Null }
}
exit $lightingExitCode
