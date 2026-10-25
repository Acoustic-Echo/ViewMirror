; ViewMirror installer. The payload is an independently verified portable release.
#ifndef PayloadDir
  #error PayloadDir must point to an extracted, verified release.
#endif
#ifndef AppVersion
  #error AppVersion is required.
#endif
#ifndef NumericVersion
  #error NumericVersion is required.
#endif

[Setup]
AppId={{779E6AE2-7D94-4A12-9557-169F9418CB33}
AppName=ViewMirror
AppVersion={#AppVersion}
AppVerName=ViewMirror {#AppVersion}
AppPublisher=ViewMirror
VersionInfoVersion={#NumericVersion}
VersionInfoProductName=ViewMirror
VersionInfoDescription=ViewMirror Setup
VersionInfoProductVersion={#NumericVersion}
DefaultDirName={localappdata}\Programs\ViewMirror
DefaultGroupName=ViewMirror
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
SetupArchitecture=x64
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
MinVersion=10.0.22000
UninstallDisplayName=ViewMirror
UninstallDisplayIcon={app}\viewMirror.exe
AppMutex=Local\viewMirror-F7F946DE185BEF23EAB79C8F
SetupMutex=Local\ViewMirror-Installer
CloseApplications=no
RestartApplications=no
ChangesEnvironment=no
WizardStyle=modern
SetupIconFile=icons\ViewMirror.ico
Compression=lzma2/normal
SolidCompression=yes
OutputBaseFilename=ViewMirror-{#AppVersion}-win-x64-setup
LicenseFile={#PayloadDir}\LICENSE.txt
InfoBeforeFile=INSTALLER-README.txt
SetupLogging=yes
UninstallLogging=yes
SignedUninstaller=no

[Languages]
Name: "japanese"; MessagesFile: "compiler:Languages\Japanese.isl"; LicenseFile: "licenses\GPL-3.0.ja.txt"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "INSTALLER-README.txt"; DestDir: "{app}"; Flags: ignoreversion
Source: "licenses\GPL-3.0.ja.txt"; DestDir: "{app}"; DestName: "LICENSE-ja.txt"; Flags: ignoreversion

[Icons]
Name: "{userprograms}\ViewMirror\ViewMirror"; Filename: "{app}\viewMirror.exe"; WorkingDir: "{app}"
Name: "{userprograms}\ViewMirror\インストールについて"; Filename: "{app}\INSTALLER-README.txt"
Name: "{userdesktop}\ViewMirror"; Filename: "{app}\viewMirror.exe"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\viewMirror.exe"; Description: "{cm:LaunchProgram,ViewMirror}"; Flags: nowait postinstall skipifsilent

; No UninstallDelete section: preferences and logs in LocalAppData\ViewMirror
; belong to the user. No firewall rules, security settings, or autostart entries.
