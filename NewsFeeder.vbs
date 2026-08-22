' NewsFeeder silent launcher — starts the app with NO console window at all
' (the .cmd route always flashes a console frame briefly; this route never does).
Dim shell, scriptDir
Set shell = CreateObject("WScript.Shell")
scriptDir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
shell.Run "pwsh.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -File """ & scriptDir & "NewsFeeder.ps1""", 0, False
