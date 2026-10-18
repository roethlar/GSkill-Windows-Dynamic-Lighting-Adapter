; Build-only validation harness. It never calls installation or removal code.
#ifndef PayloadDir
  #error PayloadDir must be supplied
#endif
#ifndef OutputPath
  #error OutputPath must be supplied
#endif
[Setup]
AppName=Royal Dynamic Lighting payload verification
AppVersion=0.1.0
DefaultDirName={tmp}\UnusedRoyalValidation
CreateAppDir=no
Uninstallable=no
CreateUninstallRegKey=no
PrivilegesRequired=lowest
SetupArchitecture=x64
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableWelcomePage=yes
DisableReadyPage=yes
DisableFinishedPage=yes
OutputDir={#OutputPath}
OutputBaseFilename=PayloadSmoke
Compression=lzma2/normal
SolidCompression=yes
SetupLogging=yes

[Files]
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: dontcopy recursesubdirs createallsubdirs
Source: "Validate-Payload.ps1"; Flags: dontcopy

[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ExitCode: Integer;
  Root: String;
begin
  NeedsRestart := False;
  Result := '';
  ExtractTemporaryFiles('{app}\*');
  ExtractTemporaryFile('Validate-Payload.ps1');
  Root := ExpandConstant('{tmp}\') + '{app}';
  if not ExecAndLogOutputWithNativeSysDir(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + ExpandConstant('{tmp}\Validate-Payload.ps1') +
    '" -PackageRoot "' + Root + '"', Root, SW_HIDE, ewWaitUntilTerminated, ExitCode, nil) then
    Result := 'Could not launch payload validation.';
  if ExitCode <> 0 then Result := 'Payload validation failed. See the smoke-test log.';
end;
