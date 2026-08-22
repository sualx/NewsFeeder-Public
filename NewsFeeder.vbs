' NewsFeeder silent launcher — starts the app with NO console window at all
' (the .cmd route always flashes a console frame briefly; this route never does).
Dim shell, fileSystem, scriptDir, powerShellPath, installedArgument, commandLine
Set shell = CreateObject("WScript.Shell")
Set fileSystem = CreateObject("Scripting.FileSystemObject")
scriptDir = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
powerShellPath = scriptDir & "runtime\pwsh.exe"
installedArgument = ""
If fileSystem.FileExists(powerShellPath) Then
	powerShellPath = """" & powerShellPath & """"
	installedArgument = " -Installed"
Else
	powerShellPath = "pwsh.exe"
End If
commandLine = powerShellPath & " -NoProfile -NoLogo -ExecutionPolicy Bypass -File """ & scriptDir & "NewsFeeder.ps1""" & installedArgument
shell.Run commandLine, 0, False
