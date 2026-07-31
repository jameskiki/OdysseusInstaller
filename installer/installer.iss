[Setup]
AppName=Odysseus AI Environment
AppVersion=1.0.0
AppPublisher=Odysseus Team
AppPublisherURL=https://github.com/pewdiepie-archdaemon/odysseus
AppSupportURL=https://github.com/pewdiepie-archdaemon/odysseus/issues
VersionInfoCompany=Odysseus Team
VersionInfoDescription=Odysseus AI Environment Installer
VersionInfoProductName=Odysseus AI Environment
VersionInfoProductVersion=1.0.0
VersionInfoVersion=1.0.0.0
VersionInfoCopyright=Copyright (c) Odysseus Team
DefaultDirName={autopf}\Odysseus
DefaultGroupName=Odysseus AI
OutputBaseFilename=Odysseus_Setup
OutputDir=..\Output
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
  GpuSupportNoteLabel: TNewStaticText;
  HostCheckBox: TNewCheckBox;
  RepoRefPage: TWizardPage;
  RepoRefCombo: TNewComboBox;
  RepoRefStatusLabel: TNewStaticText;
  RebuildModePage: TInputOptionWizardPage;
  IPPage: TInputQueryWizardPage;
  RemoteReachabilityHintLabel: TNewStaticText;
  RepoBranchesLoaded: Boolean;
  LocalPreflightChecked: Boolean;
  LocalPreflightHasWsl: Boolean;
  LocalPreflightHasUbuntu: Boolean;
  LocalPreflightHasOllama: Boolean;
  LocalPreflightHasWinget: Boolean;
  UninstallCleanupPrompted: Boolean;
  UninstallFreshMode: Boolean;
  RemoveLocalRuntimeData: Boolean;
  RemoveWslWorkspaceData: Boolean;
  RemoveWslDockerArtifacts: Boolean;
  RemoveOllamaModelsData: Boolean;
  RemoveOllamaApplication: Boolean;
  RemoveWslDistroData: Boolean;
  DisableWslRuntime: Boolean;
  RemoveResidualInstallFiles: Boolean;

function IsLocalInstallation: Boolean; forward;
function IsRemoteInstallation: Boolean; forward;
function IsHostSelected: Boolean; forward;

procedure OnDeploymentTypeChange(Sender: TObject);
begin
  HostCheckBox.Enabled := LocalInstallRadio.Checked;
  if not HostCheckBox.Enabled then
    HostCheckBox.Checked := False;
end;

function RunPowerShellExitCheck(const Script: string): Integer;
var
  ResultCode: Integer;
