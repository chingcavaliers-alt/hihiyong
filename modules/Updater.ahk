; ============================================================================
; H-016 從 GitHub 更新：其他電腦啟動後 / 每 6 小時檢查有沒有新版，有就跳提醒，使用者按了才更新。
; 來源：公開倉庫（INI [Update] Repo，預設 chingcavaliers-alt/hihiyong）的 version.json 與版本標籤的 zip。
; 更新只換程式檔；帳號密碼、Discord、統計、日誌、遊戲偏移設定、內建執行環境都不動。
; 安全：下載後先驗證發佈者的數位簽章（每個檔案的 SHA256）、版本號、主程式語法，只換內容不同的檔案（先備份到
; app\backup\），失敗就還原；裝好後等目前的工作做完才 Reload。
; 正在重新登入 / 換每日道具 / 載入中時不更新。
; ============================================================================

global UPDATE_REPO := IniRead(INI, "Update", "Repo", "chingcavaliers-alt/hihiyong")
global UPDATE_CHECK_MS := 6 * 3600000
global UPDATE_MAIN := "HIHIYONG_MultiAccount_Manager_v1.3.13.0_GameData.ahk"
; 不覆蓋、不刪除的（每台電腦自己的資料）
global UPDATE_KEEP_DIRS := ["Logs", "Stats", "WebView2UserData", "NetworkWatch", "ServerDisconnectEvidence", "runtime", "backup"]
global UPDATE_KEEP_FILES := ["HIHIYONG_AutoRecovery.ini", "HIHIYONG_Recovery_Profiles.ini", "HIHIYONG_GameOffsets.ini"
    , "HIHIYONG_Recovery_Events.log", "HiHiyong.ico"]
global updateInfo := 0, updateReq := 0, updateReqStart := 0, updateStatus := "", updateManual := false, updateRunning := false
; 發佈者的公鑰（私鑰只在穩定版電腦 D:\HIHIYONG\publish_key，不在任何倉庫裡）。下載的新版必須用它驗證簽章才會安裝。
global UPDATE_PUBKEY := '<RSAKeyValue><Modulus>xG3ugNaSp46Lx0o3wwOqjwwB5QfWwmpwC7cc8EhPVS/GMCkZKiZXr978FIoavUAPOb0kY2MzLckxN6eRDALdgy2qPIJmhHPNmf01GIH+w7njptEdVhxG64I7psQqTw9WA8+j3zHKYwBanKOvlDlAxEqsMiYD6AawZdYoRgK5s1zqeOY0MwIT2ZCQQWoVexvy/36sE5qtjoLERZ3kGuYqqdjVkEJwChswI0cSOLqgeGRkNO6XvLYI+W0Sus36dNwqGfHc1gD4v4q9ke+ET6jMkqK/0eMYMqL7+eyWDay7okAi/5dIRgJfAChqr6+/kN09n2JrOoaiCftBo0XmwQPA1UecYubCamwTA0e5vPdwrmnaApNHUHzdF+zk7HSAK17l8zb4Wwz+3//zqJw+UBm6j/wLHtgWtul1qeCyOCMpLL2h/PMBHvmu8t4w41gvcpXAPvuBp8FpkEr+IcKtb2UvxyJ3k5OLM7vYbjMgDcwvUlYFvX3z0b/GsKSCTLxAfEON</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>'

; "v1.3.24.0" 與 "v1.3.23.0" 比較：a 比 b 新回傳 true。
UpdateNewer(a, b) {
    pa := StrSplit(RegExReplace(a, "^[vV]"), "."), pb := StrSplit(RegExReplace(b, "^[vV]"), ".")
    Loop Max(pa.Length, pb.Length) {
        x := A_Index <= pa.Length && IsInteger(pa[A_Index]) ? Integer(pa[A_Index]) : 0
        y := A_Index <= pb.Length && IsInteger(pb[A_Index]) ? Integer(pb[A_Index]) : 0
        if x != y
            return x > y
    }
    return false
}

