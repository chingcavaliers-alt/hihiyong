; H-009 前景視窗變化記錄：前景變成「非遊戲、非管理程式」的視窗時只寫日誌 FOCUS_CHANGE，不做任何動作。
; 純邏輯（過濾 / 去重 / 截斷 / 格式 / 重新登入前 60 秒附註）；取得前景視窗資訊的 Win32 部分在最下面，
; 單元測試只測純邏輯，不碰真實視窗。

; 標題截斷（預設 60 字）；換行與多餘空白壓成單一空格，超過加「…」。
Focus_Truncate(title, maxLen := 60) {
    t := Trim(RegExReplace(title, "\s+", " "))
    if (StrLen(t) > maxLen)
        return SubStr(t, 1, maxLen) "…"
    return t
}

; 這個前景視窗要不要記：排除沒有視窗 / 程序、管理程式自己、遊戲程序（gameNames 為小寫程序名陣列）。
Focus_ShouldLog(hwnd, procName, pid, ownPid, gameNames) {
    if (!hwnd || !pid || procName = "")
        return false
    if (pid = ownPid)
        return false
    low := StrLower(procName)
    for n in gameNames {
        if (low = StrLower(n))
            return false
    }
    return true
}

; 去重：同一視窗（key）windowMs 內不重複記。seen 是 Map(key → 上次記錄的 tick)。
; 回傳 true 表示該記，並更新時間；順便清掉過期項目避免無限成長。
Focus_ShouldEmit(seen, key, nowTick, windowMs := 5000) {
    if seen.Has(key) && (nowTick - seen[key] >= 0) && (nowTick - seen[key] < windowMs)
        return false
    if (seen.Count > 200) {
        stale := []
        for k, t in seen {
            if (nowTick - t >= windowMs || nowTick < t)
                stale.Push(k)
        }
        for k in stale
            seen.Delete(k)
    }
    seen[key] := nowTick
    return true
}

; 日誌內容（時間由 EventLog 自帶；這裡含程序、PID、標題、父程序）。
Focus_FormatMessage(procName, pid, title, parentName) {
    return "程序=" procName "｜PID=" pid "｜標題=" Focus_Truncate(title) "｜父程序=" (parentName = "" ? "?" : parentName)
}

; 記錄最近事件（stamp 為 yyyyMMddHHmmss）；只保留最近 keep 筆。
Focus_Remember(recent, stamp, procName, title, keep := 20) {
    recent.Push({ stamp: stamp, proc: procName, title: Focus_Truncate(title, 30) })
    while (recent.Length > keep)
        recent.RemoveAt(1)
}

; 重新登入前 withinSec 秒內若有 FOCUS_CHANGE，回傳附註文字，否則回傳空字串（用最近的一筆）。
Focus_RecentNote(recent, nowStamp, withinSec := 60) {
    i := recent.Length
    while (i >= 1) {
        e := recent[i]
        d := DateDiff(nowStamp, e.stamp, "Seconds")
        if (d >= 0 && d <= withinSec)
            return "｜前 " d " 秒前景視窗被切到 " e.proc "「" e.title "」(FOCUS_CHANGE)"
        i--
    }
    return ""
}

; ---- 以下是 Win32 取得資訊（主程式呼叫；單元測試不使用）----

; 回傳 {hwnd, pid, proc, title, parent}；沒有前景視窗回傳 ""。
Focus_Query() {
    try {
        hwnd := WinExist("A")
        if !hwnd
            return ""
        pid := WinGetPID("ahk_id " hwnd)
        return { hwnd: hwnd, pid: pid, proc: ProcessGetName(pid), title: WinGetTitle("ahk_id " hwnd), parent: Focus_ParentName(pid) }
    }
    return ""
}

Focus_ParentName(pid) {
    ppid := 0
    snap := DllCall("CreateToolhelp32Snapshot", "UInt", 2, "UInt", 0, "Ptr")
    if (snap = -1)
        return ""
    ents := Map()
    size := A_PtrSize = 8 ? 568 : 556  ; PROCESSENTRY32W
    pe := Buffer(size, 0)
    NumPut("UInt", size, pe, 0)
    ok := DllCall("Process32FirstW", "Ptr", snap, "Ptr", pe)
    while ok {
        id := NumGet(pe, 8, "UInt")
        par := NumGet(pe, A_PtrSize = 8 ? 32 : 24, "UInt")
        ents[id] := [par, StrGet(pe.Ptr + (A_PtrSize = 8 ? 44 : 36), "UTF-16")]
        ok := DllCall("Process32NextW", "Ptr", snap, "Ptr", pe)
    }
    DllCall("CloseHandle", "Ptr", snap)
    if ents.Has(pid) {
        ppid := ents[pid][1]
        if ents.Has(ppid)
            return ents[ppid][2]
    }
    return ""
}
