#ifndef PayloadDir
  #define PayloadDir "stage"
#endif
#ifndef OutputPath
  #define OutputPath "..\artifacts\installer"
#endif
#define ProductVersion "0.1.0"

[Setup]
AppId={{AC2A7BA1-92AA-4570-8661-0CC10FC02586}
AppName=Royal Dynamic Lighting
AppVersion={#ProductVersion}
AppPublisher=Royal Dynamic Lighting
AppComments=G.Skill Royal RAM lighting through Windows Dynamic Lighting and PawnIO
DefaultDirName={autopf}\RoyalDynamicLighting Setup
DisableDirPage=yes
DisableProgramGroupPage=yes
UsePreviousAppDir=no
PrivilegesRequired=admin
SetupArchitecture=x64
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.22631
OutputDir={#OutputPath}
OutputBaseFilename=RoyalDynamicLighting-Setup-{#ProductVersion}-x64
Compression=lzma2/normal
SolidCompression=yes
WizardStyle=modern
SetupLogging=yes
UninstallLogging=yes
UninstallDisplayName=Royal Dynamic Lighting
UninstallDisplayIcon={autopf}\RoyalDynamicLighting\RoyalDynamicLighting.exe
CloseApplications=no
RestartApplications=no
RestartIfNeededByRun=no
AlwaysRestart=no
InfoBeforeFile=Welcome.txt
DisableWelcomePage=no
DisableReadyPage=no
DisableFinishedPage=no

[Files]
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Royal Dynamic Lighting instructions"; Filename: "{app}\INSTALL.txt"

[Code]
var
  PayloadExtracted: Boolean;
  DeferredStart: Boolean;
  PackageFailed: Boolean;
  PackageNeedsRestart: Boolean;
  PackageInstalled: Boolean;
  RemovalNeedsRestart: Boolean;

function PowerShellPath: String;
begin
  Result := ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe');
end;

function RunScript(const Root, ScriptName, Extra: String; var ExitCode: Integer): Boolean;
var
  Arguments: String;
begin
  Arguments := '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
    Root + '\scripts\' + ScriptName + '" -PackageRoot "' + Root + '" ' + Extra;
  Log('Running ' + ScriptName);
  Result := ExecAndLogOutputWithNativeSysDir(PowerShellPath, Arguments, Root, SW_HIDE, ewWaitUntilTerminated, ExitCode, nil);
  Log('Result for ' + ScriptName + ': ' + IntToStr(ExitCode));
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  TemporaryRoot: String;
  ExitCode: Integer;
begin
  Result := '';
  NeedsRestart := False;
  if CompareText(ExpandConstant('{app}'), ExpandConstant('{autopf}\RoyalDynamicLighting Setup')) <> 0 then
  begin
    Result := 'This package uses a fixed installation folder. Remove the /DIR override and try again.';
    Exit;
  end;
  if not PayloadExtracted then
  begin
    WizardForm.StatusLabel.Caption := 'Checking the installation package...';
    ExtractTemporaryFiles('{app}\*');
    PayloadExtracted := True;
  end;
  TemporaryRoot := ExpandConstant('{tmp}\') + '{app}';
  if not RunScript(TemporaryRoot, 'Install-Package.ps1', '-PreflightOnly', ExitCode) or (ExitCode <> 0) then
  begin
    Result := 'The installation check failed. An existing or incomplete installation may need removal first. ' +
      'See the setup log: ' + ExpandConstant('{log}') + '. ' +
      'Your existing installation has not been replaced.';
    Exit;
  end;
  WizardForm.StatusLabel.Caption := 'Checking PawnIO and the Microsoft runtime...';
  if not RunScript(TemporaryRoot, 'Install-Prerequisites.ps1',
    '-LogPath "' + ExpandConstant('{tmp}\Royal-prerequisites.log') + '"', ExitCode) then
  begin
    Result := 'Unable to start prerequisite setup. See the installer log.';
    Exit;
  end;
  if (ExitCode <> 0) and (ExitCode <> 3010) then
  begin
    Result := 'A prerequisite could not be installed. See the setup log: ' + ExpandConstant('{log}');
    Exit;
  end;
  DeferredStart := ExitCode = 3010;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ExitCode: Integer;
  Arguments: String;
begin
  if CurStep = ssPostInstall then
  begin
    WizardForm.StatusLabel.Caption := 'Installing the lighting driver and background adapter...';
    Arguments := '-TrustLocalCertificate';
    if DeferredStart then Arguments := Arguments + ' -DeferStart';
    if not RunScript(ExpandConstant('{app}'), 'Install-Package.ps1', Arguments, ExitCode) then
      PackageFailed := True
    else if ExitCode = 3010 then
      PackageNeedsRestart := True
    else if ExitCode = 0 then
      PackageInstalled := True
    else
      PackageFailed := True;
    { Keep the recovery payload and uninstall entry if setup failed after a system
      change. The ownership journal governs retry and uninstall. }
  end;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if CurPageID = wpFinished then
  begin
    if PackageFailed then
    begin
      WizardForm.FinishedHeadingLabel.Caption := 'Setup needs attention';
      WizardForm.FinishedLabel.Caption := 'The lighting adapter could not be installed completely. ' +
        'Details are in C:\ProgramData\RoyalDynamicLighting. ' +
        'The setup files were retained so you can retry or remove Royal Dynamic Lighting from Installed apps.';
    end
    else if PackageNeedsRestart then
    begin
      WizardForm.FinishedLabel.Caption := 'Windows needs a restart before setup can finish. ' +
        'Restart when convenient, then run this installer again to verify startup. Setup will not restart Windows.';
    end
    else if PackageInstalled then
    begin
      WizardForm.FinishedLabel.Caption := 'The lighting adapter is running and will start automatically with Windows.' + #13#10#13#10 +
        'Open Settings > Personalization > Dynamic Lighting and select HID-compliant device to change your RAM colors.';
    end;
  end;
end;

function GetCustomSetupExitCode: Integer;
begin
  Result := 0;
  if PackageFailed then Result := 1
  else if PackageNeedsRestart then Result := 3010;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  ExitCode: Integer;
begin
  if CurUninstallStep = usUninstall then
  begin
    { Inno calls this after confirmation and before deleting files. An exception
      here aborts removal and preserves the recovery payload. }
    if not RunScript(ExpandConstant('{app}'), 'Uninstall-Package.ps1', '', ExitCode) then
      RaiseException('Unable to start adapter removal. Setup files were kept for retry.');
    if (ExitCode <> 0) and (ExitCode <> 3010) then
      RaiseException('The lighting adapter could not be removed safely. Its setup files were kept for retry. ' +
        'Read the logs in C:\ProgramData\RoyalDynamicLighting.');
    RemovalNeedsRestart := ExitCode = 3010;
  end
  else if (CurUninstallStep = usPostUninstall) and RemovalNeedsRestart then
    SuppressibleMsgBox('Royal Dynamic Lighting was removed. Restart Windows when convenient to finish driver removal.',
      mbInformation, MB_OK, IDOK);
end;