; version.json → {version, date, notes}；格式不對回傳 0。
UpdateParseInfo(text) {
    if !RegExMatch(text, '"version"\s*:\s*"(v\d+(?:\.\d+){1,3})"', &v)
        return 0
    date := RegExMatch(text, '"date"\s*:\s*"([^"]*)"', &d) ? d[1] : ""
    notes := []
    if RegExMatch(text, 's)"notes"\s*:\s*\[(.*?)\]', &n) {
        pos := 1
        while pos := RegExMatch(n[1], '"((?:[^"\\]|\\.)*)"', &s, pos) {
            notes.Push(UpdateUnescape(s[1]))
            pos += StrLen(s[0])
        }
    }
    return {version: v[1], date: date, notes: notes}
}

; JSON 字串跳脫：\" \\ \n \uXXXX
UpdateUnescape(s) {
    out := "", i := 1
    while i <= StrLen(s) {
        c := SubStr(s, i, 1)
        if c != "\" || i = StrLen(s) {
            out .= c, i += 1
            continue
        }
        n := SubStr(s, i + 1, 1)
        if n = "u" && RegExMatch(SubStr(s, i + 2, 4), "^[0-9A-Fa-f]{4}$")
            out .= Chr(Integer("0x" SubStr(s, i + 2, 4))), i += 6
        else
            out .= n = "n" ? "`n" : n = "t" ? "`t" : n, i += 2
    }
    return out
}

UpdateCheckTick() => UpdateCheck(false)

; 非同步下載 version.json（不卡住管理程式）。
UpdateCheck(manual := false) {
    global updateReq, updateReqStart, updateStatus, updateManual, UPDATE_REPO
    if IsObject(updateReq)
        return
    updateManual := manual
    try {
        updateReq := ComObject("WinHttp.WinHttpRequest.5.1")
        updateReq.Open("GET", "https://raw.githubusercontent.com/" UPDATE_REPO "/main/version.json?t=" A_TickCount, true)
        updateReq.SetRequestHeader("Cache-Control", "no-cache")
        updateReq.Send()
        updateReqStart := A_TickCount
        updateStatus := "檢查更新中…"
        SetTimer UpdateCheckPoll, 300
    } catch as e {
        updateReq := 0
        updateStatus := "無法檢查更新：" e.Message
    }
    UpdatePushWeb()
}

UpdateCheckPoll() {
    global updateReq, updateReqStart, updateInfo, updateStatus, updateManual, APP_VERSION
    done := false
    try done := updateReq.WaitForResponse(0)
    if !done && A_TickCount - updateReqStart < 20000
        return
    SetTimer UpdateCheckPoll, 0
    text := "", code := 0
    try code := updateReq.Status, text := updateReq.ResponseText
    updateReq := 0
    info := code = 200 ? UpdateParseInfo(text) : 0
    if !info {
        updateStatus := code ? "檢查更新失敗（GitHub 回應 " code "）" : "檢查更新失敗（連不到 GitHub）"
    } else if UpdateNewer(info.version, APP_VERSION) {
        isNew := !IsObject(updateInfo) || updateInfo.version != info.version
        updateInfo := info
        updateStatus := ""
        if isNew {
            EventLog("GLOBAL", "UPDATE_AVAILABLE", "有新版 " info.version "（目前 " APP_VERSION "）")
            AddRecentEvent("🆕 有新版 " info.version "：按畫面上方的「有新版」查看並更新")
        }
    } else {
        updateInfo := 0
        updateStatus := updateManual ? "✓ 已是最新版（" APP_VERSION "）" : ""
    }
    UpdatePushWeb()
}

; 目前不能更新的原因（空字串 = 可以）。
UpdateBlocker() {
    global dailyRunning, foregroundOwner, processingQueue, asyncLoadingEntries, activeRecoveryHwnd
    if dailyRunning != ""
        return "正在更換每日道具"
    if processingQueue || activeRecoveryHwnd
        return "正在重新登入"
    if foregroundOwner != ""
        return "正在操作遊戲視窗"
    try if asyncLoadingEntries.Count
        return "有角色正在載入"
    return ""
}

