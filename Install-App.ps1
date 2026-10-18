#Requires -RunAsAdministrator
[CmdletBinding()]
param([switch]$Resume, [switch]$DeferStart)
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
$lightingSource = Join-Path $PSScriptRoot 'artifacts\app'
$lightingReceipt = Join-Path $lightingState 'app-install.json'
$lightingConfig = Join-Path $lightingState 'config.json'
$lightingLogPath = Join-Path $lightingState 'adapter.log'
$lightingTaskName = 'RoyalDynamicLighting'
if (!(Test-Path -LiteralPath (Join-Path $lightingSource 'RoyalDynamicLighting.exe'))) { throw 'Published application payload is missing.' }
Initialize-RoyalProtectedDirectory $lightingState
foreach ($lightingFile in @($lightingConfig, $lightingLogPath, $lightingReceipt)) {
    Assert-RoyalPlainPath $lightingFile
    if (Test-Path -LiteralPath $lightingFile) { Assert-RoyalStateAcl $lightingFile }
}
if ($Resume) {
    if (!(Test-Path -LiteralPath $lightingReceipt)) { throw 'Cannot resume without an application installation receipt.' }
    $lightingInstall = Get-Content -LiteralPath $lightingReceipt -Raw | ConvertFrom-Json
    if ($lightingInstall.installPath -ne $lightingTarget -or $lightingInstall.taskName -ne $lightingTaskName) { throw 'Application receipt does not match the expected installation.' }
    Assert-RoyalStateAcl $lightingTarget
    $lightingTask = Get-ScheduledTask -TaskName $lightingTaskName -TaskPath '\' -ErrorAction Stop
    Assert-RoyalTask $lightingTask $lightingTarget $lightingState
    Stop-RoyalTask $lightingTarget $lightingState
} else {
    if (Test-Path -LiteralPath $lightingReceipt) { throw 'An application receipt already exists. Resume or uninstall that owned installation before replacing it.' }
    if (Get-ScheduledTask -TaskName $lightingTaskName -TaskPath '\' -ErrorAction SilentlyContinue) { throw 'The adapter task already exists and will not be overwritten.' }
    Assert-RoyalPlainPath $lightingTarget
    if (Test-Path -LiteralPath $lightingTarget) { throw "Target already exists: $lightingTarget. It will not be overwritten." }
    if (Test-Path -LiteralPath $lightingConfig) {
        $null = Get-RoyalConfiguration $lightingConfig
        Write-Output "Preserving existing verified configuration: $lightingConfig"
    } else {
        $lightingSourceConfig = Join-Path $PSScriptRoot 'config.json'
        $lightingSavedConfig = Get-RoyalConfiguration $lightingSourceConfig
        Write-RoyalProtectedJson $lightingConfig $lightingSavedConfig
    }
    if (!(Test-Path -LiteralPath $lightingLogPath)) { New-RoyalProtectedFile $lightingLogPath }
    # Record ownership before creating the target or scheduled task.
    Write-RoyalProtectedJson $lightingReceipt ([ordered]@{ installPath = $lightingTarget; taskName = $lightingTaskName; status = 'preparing'; installedAt = (Get-Date).ToUniversalTime().ToString('o') })
    New-Item -ItemType Directory -Path $lightingTarget | Out-Null
    Set-RoyalStateAcl $lightingTarget $true
    Copy-Item -Path "$lightingSource\*" -Destination $lightingTarget -Recurse
    $lightingExe = Join-Path $lightingTarget 'RoyalDynamicLighting.exe'
    $lightingAction = New-ScheduledTaskAction -Execute $lightingExe -Argument (Get-RoyalTaskArguments $lightingState) -WorkingDirectory $lightingTarget
    $lightingTrigger = New-ScheduledTaskTrigger -AtStartup
    $lightingTrigger.Delay = 'PT20S'
    $lightingPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $lightingSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $lightingTaskName -TaskPath '\' -Action $lightingAction -Trigger $lightingTrigger -Principal $lightingPrincipal -Settings $lightingSettings -Description 'Expose G.Skill Royal RAM to Windows Dynamic Lighting using direct PawnIO access.' | Out-Null
}
$null = Get-RoyalConfiguration $lightingConfig
if (!(Test-Path -LiteralPath $lightingLogPath)) { New-RoyalProtectedFile $lightingLogPath }
$lightingTask = Get-ScheduledTask -TaskName $lightingTaskName -TaskPath '\' -ErrorAction Stop
Assert-RoyalTask $lightingTask $lightingTarget $lightingState
Enable-ScheduledTask -TaskName $lightingTaskName -TaskPath '\' | Out-Null
$lightingStatus = 'pending-reboot'
if (!$DeferStart) {
    $lightingLogOffset = (Get-Item -LiteralPath $lightingLogPath).Length
    Start-ScheduledTask -TaskName $lightingTaskName -TaskPath '\'
    $lightingDeadline = (Get-Date).AddSeconds(25)
    $lightingReady = $false
    do {
        Start-Sleep -Milliseconds 500
        $lightingNewLog = Read-RoyalLogSince $lightingLogPath $lightingLogOffset
        if ($lightingNewLog -match 'ERROR:') { throw "Adapter startup failed. Diagnostics retained at $lightingLogPath" }
        $lightingTask = Get-ScheduledTask -TaskName $lightingTaskName -TaskPath '\'
        if ($lightingNewLog -match 'Serving [0-9]+ RAM LEDs' -and $lightingTask.State -eq 'Running') {
            $lightingReady = $true
            break
        }
    } while ((Get-Date) -lt $lightingDeadline)
    if (!$lightingReady) { throw "Adapter did not report ready within 25 seconds. Diagnostics retained at $lightingLogPath" }
    $lightingStatus = 'installed'
}
Write-RoyalProtectedJson $lightingReceipt ([ordered]@{ installPath = $lightingTarget; taskName = $lightingTaskName; status = $lightingStatus; installedAt = (Get-Date).ToUniversalTime().ToString('o') })
if ($DeferStart) { Write-Output 'Application and startup task installed; adapter startup is deferred until Windows restarts.' }
else { Write-Output "Installed and verified adapter startup. Logs: $lightingLogPath" }
