[Setup]
AppName=Odysseus AI Environment
AppVersion=1.0.0
DefaultDirName={pf}\Odysseus
DefaultGroupName=Odysseus AI
OutputBaseFilename=Odysseus_Setup
Compression=lzma
SolidCompression=yes
PrivilegesRequired=admin
LicenseFile=Licenses.txt
SetupLogging=yes

[Files]
Source: "Launch-Odysseus.ps1"; DestDir: "{app}"; Flags: ignoreversion; Check: IsLocalInstallation
Source: "run_odysseus.sh"; DestDir: "{app}"; Flags: ignoreversion; Check: IsLocalInstallation

[Icons]
Name: "{userdesktop}\Launch Odysseus (Local)"; Filename: "{sysnative}\windowspowershell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -Command ""try {{ & '{app}\Launch-Odysseus.ps1' } catch {{ Write-Host ('[FATAL] ' + $_.Exception.Message) -ForegroundColor Red; Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray; Read-Host 'A fatal error occurred. Press ENTER to close...' }"""; IconFilename: "{sys}\shell32.dll"; IconIndex: 13; WorkingDir: "{app}"; Check: IsLocalInstallation
Name: "{userdesktop}\Connect to Shared Odysseus"; Filename: "explorer.exe"; Parameters: "http://{code:GetRemoteIP}:7000"; IconFilename: "{sys}\shell32.dll"; IconIndex: 14; Check: IsRemoteInstallation

[Run]
; Allow inbound access for shared-host mode.
Filename: "cmd.exe"; Parameters: "/c ""netsh.exe advfirewall firewall add rule name=""Odysseus AI Network Host"" dir=in action=allow protocol=TCP localport=7000 profile=private,domain || (echo Firewall configuration failed && pause)"""; StatusMsg: "Configuring network hosting permissions and firewall exceptions..."; Check: IsHostSelected

[Code]
var
  DeploymentPage: TWizardPage;
  LocalInstallRadio: TRadioButton;
  RemoteInstallRadio: TRadioButton;
  HostCheckBox: TNewCheckBox;
  IPPage: TInputQueryWizardPage;

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

  IPPage := CreateInputQueryPage(DeploymentPage.ID, 'Shared Instance Network Location', 'Specify the target IP address of the hosting workstation.', 'Please enter the IPv4 address of the computer sharing Odysseus (e.g. 192.168.1.45):');
  IPPage.Add('Host IP Address:', False);
  IPPage.Values[0] := '';
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := False;
  if (PageID = IPPage.ID) and (LocalInstallRadio.Checked) then
    Result := True;
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
end;

procedure CurStepChanged(CurStep: TSetupStep);
var ResultCode: Integer; WslCheckCode: Integer; HostModeFile: string;
begin
  if (CurStep = ssPostInstall) and (IsLocalInstallation) then begin
    if IsHostSelected then begin
      HostModeFile := ExpandConstant('{app}') + '\ODYSSEUS_HOST_MODE';
      if not FileExists(HostModeFile) then
        SaveStringToFile(HostModeFile, 'true', False);
    end;

    { Detect WSL and Ubuntu status: exit 10 = WSL absent, exit 11 = Ubuntu absent, exit 0 = both present }
    if not Exec(
      ExpandConstant('{sysnative}\windowspowershell\v1.0\powershell.exe'),
      '-NoProfile -ExecutionPolicy Bypass -Command "if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) { exit 10 }; [Console]::OutputEncoding = [System.Text.Encoding]::Unicode; $distros = (wsl -l -q) 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ }; if (-not ($distros | Where-Object { $_ -match ''^Ubuntu(-.*)?$'' })) { exit 11 }"',
      '', SW_HIDE, ewWaitUntilTerminated, WslCheckCode) then
      WslCheckCode := -1;

    if WslCheckCode = -1 then begin
      { Exec itself failed — PowerShell could not be launched }
      MsgBox('Could not verify WSL status (PowerShell failed to launch). If WSL or Ubuntu is not yet set up, re-run the installer. Otherwise use the desktop shortcut "Launch Odysseus (Local)" to start Odysseus.', mbError, MB_OK);
    end
    else if WslCheckCode = 10 then begin
      { WSL feature not installed — run wsl --install which enables the feature and installs Ubuntu }
      MsgBox('WSL is not yet enabled on this machine. A terminal window will now open to install WSL and Ubuntu. Please wait for it to finish, then reboot if Windows requests it.', mbInformation, MB_OK);
      Exec(
        ExpandConstant('{sysnative}\windowspowershell\v1.0\powershell.exe'),
        '-NoProfile -ExecutionPolicy Bypass -Command "wsl --install -d Ubuntu; Write-Host ''''; Write-Host ''Done. Press Enter to close...''; Read-Host"',
        '', SW_SHOW, ewWaitUntilTerminated, ResultCode);
      MsgBox('WSL and Ubuntu installation has run.' + #13#10#13#10 + 'If Windows prompted you to reboot, please do so now.' + #13#10 + 'After rebooting, use the desktop shortcut to launch Odysseus. If Ubuntu prompts you to create a Linux username and password on first run, complete that step and relaunch.', mbInformation, MB_OK);
    end
    else if WslCheckCode = 11 then begin
      { WSL present but no Ubuntu distro }
      MsgBox('WSL is installed but no Ubuntu distribution was found. A terminal window will now open to install Ubuntu. Please wait for it to finish.', mbInformation, MB_OK);
      Exec(
        ExpandConstant('{sysnative}\windowspowershell\v1.0\powershell.exe'),
        '-NoProfile -ExecutionPolicy Bypass -Command "wsl --install -d Ubuntu; Write-Host ''''; Write-Host ''Done. Press Enter to close...''; Read-Host"',
        '', SW_SHOW, ewWaitUntilTerminated, ResultCode);
      MsgBox('Ubuntu installation has run.' + #13#10#13#10 + 'Use the desktop shortcut to launch Odysseus. If Ubuntu prompts you to create a Linux username and password on first run, complete that step and relaunch.', mbInformation, MB_OK);
    end
    else begin
      { WSL and Ubuntu already present (exit 0) }
      MsgBox('WSL and Ubuntu are ready. Use the desktop shortcut "Launch Odysseus (Local)" to start Odysseus.', mbInformation, MB_OK);
    end;
  end;
end;