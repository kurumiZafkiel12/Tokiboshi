; Tokiboshi Windows installer (Inno Setup 6).
; Built in CI by the "Build installer" step, which passes the app
; version from pubspec.yaml as /DAppVersion=x.y.z. Paths are relative
; to this script's directory (installer/).

#ifndef AppVersion
  #define AppVersion "0.0.5"
#endif

#ifndef OutputSuffix
  #define OutputSuffix ""
#endif

[Setup]
AppId={{8F3B1C2E-7A4D-4E5F-9B6A-2D1C0E5F7A9B}
AppName=Tokiboshi
AppVersion={#AppVersion}
AppPublisher=kurumi
AppPublisherURL=https://github.com/kurumiZafkiel12/Tokiboshi
AppSupportURL=https://github.com/kurumiZafkiel12/Tokiboshi
DefaultDirName={localappdata}\Programs\Tokiboshi
DefaultGroupName=Tokiboshi
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..
OutputBaseFilename=Tokiboshi-Setup-{#AppVersion}{#OutputSuffix}
SetupIconFile=..\windows\runner\resources\app_icon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\tokiboshi.exe
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; The path-scoped upgrade hook shuts down our process tree before extraction.
CloseApplications=no
RestartApplications=no

[Languages]
Name: "chinesesimp"; MessagesFile: "languages\ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加选项："; Flags: unchecked

[Files]
Source: "prepare-upgrade.ps1"; Flags: dontcopy
Source: "legacy-v005-files.json"; Flags: dontcopy
; The whole Release folder, including the bundled sing-box.exe that
; the CI "Bundle sing-box core" step copies next to tokiboshi.exe.
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\Tokiboshi"; Filename: "{app}\tokiboshi.exe"
Name: "{autodesktop}\Tokiboshi"; Filename: "{app}\tokiboshi.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\tokiboshi.exe"; Description: "启动 Tokiboshi"; Flags: nowait postinstall skipifsilent

[Code]
var
  UpgradeSnapshot: String;
  CleanupFailed: Boolean;

function RunUpgradeHelper(Mode: String): Boolean;
var
  Code: Integer;
  Parameters: String;
begin
  Parameters := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
    ExpandConstant('{tmp}\prepare-upgrade.ps1') + '" -Mode ' + Mode +
    ' -InstallDir "' + ExpandConstant('{app}') + '" -DataDir "' +
    ExpandConstant('{userappdata}\Tokiboshi') + '" -Snapshot "' +
    UpgradeSnapshot + '" -LegacyManifest "' + ExpandConstant('{tmp}\legacy-v005-files.json') + '"';
  Result := Exec(ExpandConstant('{sys}\WindowsPowerShell\v1.0\powershell.exe'),
    Parameters, '', SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Log('Installer language: ' + ActiveLanguage);
  ExtractTemporaryFile('prepare-upgrade.ps1');
  ExtractTemporaryFile('legacy-v005-files.json');
  UpgradeSnapshot := ExpandConstant('{tmp}\tokiboshi-previous-files.json');
  if not RunUpgradeHelper('Prepare') then
    Result := '无法关闭旧版进程或读取旧版文件清单。请关闭 Tokiboshi 后重试。'
  else
    Result := '';
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then begin
    CleanupFailed := not RunUpgradeHelper('Cleanup');
    if CleanupFailed then begin
      Log('旧版文件清理未完成，用户配置未删除。');
      if not WizardSilent then
        MsgBox('新版已安装，但部分旧程序文件未能清理。请重新运行安装包重试。节点、订阅和设置已保留。', mbError, MB_OK);
    end;
  end;
end;

function GetCustomSetupExitCode: Integer;
begin
  if CleanupFailed then Result := 1 else Result := 0;
end;
