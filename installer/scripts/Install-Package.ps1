[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PackageRoot,
    [switch]$TrustLocalCertificate,
    [switch]$PreflightOnly,
    [switch]$DeferStart
)
$env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules')
if ($PSVersionTable.PSEdition -eq 'Core') { $env:PSModulePath += ';' + [IO.Path]::Combine($env:SystemRoot, 'System32\WindowsPowerShell\v1.0\Modules') }
$ErrorActionPreference = 'Stop'
$lightingTranscript = $false
$lightingJournal = $null
$lightingJournalStarted = $false
$lightingExitCode = 1
try {
    . (Join-Path $PSScriptRoot 'Package-Common.ps1')
    $lightingPaths = Get-RoyalPackagePaths $PackageRoot
    . (Join-Path $lightingPaths.PackageRoot 'transport\State-Security.ps1')
    if (![Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell for this x64 installer.' }
    Assert-RoyalPlainPath $lightingPaths.PackageRoot
    foreach ($lightingName in @('Setup.ps1','Install-App.ps1','Uninstall-App.ps1','config.json','artifacts\app\RoyalDynamicLighting.exe','transport\Install-Driver.ps1','transport\Uninstall-Driver.ps1')) {
        if (!(Test-Path -LiteralPath (Join-Path $lightingPaths.PackageRoot $lightingName))) { throw "Package file is missing: $lightingName" }
    }
    $null = Get-RoyalConfiguration (Join-Path $lightingPaths.PackageRoot 'config.json')
    $lightingSnapshot = Get-RoyalPackageSnapshot $lightingPaths
    $lightingPlan = Get-RoyalInstallPlan $lightingSnapshot.Journal $lightingSnapshot.HasApp $lightingSnapshot.HasDriver $lightingPaths.SupportRoot
    if (Test-Path -LiteralPath $lightingPaths.SupportRoot) {
        Assert-RoyalTrustedDirectory $lightingPaths.SupportRoot
        if ($PreflightOnly -and $null -eq $lightingSnapshot.Journal) {
            throw 'An unowned installer support directory already exists. Use its Apps uninstall entry before trying again; existing files will not be overwritten.'
        }
    }
    if ($PreflightOnly) {
        Write-Output "Preflight passed: $lightingPlan. Existing configuration and logs will be preserved."
        exit 0
    }
    Assert-RoyalAdministrator
    if ($lightingPaths.PackageRoot -ne $lightingPaths.SupportRoot) { throw "Install from the permanent package directory: $($lightingPaths.SupportRoot)" }
    if (!$TrustLocalCertificate) { throw 'The installer must explicitly approve its dedicated driver certificate with -TrustLocalCertificate.' }
    Set-RoyalStateAcl $lightingPaths.SupportRoot $true
    Initialize-RoyalProtectedDirectory $lightingPaths.StateRoot
    $lightingSetupLog = Join-Path $lightingPaths.StateRoot 'setup.log'
    if (!(Test-Path -LiteralPath $lightingSetupLog)) { New-RoyalProtectedFile $lightingSetupLog }
    Assert-RoyalStateAcl $lightingSetupLog
    Start-Transcript -LiteralPath $lightingSetupLog -Append | Out-Null
    $lightingTranscript = $true
    $lightingJournalPath = Join-Path $lightingPaths.StateRoot 'package-install.json'
    $lightingJournal = if ($lightingSnapshot.Journal) { $lightingSnapshot.Journal } else {
        [pscustomobject][ordered]@{
            schemaVersion = 1; packageId = $script:RoyalPackageId; supportRoot = $lightingPaths.SupportRoot
            status = 'installing'; appOwned = $true; driverOwned = $true
            installedAt = (Get-Date).ToUniversalTime().ToString('o'); lastError = $null; restartBootTime = $null
        }
    }
    $lightingBootTime = Get-RoyalBootIdentity
    if (!$lightingJournal.PSObject.Properties['restartBootTime']) { $lightingJournal | Add-Member -NotePropertyName restartBootTime -NotePropertyValue $null }
    if ($lightingPlan -eq 'RetryAfterReboot') {
        if ($lightingJournal.restartBootTime -eq $lightingBootTime) {
            Write-Output 'Windows must restart before the recorded driver cleanup can finish. Run the installer again after restart.'
            exit 3010
        }
        $lightingPlan = 'Retry'
    }
    if ($lightingPlan -eq 'Resume' -and $lightingJournal.restartBootTime -eq $lightingBootTime) { $DeferStart = $true }
    $lightingJournal.status = 'installing'
    $lightingJournal.lastError = $null
    Write-RoyalProtectedJson $lightingJournalPath $lightingJournal
    $lightingJournalStarted = $true

    if ($lightingPlan -eq 'Retry') {
        # Only a matching protected package journal permits automatic recovery.
        if ($lightingSnapshot.HasApp) {
            $lightingCode = Invoke-RoyalPowerShell (Join-Path $PackageRoot 'Uninstall-App.ps1')
            if ($lightingCode -ne 0) { throw 'Owned application recovery failed; support files and journal remain for another uninstall attempt.' }
        }
        if (Test-Path -LiteralPath (Join-Path $lightingPaths.StateRoot 'transport-install.json')) {
            $lightingRemoval = @(& (Join-Path $PackageRoot 'transport\Uninstall-Driver.ps1'))
            foreach ($lightingItem in $lightingRemoval) {
                if ($lightingItem.Operation -eq 'UninstallDriver' -and $lightingItem.RebootRequired) {
                    $lightingJournal.status = 'retry-after-reboot'
                    $lightingJournal.restartBootTime = $lightingBootTime
                    Write-RoyalProtectedJson $lightingJournalPath $lightingJournal
                    Write-Output 'Owned driver cleanup requires a restart. Run this installer again after Windows restarts.'
                    exit 3010
                }
                else { Write-Output $lightingItem }
            }
        }
    }
    $lightingArguments = @('-TrustLocalCertificate')
    if ($lightingPlan -eq 'Resume') { $lightingArguments += '-Resume' }
    if ($DeferStart) { $lightingArguments += '-DeferStart' }
    $lightingCode = Invoke-RoyalPowerShell (Join-Path $PackageRoot 'Setup.ps1') $lightingArguments
    if ($lightingCode -notin @(0,3010)) { throw "Setup failed with exit code $lightingCode. See $lightingSetupLog and adapter.log." }
    $lightingJournal.status = if ($lightingCode -eq 3010) { 'restart-required' } else { 'ready' }
    $lightingJournal.restartBootTime = if ($lightingCode -eq 3010) { $lightingBootTime } else { $null }
    Write-RoyalProtectedJson $lightingJournalPath $lightingJournal
    $lightingExitCode = $lightingCode
    Write-Output "Package installation status: $($lightingJournal.status)"
} catch {
    $lightingFailure = $_
    Write-Output ($lightingFailure | Out-String)
    if ($lightingJournalStarted) {
        $lightingJournal.status = 'failed'
        $lightingJournal.lastError = $lightingFailure.Exception.Message
        try { Write-RoyalProtectedJson $lightingJournalPath $lightingJournal } catch { Write-Output "Could not update package journal: $_" }
        # Roll back only objects claimed before this package's setup began.
        # A live task or failed graceful restore stops cleanup and preserves driver/support files.
        try {
            $lightingAppReceipt = Join-Path $lightingPaths.StateRoot 'app-install.json'
            if (Test-Path -LiteralPath $lightingAppReceipt) {
                $lightingCode = Invoke-RoyalPowerShell (Join-Path $PackageRoot 'Uninstall-App.ps1')
                if ($lightingCode -ne 0) { throw 'Application rollback did not finish; driver cleanup was skipped.' }
            }
            if (Test-Path -LiteralPath (Join-Path $lightingPaths.StateRoot 'transport-install.json')) {
                $lightingRollback = @(& (Join-Path $PackageRoot 'transport\Uninstall-Driver.ps1'))
                foreach ($lightingItem in $lightingRollback) {
                    if ($lightingItem.Operation -eq 'UninstallDriver' -and $lightingItem.RebootRequired) {
                        $lightingJournal.status = 'retry-after-reboot'
                        $lightingJournal.restartBootTime = $lightingBootTime
                        Write-RoyalProtectedJson $lightingJournalPath $lightingJournal
                        Write-Output 'Rollback requires a restart before another installation attempt.'
                    } else { Write-Output $lightingItem }
                }
            }
        } catch { Write-Output "Partial installation retained for retry: $_" }
    }
    $lightingExitCode = 1
} finally {
    if ($lightingTranscript) { Stop-Transcript | Out-Null }
}
exit $lightingExitCode
