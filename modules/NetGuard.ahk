; H-031：整體斷網守門（取代舊的「網路狀態」功能）
; 只做一件事：電腦自己整個斷網時，暫停「假在線／斷線視窗」自動重啟，避免多帳號被誤重啟。
; 不開 powershell / ping / netstat，也沒有畫面與設定；只用 Windows API 讀 TCP 表。
; 判定：遊戲沒有任何 ESTABLISHED 連線，且 Windows 回報離線，連續 2 次 → 斷網；連續 2 次恢復才解除。

global netGuardTestHook := ""   ; 單元測試用：{tcp:bool, winNet:bool}

; 任一個 pid 有 ESTABLISHED 的 IPv4 TCP 連線 → true
NetGuardAnyEstablished(pids) {
    size := 0
    DllCall("Iphlpapi\GetExtendedTcpTable", "Ptr", 0, "UIntP", &size, "Int", 0, "UInt", 2, "UInt", 5, "UInt", 0)
    if size <= 0
        return false
    buf := Buffer(size, 0)
    if DllCall("Iphlpapi\GetExtendedTcpTable", "Ptr", buf, "UIntP", &size, "Int", 0, "UInt", 2, "UInt", 5, "UInt", 0) != 0
        return false
    want := Map()
    for p in pids
        want[p + 0] := true
    n := NumGet(buf, 0, "UInt")
    Loop n {
        off := 4 + (A_Index - 1) * 24
        if NumGet(buf, off, "UInt") = 5 && want.Has(NumGet(buf, off + 20, "UInt"))
            return true
    }
    return false
}

NetGuardWindowsOnline() {
    flags := 0
    try return DllCall("Wininet\InternetGetConnectedState", "UIntP", &flags, "UInt", 0, "Int") != 0
    return true   ; 查不到就當作有網路（寧可不攔）
}

; 純判定：回傳 "down" / "up" / ""（沒有變化）。狀態存在 netOutageActive / netDownStreak / netUpStreak
NetGuardStep(tcp, winNet) {
    global netOutageActive, netDownStreak, netUpStreak
    if (!tcp && !winNet) {
        netDownStreak += 1, netUpStreak := 0
    } else {
        netUpStreak += 1, netDownStreak := 0
    }
    if !netOutageActive && netDownStreak >= 2 {
        netOutageActive := true
        return "down"
    }
    if netOutageActive && netUpStreak >= 2 {
        netOutageActive := false
        return "up"
    }
    return ""
}

NetGuardTick() {
    global fastLoginCritical, profiles, netGuardTestHook
    if fastLoginCritical
        return
    if IsObject(netGuardTestHook) {
        tcp := netGuardTestHook.tcp, win := netGuardTestHook.winNet
    } else {
        pids := []
        for p in profiles {
            if ProfileGameAlive(p)
                pids.Push(p.pid)
        }
        if pids.Length = 0
            return   ; 沒有遊戲視窗就沒東西可保護
        tcp := NetGuardAnyEstablished(pids), win := NetGuardWindowsOnline()
    }
    r := NetGuardStep(tcp, win)
    if r = "down" {
        EventLog("GLOBAL", "NETWORK_DOWN", "遊戲沒有任何連線且 Windows 網路離線（連續兩次）；暫停假在線/斷線視窗自動 Recovery")
        AddRecentEvent("🌐 電腦網路中斷｜暫停自動重啟")
        try SendDiscordMessage("🌐 HIHIYONG`n確認電腦整體網路中斷。`n已暫停假在線/斷線視窗自動 Recovery，避免多帳號誤重啟。")
        ResetSoftDisconnectRuntime()
    } else if r = "up" {
        EventLog("GLOBAL", "NETWORK_RECOVERED", "網路連續兩次恢復；重新啟用遊戲異常判定")
        AddRecentEvent("🌐 網路已恢復｜重新檢查遊戲狀態")
        try SendDiscordMessage("✅ HIHIYONG`n電腦網路已恢復。`n遊戲異常監控與自動 Recovery 已重新啟用。")
    }
}