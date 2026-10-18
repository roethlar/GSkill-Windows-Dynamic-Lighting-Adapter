param([switch]$Publish)
$ErrorActionPreference = 'Stop'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = 'true'
$lightingRoot = $PSScriptRoot
$lightingDotnet = Join-Path $lightingRoot 'tools\dotnet\dotnet.exe'
if (-not (Test-Path -LiteralPath $lightingDotnet)) {
    $lightingDotnet = (Get-Command dotnet -ErrorAction Stop).Source
}
& $lightingDotnet build (Join-Path $lightingRoot 'src\RoyalDynamicLighting\RoyalDynamicLighting.csproj') -c Release --nologo
if ($LASTEXITCODE -ne 0) { throw 'Application build failed.' }
& $lightingDotnet run --project (Join-Path $lightingRoot 'tests\RoyalDynamicLighting.Tests.csproj') -c Release
if ($LASTEXITCODE -ne 0) { throw 'Protocol verification failed.' }
if ($Publish) {
    & $lightingDotnet publish (Join-Path $lightingRoot 'src\RoyalDynamicLighting\RoyalDynamicLighting.csproj') -c Release -r win-x64 --self-contained true -o (Join-Path $lightingRoot 'artifacts\app') --nologo
    if ($LASTEXITCODE -ne 0) { throw 'Application publish failed.' }
}
