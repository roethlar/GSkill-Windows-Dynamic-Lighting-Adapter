# Imported by lifecycle scripts. Importing this file performs no system changes.
$script:RoyalPackageId = 'RoyalDynamicLighting.Standalone.v1'

function Assert-RoyalAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run the installer with administrator rights. This script never requests elevation itself.'
    }
}

function Get-RoyalPackagePaths([string]$PackageRoot) {
    [pscustomobject]@{
        PackageRoot = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')
        SupportRoot = [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'RoyalDynamicLighting Setup'))
        AppRoot = [IO.Path]::GetFullPath((Join-Path $env:ProgramFiles 'RoyalDynamicLighting'))
        StateRoot = [IO.Path]::GetFullPath((Join-Path $env:ProgramData 'RoyalDynamicLighting'))
        TaskName = 'RoyalDynamicLighting'
    }
}

function Assert-RoyalTrustedDirectory([string]$Path) {
    Assert-RoyalPlainPath $Path
    $acl = Get-Acl -LiteralPath $Path
    $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($owner -notin @('S-1-5-32-544', 'S-1-5-18')) { throw "Untrusted directory owner: $Path" }
    $writes = [int][Security.AccessControl.FileSystemRights]::Write -bor
        [int][Security.AccessControl.FileSystemRights]::Delete -bor
        [int][Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [int][Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [int][Security.AccessControl.FileSystemRights]::TakeOwnership -bor 0x10000000 -bor 0x40000000
    $trustedWriters = @('S-1-5-32-544', 'S-1-5-18', 'S-1-3-0',
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464') # TrustedInstaller
    foreach ($rule in $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            $rule.IdentityReference.Value -notin $trustedWriters -and
            (([int]$rule.FileSystemRights -band $writes) -ne 0)) {
            throw "Directory permits non-administrator writes: $Path"
        }
    }
}

function Initialize-RoyalProtectedDirectory([string]$Path) {
    Assert-RoyalPlainPath $Path
    if (Test-Path -LiteralPath $Path) { Assert-RoyalStateAcl $Path }
    else {
        New-Item -ItemType Directory -Path $Path -ErrorAction Stop | Out-Null
        Set-RoyalStateAcl $Path $true
    }
}

function New-RoyalProtectedFile([string]$Path) {
    Assert-RoyalPlainPath $Path
    $stream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $stream.Dispose()
    Set-RoyalStateAcl $Path $false
}

function Write-RoyalProtectedJson([string]$Path, $Value) {
    Assert-RoyalPlainPath $Path
    if (Test-Path -LiteralPath $Path) { Assert-RoyalStateAcl $Path }
    $temporary = Join-Path ([IO.Path]::GetDirectoryName($Path)) ('.receipt-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        New-RoyalProtectedFile $temporary
        $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temporary -Encoding UTF8
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { Move-Item -LiteralPath $temporary -Destination $Path -ErrorAction Stop }
        Assert-RoyalStateAcl $Path
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

function Get-RoyalPackageSnapshot($Paths, [switch]$SkipConfigurationValidation) {
    Assert-RoyalPlainPath $Paths.SupportRoot
    Assert-RoyalPlainPath $Paths.AppRoot
    Assert-RoyalPlainPath $Paths.StateRoot
    $journal = $null
    if (Test-Path -LiteralPath $Paths.StateRoot) {
        Assert-RoyalStateAcl $Paths.StateRoot
        foreach ($name in @('package-install.json','app-install.json','transport-install.json','config.json','adapter.log','setup.log')) {
            $path = Join-Path $Paths.StateRoot $name
            Assert-RoyalPlainPath $path
            if (Test-Path -LiteralPath $path) { Assert-RoyalStateAcl $path }
        }
        $journalPath = Join-Path $Paths.StateRoot 'package-install.json'
        if (Test-Path -LiteralPath $journalPath) {
            $journal = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
            if ($null -eq $journal) { throw 'The package installation journal is empty.' }
        }
        $config = Join-Path $Paths.StateRoot 'config.json'
        if (!$SkipConfigurationValidation -and (Test-Path -LiteralPath $config)) { $null = Get-RoyalConfiguration $config }
    }
    $task = Get-ScheduledTask -TaskName 'RoyalDynamicLighting' -TaskPath '\' -ErrorAction SilentlyContinue
    $hasApp = (Test-Path -LiteralPath $Paths.AppRoot) -or [bool]$task -or (Test-Path -LiteralPath (Join-Path $Paths.StateRoot 'app-install.json'))
    $hasDriver = Test-Path -LiteralPath (Join-Path $Paths.StateRoot 'transport-install.json')
    [pscustomobject]@{ Journal = $journal; HasApp = $hasApp; HasDriver = $hasDriver }
}

function Assert-RoyalConfiguration($Config) {
    if ($null -eq $Config -or !($Config.Port -is [int] -or $Config.Port -is [long]) -or
        !($Config.FramesPerSecond -is [int] -or $Config.FramesPerSecond -is [long]) -or $Config.Port -notin @(0, 1) -or
        $Config.FramesPerSecond -lt 1 -or $Config.FramesPerSecond -gt 30) {
        throw 'Configuration requires SMBus port 0 or 1 and a frame rate between 1 and 30.'
    }
    $devices = @($Config.Devices)
    if ($devices.Count -lt 1 -or $devices.Count -gt 4) { throw 'Configuration requires one to four RAM modules.' }
    $addresses = @(0x39,0x3A,0x3B,0x3C,0x3D,0x3E,0x3F,0x4F,0x66,0x67,0x70,0x71,0x72,0x73,0x74,0x75,0x76)
    $seen = @{}
    $ledCount = $devices[0].LedCount
    foreach ($device in $devices) {
        if ($null -eq $device -or !($device.Address -is [int] -or $device.Address -is [long]) -or
            !($device.LedCount -is [int] -or $device.LedCount -is [long]) -or
            !($device.Firmware -is [string]) -or !($device.Manufacturer -is [string]) -or
            $device.Address -notin $addresses -or $seen.ContainsKey([string]$device.Address) -or
            $device.LedCount -lt 1 -or $device.LedCount -gt 16 -or $device.LedCount -ne $ledCount -or
            $device.Firmware -ne 'AUDA0-E6K5-0101' -or [string]::IsNullOrWhiteSpace($device.Manufacturer)) {
            throw 'Configuration has an unsupported controller identity, address, LED count, or duplicate module.'
        }
        $seen[[string]$device.Address] = $true
    }
}

function Get-RoyalConfiguration([string]$Path) {
    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    Assert-RoyalConfiguration $config
    return $config
}

function Get-RoyalInstallPlan($Journal, [bool]$HasApp, [bool]$HasDriver, [string]$SupportRoot) {
    if ($null -eq $Journal) {
        if ($HasApp -or $HasDriver) {
            throw 'A manual or unowned Royal Dynamic Lighting installation already exists. Remove it with its original uninstall scripts before using this installer; it will not be replaced automatically.'
        }
        return 'Fresh'
    }
    if ($Journal.packageId -ne $script:RoyalPackageId -or $Journal.supportRoot -ne $SupportRoot -or $Journal.schemaVersion -ne 1 -or
        !($Journal.appOwned -is [bool]) -or !($Journal.driverOwned -is [bool])) {
        throw 'The installation journal belongs to a different package or path.'
    }
    if (($HasApp -and !$Journal.appOwned) -or ($HasDriver -and !$Journal.driverOwned)) {
        throw 'Existing application or driver state is not owned by this installation journal.'
    }
    switch ($Journal.status) {
        'ready' { throw 'Royal Dynamic Lighting is already installed. Use its Apps uninstall entry before replacing this release.' }
        'restart-required' { return 'Resume' }
        'retry-after-reboot' { return 'RetryAfterReboot' }
        'installing' { return 'Retry' }
        'failed' { return 'Retry' }
        'uninstalling' { throw 'A previous uninstall is incomplete. Run the Apps uninstall entry again before installing.' }
        default { throw 'The installation journal has an unsupported status.' }
    }
}

function Get-RoyalBootIdentity {
    return (Get-CimInstance Win32_OperatingSystem -Property LastBootUpTime -OperationTimeoutSec 15).LastBootUpTime.ToUniversalTime().ToString('o')
}

function Read-RoyalLogSince([string]$Path, [long]$Offset) {
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        if ($Offset -gt $stream.Length) { throw 'Adapter log was unexpectedly truncated during startup.' }
        $stream.Position = $Offset
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true, 4096, $true)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}

function Invoke-RoyalPowerShell([string]$ScriptPath, [string[]]$Arguments = @()) {
    # This process inherits the installer's token; it never launches another UAC prompt.
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (![Environment]::Is64BitProcess) {
        $powershell = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
    }
    & $powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $ScriptPath @Arguments |
        ForEach-Object { Write-Host $_ }
    return [int]$LASTEXITCODE
}

function Get-RoyalTaskArguments([string]$StateRoot) {
    return ('run --config "' + $StateRoot + '\config.json" --log "' + $StateRoot + '\adapter.log"')
}

function Assert-RoyalTask($Task, [string]$AppRoot, [string]$StateRoot) {
    $actions = @($Task.Actions)
    if ($actions.Count -ne 1 -or $actions[0].Execute -ne (Join-Path $AppRoot 'RoyalDynamicLighting.exe') -or
        $actions[0].Arguments -ne (Get-RoyalTaskArguments $StateRoot) -or
        $Task.Principal.UserId -notin @('SYSTEM', 'S-1-5-18')) {
        throw 'The scheduled task does not match this adapter installation; it will not be changed.'
    }
}

function Get-RoyalAdapterProcesses([string]$Executable) {
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name = 'RoyalDynamicLighting.exe'" -ErrorAction Stop)) {
        if ([string]::IsNullOrWhiteSpace($process.ExecutablePath)) {
            throw "Cannot verify the executable path of adapter process $($process.ProcessId); its files have been retained."
        }
        if ([IO.Path]::GetFullPath($process.ExecutablePath) -eq $Executable) { $process }
    }
}

function Stop-RoyalTask([string]$AppRoot, [string]$StateRoot) {
    $exe = Join-Path $AppRoot 'RoyalDynamicLighting.exe'
    $task = Get-ScheduledTask -TaskName 'RoyalDynamicLighting' -TaskPath '\' -ErrorAction SilentlyContinue
    if (!$task) {
        if (@(Get-RoyalAdapterProcesses $exe).Count) { throw 'An installed adapter process is running without its owned scheduled task; its files and driver have been retained.' }
        return
    }
    Assert-RoyalTask $task $AppRoot $StateRoot
    # Disabled tasks can still have a running instance. Always inspect actual
    # processes, and prevent startup/retry even when graceful shutdown fails.
    Disable-ScheduledTask -TaskName 'RoyalDynamicLighting' -TaskPath '\' -ErrorAction Stop | Out-Null
    if (!@(Get-RoyalAdapterProcesses $exe).Count) { return }
    if (!(Test-Path -LiteralPath $exe)) { throw 'A running adapter cannot be stopped because its executable is missing.' }
    # The global stop event is owned by SYSTEM. An administrator process does
    # not necessarily have access, so signal it with a short SYSTEM task. It has
    # no trigger or retry policy and is removed even if signaling fails.
    $helperName = 'RoyalDynamicLighting.Stop.' + [Guid]::NewGuid().ToString('N')
    $helperRegistered = $false
    try {
        $action = New-ScheduledTaskAction -Execute $exe -Argument 'stop' -WorkingDirectory $AppRoot
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $helperName -TaskPath '\' -Action $action -Principal $principal -Settings $settings -Description 'Temporary Royal Dynamic Lighting graceful shutdown signal; no automatic trigger.' -ErrorAction Stop | Out-Null
        $helperRegistered = $true
        $startedAt = Get-Date
        Start-ScheduledTask -TaskName $helperName -TaskPath '\' -ErrorAction Stop
        $deadline = $startedAt.AddSeconds(20)
        do {
            Start-Sleep -Milliseconds 250
            $remaining = @(Get-RoyalAdapterProcesses $exe)
            $helperTask = Get-ScheduledTask -TaskName $helperName -TaskPath '\' -ErrorAction Stop
            $helperInfo = Get-ScheduledTaskInfo -TaskName $helperName -TaskPath '\' -ErrorAction Stop
            $helperFinished = $helperInfo.LastRunTime -ge $startedAt.AddSeconds(-2) -and
                $helperTask.State -notin @('Running', 'Queued') -and $helperInfo.LastTaskResult -notin @(267009, 267011)
            if ($helperFinished) {
                if ($helperInfo.LastTaskResult -ne 0 -and $remaining.Count) {
                    throw "SYSTEM shutdown signal failed with error $($helperInfo.LastTaskResult). The startup task is disabled; the running adapter and its files have been retained."
                }
                if (!$remaining.Count) {
                    $result = (Get-ScheduledTaskInfo -TaskName 'RoyalDynamicLighting' -TaskPath '\' -ErrorAction Stop).LastTaskResult
                    if ($result -ne 267009) {
                        if ($result -ne 0) { Write-Warning "Adapter exited with error $result. No adapter process remains; inspect adapter.log for any lighting restoration error." }
                        return
                    }
                }
            }
        } while ((Get-Date) -lt $deadline)
        throw 'Adapter shutdown did not finish. Its startup task is disabled; its files and driver have been retained.'
    } finally {
        if ($helperRegistered) { Unregister-ScheduledTask -TaskName $helperName -TaskPath '\' -Confirm:$false -ErrorAction Stop }
    }
}
