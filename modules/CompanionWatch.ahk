; ============================================================================
; CompanionWatch：寵物 / 雇傭兵 / 魔法娃娃監測。掛機中發現寵物、雇傭兵（召喚獸）或魔法娃娃不在外面，就按快捷欄那一格的鍵叫出來。
; 預設關閉（工具 → 🐾 寵物雇傭兵 勾選啟用）。
; 三種卡都是「開關」：在外面再按一次會收起來，所以只在「記憶體確認不在外面」時才按，而且：
;   - 連續確認不在外面 CW_CONFIRM_MS（換地圖、前點傳送時它們會暫時消失再出現）才算；
;   - 按之前再讀一次、切到前景後再讀一次，還是不在外面才按；
;   - 按完等 CW_VERIFY_MS 確認真的出現；兩分鐘內不重按同一種；失敗的休息時間越來越長（最長 30 分鐘）；
;   - 快捷欄找不到那張卡、不知道那一格是哪個鍵 → 不按（只記一次日誌）。
; 重新登入、換每日道具、背包清理、命運箱子、組隊、示範錄製、輪流切換、緊急停止、你正在操作電腦、死亡中、不在遊戲世界時都不動作。
; 沿用自動組隊的切換視窗 / 守門 / 收尾機制（ApActivate、ApGuardAny、ApCleanup）。
; ============================================================================

CwIniFlag(key, def) {
    global INI
    v := IniRead(INI, "Companion", key, def)
    return IsInteger(v) ? (Integer(v) ? 1 : 0) : def   ; 設定檔被改壞（不是數字）時用預設，不能讓整個程式起不來
}
global CW_ENABLED := CwIniFlag("Enabled", 0)
global CW_PET := CwIniFlag("Pet", 1)
global CW_MERC := CwIniFlag("Merc", 1)
global CW_DOLL := CwIniFlag("Doll", 1)
global CW_CHECK_MS := 5000, CW_CONFIRM_MS := 10000, CW_COOLDOWN_MS := 120000, CW_VERIFY_MS := 8000
global CW_BACKOFF_MAX_MS := 1800000, CW_NOCARD_MS := 1800000
global cwBusy := false

; kind："pet" / "merc" / "doll"
CwLabel(kind) => kind = "pet" ? "寵物" : (kind = "doll" ? "魔法娃娃" : "雇傭兵")
CwCard(kind) => kind = "pet" ? "寵物卡" : (kind = "doll" ? "魔法娃娃" : "雇傭兵")   ; 娃娃卡名稱是「魔法娃娃-霜刃劍士」這類，比對只用前面的字
CwOn(kind) {
    global CW_PET, CW_MERC, CW_DOLL
    return kind = "pet" ? CW_PET : (kind = "doll" ? CW_DOLL : CW_MERC)
}
; 1 = 在外面，0 = 不在，-1 = 讀不到
CwRead(p, kind) {
    try return kind = "pet" ? ReadGamePetOut(p.pid) : (kind = "doll" ? ReadGameMagicDollOut(p.pid) : ReadGameSummonOut(p.pid))
    return -1
}
CwState(p, kind) {
    if !p.HasOwnProp("cw")
        p.cw := Map()
    if !p.cw.Has(kind)
        p.cw[kind] := {since: 0, next: 0, fails: 0, text: "", noCardAt: 0, notified: false, map: 0}
    return p.cw[kind]
}
; 目前所在地圖（讀不到回傳 0）：確認「不在外面」的這段時間內換了地圖就重新確認（換圖時它們會暫時消失）
CwMap(p) {
    m := 0
    try m := ReadGameMapId(p.pid)
    return IsInteger(m) ? m : 0
}
; 寵物剛被別的功能（登入後補開）按過：兩邊共用同一個冷卻，不要一個按完、另一個接著又按
CwPetPressedRecently(p) {
    global CW_COOLDOWN_MS
    return p.HasOwnProp("petPressedPid") && p.petPressedPid = p.pid && p.HasOwnProp("petPressedAt") && A_TickCount - p.petPressedAt < CW_COOLDOWN_MS
}
CwReset(p, kind, text := "") {
    s := CwState(p, kind)
    s.since := 0
    s.text := text
}

