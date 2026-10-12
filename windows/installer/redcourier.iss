; Inno Setup script for the Windows installer.
;
;   flutter build windows --release
;   iscc /DAppVersion=0.0.1 windows\installer\redcourier.iss
;
; Output: dist\RedCourier-<version>-windows-x64-setup.exe
; Installs per user (no administrator rights) to
; %LOCALAPPDATA%\Programs\RedCourier. Uninstalling removes the program but
; keeps groups and keys (%APPDATA%\de.red.rc\RedCourier); delete them in the app.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{060AB813-6CCB-4A52-8F00-A94C6CA32781}
AppName=RedCourier
AppVersion={#AppVersion}
AppPublisher=RedCourier
AppPublisherURL=https://github.com/inflac/redcourier
AppSupportURL=https://github.com/inflac/redcourier/issues
DefaultDirName={autopf}\RedCourier
DefaultGroupName=RedCourier
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir=..\..\dist
OutputBaseFilename=RedCourier-{#AppVersion}-windows-x64-setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\redcourier.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "german"; MessagesFile: "compiler:Languages\German.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "..\..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\RedCourier"; Filename: "{app}\redcourier.exe"
Name: "{autodesktop}\RedCourier"; Filename: "{app}\redcourier.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\redcourier.exe"; Description: "{cm:LaunchProgram,RedCourier}"; Flags: nowait postinstall skipifsilent
; Silent update started by the app: start the new version afterwards.
Filename: "{app}\redcourier.exe"; Flags: nowait; Check: WizardSilent
