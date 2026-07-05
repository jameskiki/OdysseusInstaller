[Setup]
AppName=Odysseus AI Environment
AppVersion=1.0.0
DefaultDirName={autopf}\Odysseus
DefaultGroupName=Odysseus AI
OutputBaseFilename=Odysseus_Setup
Compression=lzma
SolidCompression=yes
PrivilegesRequired=admin
LicenseFile=Licenses.txt
SetupLogging=yes

[Files]
Source: "..\scripts\windows\Launch-Odysseus.ps1"; DestDir: "{app}"; Flags: ignoreversion; Check: IsLocalInstallation
Source: "..\scripts\windows\Prepare-WslForOdysseus.ps1"; DestDir: "{app}"; Flags: ignoreversion; Check: IsLocalInstallation
Source: "..\scripts\wsl\run_odysseus.sh"; DestDir: "{app}"; Flags: ignoreversion; Check: IsLocalInstallation
Source: "..\scripts\windows\Audit-Odysseus.ps1"; DestDir: "{app}"; Flags: ignoreversion; Check: IsLocalInstallation

[Icons]
Name: "{autodesktop}\Launch Odysseus (Local)"; Filename: "{sysnative}\windowspowershell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -Command ""try {{ & '{app}\Launch-Odysseus.ps1' } catch {{ Write-Host ('[FATAL] ' + $_.Exception.Message) -ForegroundColor Red; Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray; Read-Host 'A fatal error occurred. Press ENTER to close...' }"""; IconFilename: "{sys}\shell32.dll"; IconIndex: 13; WorkingDir: "{app}"; Check: IsLocalInstallation
Name: "{group}\Prepare WSL for Odysseus"; Filename: "{sysnative}\windowspowershell\v1.0\powershell.exe"; Parameters: "-NoExit -NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -Command ""& '{app}\Prepare-WslForOdysseus.ps1'"""; IconFilename: "{sys}\shell32.dll"; IconIndex: 13; WorkingDir: "{app}"; Check: IsLocalInstallation
Name: "{autodesktop}\Prepare WSL for Odysseus"; Filename: "{sysnative}\windowspowershell\v1.0\powershell.exe"; Parameters: "-NoExit -NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -Command ""& '{app}\Prepare-WslForOdysseus.ps1'"""; IconFilename: "{sys}\shell32.dll"; IconIndex: 13; WorkingDir: "{app}"; Check: IsLocalInstallation
Name: "{group}\Odysseus Health Audit"; Filename: "{sysnative}\windowspowershell\v1.0\powershell.exe"; Parameters: "-NoExit -NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -Command ""& '{app}\Audit-Odysseus.ps1'"""; IconFilename: "{sys}\shell32.dll"; IconIndex: 168; WorkingDir: "{app}"; Check: IsLocalInstallation
Name: "{autodesktop}\Odysseus Health Audit"; Filename: "{sysnative}\windowspowershell\v1.0\powershell.exe"; Parameters: "-NoExit -NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -Command ""& '{app}\Audit-Odysseus.ps1'"""; IconFilename: "{sys}\shell32.dll"; IconIndex: 168; WorkingDir: "{app}"; Check: IsLocalInstallation
Name: "{autodesktop}\Connect to Shared Odysseus"; Filename: "explorer.exe"; Parameters: "http://{code:GetRemoteIP}:7000"; IconFilename: "{sys}\shell32.dll"; IconIndex: 14; Check: IsRemoteInstallation

[Run]
; Allow inbound access for shared-host mode.
Filename: "cmd.exe"; Parameters: "/c ""netsh.exe advfirewall firewall add rule name=""Odysseus AI Network Host"" dir=in action=allow protocol=TCP localport=7000 profile=private,domain || (echo Firewall configuration failed && pause)"""; StatusMsg: "Configuring network hosting permissions and firewall exceptions..."; Check: IsHostSelected

[Code]
var
  DeploymentPage: TWizardPage;
  LocalInstallRadio: TRadioButton;
  RemoteInstallRadio: TRadioButton;
  HostCheckBox: TNewCheckBox;
  RepoRefPage: TInputQueryWizardPage;
  RebuildModePage: TInputOptionWizardPage;
  IPPage: TInputQueryWizardPage;
  UninstallCleanupPrompted: Boolean;
  RemoveLocalRuntimeData: Boolean;
  RemoveWslWorkspaceData: Boolean;
  RemoveResidualInstallFiles: Boolean;

procedure OnDeploymentTypeChange(Sender: TObject);
begin
  HostCheckBox.Enabled := LocalInstallRadio.Checked;
  if not HostCheckBox.Enabled then
    HostCheckBox.Checked := False;
