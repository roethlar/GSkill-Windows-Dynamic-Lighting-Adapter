[CmdletBinding()]
param([string]$CompilerPath, [switch]$Publish)
$ErrorActionPreference = 'Stop'
$lightingProject = Split-Path $PSScriptRoot -Parent
if (!$CompilerPath) { $CompilerPath = Join-Path $lightingProject 'tools\installer\inno\ISCC.exe' }
if (!(Test-Path -LiteralPath $CompilerPath)) { throw 'Supply -CompilerPath pointing to Inno Setup 7 ISCC.exe.' }
if ($Publish) {
    & (Join-Path $lightingProject 'Build.ps1') -Publish
    if ($LASTEXITCODE -ne 0) { throw 'Application build failed.' }
}
& (Join-Path $lightingProject 'transport\Verify-Package.ps1') -DriverDirectory (Join-Path $lightingProject 'transport\driver')
$lightingPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
& $lightingPowerShell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'scripts\Install-Prerequisites.ps1') -PackageRoot $PSScriptRoot -CheckOnly
if ($LASTEXITCODE -ne 0) { throw 'Prerequisite verification failed.' }
$lightingStage = Join-Path $lightingProject ('artifacts\installer-build\' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0,8))
$lightingOutput = Join-Path $lightingProject 'artifacts\installer'
New-Item -ItemType Directory -Path $lightingStage,$lightingOutput -Force | Out-Null
function Copy-PayloadFile([string]$RelativePath) {
    $lightingSource = Join-Path $lightingProject $RelativePath
    if (!(Test-Path -LiteralPath $lightingSource -PathType Leaf)) { throw "Missing package input: $RelativePath" }
    $lightingDestination = Join-Path $lightingStage $RelativePath
    New-Item -ItemType Directory -Path (Split-Path $lightingDestination -Parent) -Force | Out-Null
    Copy-Item -LiteralPath $lightingSource -Destination $lightingDestination
}
foreach ($lightingRelative in @(
    'Setup.ps1','Install-App.ps1','Uninstall-App.ps1','config.json',
    'transport\Install-Driver.ps1','transport\Uninstall-Driver.ps1',
    'transport\State-Security.ps1','transport\SignatureVerification.cs','transport\Verify-Package.ps1',
    'transport\driver\WinUHidDriver.dll','transport\driver\WinUHidDriver.inf','transport\driver\WinUHidDriver.cat',
    'transport\driver\RoyalDynamicLighting.cer','transport\driver\signed-package.json',
    'transport\native\RoyalDeviceSetup.exe','transport\RoyalDeviceSetup-LICENSE.txt',
    'transport\driver\WinUHid-LICENSE.txt'
)) { Copy-PayloadFile $lightingRelative }
foreach ($lightingMapping in @(
    @{ Source='artifacts\app'; Destination='artifacts\app' },
    @{ Source='licenses'; Destination='licenses' },
    @{ Source='installer\scripts'; Destination='scripts' },
    @{ Source='installer\dependencies'; Destination='dependencies' }
)) {
    $lightingDestination = Join-Path $lightingStage $lightingMapping.Destination
    New-Item -ItemType Directory -Path $lightingDestination -Force | Out-Null
    Copy-Item -Path (Join-Path (Join-Path $lightingProject $lightingMapping.Source) '*') -Destination $lightingDestination -Recurse -Exclude 'Test-*.ps1'
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'INSTALL.txt') -Destination (Join-Path $lightingStage 'INSTALL.txt')
New-Item -ItemType Directory -Path (Join-Path $lightingStage 'research') -Force | Out-Null
foreach ($lightingRequired in @('scripts\Install-Package.ps1','scripts\Uninstall-Package.ps1','scripts\Install-Prerequisites.ps1','artifacts\app\RoyalDynamicLighting.exe','artifacts\app\WinUHid.dll','artifacts\app\modules\SmbusPIIX4.bin','dependencies\dependencies.json')) {
    if (!(Test-Path -LiteralPath (Join-Path $lightingStage $lightingRequired))) { throw "Missing installer payload: $lightingRequired" }
}
if (Get-ChildItem -LiteralPath $lightingStage -Recurse -File -Filter devcon.exe) { throw 'Do not redistribute the WDK DevCon binary.' }
$lightingScriptFiles = @(Get-ChildItem -LiteralPath $lightingStage -Recurse -File -Filter *.ps1)
foreach ($lightingScript in $lightingScriptFiles) {
    $lightingTokens = $null; $lightingErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($lightingScript.FullName, [ref]$lightingTokens, [ref]$lightingErrors)
    if ($lightingErrors.Count) { throw "PowerShell parsing failed: $($lightingScript.FullName): $lightingErrors" }
}
$lightingFiles = @(Get-ChildItem -LiteralPath $lightingStage -Recurse -File | Sort-Object FullName | ForEach-Object {
    [ordered]@{ path=$_.FullName.Substring($lightingStage.Length+1); bytes=$_.Length; sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash }
})
[ordered]@{ version='0.1.0'; builtAtUtc=(Get-Date).ToUniversalTime().ToString('o'); files=$lightingFiles } |
    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $lightingStage 'payload-manifest.json') -Encoding UTF8
& $CompilerPath '--quiet' ('--define=PayloadDir=' + $lightingStage) ('--define=OutputPath=' + $lightingOutput) (Join-Path $PSScriptRoot 'RoyalDynamicLighting.iss')
if ($LASTEXITCODE -ne 0) { throw 'Inno Setup compilation failed.' }
$lightingInstaller = Join-Path $lightingOutput 'RoyalDynamicLighting-Setup-0.1.0-x64.exe'
$lightingInstallerHash = (Get-FileHash -LiteralPath $lightingInstaller -Algorithm SHA256).Hash
Set-Content -LiteralPath ($lightingInstaller + '.sha256') -Value ($lightingInstallerHash + '  ' + (Split-Path $lightingInstaller -Leaf)) -Encoding ASCII
Copy-Item -LiteralPath (Join-Path $lightingStage 'payload-manifest.json') -Destination (Join-Path $lightingOutput 'payload-manifest.json')
Write-Output "Installer: $lightingInstaller"
Write-Output "SHA256: $lightingInstallerHash"
Write-Output "Payload: $lightingStage"
