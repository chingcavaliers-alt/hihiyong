# 印出管理程式的資料夾。依序：環境變數 HIHI_APP → 正在執行的管理程式 → 常見安裝位置裡「今天日誌最新」的那一份。
# （管理程式以系統管理員執行時，一般權限讀不到它的命令列，所以要有後面的找法）
if ($env:HIHI_APP -and (Test-Path $env:HIHI_APP)) { $env:HIHI_APP; exit 0 }

$p = Get-CimInstance Win32_Process -Filter "Name='AutoHotkey64.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*HIHIYONG_MultiAccount_Manager*' } | Select-Object -First 1
if ($p) {
    $m = [regex]::Match($p.CommandLine, '"([^"]*HIHIYONG_MultiAccount_Manager[^"]*\.ahk)"')
    if ($m.Success) { Split-Path $m.Groups[1].Value -Parent; exit 0 }
}

$roots = @()
foreach ($d in Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue) {
    $roots += Join-Path $d.Root 'HIHIYONG'
}
$roots += [Environment]::GetFolderPath('Desktop')
if ($env:OneDrive) { $roots += Join-Path $env:OneDrive 'Desktop' }
$cands = @()
foreach ($r in $roots | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique) {
    $cands += Get-ChildItem $r -Filter 'HIHIYONG_MultiAccount_Manager*.ahk' -Recurse -Depth 4 -File -ErrorAction SilentlyContinue
}
$best = $null; $bestTime = [datetime]::MinValue
foreach ($c in $cands) {
    $logs = Join-Path $c.DirectoryName 'Logs'
    if (-not (Test-Path $logs)) { continue }
    $last = Get-ChildItem $logs -Filter 'HIHIYONG_*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($last -and $last.LastWriteTime -gt $bestTime) { $best = $c.DirectoryName; $bestTime = $last.LastWriteTime }
}
if ($best) { $best; exit 0 }
Write-Error "找不到管理程式（請先開管理程式，或設定環境變數 HIHI_APP=管理程式所在資料夾）"
exit 1
