; Tokiboshi Windows installer (Inno Setup 6).
; Built in CI by the "Build installer" step, which passes the app
; version from pubspec.yaml as /DAppVersion=x.y.z. Paths are relative
; to this script's directory (installer/).

#ifndef AppVersion
  #define AppVersion "0.2.2"
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
OutputBaseFilename=Tokiboshi-Setup-{#AppVersion}
SetupIconFile=..\windows\runner\resources\app_icon.ico
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
UninstallDisplayIcon={app}\tokiboshi.exe
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional tasks:"; Flags: unchecked

[Files]
; The whole Release folder, including the bundled sing-box.exe that
; the CI "Bundle sing-box core" step copies next to tokiboshi.exe.
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\Tokiboshi"; Filename: "{app}\tokiboshi.exe"
Name: "{autodesktop}\Tokiboshi"; Filename: "{app}\tokiboshi.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\tokiboshi.exe"; Description: "Launch Tokiboshi"; Flags: nowait postinstall skipifsilent
