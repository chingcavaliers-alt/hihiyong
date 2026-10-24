; ============================================================================
; H-017 M 箱自動開啟：每個角色自己決定要不要開（工具 → 🎁 M 箱）。
; 遊戲不接受背景按鍵（2026-10-25 實測三種方式都無效），所以一定要把該角色的視窗切到前面按鍵；
; 為了少打擾：只在「該開了」的時候切過去，按完馬上切回原本在前面的視窗。
; - 每個角色各自計時：上次「確認開成功」後 IntervalSec 秒（預設 180 = 效果時間）才再開。
; - 確認方式：按鍵後背包裡的 M 箱數量少 1（讀記憶體）；沒少就 RetrySec 秒後再試，連續 3 次失敗通知。
; - 數量用完 / 快用完時通知（每個角色各一次，數量回升後重設）。
; - 重新登入、換每日道具、示範錄製、輪流切換視窗執行中時不動作。
; ============================================================================

global MBOX_ENABLED := Integer(IniRead(INI, "MBox", "Enabled", "0"))
global MBOX_INTERVAL_SEC := Max(30, Integer(IniRead(INI, "MBox", "IntervalSec", "180")))
global MBOX_ITEM := IniRead(INI, "MBox", "ItemName", "命運箱子")
; 鍵盤滑鼠要停這麼多秒才切視窗（使用者正在打字時切走，打的字會跑進遊戲）
global MBOX_IDLE_SEC := Max(0, Integer(IniRead(INI, "MBox", "IdleSec", "5")))
global MBOX_RETRY_SEC := 30, MBOX_LOW_COUNT := 10, MBOX_CONFIRM_MS := 3000
global mboxBusy := false
; 測試用：設成物件時，切換視窗 / 按鍵 / 切回都交給它（不動真正的視窗與鍵盤）。
global mboxTestDriver := 0
; 實體鍵鼠閒置毫秒數；測試可換成固定值
global mboxIdleMs := () => A_TimeIdlePhysical

MBoxOn(p) => p.HasOwnProp("mboxEnabled") && p.mboxEnabled
MBoxKeyOf(p) => p.HasOwnProp("mboxKey") && Trim(p.mboxKey) != "" ? Trim(p.mboxKey) : "e"

; 背包裡的 M 箱數量（名稱含 ItemName、不含「禮」＝不算還沒打開的禮盒）。
; 讀不到背包，或有道具讀不到名稱而一個都沒找到時回傳 -1（不能當成「用完了」）。
MBoxCount(pid) {
    global MBOX_ITEM
    slots := 0
    try slots := ReadGameInventorySlots(pid, "InvenOffset")
    if !IsObject(slots)
        return -1
    n := 0, unknown := false
    for s in slots {
        name := ""
        try name := GameItemName(s.key, pid)
        if name = ""
            unknown := true
        else if InStr(name, MBOX_ITEM) && !InStr(name, "禮")
            n += s.count
    }
    return n = 0 && unknown ? -1 : n
}

; 現在不能切視窗按鍵的原因（空字串 = 可以）。
MBoxBlocker() {
    global abortRequested, emergencyStop, processingQueue, activeRecoveryHwnd, foregroundOwner, dailyRunning, recorder
    global autoSwitchRunning, setupMode, invRunning, fastLoginCritical, asyncLoadingEntries, MBOX_IDLE_SEC, mboxIdleMs
    if abortRequested || emergencyStop
        return "自動化已停止"
    if processingQueue || activeRecoveryHwnd || fastLoginCritical
        return "重新登入中"
    try if asyncLoadingEntries.Count
        return "有角色正在載入"
    if dailyRunning != ""
        return "更換每日道具中"
    if invRunning
        return "背包清理中"
    if foregroundOwner != ""
        return "其他功能正在操作遊戲視窗"
    if IsObject(recorder)
        return "示範錄製中"
    if autoSwitchRunning
        return "「遊戲視窗自動切換」執行中（兩個一起用會互搶視窗，請先停止輪流切換）"
    if setupMode
        return "座標設定中"
    if mboxIdleMs() < MBOX_IDLE_SEC * 1000
        return "等你停止操作鍵盤滑鼠 " MBOX_IDLE_SEC " 秒"
    return ""
}

MBoxReady(p) {
    ; GameInWorld：真的在遊戲世界裡（選角畫面不算）；hpEventOpen：角色死亡中
    return p.enabled && MBoxOn(p) && p.pid && ProfileGameAlive(p) && p.state = "監控中"
        && GameOffsetsReady(p.pid) && GameInWorld(p.pid) && !(p.HasOwnProp("hpEventOpen") && p.hpEventOpen)
}

