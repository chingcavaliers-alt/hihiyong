# 冒險小隊打王控制（需要系統管理員權限，會跳出 UAC）
#   -Loop on|off  開關「打完自動接下一輪」（管理程式不用重開，下一輪結束時生效）
#   -Restart      重開管理程式並自動接續打王（只重開管理程式，不關遊戲）
param([ValidateSet('on','off','')][string]$Loop = '', [switch]$Restart)
$ErrorActionPreference = 'Stop'
$app = & (Join-Path $PSScriptRoot 'find_app.ps1')
if (-not $app) { throw '找不到管理程式資料夾' }
$ahk = Join-Path $app 'runtime\AutoHotkey64.exe'
$ini = Join-Path $app 'HIHIYONG_AutoRecovery.ini'
$main = Join-Path $app 'HIHIYONG_MultiAccount_Manager_v1.3.13.0_GameData.ahk'
$tmp = Join-Path $env:TEMP 'hihi_raid_ctl.ahk'
$out = Join-Path $env:TEMP 'hihi_raid_ctl_out.txt'

function Run-Ini([string]$key, [string]$val) {
    # 設定檔是 UTF-16，用 AutoHotkey 的 IniWrite 寫（管理程式以系統管理員執行，寫入也要用系統管理員）
    $code = "try IniWrite `"$val`", `"$ini`", `"BossRaid`", `"$key`"`nFileAppend IniRead(`"$ini`", `"BossRaid`", `"$key`", `"?`"), `"$out`"`nExitApp`n"
    [IO.File]::WriteAllText($tmp, $code, (New-Object Text.UTF8Encoding $true))
    Remove-Item $out -ErrorAction SilentlyContinue
    Start-Process $ahk -ArgumentList "`"$tmp`"" -Verb RunAs -Wait
    "$key=" + (Get-Content $out -ErrorAction SilentlyContinue)
}

if ($Loop -ne '') { Run-Ini 'Loop' ($(if ($Loop -eq 'on') { '1' } else { '0' })) }
if ($Restart) {
    Run-Ini 'ResumeOnStart' '1'
    Get-CimInstance Win32_Process -Filter "Name='AutoHotkey64.exe'" |
        Where-Object { $_.CommandLine -like '*HIHIYONG_MultiAccount_Manager*' } |
        ForEach-Object { "stop $($_.ProcessId)"; Stop-Process -Id $_.ProcessId -Force }
    Start-Sleep 2
    Start-Process $ahk -ArgumentList "`"$main`"" -WorkingDirectory $app -Verb RunAs
    "started " + (Get-Date -Format T) + "（約 40 秒後自動接續打王）"
}
