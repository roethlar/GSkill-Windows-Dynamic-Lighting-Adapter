[CmdletBinding()]
param([string]$DriverDirectory)
# Keep Windows PowerShell's built-in module discovery independent of its host.
if ($PSVersionTable.PSEdition -eq 'Desktop') { $env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules') }
$ErrorActionPreference = 'Stop'
if (!$DriverDirectory) { $DriverDirectory = Join-Path $PSScriptRoot 'driver' }
if (!('RoyalDynamicLighting.Installation.Authenticode' -as [type])) {
    $signatureSource = Join-Path $PSScriptRoot 'SignatureVerification.cs'
    if ($PSVersionTable.PSEdition -eq 'Core') {
        # CreateFromSignedFile remains necessary for the shared .NET Framework
        # implementation; newer .NET marks only this compatible API obsolete.
        Add-Type -Path $signatureSource -CompilerOptions '/nowarn:SYSLIB0057'
    } else {
        Add-Type -Path $signatureSource
    }
}
function Get-PackageSha256([string]$Path) {
    $hash = [System.Security.Cryptography.SHA256]::Create()
    $stream = [System.IO.File]::OpenRead($Path)
    try { [BitConverter]::ToString($hash.ComputeHash($stream)).Replace('-', '') }
    finally { $stream.Dispose(); $hash.Dispose() }
}
$manifest = Get-Content -LiteralPath (Join-Path $DriverDirectory 'signed-package.json') -Raw | ConvertFrom-Json
$certificate = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (Join-Path $DriverDirectory 'RoyalDynamicLighting.cer')
try {
    if ($certificate.Thumbprint -ne $manifest.thumbprint) { throw 'Signing certificate does not match the package manifest.' }
    $expectedFiles = @('WinUHidDriver.dll','WinUHidDriver.inf','WinUHidDriver.cat')
    if (@($manifest.files).Count -ne $expectedFiles.Count -or @($manifest.files.name | Select-Object -Unique).Count -ne $expectedFiles.Count) {
        throw 'Package manifest must contain exactly the driver DLL, INF, and catalog.'
    }
    foreach ($file in $manifest.files) {
        if ($file.name -notin $expectedFiles) { throw 'Unexpected manifest file.' }
        if ((Get-PackageSha256 (Join-Path $DriverDirectory $file.name)) -ne $file.sha256) { throw "Package hash mismatch: $($file.name)" }
    }
    foreach ($name in @('WinUHidDriver.dll','WinUHidDriver.cat')) {
        $result = [RoyalDynamicLighting.Installation.Authenticode]::VerifyFile((Join-Path $DriverDirectory $name))
        $code = '0x{0:X8}' -f $result.HResult
        Write-Verbose "WinVerifyTrust ${name}: $code"
        if (!$result.AcceptableBeforeTrust) { throw "Invalid Authenticode signature for ${name}: WinVerifyTrust=$code" }
        if ($result.SignerThumbprint -ne $certificate.Thumbprint) { throw "Signature mismatch: $name" }
    }
    Write-Output "Package hashes/signers verified. Only S_OK and CERT_E_UNTRUSTEDROOT (0x800B0109) are accepted before local trust. Certificate: $($certificate.Thumbprint)"
}
finally { $certificate.Dispose() }
