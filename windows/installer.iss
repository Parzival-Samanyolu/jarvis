; Inno Setup script: per-user install (no administrator password), Start Menu entry, starts with Windows.
; Build from windows/ after PyInstaller:  iscc installer.iss

#if GetEnv("MYCROFT_VERSION") != ""
  #define AppVersion GetEnv("MYCROFT_VERSION")
#else
  #define AppVersion "0.1.0"
#endif

[Setup]
AppId={{6E1F2C1B-6A54-4C1F-9B57-3B0F6A1C7D21}
AppName=Mycroft
AppVersion={#AppVersion}
AppPublisher=Mycroft
DefaultDirName={localappdata}\Programs\Mycroft
DefaultGroupName=Mycroft
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=dist
OutputBaseFilename=Mycroft-Setup-{#AppVersion}
SetupIconFile=mycroft.ico
UninstallDisplayIcon={app}\Mycroft.exe
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes

[Tasks]
Name: "startup"; Description: "Start Mycroft when Windows starts"; GroupDescription: "Options:"
Name: "desktopicon"; Description: "Desktop shortcut"; GroupDescription: "Options:"; Flags: unchecked

[Files]
Source: "dist\Mycroft\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\Mycroft"; Filename: "{app}\Mycroft.exe"
Name: "{group}\Mycroft settings check"; Filename: "{cmd}"; Parameters: "/k ""{app}\mycroft-cli.exe"" --check"
Name: "{group}\Uninstall Mycroft"; Filename: "{uninstallexe}"
Name: "{userdesktop}\Mycroft"; Filename: "{app}\Mycroft.exe"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "Mycroft"; \
  ValueData: """{app}\Mycroft.exe"""; Flags: uninsdeletevalue; Tasks: startup

[Run]
Filename: "{app}\Mycroft.exe"; Description: "Start Mycroft now"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{cmd}"; Parameters: "/c taskkill /im Mycroft.exe /f"; Flags: runhidden; RunOnceId: "StopMycroft"
; The Settings switch can also write the start-with-Windows entry: always remove it.
Filename: "{sys}\reg.exe"; Parameters: "delete HKCU\Software\Microsoft\Windows\CurrentVersion\Run /v Mycroft /f"; Flags: runhidden; RunOnceId: "RemoveRunKey"
