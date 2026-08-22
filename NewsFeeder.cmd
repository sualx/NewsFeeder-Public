@echo off
rem NewsFeeder launcher. The console starts minimized and the app hides it
rem immediately. NewsFeeder.vbs is the preferred fully silent launcher.
start "" /min pwsh.exe -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%~dp0NewsFeeder.ps1"
