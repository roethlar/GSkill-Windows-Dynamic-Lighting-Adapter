[CmdletBinding()]
param([string]$SdkVersion = '10.0.26100.0')
$ErrorActionPreference = 'Stop'
$driver = Join-Path $PSScriptRoot 'driver'
$signtool = "C:\Program Files (x86)\Windows Kits\10\bin\$SdkVersion\x64\signtool.exe"
$inf2cat = Join-Path $PSScriptRoot "packages\wdk\c\bin\$SdkVersion\x86\Inf2Cat.exe"
foreach ($path in @($signtool,$inf2cat,"$driver\WinUHidDriver.dll","$driver\WinUHidDriver.inf")) {
    if (!(Test-Path -LiteralPath $path)) { throw "Missing signing input: $path" }
}
if (Test-Path -LiteralPath "$driver\RoyalDynamicLighting.cer") {
    throw 'This package has already been signed. Preserve its certificate for uninstall; rebuild into a separate directory for a new signing identity.'
}

# This certificate is only a code-signing end-entity certificate. It is created in
# CurrentUser\My for SignTool and then removed with its private key. This script
# does not add any certificate to a trusted root or publisher store.
$certificate = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=Royal Dynamic Lighting Local Build' -FriendlyName 'Royal Dynamic Lighting local package signing' -CertStoreLocation Cert:\CurrentUser\My -KeyAlgorithm RSA -KeyLength 3072 -HashAlgorithm SHA256 -KeyExportPolicy NonExportable -NotAfter (Get-Date).AddYears(1)
try {
    & $signtool sign /sha1 $certificate.Thumbprint /s My /fd SHA256 "$driver\WinUHidDriver.dll"
    if ($LASTEXITCODE -ne 0) { throw 'Driver signing failed.' }
    & $inf2cat "/driver:$driver" /os:10_CO_X64,10_NI_X64,10_GE_X64
    if ($LASTEXITCODE -ne 0) { throw 'Catalog generation failed.' }
    & $signtool sign /sha1 $certificate.Thumbprint /s My /fd SHA256 "$driver\WinUHidDriver.cat"
    if ($LASTEXITCODE -ne 0) { throw 'Catalog signing failed.' }
    Export-Certificate -Cert $certificate -FilePath "$driver\RoyalDynamicLighting.cer" | Out-Null
    [ordered]@{
        thumbprint = $certificate.Thumbprint
        subject = $certificate.Subject
        notAfter = $certificate.NotAfter.ToUniversalTime().ToString('o')
        files = @('WinUHidDriver.dll','WinUHidDriver.inf','WinUHidDriver.cat') | ForEach-Object {
            @{ name = $_; sha256 = (Get-FileHash -LiteralPath (Join-Path $driver $_) -Algorithm SHA256).Hash }
        }
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath "$driver\signed-package.json" -Encoding UTF8
    Write-Output "Signed package with local certificate $($certificate.Thumbprint). No trust or driver installation performed."
}
finally {
    Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($certificate.Thumbprint)" -DeleteKey
}