MBoxTick() {
    global profiles, MBOX_ENABLED, mboxBusy
    if !MBOX_ENABLED || mboxBusy || MBoxBlocker() != ""
        return
    now := A_TickCount, pick := 0, pickAt := 0
    for i, p in profiles {
        if !MBoxReady(p)
            continue
        at := p.HasOwnProp("mboxNextAt") ? p.mboxNextAt : 0
        if at <= now && (!pick || at < pickAt)
            pick := i, pickAt := at
    }
    if pick
        MBoxOpen(pick)
}

MBoxOpen(idx) {
    global profiles, mboxBusy, foregroundOwner, abortRequested, MBOX_INTERVAL_SEC, MBOX_RETRY_SEC, MBOX_LOW_COUNT, MBOX_CONFIRM_MS
    p := profiles[idx]
    mboxBusy := true, foregroundOwner := "mbox"
    prev := 0
    try {
        before := MBoxCount(p.pid)
        if before < 0 {
            ; 讀不到數量就不按（無法確認，也無法避免浪費）
            p.mboxNextAt := A_TickCount + MBOX_RETRY_SEC * 1000
            p.mboxStatus := "讀不到 M 箱數量，暫不開啟（" MBOX_RETRY_SEC " 秒後再看）"
            return
        }
        if before = 0 {
            p.mboxNextAt := A_TickCount + 600000, p.mboxStatus := "背包裡沒有 M 箱（10 分鐘後再看）"
            if !(p.HasOwnProp("mboxEmptyNotified") && p.mboxEmptyNotified) {
                p.mboxEmptyNotified := 1
                EventLog(p.name, "MBOX_EMPTY", "背包裡沒有 M 箱")
                AddRecentEvent("⚠ " p.name " 的 M 箱用完了")
                try SendDiscordMessage("⚠️ HIHIYONG：" p.name " 的 M 箱用完了")
            }
            return
        }
        p.mboxEmptyNotified := 0
        if before > MBOX_LOW_COUNT
            p.mboxLowNotified := 0
        prev := MBoxForeground()
        ; 先切到前面（等待期間 F10 仍可中止）；「確認真的是它在前面＋按鍵」這一小段不讓其他計時器插進來
        sent := false
        if MBoxActivate(p) {
            Critical "On"
            if !abortRequested && MBoxIsActive(p) {
                MBoxSend(MBoxKeyOf(p))
                sent := true
            }
            Critical "Off"
        }
        ; 數量是讀記憶體，不需要遊戲在前景：按完馬上切回原本的視窗
        if prev && prev != p.hwnd
            MBoxRestore(prev)
        prev := 0
        if !sent {
            MBoxFail(p, "無法把視窗切到前面")
            return
        }
        ok := false, after := -1, start := A_TickCount
        while A_TickCount - start < MBOX_CONFIRM_MS {
            Sleep 150
            after := MBoxCount(p.pid)
            if after >= 0 && after < before {
                ok := true
                break
            }
        }
        if !ok {
            MBoxFail(p, "按 " MBoxKeyOf(p) " 後 M 箱數量沒有減少")
            return
        }
        p.mboxNextAt := A_TickCount + MBOX_INTERVAL_SEC * 1000, p.mboxFails := 0, p.mboxCount := after
        p.mboxStatus := "✓ " FormatTime(, "HH:mm:ss") " 開啟｜剩 " after " 個"
        EventLog(p.name, "MBOX_OPEN", "開啟 M 箱｜剩 " after " 個")
        if after <= MBOX_LOW_COUNT && !(p.HasOwnProp("mboxLowNotified") && p.mboxLowNotified) {
            p.mboxLowNotified := 1
            AddRecentEvent("⚠ " p.name " 的 M 箱只剩 " after " 個")
            try SendDiscordMessage("⚠️ HIHIYONG：" p.name " 的 M 箱只剩 " after " 個")
        }
    } catch as e {
        Critical "Off"
        MBoxFail(p, e.Message)
    } finally {
        if prev && prev != p.hwnd
            try MBoxRestore(prev)
        foregroundOwner := "", mboxBusy := false
    }
}

MBoxFail(p, why) {
    global MBOX_RETRY_SEC
    p.mboxFails := (p.HasOwnProp("mboxFails") ? p.mboxFails : 0) + 1
    p.mboxNextAt := A_TickCount + MBOX_RETRY_SEC * 1000
    p.mboxStatus := "⚠ " why "（第 " p.mboxFails " 次，" MBOX_RETRY_SEC " 秒後再試）"
    if p.mboxFails = 3 {
        EventLog(p.name, "MBOX_FAIL", why "｜連續 3 次")
        AddRecentEvent("⚠ " p.name " 連續 3 次沒有開成功 M 箱：" why "（可能效果還在、快捷鍵不是 " MBoxKeyOf(p) "，或角色在讀圖）")
    }
}

