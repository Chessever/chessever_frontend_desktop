; Inno Setup script for the Chessever Windows installer.
;
; Produces `chessever-{version}+{build}-setup.exe` for first-time installs.
; In-app updates no longer use this installer; they are delivered by
; package:desktop_updater from `/updates/desktop/app-archive.json`.
;
; Required #define inputs (passed via `iscc.exe /DAppVersion=...`):
;   AppVersion   — semver from pubspec.yaml's `version:` (without `+build`)
;   AppBuild     — Flutter build number from pubspec.yaml's `version: x.y.z+N`
;   BuildDir     — path to `build\windows\x64\runner\Release` after `flutter build windows --release`
;
; Optional inputs (defaulted below):
;   AppPublisher, AppURL

#ifndef AppVersion
  #error "AppVersion must be passed via /DAppVersion=x.y.z"
#endif

#ifndef AppBuild
  #error "AppBuild must be passed via /DAppBuild=N"
#endif

#ifndef BuildDir
  #error "BuildDir must be passed via /DBuildDir=...\\build\\windows\\x64\\runner\\Release"
#endif

#ifndef AppPublisher
  #define AppPublisher "ChessEver LLC"
#endif

#ifndef AppURL
  #define AppURL "https://chessever.com"
#endif

#define AppName "ChessEver"
#define AppExeName "Chessever.exe"
#define AppId "{{8C3F7AE3-1DCA-4A1C-9A37-3B5E0F5C2F6A}"

[Setup]
AppId={#AppId}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}+{#AppBuild}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}
AppUpdatesURL={#AppURL}
; Self-updates are launched by the running app, so the install must be
; writable by the same user without UAC. Keep Chessever per-user.
DefaultDirName={userpf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
DisableDirPage=auto
DisableStartupPrompt=yes
LicenseFile=
PrivilegesRequired=lowest
OutputBaseFilename=chessever-{#AppVersion}+{#AppBuild}-setup
OutputDir=output
Compression=lzma2/ultra
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; CloseApplications keeps unattended upgrades reliable. RestartApplications is
; still enabled as an OS-level best-effort, and the explicit [Run] entry below
; handles silent installer relaunches.
CloseApplications=force
CloseApplicationsFilter=*.exe
RestartApplications=yes
SetupLogging=yes
UninstallDisplayIcon={app}\{#AppExeName}
VersionInfoVersion={#AppVersion}.0
VersionInfoCompany={#AppPublisher}
VersionInfoDescription={#AppName} setup
VersionInfoProductName={#AppName}
; Windows VERSIONINFO fields must be numeric dotted versions. Keep the
; app release version as x.y.z+build, but write file metadata as x.y.z.build
; so ISCC accepts it.
VersionInfoProductVersion={#AppVersion}.{#AppBuild}

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked
Name: "associatechessfiles"; Description: "Associate PGN, FEN, EPD, and CBH database files with ChessEver"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce

[Files]
; Recursively pull in every file Flutter put in the Release directory —
; .exe, .dll, the data\flutter_assets tree, native plugin DLLs, etc.
Source: "{#BuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Registry]
; Register chessever:// so Stripe/web checkout can return to the desktop app.
; HKCU keeps the installer compatible with the lowest-privilege install mode.
Root: HKCU; Subkey: "Software\Classes\chessever"; ValueType: string; ValueName: ""; ValueData: "URL:ChessEver Protocol"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\chessever"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\chessever\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#AppExeName},0"
Root: HKCU; Subkey: "Software\Classes\chessever\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExeName}"" ""%1"""

; Optional file associations for local chess files. The runner forwards "%1"
; to Dart as an entrypoint argument, where DesktopFileOpenService opens the
; path in the Library's local browser without importing it into SQLite.
Root: HKCU; Subkey: "Software\Classes\Chessever.ChessFile"; ValueType: string; ValueName: ""; ValueData: "ChessEver chess file"; Flags: uninsdeletekey; Tasks: associatechessfiles
Root: HKCU; Subkey: "Software\Classes\Chessever.ChessFile\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#AppExeName},0"; Tasks: associatechessfiles
Root: HKCU; Subkey: "Software\Classes\Chessever.ChessFile\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExeName}"" ""%1"""; Tasks: associatechessfiles
Root: HKCU; Subkey: "Software\Classes\.pgn\OpenWithProgids"; ValueType: string; ValueName: "Chessever.ChessFile"; ValueData: ""; Flags: uninsdeletevalue; Tasks: associatechessfiles
Root: HKCU; Subkey: "Software\Classes\.gz\OpenWithProgids"; ValueType: string; ValueName: "Chessever.ChessFile"; ValueData: ""; Flags: uninsdeletevalue; Tasks: associatechessfiles
Root: HKCU; Subkey: "Software\Classes\.fen\OpenWithProgids"; ValueType: string; ValueName: "Chessever.ChessFile"; ValueData: ""; Flags: uninsdeletevalue; Tasks: associatechessfiles
Root: HKCU; Subkey: "Software\Classes\.epd\OpenWithProgids"; ValueType: string; ValueName: "Chessever.ChessFile"; ValueData: ""; Flags: uninsdeletevalue; Tasks: associatechessfiles
Root: HKCU; Subkey: "Software\Classes\.cbh\OpenWithProgids"; ValueType: string; ValueName: "Chessever.ChessFile"; ValueData: ""; Flags: uninsdeletevalue; Tasks: associatechessfiles
Root: HKCU; Subkey: "Software\Classes\.cbv\OpenWithProgids"; ValueType: string; ValueName: "Chessever.ChessFile"; ValueData: ""; Flags: uninsdeletevalue; Tasks: associatechessfiles
Root: HKCU; Subkey: "Software\Classes\.cbf\OpenWithProgids"; ValueType: string; ValueName: "Chessever.ChessFile"; ValueData: ""; Flags: uninsdeletevalue; Tasks: associatechessfiles

[Run]
; First-time install only (skipifsilent omits this for /VERYSILENT
; upgrades).
Filename: "{app}\{#AppExeName}"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent

; Silent install path. Inno's RestartApplications uses Windows Restart Manager
; and only works for apps that registered for application restart, so the
; installer launches the freshly installed executable itself unless explicitly
; disabled by /CHESSEVER_RELAUNCH=0.
Filename: "{app}\{#AppExeName}"; WorkingDir: "{app}"; Parameters: "/updated"; Flags: nowait skipifnotsilent; Check: ShouldRelaunchAfterSilentUpdate

[Code]
function ShouldRelaunchAfterSilentUpdate: Boolean;
begin
  Result := CompareText(
    ExpandConstant('{param:CHESSEVER_RELAUNCH|1}'),
    '0'
  ) <> 0;
end;
