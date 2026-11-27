# 印出管理程式的資料夾：先找正在執行的管理程式，找不到就用環境變數 HIHI_APP
$p = Get-CimInstance Win32_Process -Filter "Name='AutoHotkey64.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*HIHIYONG_MultiAccount_Manager*' } | Select-Object -First 1
if ($p) {
    $m = [regex]::Match($p.CommandLine, '"([^"]*HIHIYONG_MultiAccount_Manager[^"]*\.ahk)"')
    if ($m.Success) { Split-Path $m.Groups[1].Value -Parent; exit 0 }
}
if ($env:HIHI_APP -and (Test-Path $env:HIHI_APP)) { $env:HIHI_APP; exit 0 }
Write-Error "找不到管理程式（沒有在執行，也沒有設定 HIHI_APP）"
exit 1