; ---- 視窗 / 按鍵（測試時交給 mboxTestDriver）----
MBoxForeground() {
    global mboxTestDriver
    if IsObject(mboxTestDriver)
        return mboxTestDriver.Foreground()
    try return WinGetID("A")
    return 0
}
MBoxActivate(p) {
    global mboxTestDriver
    if IsObject(mboxTestDriver)
        return mboxTestDriver.Activate(p)
    if WinGetMinMax("ahk_id " p.hwnd) = -1
        WinRestore "ahk_id " p.hwnd
    WinActivate "ahk_id " p.hwnd
    if !WinWaitActive("ahk_id " p.hwnd, , 2)
        return false
    Sleep 120   ; 遊戲剛拿到焦點時第一個按鍵偶爾收不到
    return true
}
MBoxIsActive(p) {
    global mboxTestDriver
    if IsObject(mboxTestDriver)
        return mboxTestDriver.Foreground() = p.hwnd
    return WinActive("ahk_id " p.hwnd) != 0
}
MBoxSend(key) {
    global mboxTestDriver
    if IsObject(mboxTestDriver)
        return mboxTestDriver.Send(key)
    SendOneKey(key)
}
MBoxRestore(hwnd) {
    global mboxTestDriver
    if IsObject(mboxTestDriver)
        return mboxTestDriver.Restore(hwnd)
    if WinExist("ahk_id " hwnd)
        try WinActivate "ahk_id " hwnd
}

; ---- 設定 / 網頁 ----
MBoxSetGlobal(rawValue) {
    global INI, MBOX_ENABLED, MBOX_INTERVAL_SEC
    parts := StrSplit(rawValue, "~")
    if parts.Length < 2 || !IsInteger(parts[1]) || !IsInteger(parts[2])
        return
    MBOX_ENABLED := Integer(parts[1]) ? 1 : 0
    MBOX_INTERVAL_SEC := Max(30, Min(3600, Integer(parts[2])))
    IniWrite MBOX_ENABLED, INI, "MBox", "Enabled"
    IniWrite MBOX_INTERVAL_SEC, INI, "MBox", "IntervalSec"
    AddRecentEvent("M 箱自動開啟：" (MBOX_ENABLED ? "開啟" : "關閉") "｜每 " MBOX_INTERVAL_SEC " 秒")
}

; 「編號~開/關~按鍵~角色名稱」（名稱在最後，可含 ~）
MBoxSetRole(rawValue) {
    global profiles
    parts := StrSplit(rawValue, "~")
    if parts.Length < 4 || !IsInteger(parts[1])
        return
    idx := Integer(parts[1])
    if idx < 1 || idx > profiles.Length
        return
    name := parts[4]
    Loop parts.Length - 4
        name .= "~" parts[4 + A_Index]
    p := profiles[idx]
    if name != p.name
        return AddRecentEvent("⚠ M 箱設定沒有儲存：角色清單已變動，請重新整理畫面")
    key := Trim(parts[3])
    p.mboxEnabled := Integer(parts[2] = "1")
    p.mboxKey := RegExMatch(key, "i)^([a-z0-9]|F([1-9]|1[0-2]))$") ? key : "e"
    p.mboxNextAt := 0, p.mboxFails := 0
    SaveProfiles()
    AddRecentEvent(p.name " → M 箱自動開啟 " (p.mboxEnabled ? "ON（按 " p.mboxKey "）" : "OFF"))
}

MBoxPushWeb() {
    global webReady, WVCore, profiles, MBOX_ENABLED, MBOX_INTERVAL_SEC
    if !webReady || !WVCore
        return
    roles := "", now := A_TickCount
    for i, p in profiles {
        if !p.enabled
            continue
        nextIn := MBoxOn(p) && p.HasOwnProp("mboxNextAt") && p.mboxNextAt > now ? Ceil((p.mboxNextAt - now) / 1000) : 0
        roles .= (roles = "" ? "" : ",") '{"index":' i ',"name":"' JsonEscapeWeb(p.name) '","alive":' (p.pid && ProfileGameAlive(p) ? "true" : "false")
            . ',"on":' (MBoxOn(p) ? "true" : "false") ',"key":"' JsonEscapeWeb(MBoxKeyOf(p)) '","nextIn":' nextIn
            . ',"count":' (p.HasOwnProp("mboxCount") ? p.mboxCount : -1) ',"status":"' JsonEscapeWeb(p.HasOwnProp("mboxStatus") ? p.mboxStatus : "") '"}'
    }
    try WVCore.PostWebMessageAsJson('{"type":"mbox","data":{"enabled":' (MBOX_ENABLED ? "true" : "false") ',"interval":' MBOX_INTERVAL_SEC
        . ',"blocker":"' JsonEscapeWeb(MBoxBlocker()) '","roles":[' roles ']}}')
}
