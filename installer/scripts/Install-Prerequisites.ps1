[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$PackageRoot,
    [switch]$CheckOnly,
    [string]$LogPath
)
$ErrorActionPreference = 'Stop'
$env:PSModulePath = [IO.Path]::Combine($PSHOME, 'Modules')
$lightingTranscript = $false
try {
    if ($LogPath) {
        Start-Transcript -LiteralPath $LogPath -Append | Out-Null
        $lightingTranscript = $true
    }
    if (![Environment]::Is64BitProcess) { throw 'Run this script with 64-bit Windows PowerShell.' }
    if (!$CheckOnly) {
        $lightingIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $lightingPrincipal = New-Object Security.Principal.WindowsPrincipal $lightingIdentity
        if (!$lightingPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Administrator access is required to install prerequisites.' }
    }
    $lightingDependencies = @(
        @{ Name='vc_redist.x64.exe'; Hash='843068991DAAA1F73AD9F6239BCE4D0F6A07A51F18C37EA2A867E9BECA71295C'; Publisher='CN=Microsoft Corporation'; Arguments='/install /quiet /norestart' },
        @{ Name='PawnIO_setup.exe'; Hash='1F519A22E47187F70A1379A48CA604981C4FCF694F4E65B734AAA74A9FBA3032'; Publisher='CN=namazso.eu'; Arguments='-install -silent' }
    )
    foreach ($lightingDependency in $lightingDependencies) {
        $lightingFile = Join-Path $PackageRoot ('dependencies\' + $lightingDependency.Name)
        if ((Get-FileHash -LiteralPath $lightingFile -Algorithm SHA256).Hash -ne $lightingDependency.Hash) { throw "Prerequisite hash mismatch: $($lightingDependency.Name)" }
        $lightingSignature = Get-AuthenticodeSignature -LiteralPath $lightingFile
        if ($lightingSignature.Status -ne 'Valid' -or !$lightingSignature.SignerCertificate -or
            $lightingSignature.SignerCertificate.Subject -notmatch ([regex]::Escape($lightingDependency.Publisher) + '(,|$)')) {
            throw "Prerequisite signature verification failed: $($lightingDependency.Name)"
        }
    }
    $lightingRuntime = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64' -ErrorAction SilentlyContinue
    $lightingVcReady = $lightingRuntime -and $lightingRuntime.Installed -eq 1 -and [version]($lightingRuntime.Version -replace '^v','') -ge [version]'14.44.35211.0'
    $lightingPawnDll = Join-Path $env:ProgramFiles 'PawnIO\PawnIOLib.dll'
    $lightingPawnService = Get-Service -Name PawnIO -ErrorAction SilentlyContinue
    $lightingPawnReady = (Test-Path -LiteralPath $lightingPawnDll) -and $lightingPawnService -and
        [version](Get-Item -LiteralPath $lightingPawnDll).VersionInfo.FileVersion -ge [version]'2.2.0'
    Write-Output "Prerequisite packages: signatures and hashes verified. Visual C++ ready: $([bool]$lightingVcReady); PawnIO ready: $([bool]$lightingPawnReady)."
    if ($CheckOnly) { exit 0 }
    $lightingReboot = $false
    for ($lightingIndex = 0; $lightingIndex -lt $lightingDependencies.Count; $lightingIndex++) {
        if (($lightingIndex -eq 0 -and $lightingVcReady) -or ($lightingIndex -eq 1 -and $lightingPawnReady)) { continue }
        $lightingDependency = $lightingDependencies[$lightingIndex]
        Write-Output "Installing $($lightingDependency.Name)..."
        $lightingChild = Start-Process -FilePath (Join-Path $PackageRoot ('dependencies\' + $lightingDependency.Name)) -ArgumentList $lightingDependency.Arguments -WindowStyle Hidden -Wait -PassThru
        if ($lightingChild.ExitCode -eq 3010) { $lightingReboot = $true }
        elseif ($lightingChild.ExitCode -ne 0) { throw "$($lightingDependency.Name) failed (exit $($lightingChild.ExitCode))." }
    }
    if (!$lightingReboot) {
        $lightingRuntime = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64' -ErrorAction Stop
        if ($lightingRuntime.Installed -ne 1 -or [version]($lightingRuntime.Version -replace '^v','') -lt [version]'14.44.35211.0') { throw 'The required x64 Visual C++ runtime was not installed.' }
        if (!(Test-Path -LiteralPath $lightingPawnDll)) { throw 'PawnIO did not install its library.' }
        if ([version](Get-Item -LiteralPath $lightingPawnDll).VersionInfo.FileVersion -lt [version]'2.2.0') { throw 'PawnIO version 2.2.0 or later is required.' }
        $lightingPawnService = Get-Service -Name PawnIO -ErrorAction Stop
        if ($lightingPawnService.Status -ne 'Running') { Start-Service -Name PawnIO -ErrorAction Stop }
    }
    if ($lightingReboot) { Write-Output 'A prerequisite requires a restart. This script will not restart Windows.'; exit 3010 }
    Write-Output 'Prerequisites are ready.'
    exit 0
} catch {
    Write-Output ($_ | Out-String)
    exit 1
} finally {
    if ($lightingTranscript) { Stop-Transcript | Out-Null }
}
