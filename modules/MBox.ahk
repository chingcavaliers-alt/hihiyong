; ============================================================================
; H-017 命運箱子自動開啟：每個角色自己決定要不要開（工具 → 🎁 命運箱子）。
; 遊戲不接受背景按鍵（2026-10-25 實測三種方式都無效），所以一定要把該角色的視窗切到前面按鍵；
; 為了少打擾：只在「該開了」的時候切過去，按完馬上切回原本在前面的視窗。
; - 每個角色各自計時：上次「確認開成功」後 IntervalSec 秒（預設 180 = 效果時間）才再開。
; - 確認方式：按鍵後背包裡的命運箱子數量少 1（讀記憶體）；沒少就 RetrySec 秒後再試，連續 3 次失敗通知。
; - 數量用完 / 快用完時通知（每個角色各一次，數量回升後重設）。
; - 重新登入、換每日道具、示範錄製、輪流切換視窗執行中時不動作。
; H-019 防暴衝（2026-10-25 實際發生：按一次 E 卻一口氣用掉約 90 個箱子，一晚用掉 800 多個）：
;   遊戲在背景時畫面更新很慢，按完 E 馬上切走視窗，遊戲可能還沒收到「放開」就一直以為 E 還按著。
;   - 效果輔助判斷：讀角色身上的效果清單（右下角狀態圖示的資料）；效果還在作用就不按，並依剩餘時間安排下一次。
;     命運箱子效果的編號第一次成功開箱時自動學習（按前後效果清單多出來的那一個）。
;   - 按完先留在遊戲視窗 0.4 秒再切走；按完 0.6 / 1.5 / 2.8 秒再讀箱子數量，一次用掉超過 3 個 = 按鍵卡住。
;   - 卡住：切回去補送「放開」；再發生（或放開後還在掉）就自動停掉那個角色的命運箱子並通知 Discord。
;   - 兩次開啟之間每 10 秒檢查一次「沒按卻在掉箱子」，最多只會損失幾個。
;   - 按鍵一律轉小寫（大寫 E 會被送成 Shift+E），送鍵前先放開 Shift / Ctrl / Alt。
; ============================================================================

global MBOX_ENABLED := Integer(IniRead(INI, "MBox", "Enabled", "0"))
global MBOX_INTERVAL_SEC := Max(30, Integer(IniRead(INI, "MBox", "IntervalSec", "180")))
global MBOX_ITEM := IniRead(INI, "MBox", "ItemName", "命運箱子")
; 鍵盤滑鼠要停這麼多秒才切視窗（使用者正在打字時切走，打的字會跑進遊戲）
global MBOX_IDLE_SEC := Max(0, Integer(IniRead(INI, "MBox", "IdleSec", "5")))
global MBOX_RETRY_SEC := 30, MBOX_LOW_COUNT := 10, MBOX_CONFIRM_MS := 3000
; H-019
global MBOX_HOLD_MS := 400, MBOX_BURST_MAX := 3, MBOX_WATCH_SEC := 10, MBOX_REFRESH_MARGIN := 8, MBOX_STUCK_WINDOW_SEC := 1800
global MBOX_POST_MS := [600, 1500, 2800]
; 學到的命運箱子效果編號（"主-子"）與 age 的意思（remain = 剩餘秒數 / elapsed = 已過秒數；空 = 還不知道）
global MBOX_BUFF_CANDS := Map(), mboxLastOwn := 0, MBOX_OWN_MARGIN := 50
global MBOX_BUFF_ID := IniRead(INI, "MBox", "BuffId", "Q10"), MBOX_BUFF_MODE := IniRead(INI, "MBox", "BuffMode", "")   ; Q10 = 「問號道具」類效果 10（命運箱子，2026-10-25 實測：持續 180 秒、fTime 固定 180）
global mboxBusy := false
; 測試用：設成物件時，切換視窗 / 按鍵 / 切回都交給它（不動真正的視窗與鍵盤）。
global mboxTestDriver := 0
; 實體鍵鼠閒置毫秒數；測試可換成固定值
global mboxIdleMs := () => A_TimeIdlePhysical

MBoxOn(p) => p.HasOwnProp("mboxEnabled") && p.mboxEnabled
MBoxKeyOf(p) {
    k := p.HasOwnProp("mboxKey") && Trim(p.mboxKey) != "" ? Trim(p.mboxKey) : "e"
    return StrLen(k) = 1 ? StrLower(k) : k   ; 大寫字母會被送成 Shift+字母
}

