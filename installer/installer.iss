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
Source: "..\scripts\windows\lib\Odysseus.RuntimeChecks.psm1"; DestDir: "{app}\lib"; Flags: ignoreversion; Check: IsLocalInstallation

[Icons]
Name: "{autodesktop}\Launch Odysseus (Local)"; Filename: "{sysnative}\windowspowershell\v1.0\powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -Command ""try {{ & '{app}\Launch-Odysseus.ps1' } catch {{ Write-Host ('[FATAL] ' + $_.Exception.Message) -ForegroundColor Red; Write-Host $_.ScriptStackTrace -ForegroundColor DarkGray; Read-Host 'A fatal error occurred. Press ENTER to close...' }"""; IconFilename: "{sys}\shell32.dll"; IconIndex: 13; WorkingDir: "{app}"; Check: IsLocalInstallation
Name: "{group}\Prepare WSL for Odysseus"; Filename: "{sysnative}\windowspowershell\v1.0\powershell.exe"; Parameters: "-NoExit -NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -Command ""& '{app}\Prepare-WslForOdysseus.ps1'"""; IconFilename: "{sys}\shell32.dll"; IconIndex: 13; WorkingDir: "{app}"; Check: IsLocalInstallation
Name: "{autodesktop}\Prepare WSL for Odysseus"; Filename: "{sysnative}\windowspowershell\v1.0\powershell.exe"; Parameters: "-NoExit -NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -Command ""& '{app}\Prepare-WslForOdysseus.ps1'"""; IconFilename: "{sys}\shell32.dll"; IconIndex: 13; WorkingDir: "{app}"; Check: IsLocalInstallation
Name: "{group}\Odysseus Health Audit"; Filename: "{sysnative}\windowspowershell\v1.0\powershell.exe"; Parameters: "-NoExit -NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -Command ""& '{app}\Audit-Odysseus.ps1'"""; IconFilename: "{sys}\shell32.dll"; IconIndex: 168; WorkingDir: "{app}"; Check: IsLocalInstallation
Name: "{autodesktop}\Odysseus Health Audit"; Filename: "{sysnative}\windowspowershell\v1.0\powershell.exe"; Parameters: "-NoExit -NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -Command ""& '{app}\Audit-Odysseus.ps1'"""; IconFilename: "{sys}\shell32.dll"; IconIndex: 168; WorkingDir: "{app}"; Check: IsLocalInstallation

[Run]
; Allow WSL-to-Windows Ollama traffic for local deployments.
Filename: "cmd.exe"; Parameters: "/c ""netsh.exe advfirewall firewall delete rule name=""Odysseus Ollama WSL Bridge"" 1>nul 2>nul & netsh.exe advfirewall firewall add rule name=""Odysseus Ollama WSL Bridge"" dir=in action=allow protocol=TCP localport=11434 profile=any || (echo Ollama firewall bridge configuration failed && pause)"""; StatusMsg: "Configuring Ollama WSL bridge firewall permissions..."; Check: IsLocalInstallation

[Code]
var
  DeploymentPage: TWizardPage;
  DeploymentInfoLabel: TNewStaticText;
  GpuSupportNoteLabel: TNewStaticText;
  LocalPreflightChecked: Boolean;
  LocalPreflightHasWsl: Boolean;
  LocalPreflightHasUbuntu: Boolean;
  LocalPreflightHasOllama: Boolean;
  LocalPreflightHasWinget: Boolean;
  UninstallCleanupPrompted: Boolean;
  UninstallFullCleanup: Boolean;
  RemoveLocalRuntimeData: Boolean;
  RemoveWslWorkspaceData: Boolean;
  RemoveWslDockerArtifacts: Boolean;
  RemoveOllamaModelsData: Boolean;
  RemoveOllamaApplication: Boolean;
  RemoveResidualInstallFiles: Boolean;

function IsLocalInstallation: Boolean;
begin
  Result := True;
end;

function RunPowerShellExitCheck(const Script: string): Integer;
var
  ResultCode: Integer;
  ScriptFile: string;
