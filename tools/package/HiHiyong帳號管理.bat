@echo off
rem HIHIYONG launcher: run app\HIHIYONG_MultiAccount_Manager_v1.3.13.0_GameData.ahk as administrator
rem (the game runs as administrator, so the manager must too).
rem It also keeps a desktop shortcut named after this file, with the icon app\HiHiyong.ico
rem (falls back to app\HiHiyong_default.ico). The shortcut is only rewritten when it is missing
rem or points somewhere else (e.g. the folder was moved), so a custom icon is kept.
set "APP=%~dp0app"
set "BAT=%~f0"
set "AHK=%APP%\runtime\AutoHotkey64.exe"
if not exist "%AHK%" set "AHK=%ProgramFiles%\AutoHotkey\v2\AutoHotkey64.exe"
if not exist "%AHK%" (
  echo [HIHIYONG] AutoHotkey64.exe not found in app\runtime
  pause
  exit /b 1
)
powershell -NoProfile -WindowStyle Hidden -Command "try{$ico=Join-Path $env:APP 'HiHiyong.ico'; if(-not (Test-Path $ico)){$ico=Join-Path $env:APP 'HiHiyong_default.ico'}; $name=[IO.Path]::GetFileNameWithoutExtension($env:BAT); $ws=New-Object -ComObject WScript.Shell; $l=$ws.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) ($name+'.lnk'))); if($l.TargetPath -ne $env:BAT){$l.TargetPath=$env:BAT; $l.WorkingDirectory=Split-Path $env:BAT; $l.IconLocation=$ico+',0'; $l.WindowStyle=7; $l.Description='HiHiyong multi-account manager'; $l.Save()}}catch{}; Start-Process -FilePath $env:AHK -ArgumentList ([char]34 + $env:APP + '\HIHIYONG_MultiAccount_Manager_v1.3.13.0_GameData.ahk' + [char]34) -WorkingDirectory $env:APP -Verb RunAs"