; 背包裡的命運箱子數量（名稱含 ItemName、不含「禮」＝不算還沒打開的禮盒）。
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

; 效果清單：{read: 讀得到清單, ids: Map(編號 → age), active: 命運箱子效果在作用中, age: 該效果的 age}。
; 沒有位置資料 / 讀不到時 read = false（不能當成「效果不在」）。
MBoxBuff(pid) {
    global MBOX_BUFF_ID
    res := {read: false, ids: Map(), active: false, age: 0}
    list := ""
    try list := ReadGameSkillFacts(pid)
    if !IsObject(list)
        return res
    res.read := true
    for e in list
        res.ids[e.id] := e.age
    if MBOX_BUFF_ID != "" && res.ids.Has(MBOX_BUFF_ID)
        res.active := true, res.age := res.ids[MBOX_BUFF_ID]
    return res
}
; 效果還剩幾秒；不知道（還沒學到 age 的意思）回傳 -1。
MBoxRemainSec(b) {
    global MBOX_BUFF_MODE, MBOX_INTERVAL_SEC
    if MBOX_BUFF_MODE = "remain"
        return b.age
    if MBOX_BUFF_MODE = "elapsed"
        return Max(0, MBOX_INTERVAL_SEC - b.age)
    return -1
}
; 學效果編號：每次成功開箱，按前後效果清單「多出來」的編號當候選；要連續兩次開箱都出現的才算（避免誤學到
; 剛好同時冒出來的別的增益）。多個候選就取 age 最大的。想重學：刪掉 INI [MBox] 的 BuffId / BuffMode。
MBoxLearnBuff(p, before, after) {
    global MBOX_BUFF_ID, MBOX_BUFF_CANDS, INI
    if MBOX_BUFF_ID != "" || !before.read || !after.read
        return
    fresh := Map()
    for id, age in after.ids
        if !before.ids.Has(id)
            fresh[id] := age
    if !MBOX_BUFF_CANDS.Count {
        MBOX_BUFF_CANDS := fresh
        return
    }
    best := "", bestAge := -1
    for id, age in fresh
        if MBOX_BUFF_CANDS.Has(id) && age > bestAge
            best := id, bestAge := age
    MBOX_BUFF_CANDS := fresh
    if best = ""
        return
    MBOX_BUFF_ID := best
    try IniWrite best, INI, "MBox", "BuffId"
    EventLog(p.name, "MBOX_BUFF_LEARNED", "命運箱子效果編號 " best "（age " Round(bestAge, 1) "）")
    AddRecentEvent("🎁 學到命運箱子的效果編號：" best "（之後效果還在就不會重複按）")
}
; 兩次取樣的 age：變小 = 剩餘秒數，變大 = 已過秒數。
MBoxLearnMode(ages) {
    global MBOX_BUFF_MODE, INI
    if MBOX_BUFF_MODE != "" || ages.Length < 2
        return
    d := ages[ages.Length] - ages[1]
    if Abs(d) < 0.3
        return
    MBOX_BUFF_MODE := d < 0 ? "remain" : "elapsed"
    try IniWrite MBOX_BUFF_MODE, INI, "MBox", "BuffMode"
    EventLog("GLOBAL", "MBOX_BUFF_MODE", "效果 age 是" (MBOX_BUFF_MODE = "remain" ? "剩餘" : "已過") "時間")
}

; 現在不能切視窗按鍵的原因（空字串 = 可以）。
MBoxBlocker() {
    global abortRequested, emergencyStop, processingQueue, activeRecoveryHwnd, foregroundOwner, dailyRunning, recorder, mboxLastOwn, MBOX_OWN_MARGIN
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
    ; 閒置時間會被我們自己送出的按鍵 / 切視窗歸零（沒有裝輸入鉤子時分不出來），所以只有「我們最後一次動作之後」
    ; 又有輸入才算你在操作。
    idle := mboxIdleMs()
    if idle < MBOX_IDLE_SEC * 1000 && idle < A_TickCount - mboxLastOwn - MBOX_OWN_MARGIN
        return "等你停止操作鍵盤滑鼠 " MBOX_IDLE_SEC " 秒"
    return ""
}

