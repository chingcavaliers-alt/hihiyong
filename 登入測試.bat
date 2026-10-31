@echo off
chcp 65001 >nul
rem 登入測試工具：先用最新的遊戲位置資料工具解析 game.exe，再開啟測試視窗（會跳出系統管理員權限詢問）。
set "HERE=%~dp0"
set "OFFS=%TEMP%\hihiyong_login_test_offsets.ini"
echo 解析遊戲位置資料（約 20 秒）...
py -3 "%HERE%tools\resolve_game_offsets.py" --exe "D:\HiHiYong2.0\Game.exe" --out "%OFFS%" >nul
if errorlevel 1 (
  echo 解析失敗：請確認 D:\HiHiYong2.0\Game.exe 與 Game.pdb 在同一個資料夾，且電腦有安裝 Python。
  pause
  exit /b 1
)
set "AHK=D:\Program Files\AutoHotkey\v2\AutoHotkey64.exe"
if not exist "%AHK%" set "AHK=%HERE%..\Release\HIHIYONG\app\runtime\AutoHotkey64.exe"
start "" "%AHK%" "%HERE%tools\login_test.ahk" "%OFFS%"