end;

procedure OnLicenseLinkClick(Sender: TObject; const Link: string; LinkType: TSysLinkType);
var
  ErrorCode: Integer;
begin
  ShellExecAsOriginalUser('open', Link, '', '', SW_SHOWNORMAL, ewNoWait, ErrorCode);
end;

procedure InitializeWizard;
var
  LinkLabel: TNewLinkLabel;
begin
  WizardForm.LicenseMemo.Height := WizardForm.LicenseMemo.Height - ScaleY(24);
  WizardForm.LicenseAcceptedRadio.Top := WizardForm.LicenseAcceptedRadio.Top - ScaleY(24);
  WizardForm.LicenseNotAcceptedRadio.Top := WizardForm.LicenseNotAcceptedRadio.Top - ScaleY(24);

  LinkLabel := TNewLinkLabel.Create(WizardForm);
  LinkLabel.Parent := WizardForm.LicensePage;
  LinkLabel.Left := WizardForm.LicenseNotAcceptedRadio.Left;
  LinkLabel.Top := WizardForm.LicenseNotAcceptedRadio.Top + WizardForm.LicenseNotAcceptedRadio.Height + ScaleY(6);
  LinkLabel.Width := WizardForm.LicenseMemo.Width;
  LinkLabel.Height := ScaleY(20);
  LinkLabel.Caption := 'Review Web Licenses: <a href="https://apache.org">Apache 2.0</a> | <a href="https://ubuntu.com">Ubuntu Legal</a> | <a href="https://git-scm.com">Git GPL</a>';
  LinkLabel.OnLinkClick := @OnLicenseLinkClick;

  DeploymentPage := CreateCustomPage(wpLicense, 'Deployment Type Selection', 'How would you like to access the Odysseus AI Environment?');
  
  LocalInstallRadio := TRadioButton.Create(DeploymentPage);
  LocalInstallRadio.Parent := DeploymentPage.Surface;
  LocalInstallRadio.Caption := 'Run a local instance on my own computer (Requires Nvidia GPU or high CPU/RAM resources)';
  LocalInstallRadio.Font.Style := [fsBold];
  LocalInstallRadio.Left := ScaleX(8);
  LocalInstallRadio.Top := ScaleY(16);
  LocalInstallRadio.Width := DeploymentPage.SurfaceWidth - ScaleX(16);
  LocalInstallRadio.Checked := True;
  LocalInstallRadio.OnClick := @OnDeploymentTypeChange;

  HostCheckBox := TNewCheckBox.Create(DeploymentPage);
  HostCheckBox.Parent := DeploymentPage.Surface;
  HostCheckBox.Caption := 'Act as Host: Allow other computers on the office network to connect to this machine';
  HostCheckBox.Left := ScaleX(28); 
  HostCheckBox.Top := LocalInstallRadio.Top + ScaleY(24);
  HostCheckBox.Width := DeploymentPage.SurfaceWidth - ScaleX(32);
  HostCheckBox.Checked := False;

  RemoteInstallRadio := TRadioButton.Create(DeploymentPage);
  RemoteInstallRadio.Parent := DeploymentPage.Surface;
  RemoteInstallRadio.Caption := 'Connect to a shared instance running on the office network';
  RemoteInstallRadio.Font.Style := [fsBold];
  RemoteInstallRadio.Left := ScaleX(8);
  RemoteInstallRadio.Top := HostCheckBox.Top + ScaleY(32);
  RemoteInstallRadio.Width := DeploymentPage.SurfaceWidth - ScaleX(16);
  RemoteInstallRadio.OnClick := @OnDeploymentTypeChange;

  RepoRefPage := CreateInputQueryPage(DeploymentPage.ID, 'Odysseus Version Selection', 'Choose which Odysseus branch or tag to use.', 'Leave this as "main" unless you were given a specific branch or release tag.');
  RepoRefPage.Add('Git branch or tag:', False);
  RepoRefPage.Values[0] := 'main';

  RebuildModePage := CreateInputOptionPage(RepoRefPage.ID, 'Container Rebuild Preference', 'Choose how Odysseus container rebuilds should be handled on launch.', 'Recommended default: Ask each launch.', True, False);
  RebuildModePage.Add('Ask each launch (recommended)');
  RebuildModePage.Add('Always rebuild before launch');
  RebuildModePage.Add('Never rebuild automatically');
  RebuildModePage.Values[0] := True;

  IPPage := CreateInputQueryPage(RebuildModePage.ID, 'Shared Instance Network Location', 'Specify the target IP address of the hosting workstation.', 'Please enter the IPv4 address of the computer sharing Odysseus (e.g. 192.168.1.45):');
  IPPage.Add('Host IP Address:', False);
  IPPage.Values[0] := '';
