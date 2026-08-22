#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef SourceDir
  #error SourceDir must point to the staged release files
#endif
#ifndef OutputDir
  #define OutputDir "..\artifacts"
#endif

[Setup]
AppId={{4B4A7E8D-E21E-4B61-9A56-0B213A95D741}
AppName=NewsFeeder
AppVersion={#AppVersion}
AppPublisher=Claus Erichsen
AppPublisherURL=https://github.com/sualx/NewsFeeder-Public
AppSupportURL=https://github.com/sualx/NewsFeeder-Public/issues
AppUpdatesURL=https://github.com/sualx/NewsFeeder-Public/releases/latest
DefaultDirName={localappdata}\Programs\NewsFeeder
DefaultGroupName=NewsFeeder
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
Compression=lzma2/max
SolidCompression=yes
OutputDir={#OutputDir}
OutputBaseFilename=NewsFeeder-Setup
UninstallDisplayIcon={sys}\shell32.dll
WizardStyle=modern

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\NewsFeeder.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\NewsFeeder.vbs"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\NewsFeeder.cmd"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\feeds.json"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\README.md"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\LICENSE"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\Stop-NewsFeeder.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#SourceDir}\runtime\*"; DestDir: "{app}\runtime"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\NewsFeeder"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\NewsFeeder.vbs"""; WorkingDir: "{app}"; IconFilename: "{sys}\shell32.dll"; IconIndex: 244
Name: "{autodesktop}\NewsFeeder"; Filename: "{sys}\wscript.exe"; Parameters: """{app}\NewsFeeder.vbs"""; WorkingDir: "{app}"; IconFilename: "{sys}\shell32.dll"; IconIndex: 244; Tasks: desktopicon

[Run]
Filename: "{sys}\wscript.exe"; Parameters: """{app}\NewsFeeder.vbs"""; WorkingDir: "{app}"; Description: "Start NewsFeeder"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{app}\runtime\pwsh.exe"; Parameters: "-NoProfile -NoLogo -ExecutionPolicy Bypass -File ""{app}\Stop-NewsFeeder.ps1"""; Flags: runhidden waituntilterminated; RunOnceId: "StopNewsFeeder"

[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  ResultCode: Integer;
begin
  Result := '';
  if FileExists(ExpandConstant('{app}\runtime\pwsh.exe')) and
     FileExists(ExpandConstant('{app}\Stop-NewsFeeder.ps1')) then
  begin
    Exec(
      ExpandConstant('{app}\runtime\pwsh.exe'),
      ExpandConstant('-NoProfile -NoLogo -ExecutionPolicy Bypass -File "{app}\Stop-NewsFeeder.ps1"'),
      '', SW_HIDE, ewWaitUntilTerminated, ResultCode);
  end;
end;