CompanionTick() {
    global profiles, CW_ENABLED, CW_CONFIRM_MS, apBusy, cwBusy
    if !CW_ENABLED
        return
    if apBusy || cwBusy {
        ; 別的功能（例如組隊）正在動遊戲視窗：這段時間不算「連續確認」，等它做完重新計
        if !cwBusy
            for p in profiles
                for kind in ["pet", "merc", "doll"]
                    CwState(p, kind).since := 0
        return
    }
    why := ApBlockerRaw()
    if why != "" {
        for p in profiles
            for kind in ["pet", "merc", "doll"]
                if CwOn(kind)
                    CwReset(p, kind, "等待中：" why)
        return
    }
    now := A_TickCount
    todo := []
    for p in profiles {
        if !p.enabled
            continue
        for kind in ["pet", "merc", "doll"] {
            if !CwOn(kind) {
                CwReset(p, kind, "")
                continue
            }
            s := CwState(p, kind)
            if !ApReady(p) {
                CwReset(p, kind, "還沒進遊戲世界（或死亡中）")
                continue
            }
            st := CwRead(p, kind)
            if st < 0 {
                CwReset(p, kind, "讀不到狀態（這個遊戲版本沒有這項資料）")
                continue
            }
            if st = 1 {
                s.since := 0, s.fails := 0, s.notified := false, s.text := "✓ 在外面"
                continue
            }
            map := CwMap(p)
            if !s.since || s.map != map {
                s.since := now, s.map := map   ; 第一次看到不在外面，或這段時間換了地圖：重新確認
            }
            if now - s.since < CW_CONFIRM_MS {
                s.text := "不在外面，確認中 " Round((now - s.since) / 1000) " 秒"
                continue
            }
            if kind = "pet" && CwPetPressedRecently(p) {
                s.text := "不在外面｜剛剛按過寵物卡，休息中"
                continue
            }
            if now < s.next {
                s.text := "不在外面｜休息中（" Ceil((s.next - now) / 1000) " 秒後再試）"
                continue
            }
            todo.Push({p: p, kind: kind})
        }
    }
    if !todo.Length
        return
    busy := ApBlocker()   ; 含「等你停止操作鍵盤滑鼠」
    if busy != "" {
        for t in todo
            CwState(t.p, t.kind).text := "不在外面｜" busy
        return
    }
    CompanionRun(todo[1].p, todo[1].kind)
}

CompanionRun(p, kind) {
    global cwBusy, apBusy, foregroundOwner, apRunStart, apLastOwn, CW_COOLDOWN_MS, CW_VERIFY_MS, CW_BACKOFF_MAX_MS, CW_NOCARD_MS
    s := CwState(p, kind)
    label := CwLabel(kind)
    cwBusy := true, apBusy := true, foregroundOwner := "companion", apRunStart := A_TickCount, apLastOwn := A_TickCount
    prev := 0, cursor := 0, minimized := [], stopped := false
    try {
        info := DailyQuickInfo(p.pid, CwCard(kind))
        if info = "" {   ; 讀不到快捷欄資料（和「快捷欄裡沒有這張卡」不同）
            s.next := A_TickCount + 60000
            s.text := "不在外面｜讀不到道具快捷欄，稍後再試"
            return
        }
        if !IsObject(info) || info.key = "" {
            if A_TickCount - s.noCardAt > CW_NOCARD_MS {
                s.noCardAt := A_TickCount
                EventLog(p.name, "CW_SKIP", label "不在外面，但" (!IsObject(info) ? "道具快捷欄找不到" CwCard(kind) : CwCard(kind) "在快捷欄第 " info.slot " 格，不知道那一格是哪個鍵") "｜不按鍵")
            }
            s.next := A_TickCount + CW_NOCARD_MS
            s.text := "不在外面｜快捷欄沒有" CwCard(kind) "（或不知道是哪個鍵）"
            return
        }
        if CwRead(p, kind) != 0 || !ApReady(p)
            return
        prev := ApForeground(), cursor := ApCursor()
        if ApIsMinimized(p)
            minimized.Push(p)
        if !ApActivate(p) {
            s.next := A_TickCount + 30000
            s.text := "不在外面｜切不到遊戲視窗，稍後再試"
            return
        }
        ; 切到前景後再確認一次（這幾秒內它可能自己出現了：再按就收起來了）
        if CwRead(p, kind) != 0 || !ApReady(p)
            return
        ApKey(p, info.key)
        s.next := A_TickCount + CW_COOLDOWN_MS   ; 先記冷卻：開關型，不連續切換
        if kind = "pet"
            p.petPressedPid := p.pid, p.petPressedAt := A_TickCount   ; 和登入後補開寵物（RecoveryGuard）共用冷卻
        ok := ApWait(() => (ApGuardAny(), CwRead(p, kind) = 1), CW_VERIFY_MS)
        if ok {
            s.fails := 0, s.notified := false, s.since := 0, s.text := "✓ 剛剛已叫出（" FormatTime(, "HH:mm:ss") "）"
            EventLog(p.name, "CW_OK", label "不在外面｜已按 " StrUpper(info.key) "（快捷欄第 " info.slot " 格）叫出")
            AddRecentEvent("🐾 " p.name "：" label "不在外面，已叫出")
        } else {
            s.fails += 1
            wait := Min(CW_BACKOFF_MAX_MS, CW_COOLDOWN_MS * (2 ** Min(s.fails - 1, 5)))   ; 指數上限 5：連續失敗很多次也不會整數溢位
            s.next := A_TickCount + wait
            s.since := 0   ; 休息完要重新確認 10 秒，不能直接再按
            s.text := "⚠ 按了 " StrUpper(info.key) " 但" label "還是沒出來｜" Round(wait / 60000, 1) " 分鐘後再試"
            EventLog(p.name, "CW_FAIL", "按 " StrUpper(info.key) " 後 " Round(CW_VERIFY_MS / 1000) " 秒" label "仍不在外面｜連續第 " s.fails " 次｜" Round(wait / 60000, 1) " 分鐘後再試")
            if s.fails >= 3 && !s.notified {
                s.notified := true
                AddRecentEvent("⚠ " p.name "：" label "叫不出來（連續 " s.fails " 次）")
                try SendDiscordMessage("⚠️ HIHIYONG " label "叫不出來`n角色：" p.name "`n已按 " StrUpper(info.key) " 連續 " s.fails " 次，" label "仍不在外面。可能是卡片沒有了、沒有冷卻完或遊戲畫面有別的視窗擋住，請有空時確認。")
            }
        }
    } catch as e {
        if e.Extra = "stop" {
            stopped := true
            s.next := Max(s.next, A_TickCount + 20000)   ; 按鍵之後被中止時，兩分鐘冷卻不能被縮短
            s.since := 0
            s.text := "⏸ " e.Message "（稍後再試）"
            EventLog(p.name, "CW_STOP", e.Message)
        } else {
            s.next := Max(s.next, A_TickCount + 60000)
            s.since := 0
            s.text := "⚠ " e.Message
            EventLog(p.name, "CW_ERROR", e.Message)
        }
    } finally {
        ApCleanup(p, false, minimized, prev, cursor, stopped)
        foregroundOwner := "", apBusy := false, apRunStart := 0, cwBusy := false
    }
}

