[CmdletBinding()]
param(
    [string]$BuildTools = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools',
    [string]$WindowsKits = 'C:\Program Files (x86)\Windows Kits\10',
    [string]$SdkVersion = '10.0.26100.0'
)
$ErrorActionPreference = 'Stop'
$vc = Get-ChildItem -LiteralPath (Join-Path $BuildTools 'VC\Tools\MSVC') -Directory |
    Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
$compiler = Join-Path $vc 'bin\Hostx64\x64\cl.exe'
$intermediate = Join-Path $PSScriptRoot 'obj\device-setup'
$native = Join-Path $PSScriptRoot 'native'
New-Item -ItemType Directory -Path $intermediate,$native -Force | Out-Null
$includes = @("$vc\include", "$WindowsKits\Include\$SdkVersion\um", "$WindowsKits\Include\$SdkVersion\shared", "$WindowsKits\Include\$SdkVersion\ucrt") | ForEach-Object { "/I$_" }
$libraries = @("$vc\lib\x64", "$WindowsKits\Lib\$SdkVersion\um\x64", "$WindowsKits\Lib\$SdkVersion\ucrt\x64") | ForEach-Object { "/LIBPATH:$_" }
& $compiler /nologo /std:c++17 /EHsc /MT /O2 /W4 /WX /guard:cf /DUNICODE /D_UNICODE /DWIN32_LEAN_AND_MEAN /D_WIN32_WINNT=0x0A00 @includes "/Fo$intermediate\RoyalDeviceSetup.obj" "/Fe$native\RoyalDeviceSetup.exe" (Join-Path $PSScriptRoot 'RoyalDeviceSetup.cpp') /link /DYNAMICBASE /NXCOMPAT /CETCOMPAT @libraries setupapi.lib newdev.lib cfgmgr32.lib advapi32.lib user32.lib
if ($LASTEXITCODE -ne 0) { throw "Device setup helper build failed ($LASTEXITCODE)." }
Write-Output "Built $native\RoyalDeviceSetup.exe with the static C++ runtime; no installation performed."
