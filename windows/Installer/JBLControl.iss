; The JBLControl Windows installer (Inno Setup 6). Built per architecture by
;   powershell -ExecutionPolicy Bypass -File scripts/build-windows.ps1 -Installer
; which passes AppVersion/BuildNumber (from Resources/Info.plist), Arch, SourceDir (the self-contained
; publish folder) and OutputDir. Installs per user, without an admin prompt, like the app's own settings
; (HKCU, %LOCALAPPDATA%). The wizard images come from scripts/make-windows-icons.ps1.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef BuildNumber
  #define BuildNumber "0"
#endif
#ifndef Arch
  #define Arch "x64"
#endif
#ifndef SourceDir
  #error SourceDir (the published app folder) must be defined
#endif
#ifndef OutputDir
  #define OutputDir "..\..\build"
#endif

#define AppName "JBLControl"
#define AppExe "JBLControl.exe"
#define RepoUrl "https://github.com/ffrafat/JBLControl"

[Setup]
; Never change: it's how Windows recognizes an upgrade of the same app.
AppId={{76F22066-C234-4637-A39B-879E5E7DEE4D}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=JBLControl contributors
AppPublisherURL={#RepoUrl}
AppSupportURL={#RepoUrl}/issues
AppUpdatesURL={#RepoUrl}/releases
AppCopyright=Copyright (c) 2026 JBLControl contributors
VersionInfoVersion={#AppVersion}.{#BuildNumber}
VersionInfoProductName={#AppName}
VersionInfoDescription={#AppName} Setup
VersionInfoCompany=JBLControl contributors

DefaultDirName={autopf}\{#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
MinVersion=10.0.17763
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif

WizardStyle=modern
DisableWelcomePage=no
WizardImageFile=WizardImage-100.bmp,WizardImage-150.bmp,WizardImage-200.bmp
WizardSmallImageFile=WizardSmallImage-100.bmp,WizardSmallImage-150.bmp,WizardSmallImage-200.bmp
SetupIconFile=..\JBLControl.Windows\Assets\AppIcon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
; JBLControl's MIT license plus the terms of the bundled runtimes, which users must accept (the Windows App
; SDK's redistribution terms require it). Full texts are installed in {app}\licenses.
LicenseFile=License.txt

OutputDir={#OutputDir}
OutputBaseFilename=JBLControl-win-{#Arch}-{#AppVersion}-setup
Compression=lzma2/max
SolidCompression=yes
; The running app is closed by PrepareToInstall below; it has no windows the Restart Manager could ask to close.
CloseApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Messages]
WelcomeLabel2=This will install [name/ver] on your computer.%n%nBattery level, EQ presets and a custom equalizer for your JBL speaker, in a window and the system tray. No phone, no JBL Portable app.%n%nUnofficial. Not affiliated with or endorsed by JBL or Harman International.
FinishedLabel=Setup has finished installing [name] on your computer.%n%nTurn your JBL speaker on nearby and JBLControl finds it by itself. Closing its window keeps it running in the system tray.

[Tasks]
Name: "startup"; Description: "Start JBLControl in the system tray when I sign in"; GroupDescription: "Startup:"; Flags: unchecked
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
; The app sets this AppUserModelID for its notifications; the shortcuts carry it too, so a pinned taskbar
; icon and the running window share one taskbar button.
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"; Comment: "JBL speaker control"; AppUserModelID: "io.github.jblcontrol"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Comment: "JBL speaker control"; AppUserModelID: "io.github.jblcontrol"; Tasks: desktopicon

[Registry]
; The same entry Settings → Launch at login writes: start quietly in the tray.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "{#AppName}"; \
  ValueData: """{app}\{#AppExe}"" --background"; Tasks: startup; Flags: uninsdeletevalue

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Cached speaker photos; settings stay in case it's reinstalled.
Type: filesandordirs; Name: "{localappdata}\JBLControl\photos"

[Code]
// The tray app keeps running after its window closes, so close it before files are replaced or removed.
procedure CloseRunningApp;
var
  ResultCode: Integer;
begin
  Exec(ExpandConstant('{sys}\taskkill.exe'), '/f /im {#AppExe}', '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  if ResultCode = 0 then Sleep(800);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  CloseRunningApp;
  Result := '';
end;

function InitializeUninstall(): Boolean;
begin
  CloseRunningApp;
  Result := True;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    // The app writes these itself (Settings → Launch at login, notifications); don't leave them behind.
    RegDeleteValue(HKEY_CURRENT_USER, 'Software\Microsoft\Windows\CurrentVersion\Run', '{#AppName}');
    RegDeleteKeyIncludingSubkeys(HKEY_CURRENT_USER, 'Software\Classes\AppUserModelId\io.github.jblcontrol');
  end;
end;
