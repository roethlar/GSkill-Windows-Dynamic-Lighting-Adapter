# Pure lifecycle checks plus a temporary log fixture. No installer, task, driver,
# certificate, administrator command, or hardware operation is invoked.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Package-Common.ps1')
function Check([bool]$Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Throws([scriptblock]$Action, [string]$Message) {
    $thrown = $false
    try { & $Action } catch { $thrown = $true }
    Check $thrown $Message
}
function New-TestJournal([string]$Status) {
    [pscustomobject]@{ packageId = $script:RoyalPackageId; schemaVersion = 1; supportRoot = 'C:\Program Files\RoyalDynamicLighting Setup'; status = $Status; appOwned = $true; driverOwned = $true }
}
$support = 'C:\Program Files\RoyalDynamicLighting Setup'
Check ((Get-RoyalInstallPlan $null $false $false $support) -eq 'Fresh') 'Clean install must be fresh.'
Throws { Get-RoyalInstallPlan $null $true $false $support } 'Manual app must be refused.'
Throws { Get-RoyalInstallPlan $null $false $true $support } 'Manual driver must be refused.'
foreach ($status in @('failed', 'installing')) {
    Check ((Get-RoyalInstallPlan (New-TestJournal $status) $true $true $support) -eq 'Retry') 'Owned partial installation must be retryable.'
}
Check ((Get-RoyalInstallPlan (New-TestJournal 'restart-required') $true $true $support) -eq 'Resume') 'Restart must resume existing application.'
Check ((Get-RoyalInstallPlan (New-TestJournal 'retry-after-reboot') $false $false $support) -eq 'RetryAfterReboot') 'Pending removal must wait for restart.'
Throws { Get-RoyalInstallPlan (New-TestJournal 'ready') $true $true $support } 'Installed release must not be overwritten silently.'
Throws { Get-RoyalInstallPlan (New-TestJournal 'uninstalling') $false $true $support } 'Partial uninstall must retain recovery state.'
$bad = New-TestJournal 'failed'
$bad.appOwned = $false
Throws { Get-RoyalInstallPlan $bad $true $true $support } 'Unowned application cannot be reclaimed.'
$bad = New-TestJournal 'failed'
$bad.supportRoot = 'C:\Elsewhere'
Throws { Get-RoyalInstallPlan $bad $true $true $support } 'Journal cannot redirect cleanup.'
Write-Output 'PASS: ownership, fresh/retry/resume/reboot, and refusal transitions'

$config = '{"Port":0,"FramesPerSecond":30,"Devices":[{"Address":113,"Firmware":"AUDA0-E6K5-0101","Manufacturer":"raw:010203","LedCount":8},{"Address":115,"Firmware":"AUDA0-E6K5-0101","Manufacturer":"raw:010203","LedCount":8}]}' | ConvertFrom-Json
Assert-RoyalConfiguration $config
$config.Devices[1].Address = 113
Throws { Assert-RoyalConfiguration $config } 'Duplicate addresses must fail before installation.'
$config.Devices[1].Address = 0x50
Throws { Assert-RoyalConfiguration $config } 'SPD address must never be accepted.'
$config.Devices[1].Address = 115
$config.Devices[1].Firmware = 'UNRECOGNIZED'
Throws { Assert-RoyalConfiguration $config } 'Unknown firmware must be rejected.'
$config.Devices[1].Firmware = 'AUDA0-E6K5-0101'
$config.FramesPerSecond = '30'
Throws { Assert-RoyalConfiguration $config } 'String numbers accepted by PowerShell must still be rejected for the managed JSON parser.'
Write-Output 'PASS: preserved configuration validation'

$task = [pscustomobject]@{
    Actions = @([pscustomobject]@{ Execute = 'C:\Program Files\RoyalDynamicLighting\RoyalDynamicLighting.exe'; Arguments = 'run --config "C:\ProgramData\RoyalDynamicLighting\config.json" --log "C:\ProgramData\RoyalDynamicLighting\adapter.log"' })
    Principal = [pscustomobject]@{ UserId = 'SYSTEM' }
}
Assert-RoyalTask $task 'C:\Program Files\RoyalDynamicLighting' 'C:\ProgramData\RoyalDynamicLighting'
$task.Actions[0].Execute = 'C:\Other.exe'
Throws { Assert-RoyalTask $task 'C:\Program Files\RoyalDynamicLighting' 'C:\ProgramData\RoyalDynamicLighting' } 'Unrelated task executable must not be stopped or removed.'
Write-Output 'PASS: scheduled task ownership and quoted argument checks'

# Every task/process command below is replaced in this child scope. These checks
# exercise the real stop coordinator without elevation, tasks, or an executable.
& {
    $appRoot = 'C:\Program Files\RoyalDynamicLighting'
    $stateRoot = 'C:\ProgramData\RoyalDynamicLighting'
    $mock = [pscustomobject]@{ Mode = ''; ProcessChecks = 0; Clock = 0; Events = $null }
    $mockTask = [pscustomobject]@{
        State = 'Disabled'
        Actions = @([pscustomobject]@{ Execute = "$appRoot\RoyalDynamicLighting.exe"; Arguments = (Get-RoyalTaskArguments $stateRoot) })
        Principal = [pscustomobject]@{ UserId = 'SYSTEM' }
    }
    function Get-ScheduledTask {
        param($TaskName, $TaskPath, $ErrorAction)
        if ($TaskName -eq 'RoyalDynamicLighting') { $mockTask }
        else { [pscustomobject]@{ State = 'Ready' } }
    }
    function Disable-ScheduledTask {
        param($TaskName, $TaskPath, $ErrorAction)
        Check ($TaskName -eq 'RoyalDynamicLighting' -and $TaskPath -eq '\') 'Only the owned main task may be disabled.'
        $mock.Events.Add('disable')
    }
    function Get-RoyalAdapterProcesses {
        param($Executable)
        $mock.ProcessChecks++
        if ($mock.Mode -eq 'Stopped') { return }
        if ($mock.Mode -in @('Success', 'Nonzero') -and $mock.ProcessChecks -gt 1) { return }
        [pscustomobject]@{ ProcessId = 1234; ExecutablePath = $Executable }
    }
    function Test-Path { param($LiteralPath) return $true }
    function New-ScheduledTaskAction {
        param($Execute, $Argument, $WorkingDirectory)
        Check ($Execute -eq "$appRoot\RoyalDynamicLighting.exe" -and $Argument -eq 'stop' -and $WorkingDirectory -eq $appRoot) 'SYSTEM helper must only invoke the installed stop command.'
        [pscustomobject]@{ Execute = $Execute; Arguments = $Argument }
    }
    function New-ScheduledTaskPrincipal {
        param($UserId, $LogonType, $RunLevel)
        Check ($UserId -eq 'SYSTEM' -and $LogonType -eq 'ServiceAccount' -and $RunLevel -eq 'Highest') 'Shutdown helper must run as SYSTEM.'
        [pscustomobject]@{ UserId = $UserId }
    }
    function New-ScheduledTaskSettingsSet {
        param([switch]$AllowStartIfOnBatteries, [switch]$DontStopIfGoingOnBatteries, $ExecutionTimeLimit, $MultipleInstances)
        [pscustomobject]@{ MultipleInstances = $MultipleInstances }
    }
    function Register-ScheduledTask {
        param($TaskName, $TaskPath, $Action, $Principal, $Settings, $Description, $Trigger, $ErrorAction)
        Check ($TaskName -match '^RoyalDynamicLighting\.Stop\.[0-9a-f]{32}$') 'Helper name must be unique and scoped to shutdown.'
        Check (!$PSBoundParameters.ContainsKey('Trigger')) 'Helper must have no automatic trigger.'
        $mock.Events.Add('register')
        if ($mock.Mode -eq 'RegisterFail') { throw 'Simulated registration failure.' }
    }
    function Start-ScheduledTask { param($TaskName, $TaskPath, $ErrorAction) $mock.Events.Add('start') }
    function Unregister-ScheduledTask { param($TaskName, $TaskPath, $Confirm, $ErrorAction) $mock.Events.Add('cleanup') }
    function Get-ScheduledTaskInfo {
        param($TaskName, $TaskPath, $ErrorAction)
        $result = 0
        if ($TaskName -ne 'RoyalDynamicLighting' -and $mock.Mode -eq 'SignalFail') { $result = 1 }
        if ($TaskName -eq 'RoyalDynamicLighting' -and $mock.Mode -eq 'Nonzero') { $result = 1 }
        [pscustomobject]@{ LastTaskResult = $result; LastRunTime = [datetime]'2026-01-01T00:00:00' }
    }
    function Get-Date {
        $value = ([datetime]'2026-01-01T00:00:00').AddSeconds($mock.Clock)
        $mock.Clock++
        return $value
    }
    function Start-Sleep { param($Milliseconds) }
    foreach ($mode in @('Success', 'Nonzero', 'Stopped', 'SignalFail', 'Timeout', 'RegisterFail')) {
        $mock.Mode = $mode
        $mock.ProcessChecks = 0
        $mock.Clock = 0
        $mock.Events = New-Object 'Collections.Generic.List[string]'
        if ($mode -in @('SignalFail', 'Timeout', 'RegisterFail')) {
            Throws { Stop-RoyalTask $appRoot $stateRoot } "Shutdown must fail for $mode."
        } else { Stop-RoyalTask $appRoot $stateRoot -WarningAction SilentlyContinue }
        Check ($mock.Events[0] -eq 'disable') 'Disable automatic startup before any helper operation.'
        if ($mode -eq 'Stopped') { Check ($mock.Events.Count -eq 1) 'Already stopped adapter needs no helper.' }
        elseif ($mode -eq 'RegisterFail') { Check (!$mock.Events.Contains('cleanup')) 'Failed registration must never delete an unowned helper.' }
        else { Check ($mock.Events[$mock.Events.Count - 1] -eq 'cleanup') 'Always remove the registered SYSTEM helper.' }
    }
}
Write-Output 'PASS: disabled-task graceful SYSTEM shutdown, actual-process waiting, failure retention, and helper cleanup'

$logFixture = Join-Path ([IO.Path]::GetTempPath()) ('Royal-log-test-' + [Guid]::NewGuid().ToString('N') + '.txt')
try {
    [IO.File]::WriteAllText($logFixture, "old Serving 16 RAM LEDs`r`n", [Text.Encoding]::UTF8)
    $offset = (Get-Item -LiteralPath $logFixture).Length
    [IO.File]::AppendAllText($logFixture, "new ERROR: simulated failure`r`n", [Text.Encoding]::UTF8)
    $newLog = Read-RoyalLogSince $logFixture $offset
    Check ($newLog -notmatch 'Serving') 'Old successful startup text must not leak into new startup checks.'
    Check ($newLog -match 'new ERROR:') 'New startup failure must remain visible.'
    Throws { Read-RoyalLogSince $logFixture 999999 } 'Unexpected log truncation must fail closed.'
} finally {
    if (Test-Path -LiteralPath $logFixture) { Remove-Item -LiteralPath $logFixture }
}
Write-Output 'PASS: fresh log offsets preserve history without false startup success'

# Replace only the ACL adapters within this child scope. The real atomic JSON
# write/replace logic is exercised on an ordinary temporary file without elevation.
$journalFixture = Join-Path ([IO.Path]::GetTempPath()) ('Royal-journal-test-' + [Guid]::NewGuid().ToString('N') + '.json')
try {
    & {
        param($Fixture)
        function Assert-RoyalPlainPath([string]$Path) { }
        function Assert-RoyalStateAcl([string]$Path) { }
        function New-RoyalProtectedFile([string]$Path) {
            $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew)
            $stream.Dispose()
        }
        Write-RoyalProtectedJson $Fixture ([pscustomobject]@{ status = 'installing' })
        Write-RoyalProtectedJson $Fixture ([pscustomobject]@{ status = 'ready' })
        Check ((Get-Content -LiteralPath $Fixture -Raw | ConvertFrom-Json).status -eq 'ready') 'Atomic receipt replacement must preserve a readable final record.'
    } $journalFixture
} finally {
    if (Test-Path -LiteralPath $journalFixture) { Remove-Item -LiteralPath $journalFixture }
}
Write-Output 'PASS: atomic receipt creation and replacement under Windows PowerShell'

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$parseFiles = @('Setup.ps1','Install-App.ps1','Uninstall-App.ps1','installer\scripts\Package-Common.ps1','installer\scripts\Install-Package.ps1','installer\scripts\Uninstall-Package.ps1')
foreach ($path in $parseFiles) {
    $tokens = $null
    $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot $path), [ref]$tokens, [ref]$errors)
    Check ($errors.Count -eq 0) "Parser errors in $path"
}
Write-Output 'PASS: lifecycle scripts parse without errors'
