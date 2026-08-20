#ifndef SourceRoot
  #define SourceRoot "..\package"
#endif
#ifndef AppVersion
  #define AppVersion "0.1.0"
#endif
#define AppName "LGHS Imager"

[Setup]
AppId={{F0282D9D-CA34-4A5C-AB7E-940A8EA7074B}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=LGHS
DefaultDirName={autopf}\LGHS Imager
DefaultGroupName=LGHS Imager
OutputDir=..\dist
OutputBaseFilename=LGHS-Imager-Setup-x64
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=admin
DisableProgramGroupPage=yes
CloseApplications=yes
RestartApplications=yes
UninstallDisplayName=LGHS Imager

[Files]
Source: "{#SourceRoot}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\LGHS Imager"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\LGHS-Imager.vbs"""; WorkingDir: "{app}"
Name: "{autodesktop}\LGHS Imager"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\LGHS-Imager.vbs"""; WorkingDir: "{app}"

[Run]
Filename: "{sys}\wscript.exe"; Parameters: """{app}\LGHS-Imager.vbs"""; Description: "Launch LGHS Imager"; Flags: nowait postinstall skipifsilent
