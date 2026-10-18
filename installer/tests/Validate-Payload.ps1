[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$PackageRoot)
$ErrorActionPreference = 'Stop'
$env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules')
try {
    $lightingRoot = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\')
    $lightingManifest = Get-Content -LiteralPath (Join-Path $lightingRoot 'payload-manifest.json') -Raw | ConvertFrom-Json
    foreach ($lightingFile in $lightingManifest.files) {
        $lightingPath = [IO.Path]::GetFullPath((Join-Path $lightingRoot $lightingFile.path))
        if (!$lightingPath.StartsWith($lightingRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Manifest path escapes payload.' }
        if ((Get-FileHash -LiteralPath $lightingPath -Algorithm SHA256).Hash -ne $lightingFile.sha256) { throw "Payload hash mismatch: $($lightingFile.path)" }
    }
    foreach ($lightingFile in Get-ChildItem -LiteralPath $lightingRoot -Recurse -File -Filter *.ps1) {
        $lightingTokens = $null; $lightingErrors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($lightingFile.FullName, [ref]$lightingTokens, [ref]$lightingErrors)
        if ($lightingErrors.Count) { throw "Invalid Windows PowerShell syntax: $($lightingFile.Name)" }
    }
    . (Join-Path $lightingRoot 'scripts\Package-Common.ps1')
    $null = Get-RoyalConfiguration (Join-Path $lightingRoot 'config.json')
    & (Join-Path $lightingRoot 'transport\Verify-Package.ps1') -DriverDirectory (Join-Path $lightingRoot 'transport\driver')
    $lightingShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $lightingShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $lightingRoot 'scripts\Install-Prerequisites.ps1') -PackageRoot $lightingRoot -CheckOnly
    if ($LASTEXITCODE -ne 0) { throw 'Bundled prerequisite verification failed.' }
    & (Join-Path $lightingRoot 'transport\native\RoyalDeviceSetup.exe') --help
    if ($LASTEXITCODE -ne 0) { throw 'Native device setup helper could not load.' }
    foreach ($lightingRelative in @('artifacts\app\RoyalDynamicLighting.exe','artifacts\app\WinUHid.dll','transport\driver\WinUHidDriver.dll','transport\native\RoyalDeviceSetup.exe')) {
        $lightingStream = [IO.File]::OpenRead((Join-Path $lightingRoot $lightingRelative))
        $lightingReader = New-Object IO.BinaryReader $lightingStream
        try {
            $lightingStream.Position = 0x3c
            $lightingHeader = $lightingReader.ReadInt32()
            $lightingStream.Position = $lightingHeader
            if ($lightingReader.ReadUInt32() -ne 0x4550 -or $lightingReader.ReadUInt16() -ne 0x8664) { throw "Expected native x64 PE: $lightingRelative" }
        } finally { $lightingReader.Dispose(); $lightingStream.Dispose() }
    }
    if (Get-ChildItem -LiteralPath $lightingRoot -Recurse -File -Filter devcon.exe) { throw 'The package contains the WDK DevCon binary.' }
    Write-Output "PASS: extracted payload, $(@($lightingManifest.files).Count) hashes, PowerShell 5.1 syntax, hardware configuration, signed driver/prerequisites, x64 binaries, and helper loading. No installation was performed."
    exit 0
} catch {
    Write-Output ($_ | Out-String)
    exit 1
}