begin
  if Exec(
    ExpandConstant('{sysnative}\windowspowershell\v1.0\powershell.exe'),
    '-NoProfile -ExecutionPolicy Bypass -Command "' + Script + '"',
    '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Result := ResultCode
  else
    Result := -1;
end;

procedure RefreshLocalPreflightChecks;
var
  WslCode: Integer;
  UbuntuCode: Integer;
  OllamaCode: Integer;
  WingetCode: Integer;
begin
  if LocalPreflightChecked then
    exit;

  WslCode := RunPowerShellExitCheck('if (Get-Command wsl -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }');
  LocalPreflightHasWsl := (WslCode = 0);

  UbuntuCode := RunPowerShellExitCheck(
    'if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) { exit 2 }; ' +
    '[Console]::OutputEncoding = [System.Text.Encoding]::Unicode; ' +
    '$distros = (wsl -l -q) 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ }; ' +
    'if ($distros | Where-Object { $_ -match ''^Ubuntu(-.*)?$'' }) { exit 0 } else { exit 1 }');
  LocalPreflightHasUbuntu := (UbuntuCode = 0);

  OllamaCode := RunPowerShellExitCheck(
    '$cmd = Get-Command ollama.exe -ErrorAction SilentlyContinue; ' +
    'if ($cmd) { exit 0 }; ' +
    '$paths = @(Join-Path $env:LOCALAPPDATA ''Programs\Ollama\ollama.exe'', Join-Path $env:ProgramFiles ''Ollama\ollama.exe'', Join-Path ${env:ProgramFiles(x86)} ''Ollama\ollama.exe''); ' +
    'foreach ($p in $paths) { if ($p -and (Test-Path $p)) { exit 0 } }; exit 1');
  LocalPreflightHasOllama := (OllamaCode = 0);

  WingetCode := RunPowerShellExitCheck('if (Get-Command winget -ErrorAction SilentlyContinue) { exit 0 } else { exit 1 }');
  LocalPreflightHasWinget := (WingetCode = 0);

  LocalPreflightChecked := True;
end;

function GetSelectedRepoRef: string;
begin
  if RepoRefCombo.ItemIndex >= 0 then
    Result := Trim(RepoRefCombo.Items[RepoRefCombo.ItemIndex])
  else
    Result := 'main';

  if Result = '' then
    Result := 'main';
end;

procedure PopulateRepoBranches;
var
  TempFile: string;
  PsScript: string;
  FetchExitCode: Integer;
  BranchLines: TArrayOfString;
  I: Integer;
  BranchName: string;
  MainIndex: Integer;
begin
  if RepoBranchesLoaded then
    exit;

  RepoRefCombo.Items.Clear;
  RepoRefCombo.Items.Add('main');
  RepoRefCombo.ItemIndex := 0;
  RepoRefStatusLabel.Caption := 'Loading remote branches from GitHub...';

  TempFile := ExpandConstant('{tmp}\odysseus-branches.txt');
  if FileExists(TempFile) then
    DeleteFile(TempFile);

  PsScript :=
    '$ErrorActionPreference = ''Stop''; ' +
    '$ProgressPreference = ''SilentlyContinue''; ' +
    '$resp = Invoke-RestMethod -UseBasicParsing -Uri ''https://api.github.com/repos/pewdiepie-archdaemon/odysseus/branches?per_page=100''; ' +
    '$names = @($resp | ForEach-Object { $_.name } | Where-Object { $_ } | Sort-Object -Unique); ' +
    'if ($names.Count -eq 0) { $names = @(''main'') }; ' +
    '$names | Out-File -Encoding ascii -FilePath ''' + TempFile + '''';

  FetchExitCode := RunPowerShellExitCheck(PsScript);
  if (FetchExitCode = 0) and LoadStringsFromFile(TempFile, BranchLines) then begin
    RepoRefCombo.Items.Clear;
    MainIndex := -1;

    for I := 0 to GetArrayLength(BranchLines) - 1 do begin
      BranchName := Trim(BranchLines[I]);
      if BranchName = '' then
        continue;
      if RepoRefCombo.Items.IndexOf(BranchName) >= 0 then
        continue;

      RepoRefCombo.Items.Add(BranchName);
      if BranchName = 'main' then
        MainIndex := RepoRefCombo.Items.Count - 1;
    end;

    if RepoRefCombo.Items.Count = 0 then begin
      RepoRefCombo.Items.Add('main');
      RepoRefCombo.ItemIndex := 0;
      RepoRefStatusLabel.Caption := 'No branches returned by GitHub. Defaulted to "main".';
    end
    else begin
      if MainIndex >= 0 then
        RepoRefCombo.ItemIndex := MainIndex
      else
        RepoRefCombo.ItemIndex := 0;
      RepoRefStatusLabel.Caption := 'Branch list loaded from remote repository.';
    end;
  end
  else begin
    RepoRefCombo.Items.Clear;
    RepoRefCombo.Items.Add('main');
    RepoRefCombo.ItemIndex := 0;
    RepoRefStatusLabel.Caption := 'Could not fetch remote branches right now. Defaulted to "main".';
  end;

  RepoBranchesLoaded := True;
end;

procedure UpdateRemoteReachabilityHint;
var
  RemoteIp: string;
begin
  RemoteIp := Trim(IPPage.Values[0]);
  if RemoteIp <> '' then
    RemoteReachabilityHintLabel.Caption := 'Shared Odysseus URL from this PC: http://' + RemoteIp + ':7000'
  else
    RemoteReachabilityHintLabel.Caption := 'Shared Odysseus URL from this PC: http://<host-ip>:7000';
end;

procedure OnRemoteIpChanged(Sender: TObject);
begin
  UpdateRemoteReachabilityHint;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if (CurPageID = RepoRefPage.ID) and IsLocalInstallation then
    PopulateRepoBranches;

  if (CurPageID = IPPage.ID) and IsRemoteInstallation then
    UpdateRemoteReachabilityHint;
end;

function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo, MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
var
  S: string;
  RemoteIp: string;
begin
  S := '';
  S := S + 'Deployment mode:' + Space;
  if IsLocalInstallation then
    S := S + 'Local instance on this computer' + NewLine
  else
    S := S + 'Connect to shared network instance' + NewLine;

  S := S + NewLine + 'Already present:' + NewLine;
  if IsLocalInstallation then begin
    RefreshLocalPreflightChecks;

    if LocalPreflightHasWsl then
      S := S + '- WSL runtime detected' + NewLine;
    if LocalPreflightHasUbuntu then
      S := S + '- Ubuntu WSL distro detected' + NewLine;
    if LocalPreflightHasOllama then
      S := S + '- Ollama installation detected' + NewLine;
    if not (LocalPreflightHasWsl or LocalPreflightHasUbuntu or LocalPreflightHasOllama) then
      S := S + '- No required local runtime dependencies detected yet' + NewLine;

    S := S + NewLine + 'Will be installed/configured:' + NewLine;
    S := S + '- Odysseus launcher and support scripts' + NewLine;
    S := S + '- Selected branch: ' + GetSelectedRepoRef + NewLine;
    if IsHostSelected then
      S := S + '- Firewall rule for inbound TCP 7000 (private/domain profiles)' + NewLine;

    S := S + NewLine + 'Manual action required:' + NewLine;
    if not LocalPreflightHasWsl then
      S := S + '- Install WSL and Ubuntu using "Prepare WSL for Odysseus"' + NewLine;
    if LocalPreflightHasWsl and (not LocalPreflightHasUbuntu) then
      S := S + '- Add an Ubuntu distro in WSL using "Prepare WSL for Odysseus"' + NewLine;
    if (not LocalPreflightHasOllama) and (not LocalPreflightHasWinget) then
      S := S + '- Install Ollama manually from https://ollama.com/download' + NewLine;
    if LocalPreflightHasOllama or LocalPreflightHasWinget then
      S := S + '- No blocking manual actions detected' + NewLine;
  end
  else begin
    RemoteIp := Trim(IPPage.Values[0]);
    if RemoteIp = '' then
      RemoteIp := '<host-ip>';

    S := S + '- Windows desktop and Start menu shortcut for remote access' + NewLine;
    S := S + NewLine + 'Will be installed/configured:' + NewLine;
    S := S + '- Remote shortcut target: http://' + RemoteIp + ':7000' + NewLine;
    S := S + NewLine + 'Manual action required:' + NewLine;
    S := S + '- Confirm host machine is running Odysseus and reachable at the selected IP' + NewLine;
  end;

  S := S + NewLine + MemoDirInfo;
  Result := S;
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
  LocalInstallRadio.Caption := 'Run a local instance on my own computer (Best with NVIDIA GPU; CPU mode also supported)';
  LocalInstallRadio.Font.Style := [fsBold];
  LocalInstallRadio.Left := ScaleX(8);
  LocalInstallRadio.Top := ScaleY(16);
  LocalInstallRadio.Width := DeploymentPage.SurfaceWidth - ScaleX(16);
  LocalInstallRadio.Checked := True;
  LocalInstallRadio.OnClick := @OnDeploymentTypeChange;

  GpuSupportNoteLabel := TNewStaticText.Create(DeploymentPage);
  GpuSupportNoteLabel.Parent := DeploymentPage.Surface;
  GpuSupportNoteLabel.Caption := 'Note: AMD GPU acceleration is not currently auto-detected in this installer. Local runs on unsupported GPUs may fall back to CPU mode.';
  GpuSupportNoteLabel.Left := ScaleX(28);
  GpuSupportNoteLabel.Top := LocalInstallRadio.Top + ScaleY(22);
  GpuSupportNoteLabel.Width := DeploymentPage.SurfaceWidth - ScaleX(36);
  GpuSupportNoteLabel.WordWrap := True;

  HostCheckBox := TNewCheckBox.Create(DeploymentPage);
  HostCheckBox.Parent := DeploymentPage.Surface;
  HostCheckBox.Caption := 'Act as Host: Allow other computers on the office network to connect to this machine';
  HostCheckBox.Left := ScaleX(28); 
  HostCheckBox.Top := GpuSupportNoteLabel.Top + GpuSupportNoteLabel.Height + ScaleY(6);
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

  RepoRefPage := CreateCustomPage(DeploymentPage.ID, 'Odysseus Version Selection', 'Choose which remote Odysseus branch to use.');

  RepoRefCombo := TNewComboBox.Create(RepoRefPage);
  RepoRefCombo.Parent := RepoRefPage.Surface;
  RepoRefCombo.Style := csDropDownList;
  RepoRefCombo.Left := ScaleX(8);
  RepoRefCombo.Top := ScaleY(18);
  RepoRefCombo.Width := RepoRefPage.SurfaceWidth - ScaleX(16);
  RepoRefCombo.Items.Add('main');
  RepoRefCombo.ItemIndex := 0;

  RepoRefStatusLabel := TNewStaticText.Create(RepoRefPage);
  RepoRefStatusLabel.Parent := RepoRefPage.Surface;
  RepoRefStatusLabel.Left := ScaleX(8);
  RepoRefStatusLabel.Top := RepoRefCombo.Top + RepoRefCombo.Height + ScaleY(8);
  RepoRefStatusLabel.Width := RepoRefPage.SurfaceWidth - ScaleX(16);
  RepoRefStatusLabel.Caption := 'Branch list will be fetched from GitHub when this page opens.';
  RepoRefStatusLabel.WordWrap := True;

  RebuildModePage := CreateInputOptionPage(RepoRefPage.ID, 'Container Rebuild Preference', 'Choose how Odysseus container rebuilds should be handled on launch.', 'Recommended default: Ask each launch.', True, False);
  RebuildModePage.Add('Ask each launch (recommended)');
  RebuildModePage.Add('Always rebuild before launch');
  RebuildModePage.Add('Never rebuild automatically');
  RebuildModePage.Values[0] := True;

  IPPage := CreateInputQueryPage(RebuildModePage.ID, 'Shared Instance Network Location', 'Specify the target IP address of the hosting workstation.', 'Please enter the IPv4 address of the computer sharing Odysseus (e.g. 192.168.1.45):');
  IPPage.Add('Host IP Address:', False);
  IPPage.Values[0] := '';

  RemoteReachabilityHintLabel := TNewStaticText.Create(IPPage);
  RemoteReachabilityHintLabel.Parent := IPPage.Surface;
  RemoteReachabilityHintLabel.Left := IPPage.Edits[0].Left;
  RemoteReachabilityHintLabel.Top := IPPage.Edits[0].Top + IPPage.Edits[0].Height + ScaleY(8);
  RemoteReachabilityHintLabel.Width := IPPage.SurfaceWidth - ScaleX(16);
  RemoteReachabilityHintLabel.Caption := 'Shared Odysseus URL from this PC: http://<host-ip>:7000';
  RemoteReachabilityHintLabel.WordWrap := True;
  IPPage.Edits[0].OnChange := @OnRemoteIpChanged;

  RepoBranchesLoaded := False;
  LocalPreflightChecked := False;
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

function IsDigitsOnly(const Value: string): Boolean;
var
  I: Integer;
begin
  Result := Length(Value) > 0;
  if not Result then
    exit;

  for I := 1 to Length(Value) do begin
    if (Value[I] < '0') or (Value[I] > '9') then begin
      Result := False;
      exit;
    end;
  end;
end;

function IsValidIPv4Address(const Value: string): Boolean;
var
  Remaining: string;
  Segment: string;
  DotPos: Integer;
  DotCount: Integer;
  SegmentValue: Integer;
begin
  Result := False;
  Remaining := Trim(Value);
  if Remaining = '' then
    exit;

  DotCount := 0;
  while True do begin
    DotPos := Pos('.', Remaining);
    if DotPos > 0 then begin
      Segment := Copy(Remaining, 1, DotPos - 1);
      Remaining := Copy(Remaining, DotPos + 1, Length(Remaining) - DotPos);
      DotCount := DotCount + 1;
    end
    else begin
      Segment := Remaining;
      Remaining := '';
    end;

    if (Segment = '') or (Length(Segment) > 3) then
      exit;
    if not IsDigitsOnly(Segment) then
      exit;

    SegmentValue := StrToInt(Segment);
    if (SegmentValue < 0) or (SegmentValue > 255) then
      exit;

    if (Length(Segment) > 1) and (Segment[1] = '0') then
      exit;

    if DotPos = 0 then
      break;
  end;

  if DotCount <> 3 then
    exit;

  Result := True;
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
    end
    else if not IsValidIPv4Address(IPPage.Values[0]) then begin
      MsgBox('Enter a valid IPv4 address (for example: 192.168.1.45).', mbError, MB_OK);
      Result := False;
    end;
  end;

  if (CurPageID = RepoRefPage.ID) and IsLocalInstallation then begin
    if RepoRefCombo.ItemIndex < 0 then begin
      MsgBox('Select a remote branch to continue.', mbError, MB_OK);
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
    SelectedRepoRef := GetSelectedRepoRef;

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

procedure ApplyUninstallPreset(IsFresh: Boolean);
begin
  UninstallFreshMode := IsFresh;

  if IsFresh then begin
    RemoveResidualInstallFiles := True;
    RemoveLocalRuntimeData := True;
    RemoveWslWorkspaceData := True;
    RemoveWslDockerArtifacts := True;
    RemoveOllamaModelsData := True;
    RemoveOllamaApplication := True;
    RemoveWslDistroData := False;
    DisableWslRuntime := False;
  end
  else begin
    RemoveResidualInstallFiles := True;
    RemoveLocalRuntimeData := False;
    RemoveWslWorkspaceData := False;
    RemoveWslDockerArtifacts := False;
    RemoveOllamaModelsData := False;
    RemoveOllamaApplication := False;
    RemoveWslDistroData := False;
    DisableWslRuntime := False;
  end;
end;

procedure PromptForUninstallSelections;
begin
  RemoveResidualInstallFiles :=
    MsgBox(
      'Remove the installed Odysseus program files folder after uninstall completes?' + #13#10 + #13#10 +
      '- Installation directory under Program Files',
      mbConfirmation, MB_YESNO) = IDYES;

  RemoveLocalRuntimeData :=
    MsgBox(
      'Remove local Odysseus runtime data for this Windows user?' + #13#10 + #13#10 +
      '- Logs in %LOCALAPPDATA%\Odysseus\Logs' + #13#10 +
      '- Cached user settings/state under %LOCALAPPDATA%\Odysseus' + #13#10 +
      '- User environment variable OLLAMA_HOST',
      mbConfirmation, MB_YESNO) = IDYES;

  RemoveWslWorkspaceData :=
    MsgBox(
      'Remove Odysseus workspace files inside Ubuntu WSL?' + #13#10 + #13#10 +
      '- ~/odysseus' + #13#10 +
      '- ~/run_odysseus.sh',
      mbConfirmation, MB_YESNO) = IDYES;

  RemoveWslDockerArtifacts :=
    MsgBox(
      'Remove Odysseus Docker artifacts in WSL (containers, project volumes, and networks)?' + #13#10 + #13#10 +
      'This targets the Odysseus compose project only.',
      mbConfirmation, MB_YESNO) = IDYES;

  RemoveOllamaModelsData :=
    MsgBox(
      'Remove Ollama models and local Ollama cache data?' + #13#10 + #13#10 +
      '- %USERPROFILE%\.ollama\models' + #13#10 +
      '- %LOCALAPPDATA%\Ollama',
      mbConfirmation, MB_YESNO) = IDYES;

  RemoveOllamaApplication :=
    MsgBox(
      'Uninstall the Ollama Windows application (if installed)?',
      mbConfirmation, MB_YESNO) = IDYES;

  RemoveWslDistroData :=
    MsgBox(
      'Also remove the Odysseus Ubuntu distro data by unregistering the detected Odysseus distro?' + #13#10 + #13#10 +
      'WARNING: This permanently deletes all files in that distro.',
      mbConfirmation, MB_YESNO) = IDYES;

  DisableWslRuntime :=
    MsgBox(
      'Also disable the Windows WSL runtime feature?' + #13#10 + #13#10 +
      'WARNING: This affects all WSL usage on this PC and may require a reboot.',
      mbConfirmation, MB_YESNO) = IDYES;
end;

function ConfirmDestructiveWslActions: Boolean;
begin
  Result := True;

  if not (RemoveWslDistroData or DisableWslRuntime) then
    exit;

  Result :=
    MsgBox(
      'Final confirmation:' + #13#10 + #13#10 +
      'You selected irreversible WSL cleanup options.' + #13#10 +
      '- Distro unregister permanently deletes distro data.' + #13#10 +
      '- WSL runtime disable affects system-wide WSL usage.' + #13#10 + #13#10 +
      'Do you want to continue with these destructive actions?',
      mbConfirmation, MB_YESNO) = IDYES;

  if not Result then begin
    RemoveWslDistroData := False;
    DisableWslRuntime := False;
  end;
end;

procedure RunSelectedCleanupActions;
var
  LocalDataDir: string;
begin
  if RemoveLocalRuntimeData then begin
    LocalDataDir := ExpandConstant('{localappdata}\Odysseus');
    if DirExists(LocalDataDir) then
      DelTree(LocalDataDir, True, True, True);

    RunPowerShellHidden('[Environment]::SetEnvironmentVariable(''OLLAMA_HOST'', $null, ''User'')');
  end;

  if RemoveWslWorkspaceData then begin
    RunPowerShellHidden(
      '$distros = (wsl -l -q) 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ -match ''^Ubuntu(-.*)?$'' }; ' +
      '$target = $distros | Select-Object -First 1; ' +
      'if ($target) { wsl -d $target -- bash -lc ''rm -rf ~/odysseus ~/run_odysseus.sh'' 2>$null | Out-Null }');
  end;

  if RemoveWslDockerArtifacts then begin
    RunPowerShellHidden(
      '$distros = (wsl -l -q) 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ -match ''^Ubuntu(-.*)?$'' }; ' +
      '$target = $distros | Select-Object -First 1; ' +
      'if ($target) { ' +
      'wsl -d $target -- bash -lc ''cd ~/odysseus 2>/dev/null && docker compose down --volumes --remove-orphans'' 2>$null | Out-Null; ' +
      'wsl -d $target -- bash -lc ''cd ~/odysseus 2>/dev/null && sudo -n docker compose down --volumes --remove-orphans'' 2>$null | Out-Null }');
  end;

  if RemoveOllamaModelsData then begin
    RunPowerShellHidden(
      '$paths = @("$env:USERPROFILE\\.ollama\\models", "$env:LOCALAPPDATA\\Ollama"); ' +
      'foreach ($p in $paths) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue } }');
  end;

  if RemoveOllamaApplication then begin
    RunPowerShellHidden(
      '$entries = Get-ItemProperty ''HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'', ''HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'', ''HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'' -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like ''Ollama*'' }; ' +
      '$entry = $entries | Select-Object -First 1; ' +
      'if ($entry) { ' +
      'if ($entry.QuietUninstallString) { Start-Process -FilePath ''cmd.exe'' -ArgumentList ''/c'', $entry.QuietUninstallString -WindowStyle Hidden -Wait } ' +
      'elseif ($entry.UninstallString) { Start-Process -FilePath ''cmd.exe'' -ArgumentList ''/c'', ($entry.UninstallString + '' /S'') -WindowStyle Hidden -Wait } }');
  end;

  if RemoveWslDistroData then begin
    RunPowerShellHidden(
      '$distros = (wsl -l -q) 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ -match ''^Ubuntu(-.*)?$'' }; ' +
      '$target = $distros | Select-Object -First 1; ' +
      'if ($target) { wsl --unregister $target 2>$null | Out-Null }');
  end;

  if DisableWslRuntime then begin
    RunPowerShellHidden(
      'dism.exe /Online /Disable-Feature /FeatureName:Microsoft-Windows-Subsystem-Linux /NoRestart 1>$null 2>$null');
  end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if (CurUninstallStep = usUninstall) and (not UninstallCleanupPrompted) then begin
    UninstallCleanupPrompted := True;

    UninstallFreshMode :=
      MsgBox(
        'Select uninstall mode:' + #13#10 + #13#10 +
        'YES = Fresh cleanup mode (recommended for clean reinstallation).' + #13#10 +
        'NO = Preserve mode (faster reinstall; keeps environment data).',
        mbConfirmation, MB_YESNO) = IDYES;

    ApplyUninstallPreset(UninstallFreshMode);

    if MsgBox('Do you want to review and customize individual uninstall components?', mbConfirmation, MB_YESNO) = IDYES then
      PromptForUninstallSelections;

    ConfirmDestructiveWslActions;
    RunSelectedCleanupActions;
  end;

  if CurUninstallStep = usPostUninstall then begin
    RunPowerShellHidden(
      'netsh.exe advfirewall firewall delete rule name=''Odysseus AI Network Host'' 1>$null 2>$null');

    if not RemoveResidualInstallFiles then
      exit;

    if DirExists(ExpandConstant('{app}')) then
      DelTree(ExpandConstant('{app}'), True, True, True);
  end;
end;