UpdateApply() {
    global updateInfo, updateStatus, updateRunning, foregroundOwner, UPDATE_REPO, APP_VERSION
    if !IsObject(updateInfo) || updateRunning
        return
    if (why := UpdateBlocker()) != "" {
        updateStatus := "目前" why "，請稍後再按更新"
        return UpdatePushWeb()
    }
    ver := updateInfo.version
    updateRunning := true, foregroundOwner := "update"   ; 每日道具、命運箱子等都會等它
    zip := UpdateWorkDir() "\" ver ".zip"
    try {
        updateStatus := "下載 " ver " 中…"
        UpdatePushWeb()
        try FileDelete zip
        Download "https://github.com/" UPDATE_REPO "/archive/refs/tags/" ver ".zip", zip
        r := UpdateInstall(zip, ver, A_ScriptDir, APP_VERSION)
        try FileDelete zip
        EventLog("GLOBAL", "UPDATE_DONE", APP_VERSION " → " ver "｜換了 " r.count " 個檔案｜備份：" r.backup)
        updateStatus := "✓ 已安裝 " ver "，等目前的工作結束後自動重新啟動…"
        AddRecentEvent("✓ 已安裝 " ver "（換了 " r.count " 個檔案，舊檔備份在 backup 資料夾），準備重新啟動")
        foregroundOwner := ""
        UpdatePushWeb()
        SetTimer UpdateReloadWhenIdle, 1000
    } catch as e {
        updateStatus := "更新失敗：" e.Message
        EventLog("GLOBAL", "UPDATE_FAIL", e.Message)
        AddRecentEvent("⚠ " updateStatus)
        updateRunning := false, foregroundOwner := ""
        UpdatePushWeb()
    }
}

; 新檔已就位：等重新登入 / 每日道具等做完才重新啟動（不會把它們從中間砍掉）。
UpdateReloadWhenIdle() {
    if UpdateBlocker() != ""
        return
    SetTimer UpdateReloadWhenIdle, 0
    Reload
}

; 暫存資料夾放在程式資料夾裡（不放 %TEMP%：同一使用者的一般程式不該有機會在下載與安裝之間換掉檔案）。
; 測試時 UpdateInstall 會把 updateWorkBase 指到測試用的程式資料夾。
global updateWorkBase := ""
UpdateWorkDir() {
    global updateWorkBase
    d := (updateWorkBase != "" ? updateWorkBase : A_ScriptDir) "\backup\_update"
    DirCreate d
    return d
}

