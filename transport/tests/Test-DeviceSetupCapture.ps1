[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$helper = Join-Path (Split-Path -Parent $PSScriptRoot) 'native\RoyalDeviceSetup.exe'
# A relative INF is rejected before enumeration, staging, or device changes.
try {
    $captured = @(& $helper install 'relative\WinUHidDriver.inf')
    $childCode = $LASTEXITCODE
    if ($childCode -ne 161) { throw "Unexpected invalid-path exit code: $childCode" }
    Write-Output "PASS: stdout capture completed under ErrorActionPreference=Stop; exit=$childCode; stdoutLines=$($captured.Count)."
} catch {
    Write-Output "CAUGHT: $($_.Exception.GetType().FullName): $($_.Exception.Message); exit=$LASTEXITCODE"
    exit 7
}