begin
  { Run via a temp script file so embedded quotes can never break the command line. }
  ScriptFile := ExpandConstant('{tmp}\odysseus-check.ps1');
  if not SaveStringToFile(ScriptFile, Script, False) then begin
    Result := -1;
    exit;
  end;

  if Exec(
    ExpandConstant('{sysnative}\windowspowershell\v1.0\powershell.exe'),
    '-NoProfile -ExecutionPolicy Bypass -File "' + ScriptFile + '"',
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

function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo, MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
var
  S: string;
begin
  S := '';
  S := S + 'Deployment mode:' + Space;
  S := S + 'Local instance on this computer' + NewLine;

  S := S + NewLine + 'Already present:' + NewLine;
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
  S := S + '- Default repo ref: dev (advanced override via odysseus-launcher.config)' + NewLine;
  S := S + '- Default repo sync mode: managed-clean (advanced override via odysseus-launcher.config)' + NewLine;
  S := S + '- Default rebuild mode: ask (advanced override via odysseus-launcher.config)' + NewLine;
  S := S + '- Firewall rule for inbound TCP 11434 (all profiles, WSL -> Ollama bridge)' + NewLine;

  S := S + NewLine + 'Manual action required:' + NewLine;
  if not LocalPreflightHasWsl then
    S := S + '- Install WSL and Ubuntu using "Prepare WSL for Odysseus"' + NewLine;
  if LocalPreflightHasWsl and (not LocalPreflightHasUbuntu) then
    S := S + '- Add an Ubuntu distro in WSL using "Prepare WSL for Odysseus"' + NewLine;
  if (not LocalPreflightHasOllama) and (not LocalPreflightHasWinget) then
    S := S + '- Install Ollama manually from https://ollama.com/download' + NewLine;
  if LocalPreflightHasOllama or LocalPreflightHasWinget then
    S := S + '- No blocking manual actions detected' + NewLine;

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

  DeploymentPage := CreateCustomPage(wpLicense, 'Local Installation', 'Odysseus installs as a local instance on this computer.');

  DeploymentInfoLabel := TNewStaticText.Create(DeploymentPage);
  DeploymentInfoLabel.Parent := DeploymentPage.Surface;
  DeploymentInfoLabel.Caption := 'This installer configures the local Odysseus launcher only. Advanced runtime overrides (repo ref, sync mode, rebuild mode, and endpoint host overrides) are available in odysseus-launcher.config after install.';
  DeploymentInfoLabel.Left := ScaleX(8);
  DeploymentInfoLabel.Top := ScaleY(16);
  DeploymentInfoLabel.Width := DeploymentPage.SurfaceWidth - ScaleX(16);
  DeploymentInfoLabel.WordWrap := True;

  GpuSupportNoteLabel := TNewStaticText.Create(DeploymentPage);
  GpuSupportNoteLabel.Parent := DeploymentPage.Surface;
  GpuSupportNoteLabel.Caption := 'Note: AMD GPU acceleration is not currently auto-detected in this installer. Local runs on unsupported GPUs may fall back to CPU mode.';
  GpuSupportNoteLabel.Left := ScaleX(8);
  GpuSupportNoteLabel.Top := DeploymentInfoLabel.Top + DeploymentInfoLabel.Height + ScaleY(10);
  GpuSupportNoteLabel.Width := DeploymentPage.SurfaceWidth - ScaleX(16);
  GpuSupportNoteLabel.WordWrap := True;

  LocalPreflightChecked := False;
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
  if CurPageID = DeploymentPage.ID then begin
    IsNvidiaDetected := IsNvidiaGpuPresent;
    if not IsNvidiaDetected then begin
      if MsgBox('WARNING: No dedicated NVIDIA GPU was detected.' + #13#10#13#10 + 'Odysseus will run in "CPU-Only mode" locally with reduced processing speeds.' + #13#10#13#10 + 'Do you want to proceed with a local CPU installation?', mbConfirmation, MB_YESNO) = IDNO then
        Result := False;
    end;
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  WslCheckCode: Integer;
  LauncherConfig: string;
begin
  if (CurStep = ssPostInstall) and IsLocalInstallation then begin
    { Single launcher config replaces the former per-key marker files. }
    LauncherConfig :=
      'ODYSSEUS_REPO_REF=dev' + #13#10 +
      'ODYSSEUS_REBUILD_MODE=ask' + #13#10 +
      'ODYSSEUS_REPO_SYNC_MODE=managed-clean' + #13#10 +
      'ODYSSEUS_HOST_MODE=0' + #13#10;

    SaveStringToFile(ExpandConstant('{app}') + '\odysseus-launcher.config', LauncherConfig, False);

    { Remove legacy marker files from earlier installer versions. }
    DeleteFile(ExpandConstant('{app}') + '\ODYSSEUS_REPO_REF');
    DeleteFile(ExpandConstant('{app}') + '\ODYSSEUS_REBUILD_MODE');
    DeleteFile(ExpandConstant('{app}') + '\ODYSSEUS_REPO_SYNC_MODE');
    DeleteFile(ExpandConstant('{app}') + '\ODYSSEUS_HOST_MODE');
    DeleteFile(ExpandConstant('{app}') + '\ODYSSEUS_TEST_MODE');

    { Readiness check only: exit 10 = WSL absent, exit 11 = Ubuntu absent, exit 0 = both present }
    if not Exec(
      ExpandConstant('{sysnative}\windowspowershell\v1.0\powershell.exe'),
      '-NoProfile -ExecutionPolicy Bypass -Command "if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) { exit 10 }; [Console]::OutputEncoding = [System.Text.Encoding]::Unicode; $distros = (wsl -l -q) 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ }; if (-not ($distros | Where-Object { $_ -match ''^Ubuntu(-.*)?$'' })) { exit 11 }"',
      '', SW_HIDE, ewWaitUntilTerminated, WslCheckCode) then
      WslCheckCode := -1;

    if WslCheckCode = -1 then begin
      MsgBox('Could not verify WSL readiness because PowerShell failed to launch.' + #13#10#13#10 + 'Use the "Prepare WSL for Odysseus" shortcut to install/prepare WSL2 + Ubuntu, then launch Odysseus.', mbCriticalError, MB_OK);
    end
    else if WslCheckCode = 10 then begin
      MsgBox('WSL2 with Ubuntu is required before launching Odysseus.' + #13#10#13#10 + 'Use the "Prepare WSL for Odysseus" shortcut. It will run "wsl --install -d Ubuntu", guide reboot if needed, and help complete Ubuntu first-run setup.', mbCriticalError, MB_OK);
    end
    else if WslCheckCode = 11 then begin
      MsgBox('WSL is installed, but no Ubuntu distribution was found.' + #13#10#13#10 + 'Use the "Prepare WSL for Odysseus" shortcut. It installs Ubuntu and guides first-run setup.', mbCriticalError, MB_OK);
    end
    else begin
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

procedure ApplyUninstallPreset(IsFullCleanup: Boolean);
begin
  UninstallFullCleanup := IsFullCleanup;
  RemoveResidualInstallFiles := True;

  if IsFullCleanup then begin
    RemoveLocalRuntimeData := True;
    RemoveWslWorkspaceData := True;
    RemoveWslDockerArtifacts := True;
    RemoveOllamaModelsData := True;
    RemoveOllamaApplication := True;
  end
  else begin
    RemoveLocalRuntimeData := False;
    RemoveWslWorkspaceData := False;
    RemoveWslDockerArtifacts := False;
    RemoveOllamaModelsData := False;
    RemoveOllamaApplication := False;
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
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if (CurUninstallStep = usUninstall) and (not UninstallCleanupPrompted) then begin
    UninstallCleanupPrompted := True;

    UninstallFullCleanup :=
      MsgBox(
        'Select uninstall mode:' + #13#10 + #13#10 +
        'YES = Full cleanup mode (removes local runtime data, WSL workspace/container artifacts, and Ollama data/application).' + #13#10 +
        'NO = Standard uninstall (removes installed program files only).',
        mbConfirmation, MB_YESNO) = IDYES;

    if UninstallFullCleanup then begin
      if MsgBox(
        'Full cleanup is destructive and may remove local models, WSL workspace data, and Docker artifacts.' + #13#10 + #13#10 +
        'Do you want to continue?',
        mbConfirmation, MB_YESNO) = IDNO then
        UninstallFullCleanup := False;
    end;

    ApplyUninstallPreset(UninstallFullCleanup);
    RunSelectedCleanupActions;
  end;

  if CurUninstallStep = usPostUninstall then begin
    RunPowerShellHidden(
      'netsh.exe advfirewall firewall delete rule name=''Odysseus Ollama WSL Bridge'' 1>$null 2>$null');

    if not RemoveResidualInstallFiles then
      exit;

    if DirExists(ExpandConstant('{app}')) then
      DelTree(ExpandConstant('{app}'), True, True, True);
  end;
end;
