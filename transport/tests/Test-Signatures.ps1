[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$transport = Split-Path -Parent $PSScriptRoot
& (Join-Path $transport 'Verify-Package.ps1') -Verbose

# Alter a separate fixture in the PE's first section, never the signed package.
$bytes = [System.IO.File]::ReadAllBytes((Join-Path $transport 'driver\WinUHidDriver.dll'))
$pe = [BitConverter]::ToInt32($bytes, 0x3c)
$optionalSize = [BitConverter]::ToUInt16($bytes, $pe + 20)
$section = $pe + 24 + $optionalSize
$raw = [BitConverter]::ToInt32($bytes, $section + 20)
$bytes[$raw + 16] = $bytes[$raw + 16] -bxor 1
$fixtures = Join-Path $transport 'obj\signature-tests'
New-Item -ItemType Directory -Path $fixtures -Force | Out-Null
$corrupt = Join-Path $fixtures 'corrupt-driver.dll'
[System.IO.File]::WriteAllBytes($corrupt, $bytes)
$result = [RoyalDynamicLighting.Installation.Authenticode]::VerifyFile($corrupt)
if ($result.AcceptableBeforeTrust -or $result.HResult -ne 0x80096010L) {
    throw ('Corrupt signature was not rejected as TRUST_E_BAD_DIGEST: 0x{0:X8}' -f $result.HResult)
}
Write-Output 'PASS: corrupted signed DLL rejected with TRUST_E_BAD_DIGEST (0x80096010).'
$unsigned = [RoyalDynamicLighting.Installation.Authenticode]::VerifyFile((Join-Path $transport 'native\WinUHid.dll'))
if ($unsigned.AcceptableBeforeTrust) { throw 'Unsigned client DLL was accepted.' }
Write-Output ('PASS: unsigned DLL rejected (0x{0:X8}).' -f $unsigned.HResult)
& (Join-Path $transport 'Verify-Package.ps1') -Verbose
Write-Output 'PASS: original package remains unchanged; no UI, trust, or installation actions performed.'