end;

function IsLocalInstallation: Boolean;
begin
  Result := LocalInstallRadio.Checked;
end;

function IsRemoteInstallation: Boolean;
begin
  Result := RemoteInstallRadio.Checked;
end;

function IsHostSelected: Boolean;
begin
  Result := LocalInstallRadio.Checked and HostCheckBox.Checked;
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  if (PageID = RepoRefPage.ID) and IsRemoteInstallation then
    Result := True;
  if (PageID = RebuildModePage.ID) and IsRemoteInstallation then
    Result := True;
  if (PageID = IPPage.ID) and (LocalInstallRadio.Checked) then
    Result := True;
end;

function GetSelectedRebuildMode: string;
begin
  if RebuildModePage.Values[1] then
    Result := 'always'
  else if RebuildModePage.Values[2] then
    Result := 'never'
  else
    Result := 'ask';
end;

function GetRemoteIP(Param: string): string;
begin
  Result := Trim(IPPage.Values[0]);
  if Result = '' then Result := '127.0.0.1';
end;

function IsNvidiaGpuPresent: Boolean;
var
  SubKeys: TArrayOfString;
  I: Integer;
  GpuDescription: string;
begin
  Result := False;
  if RegGetSubkeyNames(HKEY_LOCAL_MACHINE, 'SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}', SubKeys) then begin
    for I := 0 to GetArrayLength(SubKeys) - 1 do begin
      if RegQueryStringValue(HKEY_LOCAL_MACHINE, 'SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\' + SubKeys[I], 'DriverDesc', GpuDescription) then begin
        if Pos('NVIDIA', UpperCase(GpuDescription)) > 0 then begin
          Result := True;
          Break;
        end;
      end;
    end;
  end;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  IsNvidiaDetected: Boolean;
begin
  Result := True;
  if (CurPageID = DeploymentPage.ID) and IsLocalInstallation then begin
    IsNvidiaDetected := IsNvidiaGpuPresent;
    if not IsNvidiaDetected then begin
      if MsgBox('WARNING: No dedicated NVIDIA GPU was detected.' + #13#10#13#10 + 'Odysseus will run in "CPU-Only mode" locally with reduced processing speeds.' + #13#10#13#10 + 'Do you want to proceed with a local CPU installation?', mbConfirmation, MB_YESNO) = IDNO then 
        Result := False;
    end;
  end;

  if (CurPageID = IPPage.ID) and IsRemoteInstallation then begin
    if Trim(IPPage.Values[0]) = '' then begin
      MsgBox('Enter the IPv4 address of the workstation that is hosting Odysseus.', mbError, MB_OK);
      Result := False;
    end;
  end;

  if (CurPageID = RepoRefPage.ID) and IsLocalInstallation then begin
    if Trim(RepoRefPage.Values[0]) = '' then begin
      MsgBox('Enter a branch or tag name (for example: main).', mbError, MB_OK);
      Result := False;
    end;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  WslCheckCode: Integer;
  HostModeFile: string;
  RepoRefFile: string;
  RebuildModeFile: string;
  SelectedRepoRef: string;
  SelectedRebuildMode: string;
begin
  if (CurStep = ssPostInstall) and (IsLocalInstallation) then begin
    SelectedRepoRef := Trim(RepoRefPage.Values[0]);
    if SelectedRepoRef = '' then
      SelectedRepoRef := 'main';

    SelectedRebuildMode := GetSelectedRebuildMode;

    RepoRefFile := ExpandConstant('{app}') + '\ODYSSEUS_REPO_REF';
    SaveStringToFile(RepoRefFile, SelectedRepoRef, False);

    RebuildModeFile := ExpandConstant('{app}') + '\ODYSSEUS_REBUILD_MODE';
    SaveStringToFile(RebuildModeFile, SelectedRebuildMode, False);

    if IsHostSelected then begin
      HostModeFile := ExpandConstant('{app}') + '\ODYSSEUS_HOST_MODE';
      SaveStringToFile(HostModeFile, 'true', False);
    end
    else begin
      HostModeFile := ExpandConstant('{app}') + '\ODYSSEUS_HOST_MODE';
      if FileExists(HostModeFile) then
        DeleteFile(HostModeFile);
    end;

    { Readiness check only: exit 10 = WSL absent, exit 11 = Ubuntu absent, exit 0 = both present }
    if not Exec(
      ExpandConstant('{sysnative}\windowspowershell\v1.0\powershell.exe'),
      '-NoProfile -ExecutionPolicy Bypass -Command "if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) { exit 10 }; [Console]::OutputEncoding = [System.Text.Encoding]::Unicode; $distros = (wsl -l -q) 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ }; if (-not ($distros | Where-Object { $_ -match ''^Ubuntu(-.*)?$'' })) { exit 11 }"',
      '', SW_HIDE, ewWaitUntilTerminated, WslCheckCode) then
      WslCheckCode := -1;

    if WslCheckCode = -1 then begin
      { Exec itself failed — PowerShell could not be launched }
      MsgBox('Could not verify WSL readiness because PowerShell failed to launch.' + #13#10#13#10 + 'Use the "Prepare WSL for Odysseus" shortcut to install/prepare WSL2 + Ubuntu, then launch Odysseus.', mbCriticalError, MB_OK);
    end
    else if WslCheckCode = 10 then begin
      MsgBox('WSL2 with Ubuntu is required before launching Odysseus.' + #13#10#13#10 + 'Use the "Prepare WSL for Odysseus" shortcut. It will run "wsl --install -d Ubuntu", guide reboot if needed, and help complete Ubuntu first-run setup.', mbCriticalError, MB_OK);
    end
    else if WslCheckCode = 11 then begin
      MsgBox('WSL is installed, but no Ubuntu distribution was found.' + #13#10#13#10 + 'Use the "Prepare WSL for Odysseus" shortcut. It installs Ubuntu and guides first-run setup.', mbCriticalError, MB_OK);
    end
    else begin
      { WSL and Ubuntu already present (exit 0) }
      MsgBox('WSL and Ubuntu are ready. Use the desktop shortcut "Launch Odysseus (Local)" to start Odysseus.', mbInformation, MB_OK);
    end;
  end;
end;

procedure RunPowerShellHidden(const Command: string);
var
  ResultCode: Integer;
begin
  Exec(
    ExpandConstant('{sysnative}\windowspowershell\v1.0\powershell.exe'),
    '-NoProfile -ExecutionPolicy Bypass -Command "' + Command + '"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  LocalDataDir: string;
begin
  if (CurUninstallStep = usUninstall) and (not UninstallCleanupPrompted) then begin
    UninstallCleanupPrompted := True;

    RemoveLocalRuntimeData :=
      MsgBox(
        'Remove local Odysseus runtime data for this Windows user?' + #13#10 + #13#10 +
        '- Logs in %LOCALAPPDATA%\Odysseus\Logs' + #13#10 +
        '- Cached user settings/state under %LOCALAPPDATA%\Odysseus' + #13#10 +
        '- User environment variable OLLAMA_HOST',
        mbConfirmation, MB_YESNO) = IDYES;

    RemoveWslWorkspaceData :=
      MsgBox(
        'Remove Odysseus files inside Ubuntu WSL as well?' + #13#10 + #13#10 +
        '- ~/odysseus' + #13#10 +
        '- ~/run_odysseus.sh' + #13#10 + #13#10 +
        'This does not uninstall WSL or Ubuntu itself.',
        mbConfirmation, MB_YESNO) = IDYES;

    RemoveResidualInstallFiles :=
      MsgBox(
        'After uninstall finishes, remove any remaining files in the installation folder if any are left behind?',
        mbConfirmation, MB_YESNO) = IDYES;

    if RemoveLocalRuntimeData then begin
      LocalDataDir := ExpandConstant('{localappdata}\Odysseus');
      if DirExists(LocalDataDir) then
        DelTree(LocalDataDir, True, True, True);

      RunPowerShellHidden('[Environment]::SetEnvironmentVariable(''OLLAMA_HOST'', $null, ''User'')');
    end;

    if RemoveWslWorkspaceData then begin
      RunPowerShellHidden(
        '$distros = (wsl -l -q) 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ -match ''^Ubuntu(-.*)?$'' }; ' +
        'foreach ($d in $distros) { wsl -d $d -- bash -lc ''rm -rf ~/odysseus ~/run_odysseus.sh'' 2>$null | Out-Null }');
    end;
  end;

  if (CurUninstallStep = usPostUninstall) and RemoveResidualInstallFiles then begin
    if DirExists(ExpandConstant('{app}')) then
      DelTree(ExpandConstant('{app}'), True, True, True);

    RunPowerShellHidden(
      'netsh.exe advfirewall firewall delete rule name=''Odysseus AI Network Host'' 1>$null 2>$null');
  end;
end;