CompanionSet(rawValue) {
    global INI, CW_ENABLED, CW_PET, CW_MERC, CW_DOLL
    parts := StrSplit(rawValue, "~")
    if parts.Length < 3 || !IsInteger(parts[1]) || !IsInteger(parts[2]) || !IsInteger(parts[3]) || (parts.Length >= 4 && !IsInteger(parts[4]))
        return
    CW_ENABLED := Integer(parts[1]) ? 1 : 0, CW_PET := Integer(parts[2]) ? 1 : 0, CW_MERC := Integer(parts[3]) ? 1 : 0
    if parts.Length >= 4
        CW_DOLL := Integer(parts[4]) ? 1 : 0
    IniWrite CW_ENABLED, INI, "Companion", "Enabled"
    IniWrite CW_PET, INI, "Companion", "Pet"
    IniWrite CW_MERC, INI, "Companion", "Merc"
    IniWrite CW_DOLL, INI, "Companion", "Doll"
    AddRecentEvent("🐾 寵物 / 雇傭兵 / 魔法娃娃監測：" (CW_ENABLED ? "開啟" : "關閉") "｜寵物 " (CW_PET ? "監測" : "不監測") "｜雇傭兵 " (CW_MERC ? "監測" : "不監測") "｜魔法娃娃 " (CW_DOLL ? "監測" : "不監測"))
}

CompanionPushWeb() {
    global webReady, WVCore, profiles, CW_ENABLED, CW_PET, CW_MERC, CW_DOLL
    if !webReady || !WVCore
        return
    roles := ""
    for p in profiles {
        if !p.enabled
            continue
        pt := CW_PET ? CwState(p, "pet").text : "", mt := CW_MERC ? CwState(p, "merc").text : "", dt := CW_DOLL ? CwState(p, "doll").text : ""
        roles .= (roles = "" ? "" : ",") '{"name":"' JsonEscapeWeb(p.name) '","pet":"' JsonEscapeWeb(pt) '","merc":"' JsonEscapeWeb(mt) '","doll":"' JsonEscapeWeb(dt) '"}'
    }
    try WVCore.PostWebMessageAsJson('{"type":"companion","data":{"enabled":' (CW_ENABLED ? "true" : "false") ',"pet":' (CW_PET ? "true" : "false")
        . ',"merc":' (CW_MERC ? "true" : "false") ',"doll":' (CW_DOLL ? "true" : "false") ',"blocker":"' JsonEscapeWeb(ApBlockerRaw()) '","roles":[' roles ']}}')
}