; 安裝下載好的 zip 到 target，回傳 {backup, count}。測試可以直接呼叫（不需要網路）。
; 1. 解壓，必須剛好一個頂層資料夾
; 2. 驗證簽章：manifest.json（每個檔案的 SHA256）由發佈者的私鑰簽名（manifest.sig），用寫死的公鑰驗證；
;    每個檔案的 SHA256 都要和清單相符，且不能有清單以外的檔案 → 公開倉庫被別人改了也裝不進來
; 3. 主程式版本號相符、語法檢查通過
; 4. 只換「內容不同」的檔案（相同的略過，例如執行中被鎖住的 WebView2Loader.dll）；換之前先備份舊檔
; 5. 覆蓋：被鎖住的檔案先改名成 .old（下次啟動刪掉）再放新檔；途中失敗就用備份還原
UpdateInstall(zip, ver, target, current, pubKey := "") {
    global UPDATE_MAIN, UPDATE_PUBKEY, updateWorkBase
    updateWorkBase := target
    work := UpdateWorkDir() "\" ver
    try DirDelete work, true
    try {
        UpdateRun('powershell -NoProfile -Command "Expand-Archive -LiteralPath ' "'" zip "'" ' -DestinationPath ' "'" work "'" ' -Force"', "解壓縮失敗")
        dirs := []
        Loop Files work "\*", "DF"
            dirs.Push(A_LoopFileFullPath)
        if dirs.Length != 1 || !DirExist(dirs[1])
            throw Error("下載的檔案格式不對，目前的程式沒有被改動")
        root := dirs[1]
        if (err := UpdateVerify(root, pubKey != "" ? pubKey : UPDATE_PUBKEY, ver)) != ""
            throw Error("簽章驗證沒有通過（" err "），為了安全不安裝；目前的程式沒有被改動")
        if !FileExist(root "\" UPDATE_MAIN)
            throw Error("下載的檔案不完整（找不到主程式），目前的程式沒有被改動")
        if !RegExMatch(FileRead(root "\" UPDATE_MAIN, "UTF-8"), 'global APP_VERSION := "\Q' ver '\E"')
            throw Error("下載的主程式版本號不是 " ver "，目前的程式沒有被改動")
        if (err := UpdateValidate(root)) != ""
            throw Error("新版主程式語法檢查沒有通過（" err "），目前的程式沒有被改動")
        changed := UpdateChangedFiles(root, target)
        backup := target "\backup\" current "_" FormatTime(, "yyyyMMdd-HHmmss")
        for rel in changed
            if FileExist(target "\" rel) {
                SplitPath backup "\" rel, , &bdir
                DirCreate bdir
                FileCopy target "\" rel, backup "\" rel, 1
            }
        done := []
        try {
            for rel in changed {
                UpdatePut(root "\" rel, target "\" rel)
                done.Push(rel)
            }
        } catch as e {
            bad := ""
            for rel in done {
                try {
                    if FileExist(backup "\" rel)
                        UpdatePut(backup "\" rel, target "\" rel)
                    else
                        FileDelete target "\" rel
                } catch
                    bad .= (bad = "" ? "" : "、") rel
            }
            if bad != ""
                throw Error(e.Message "；而且還原時有檔案失敗（" bad "），請手動把 " backup " 裡的檔案複製回程式資料夾")
            throw Error(e.Message "，已用備份還原，目前的程式沒有被改動")
        }
    } finally {
        try DirDelete work, true
    }
    return {backup: backup, count: changed.Length}
}

UpdateRun(cmd, failText) {
    if RunWait(cmd, , "Hide") != 0
        throw Error(failText)
}

; 相對路徑是否屬於每台電腦自己的資料（任何一層資料夾名稱或檔名符合都算），或發佈用的檔案。
UpdateIsKept(rel) {
    global UPDATE_KEEP_DIRS, UPDATE_KEEP_FILES
    parts := StrSplit(rel, "\")
    Loop parts.Length - 1 {
        seg := parts[A_Index]
        for d in UPDATE_KEEP_DIRS
            if seg = d
                return true
        if seg = ".git" || seg = "__pycache__"
            return true
    }
    name := parts[parts.Length]
    for f in UPDATE_KEEP_FILES
        if name = f
            return true
    return name = "version.json" || name = "manifest.json" || name = "manifest.sig" || name = "__validate_tmp.ahk"
}

; 新版中和目前內容不同（或新增）的檔案（相對路徑）。
UpdateChangedFiles(root, target) {
    out := []
    Loop Files root "\*", "FR" {
        rel := SubStr(A_LoopFileFullPath, StrLen(root) + 2)
        if UpdateIsKept(rel)
            continue
        if !UpdateSameFile(A_LoopFileFullPath, target "\" rel)
            out.Push(rel)
    }
    return out
}

UpdateSameFile(a, b) {
    if !FileExist(b) || FileGetSize(a) != FileGetSize(b)
        return false
    fa := FileOpen(a, "r"), fb := FileOpen(b, "r")
    if !fa || !fb
        return false
    n := fa.Length, ba := Buffer(n), bb := Buffer(n)
    fa.RawRead(ba, n), fb.RawRead(bb, n)
    fa.Close(), fb.Close()
    return n = 0 || DllCall("msvcrt\memcmp", "Ptr", ba, "Ptr", bb, "UPtr", n, "Int") = 0
}

; 放一個檔案；目標被鎖住（執行中載入的 DLL 等）時先把舊檔改名成 .old 再放。
UpdatePut(src, dst) {
    SplitPath dst, , &dir
    DirCreate dir
    try {
        FileCopy src, dst, 1
    } catch {
        FileMove dst, dst ".old" A_TickCount, 1
        FileCopy src, dst, 1
    }
}

; 上次更新留下、當時被鎖住的舊檔（*.old<數字>）：重新啟動後就可以刪了。
UpdateCleanupOld() {
    Loop Files A_ScriptDir "\*.old*", "FR"
        if RegExMatch(A_LoopFileName, "\.old\d+$") && !UpdateIsKept(SubStr(A_LoopFileFullPath, StrLen(A_ScriptDir) + 2))
            try FileDelete A_LoopFileFullPath
}

; 驗證 manifest 簽章與每個檔案的 SHA256。通過回傳 ""，否則回傳原因。
UpdateVerify(root, pubKey, ver) {
    if !FileExist(root "\manifest.json") || !FileExist(root "\manifest.sig")
        return "缺少簽章檔"
    ps := UpdateWorkDir() "\verify.ps1"
    try FileDelete ps
    FileAppend "
    (
param([string]$root, [string]$key, [string]$ver, [string]$out)
$ErrorActionPreference = 'Stop'
function Done($code, $msg) { [IO.File]::WriteAllText($out, $msg); exit $code }
try {
  $root = (Get-Item -LiteralPath $root).FullName.TrimEnd([char]92)
  $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
  $rsa.FromXmlString($key)
  $m = [IO.File]::ReadAllBytes((Join-Path $root 'manifest.json'))
  $sig = [Convert]::FromBase64String(([IO.File]::ReadAllText((Join-Path $root 'manifest.sig'))).Trim())
  if (-not $rsa.VerifyData($m, 'SHA256', $sig)) { Done 3 'signature' }
  $j = [Text.Encoding]::UTF8.GetString($m) | ConvertFrom-Json
  if ($j.version -ne $ver) { Done 7 $j.version }
  $list = $j.files
  $want = @{}
  foreach ($f in $list) { $want[$f.path.ToLowerInvariant()] = $f.sha256.ToLowerInvariant() }
  $seen = 0
  foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -File -Force) {
    $rel = $f.FullName.Substring($root.Length + 1)
    if ($rel -in 'manifest.json', 'manifest.sig', 'version.json') { continue }
    $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($want[$rel.ToLowerInvariant()] -ne $h) { Done 4 $rel }
    $seen++
  }
  if ($seen -ne $want.Count) { Done 5 'missing' }
  Done 0 'ok'
} catch { Done 6 $_.Exception.Message }
    )", ps, "UTF-8"
    out := UpdateWorkDir() "\verify.txt"
    try FileDelete out
    ; 公鑰直接當參數傳（不寫成檔案，避免在驗證前被換掉）；RSA XML 裡沒有空白與引號
    rc := RunWait('powershell -NoProfile -ExecutionPolicy Bypass -File "' ps '" -root "' root '" -key "' pubKey '" -ver "' ver '" -out "' out '"', , "Hide")
    msg := ""
    try msg := Trim(FileRead(out, "UTF-8"))
    for f in [ps, out]
        try FileDelete f
    return rc = 0 ? "" : rc = 3 ? "簽章不符" : rc = 4 ? "檔案內容和簽章清單不符：" msg : rc = 5 ? "缺少清單中的檔案"
        : rc = 7 ? "簽章清單是 " msg " 的，不是 " ver : "無法驗證（" SubStr(msg, 1, 120) "）"
}

; 用目前的 AutoHotkey 對新版主程式做語法檢查（在 Persistent 前插入 ExitApp，不會真的執行）。回傳錯誤訊息，通過回傳 ""。
UpdateValidate(root) {
    global UPDATE_MAIN
    s := FileRead(root "\" UPDATE_MAIN, "UTF-8")
    p := RegExMatch(s, "m)^Persistent")
    if !p
        return "找不到 Persistent"
    tmp := root "\__validate_tmp.ahk"
    try FileDelete tmp
    FileAppend SubStr(s, 1, p - 1) "ExitApp`r`n" SubStr(s, p), tmp, "UTF-8"
    out := UpdateWorkDir() "\validate.txt"
    try FileDelete out
    rc := RunWait(A_ComSpec ' /c ""' A_AhkPath '" /ErrorStdOut=UTF-8 /Validate "' tmp '" > "' out '" 2>&1"', root, "Hide")
    msg := ""
    try msg := Trim(FileRead(out, "UTF-8"))
    try FileDelete tmp
    try FileDelete out
    return rc = 0 ? "" : (msg != "" ? SubStr(msg, 1, 200) : "錯誤碼 " rc)
}

UpdatePushWeb() {
    global webReady, WVCore, updateInfo, updateStatus, updateReq, APP_VERSION
    if !webReady || !WVCore
        return
    notes := ""
    if IsObject(updateInfo)
        for n in updateInfo.notes
            notes .= (notes = "" ? "" : ",") '"' JsonEscapeWeb(RegExReplace(n, "[\x00-\x1F]", " ")) '"'
    try WVCore.PostWebMessageAsJson('{"type":"update","data":{"current":"' APP_VERSION '"'
        . ',"available":' (IsObject(updateInfo) ? '{"version":"' updateInfo.version '","date":"' JsonEscapeWeb(updateInfo.date) '","notes":[' notes ']}' : "null")
        . ',"status":"' JsonEscapeWeb(updateStatus) '","checking":' (IsObject(updateReq) ? "true" : "false") ',"busy":"' JsonEscapeWeb(UpdateBlocker()) '"}}')
}