; MBoxOpen / MBoxRecover 執行中自己占著 foregroundOwner；這裡暫時不算它，看有沒有「其他」原因不能切視窗。
MBoxBlockedForSwitch() {
    global foregroundOwner
    own := foregroundOwner
    foregroundOwner := ""
    try r := MBoxBlocker()
    catch
        r := "檢查失敗"
    foregroundOwner := own
    return r
}

MBoxReady(p) {
    ; GameInWorld：真的在遊戲世界裡（選角畫面不算）；hpEventOpen：角色死亡中
    return p.enabled && MBoxOn(p) && p.pid && ProfileGameAlive(p) && p.state = "監控中"
        && GameOffsetsReady(p.pid) && GameInWorld(p.pid) && !(p.HasOwnProp("hpEventOpen") && p.hpEventOpen)
}

MBoxTick() {
    global profiles, MBOX_ENABLED, mboxBusy
    if mboxBusy
        return
    if MBOX_ENABLED
        MBoxWatchTick()   ; 唯讀：偵測「沒按卻在掉箱子」（就算現在不能切視窗也要看，越早知道損失越少）
    if MBoxBlocker() != ""
        return
    ; 卡住的善後優先於一般開箱，而且不看命運箱子開關（使用者中途關掉也一定要把卡住的鍵放開）
    for i, p in profiles
        if p.HasOwnProp("mboxStuckPending") && p.mboxStuckPending && p.pid && ProfileGameAlive(p) && GameOffsetsReady(p.pid) {
            MBoxRecover(i)
            return
        }
    if !MBOX_ENABLED
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

; 兩次開啟之間，每 MBOX_WATCH_SEC 秒讀一次箱子數量：比「上次開啟後的數量」少了 2 個以上 = 我們沒按卻在掉
; （按鍵卡住，或有人在手動用）。只讀記憶體、不動視窗；標記後由 MBoxTick 切回去處理。
MBoxWatchTick() {
    global profiles, MBOX_WATCH_SEC
    now := A_TickCount
    for i, p in profiles {
        if !(MBoxOn(p) && MBoxReady(p) && p.HasOwnProp("mboxExpected") && p.mboxExpected >= 0)
            continue
        if p.HasOwnProp("mboxWatchAt") && now < p.mboxWatchAt
            continue
        p.mboxWatchAt := now + MBOX_WATCH_SEC * 1000
        c := MBoxCount(p.pid)
        if c < 0 || (p.HasOwnProp("mboxStuckPending") && p.mboxStuckPending)
            continue
        if c < p.mboxExpected - 1 {
            ; 要連續兩次都讀到偏少（而且沒回升）才算，避免背包剛好在變動時讀到不完整的數字
            seen := p.HasOwnProp("mboxDrainSeen") ? p.mboxDrainSeen : -1
            if seen < 0 || c > seen {
                p.mboxDrainSeen := c
                continue
            }
            p.mboxDrainSeen := -1
            p.mboxStuckPending := true, p.mboxStuckCount := c
            p.mboxStatus := "⚠ 沒有按卻少了 " p.mboxExpected - c " 個，處理中"
            EventLog(p.name, "MBOX_DRAIN", "沒按卻少了 " p.mboxExpected - c " 個（" p.mboxExpected " → " c "）")
            AddRecentEvent("⚠ " p.name " 沒有按命運箱子，數量卻在減少（" p.mboxExpected " → " c "），準備放開按鍵")
            try SendDiscordMessage("⚠️ HIHIYONG：" p.name " 沒有按命運箱子，箱子數量卻在減少（" p.mboxExpected " → " c "），正在補送按鍵放開。")
        } else
            p.mboxExpected := c, p.mboxDrainSeen := -1   ; 沒少（或變多）：以現在的數量為準
    }
}

MBoxOpen(idx) {
    global profiles, mboxBusy, foregroundOwner, abortRequested, MBOX_INTERVAL_SEC, MBOX_RETRY_SEC, MBOX_LOW_COUNT, MBOX_CONFIRM_MS
    global MBOX_HOLD_MS, MBOX_BURST_MAX, MBOX_REFRESH_MARGIN, MBOX_BUFF_ID
    p := profiles[idx]
    mboxBusy := true, foregroundOwner := "mbox"
    prev := 0
    try {
        before := MBoxCount(p.pid)
        if before < 0 {
            ; 讀不到數量就不按（無法確認，也無法避免浪費）
            p.mboxNextAt := A_TickCount + MBOX_RETRY_SEC * 1000
            p.mboxStatus := "讀不到命運箱子數量，暫不開啟（" MBOX_RETRY_SEC " 秒後再看）"
            return
        }
        if before = 0 {
            p.mboxNextAt := A_TickCount + 600000, p.mboxStatus := "背包裡沒有命運箱子（10 分鐘後再看）"
            if !(p.HasOwnProp("mboxEmptyNotified") && p.mboxEmptyNotified) {
                p.mboxEmptyNotified := 1
                EventLog(p.name, "MBOX_EMPTY", "背包裡沒有命運箱子")
                AddRecentEvent("⚠ " p.name " 的命運箱子用完了")
                try SendDiscordMessage("⚠️ HIHIYONG：" p.name " 的命運箱子用完了")
            }
            return
        }
        p.mboxEmptyNotified := 0
        if before > MBOX_LOW_COUNT
            p.mboxLowNotified := 0
        ; 輔助判斷：效果（右下角的狀態圖示）還在作用中就不按
        b0 := MBoxBuff(p.pid)
        if b0.active {
            remain := MBoxRemainSec(b0)
            wait := remain >= 0 ? Max(2, remain - MBOX_REFRESH_MARGIN) : 4   ; 剩餘時間不明（遊戲裡是固定的總長度）：效果一結束就補開
            p.mboxNextAt := A_TickCount + wait * 1000
            p.mboxStatus := "效果還在作用中" (remain >= 0 ? "（剩 " Round(remain) " 秒）" : "") "，不重複開（" Round(wait) " 秒後再看）"
            p.mboxExpected := before
            return
        }
        prev := MBoxForeground()
        ; 先切到前面（等待期間 F10 仍可中止）；「確認真的是它在前面＋按鍵」這一小段不讓其他計時器插進來
        sent := false, t0 := A_TickCount
        if MBoxActivate(p) {
            Critical "On"
            if !abortRequested && MBoxIsActive(p) {
                MBoxSend(MBoxKeyOf(p))
                sent := true, t0 := A_TickCount
            }
            Critical "Off"
            ; 先別切走：背景的遊戲畫面更新很慢，要讓它處理到「放開」
            if sent
                Sleep MBOX_HOLD_MS
        }
        if prev && prev != p.hwnd
            MBoxRestore(prev)
        prev := 0
        if !sent {
            MBoxFail(p, "無法把視窗切到前面")
            return
        }
        ; 確認：箱子數量減少（效果清單多了東西也算）；數量是讀記憶體，不需要遊戲在前景
        ok := false, after := -1, b1 := b0, start := A_TickCount
        while A_TickCount - start < MBOX_CONFIRM_MS {
            Sleep 150
            after := MBoxCount(p.pid)
            b1 := MBoxBuff(p.pid)
            countOk := after >= 0 && after < before
            buffOk := after < 0 && b1.read && (MBOX_BUFF_ID != "" ? b1.active : MBoxHasNewBuff(b0, b1))
            if countOk || buffOk {
                ok := true
                break
            }
        }
        if !ok {
            MBoxFail(p, "按 " MBoxKeyOf(p) " 後命運箱子數量沒有減少")
            return
        }
        ; 事後監看：按完幾秒內再讀幾次，用掉太多 = 按鍵卡住了
        w := MBoxWatchAfter(p, before, t0)
        MBoxLearnBuff(p, b0, w.buff.read ? w.buff : b1)   ; 效果可能比數量晚出現，用事後最後一次讀到的
        p.mboxExpected := w.last, p.mboxDrainSeen := -1
        if w.used > MBOX_BURST_MAX {
            ; 再讀一次確認（讀到不完整的數字不算）
            Sleep 300
            c := MBoxCount(p.pid)
            if c >= 0 && before - c > MBOX_BURST_MAX {
                w.last := c, w.used := before - c
                p.mboxExpected := c, p.mboxCount := c
                if MBoxBlockedForSwitch() {
                    ; 你正在操作 / 按了 F10：不搶視窗，交給 MBoxTick 等可以時再處理
                    p.mboxStuckPending := true, p.mboxStuckCount := c, p.mboxStuckFromPress := true
                    p.mboxStatus := "⚠ 按一次用掉 " w.used " 個，等可以切視窗時補送放開"
                    EventLog(p.name, "MBOX_STUCK", "按一次用掉 " w.used " 個，暫時不能切視窗，稍後處理")
                    try SendDiscordMessage("⚠️ HIHIYONG：" p.name " 按一次命運箱子用掉 " w.used " 個，稍後補送按鍵放開。")
                } else
                    MBoxStuck(p, w.used, "按一次用掉 " w.used " 個", c, true)
                return
            }
            if c < 0 {
                ; 確認時讀不到：不能當成沒事，排隊讓 MBoxRecover 重讀並放開
                p.mboxStuckPending := true, p.mboxStuckCount := w.last, p.mboxStuckFromPress := true
                p.mboxStatus := "⚠ 按一次似乎用掉 " w.used " 個，但確認時讀不到數量，稍後處理"
                EventLog(p.name, "MBOX_STUCK", "按一次似乎用掉 " w.used " 個，確認時讀不到數量，稍後處理")
                return
            }
            w.last := c
            w.used := Max(0, before - c)
            p.mboxExpected := c
        }
        p.mboxNextAt := A_TickCount + MBoxNextWaitSec(w.buff) * 1000, p.mboxFails := 0, p.mboxCount := w.last
        p.mboxStatus := "✓ " FormatTime(, "HH:mm:ss") " 開啟｜剩 " w.last " 個"
        EventLog(p.name, "MBOX_OPEN", "開啟命運箱子｜剩 " after " 個｜用掉 " w.used " 個｜事後剩 " w.last " 個")
        if w.last <= MBOX_LOW_COUNT && !(p.HasOwnProp("mboxLowNotified") && p.mboxLowNotified) {
            p.mboxLowNotified := 1
            AddRecentEvent("⚠ " p.name " 的命運箱子只剩 " w.last " 個")
            try SendDiscordMessage("⚠️ HIHIYONG：" p.name " 的命運箱子只剩 " w.last " 個")
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

; 沒學到效果編號時，只看「有沒有多出新的效果」。
MBoxHasNewBuff(b0, b1) {
    for id, age in b1.ids
        if !b0.ids.Has(id)
            return true
    return false
}

; 下一次開啟的等待秒數：讀得到剩餘時間就依它（剩餘 − 緩衝），不然用固定間隔。
MBoxNextWaitSec(b) {
    global MBOX_INTERVAL_SEC, MBOX_REFRESH_MARGIN
    if IsObject(b) && b.active {
        remain := MBoxRemainSec(b)
        if remain > 0
            return Max(30, remain - MBOX_REFRESH_MARGIN)
    }
    return MBOX_INTERVAL_SEC
}

; 按完後在 MBOX_POST_MS 的幾個時間點（距離按鍵）各讀一次數量與效果。回傳 {used: 最多用掉幾個, last: 最後讀到的數量}。
MBoxWatchAfter(p, before, t0) {
    global MBOX_POST_MS, MBOX_BURST_MAX, MBOX_BUFF_ID
    used := 0, last := before, ages := [], b := {read: false, ids: Map(), active: false, age: 0}
    for ms in MBOX_POST_MS {
        wait := ms - (A_TickCount - t0)
        if wait > 0
            Sleep wait
        c := MBoxCount(p.pid)
        if c >= 0 {
            last := c
            used := Max(used, before - c)
        }
        b := MBoxBuff(p.pid)
        if b.read && MBOX_BUFF_ID != "" && b.ids.Has(MBOX_BUFF_ID)
            ages.Push(b.ids[MBOX_BUFF_ID])
        if used > MBOX_BURST_MAX
            break
    }
    MBoxLearnMode(ages)
    return {used: used, last: last, buff: b}
}

; 兩次開啟之間偵測到「沒按卻在掉箱子」，切過去放開按鍵。
MBoxRecover(idx) {
    global profiles, mboxBusy, foregroundOwner
    p := profiles[idx]
    mboxBusy := true, foregroundOwner := "mbox"
    try {
        fromPress := p.HasOwnProp("mboxStuckFromPress") && p.mboxStuckFromPress
        c1 := MBoxCount(p.pid)   ; 被擋住一段時間後再處理：用現在的數量當基準
        if c1 < 0
            c1 := p.HasOwnProp("mboxStuckCount") ? p.mboxStuckCount : -1
        exp := p.HasOwnProp("mboxExpected") && p.mboxExpected >= 0 ? p.mboxExpected : c1
        MBoxStuck(p, Max(0, exp - c1), fromPress ? "按一次用掉太多個" : "沒按卻在掉箱子", c1, fromPress)
    } catch as e {
        Critical "Off"
        MBoxFail(p, e.Message)
    } finally {
        p.mboxStuckPending := false, p.mboxStuckFromPress := false
        foregroundOwner := "", mboxBusy := false
    }
}

; 按鍵卡住的處理：切回去補送「放開」→ 等 1.5 秒再讀數量。還在掉、或 30 分鐘內第二次（我們按的那種）→ 停掉這個角色的命運箱子。
MBoxStuck(p, used, why, c1, fromPress) {
    global MBOX_STUCK_WINDOW_SEC
    now := A_TickCount
    ; 按鍵造成的、與「沒按卻在掉」的各自計 30 分鐘內第二次（避免手動用箱子被算成按鍵的第二次）
    k := fromPress ? "mboxStuckAt" : "mboxDrainAt"
    again := p.HasOwnProp(k) && now - p.%k% < MBOX_STUCK_WINDOW_SEC * 1000
    p.%k% := now
    EventLog(p.name, "MBOX_STUCK", why "｜數量 " c1)
    AddRecentEvent("⚠ " p.name " 的命運箱子：" why "，補送按鍵放開")
    MBoxReleaseKeys(p)
    Sleep 1500
    c2 := MBoxCount(p.pid)
    still := c2 >= 0 && c1 >= 0 && c2 < c1 - 1
    if c2 >= 0
        p.mboxExpected := c2, p.mboxCount := c2
    if still || again {
        p.mboxEnabled := 0, p.mboxExpected := -1
        try SaveProfiles()
        p.mboxStatus := "⛔ 已停止：" why (still ? "，放開按鍵後還在掉" : "，30 分鐘內第二次")
        EventLog(p.name, "MBOX_DISABLED", p.mboxStatus)
        AddRecentEvent("⛔ " p.name " 的命運箱子已自動停止（" why "）")
        try SendDiscordMessage("⛔ HIHIYONG：" p.name " 的命運箱子已自動停止：" why (still ? "，放開按鍵後箱子還在減少" : "，30 分鐘內第二次") "。請到遊戲確認後再手動開啟。")
    } else {
        ; 下一次：效果還在就依剩餘時間，不然等一個完整間隔（不要 30 秒就又按）
        p.mboxNextAt := A_TickCount + MBoxNextWaitSec(MBoxBuff(p.pid)) * 1000
        p.mboxStatus := "⚠ " why "，已放開按鍵（箱子不再減少）"
        try SendDiscordMessage("⚠️ HIHIYONG：" p.name " 的命運箱子" why "，已補送按鍵放開，箱子沒有再減少。")
    }
}

MBoxFail(p, why) {
    global MBOX_RETRY_SEC
    p.mboxFails := (p.HasOwnProp("mboxFails") ? p.mboxFails : 0) + 1
    p.mboxNextAt := A_TickCount + MBOX_RETRY_SEC * 1000
    p.mboxStatus := "⚠ " why "（第 " p.mboxFails " 次，" MBOX_RETRY_SEC " 秒後再試）"
    if p.mboxFails = 3 {
        EventLog(p.name, "MBOX_FAIL", why "｜連續 3 次")
        AddRecentEvent("⚠ " p.name " 連續 3 次沒有開成功命運箱子：" why "（可能效果還在、快捷鍵不是 " MBoxKeyOf(p) "，或角色在讀圖）")
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
    global mboxTestDriver, mboxLastOwn
    if !IsObject(mboxTestDriver)
        mboxLastOwn := A_TickCount
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
    global mboxTestDriver, mboxLastOwn
    if !IsObject(mboxTestDriver)
        mboxLastOwn := A_TickCount
    if IsObject(mboxTestDriver)
        return mboxTestDriver.Send(key)
    Send "{Shift up}{Ctrl up}{Alt up}"   ; 沒有任何修飾鍵卡著（大寫字母 / 其他功能留下的）
    SendOneKey(key)
}
; 補送「放開」：按鍵卡住時用
MBoxSendUp(key) {
    global mboxTestDriver, mboxLastOwn
    if !IsObject(mboxTestDriver)
        mboxLastOwn := A_TickCount
    if IsObject(mboxTestDriver)
        return mboxTestDriver.Up(key)
    Send "{Shift up}{Ctrl up}{Alt up}{" key " up}"
}
; 切到這個角色的視窗補送「放開」，再切回原本的視窗。
MBoxReleaseKeys(p) {
    prev := MBoxForeground()
    ok := false
    try {
        if MBoxActivate(p) {
            Critical "On"
            try {
                if MBoxIsActive(p) {
                    MBoxSendUp(MBoxKeyOf(p))
                    ok := true
                }
            } finally
                Critical "Off"
            Sleep 300
        }
    } finally {
        if prev && prev != p.hwnd
            try MBoxRestore(prev)
    }
    return ok
}
MBoxRestore(hwnd) {
    global mboxTestDriver, mboxLastOwn
    if !IsObject(mboxTestDriver)
        mboxLastOwn := A_TickCount
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
    AddRecentEvent("命運箱子自動開啟：" (MBOX_ENABLED ? "開啟" : "關閉") "｜每 " MBOX_INTERVAL_SEC " 秒")
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
        return AddRecentEvent("⚠ 命運箱子設定沒有儲存：角色清單已變動，請重新整理畫面")
    key := Trim(parts[3])
    p.mboxEnabled := Integer(parts[2] = "1")
    p.mboxKey := RegExMatch(key, "i)^([a-z0-9]|F([1-9]|1[0-2]))$") ? (StrLen(key) = 1 ? StrLower(key) : key) : "e"
    p.mboxNextAt := 0, p.mboxFails := 0, p.mboxDrainSeen := -1   ; 等待中的「補送放開」不在這裡清掉（一定要送出去）
    for k in ["mboxStuckAt", "mboxDrainAt"]
        if p.HasOwnProp(k)
            p.DeleteProp(k)
    SaveProfiles()
    AddRecentEvent(p.name " → 命運箱子自動開啟 " (p.mboxEnabled ? "ON（按 " p.mboxKey "）" : "OFF"))
}

MBoxPushWeb() {
    global webReady, WVCore, profiles, MBOX_ENABLED, MBOX_INTERVAL_SEC, MBOX_BUFF_ID
    if !webReady || !WVCore
        return
    roles := "", now := A_TickCount
    for i, p in profiles {
        if !p.enabled
            continue
        nextIn := MBoxOn(p) && p.HasOwnProp("mboxNextAt") && p.mboxNextAt > now ? Ceil((p.mboxNextAt - now) / 1000) : 0
        buffText := ""
        if MBoxOn(p) && p.pid && ProfileGameAlive(p) {
            b := MBoxBuff(p.pid)
            if !b.read
                buffText := "效果：讀不到"
            else if MBOX_BUFF_ID = ""
                buffText := "效果：尚未學到編號"
            else if b.active {
                rs := MBoxRemainSec(b)
                buffText := "效果：作用中" (rs >= 0 ? "（剩 " Round(rs) " 秒）" : "")
            } else
                buffText := "效果：未作用"
        }
        roles .= (roles = "" ? "" : ",") '{"index":' i ',"name":"' JsonEscapeWeb(p.name) '","alive":' (p.pid && ProfileGameAlive(p) ? "true" : "false")
            . ',"on":' (MBoxOn(p) ? "true" : "false") ',"key":"' JsonEscapeWeb(MBoxKeyOf(p)) '","nextIn":' nextIn
            . ',"count":' (p.HasOwnProp("mboxCount") ? p.mboxCount : -1) ',"buff":"' JsonEscapeWeb(buffText) '","status":"' JsonEscapeWeb(p.HasOwnProp("mboxStatus") ? p.mboxStatus : "") '"}'
    }
    try WVCore.PostWebMessageAsJson('{"type":"mbox","data":{"enabled":' (MBOX_ENABLED ? "true" : "false") ',"interval":' MBOX_INTERVAL_SEC
        . ',"blocker":"' JsonEscapeWeb(MBoxBlocker()) '","roles":[' roles ']}}')
}
