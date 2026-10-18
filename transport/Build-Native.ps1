[CmdletBinding()]
param(
    [string]$BuildTools = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools',
    [string]$WindowsKits = 'C:\Program Files (x86)\Windows Kits\10',
    [string]$SdkVersion = '10.0.26100.0'
)
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$source = Join-Path $project 'third_party\WinUHid'
$wdk = Join-Path $PSScriptRoot 'packages\wdk\c'
$vc = Get-ChildItem -LiteralPath (Join-Path $BuildTools 'VC\Tools\MSVC') -Directory |
    Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty FullName
$compiler = Join-Path $vc 'bin\Hostx64\x64\cl.exe'
$msbuild = Join-Path $BuildTools 'MSBuild\Current\Bin\MSBuild.exe'
$intermediate = Join-Path $PSScriptRoot 'obj\driver'
$driver = Join-Path $PSScriptRoot 'driver'
$native = Join-Path $PSScriptRoot 'native'
foreach ($path in @($source,$wdk,$compiler,$msbuild)) {
    if (!(Test-Path -LiteralPath $path)) { throw "Missing build input: $path" }
}
New-Item -ItemType Directory -Path $intermediate,$driver,$native -Force | Out-Null
function Assert-Exit([string]$step) { if ($LASTEXITCODE -ne 0) { throw "$step failed ($LASTEXITCODE)." } }

& $msbuild (Join-Path $source 'WinUHid\WinUHid.vcxproj') /p:Configuration=Release /p:Platform=x64 "/p:WindowsTargetPlatformVersion=$SdkVersion" "/p:OutDir=$native\" "/p:IntDir=$PSScriptRoot\obj\native\" /m /verbosity:minimal
Assert-Exit 'Native client build'

# Run the stock WPP preprocessor, then compile the unchanged upstream UMDF source.
# The extracted WDK NuGet package avoids requiring machine-wide WDK/VS integration.
& (Join-Path $WindowsKits "bin\$SdkVersion\x64\tracewpp.exe") "-I$WindowsKits\bin\$SdkVersion\WppConfig\Rev1" "-scan:$source\WinUHid Driver\Trace.h" "-odir:$intermediate" (Join-Path $source 'WinUHid Driver\WinUHid.c')
Assert-Exit 'WPP preprocessing'
$includes = @(
    "$vc\include", "$wdk\Include\wdf\umdf\2.33", "$wdk\Include\$SdkVersion\um",
    "$wdk\Include\$SdkVersion\shared", "$WindowsKits\Include\$SdkVersion\um",
    "$WindowsKits\Include\$SdkVersion\shared", "$WindowsKits\Include\$SdkVersion\ucrt", $intermediate
) | ForEach-Object { "/I$_" }
$libraries = @(
    "$wdk\Lib\wdf\umdf\x64\2.33", "$wdk\Lib\$SdkVersion\um\x64",
    "$WindowsKits\Lib\$SdkVersion\um\x64", "$WindowsKits\Lib\$SdkVersion\ucrt\x64", "$vc\lib\x64"
) | ForEach-Object { "/LIBPATH:$_" }
& $compiler /nologo /LD /MD /O2 /W3 /guard:cf /guard:ehcont /DUMDF_VERSION_MAJOR=2 /DUMDF_VERSION_MINOR=33 /DUMDF_USING_NTSTATUS /DUNICODE /D_UNICODE /DWIN32_LEAN_AND_MEAN /D_WIN32_WINNT=0x0A00 /DWPP_MACRO_USE_KM_VERSION_FOR_UM=1 @includes "/Fo$intermediate\WinUHid.obj" "/Fe$driver\WinUHidDriver.dll" (Join-Path $source 'WinUHid Driver\WinUHid.c') /link /INCLUDE:FxDriverEntryUm /DYNAMICBASE /NXCOMPAT /CETCOMPAT @libraries WdfDriverStubUm.lib ntdll.lib OneCoreUAP.lib advapi32.lib
Assert-Exit 'UMDF driver build'

Copy-Item -LiteralPath (Join-Path $source 'WinUHid Driver\WinUHidDriver.inf') -Destination $driver
& (Join-Path $wdk "bin\$SdkVersion\x64\stampinf.exe") -f "$driver\WinUHidDriver.inf" -a amd64 -d 10/17/2026 -v 0.1.0.0 -u 2.33.0
Assert-Exit 'INF stamping'
& (Join-Path $wdk "bin\$SdkVersion\x86\Inf2Cat.exe") "/driver:$driver" /os:10_CO_X64,10_NI_X64,10_GE_X64
Assert-Exit 'Catalog generation'
Copy-Item -LiteralPath (Join-Path $source 'LICENSE') -Destination (Join-Path $driver 'WinUHid-LICENSE.txt')
& $compiler /nologo /MT /O2 @includes "/I$source\WinUHid" "/Fo$intermediate\NativeAbi.obj" "/Fe$native\NativeAbi.exe" (Join-Path $PSScriptRoot 'tests\NativeAbi.cpp') /link @libraries
Assert-Exit 'Native ABI probe build'
& "$native\NativeAbi.exe" | Set-Content -LiteralPath "$native\native-abi.json" -Encoding ASCII
Assert-Exit 'Native ABI probe'
Write-Output 'Built x64 client, unsigned UMDF driver package, and native ABI probe. No driver/certificate was installed.'
