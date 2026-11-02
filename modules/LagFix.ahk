; ============================================================================
; LagFix：視窗回應變慢時，自動過一次圖（起點傳送卡 → 前點傳送卡）。預設關閉。
; 久掛後畫面更新變慢（動作延遲、寵物撿東西慢），過圖就恢復；重新登入效果一樣但要 60 秒，過圖約 10 秒。
; 量測（LagProbe）顯示變慢的視窗「視窗回應」會從 20 毫秒以下升到 100～300 毫秒，過圖後立刻回到個位數。
;
; 觸發：最近 LF_SAMPLES 次視窗回應的中位數 >= LF_PING_MS（毫秒），而且角色在野外地圖、活著、沒有其他自動化在動遊戲視窗、
;       你沒有在操作電腦。一次只處理一個視窗，視窗之間隔 LF_GAP_MS，同一個視窗至少隔 LF_WINDOW_GAP_MS。
; 做法（每個「按鍵」之前都再確認一次狀態，全部用記憶體判斷，不盲按）：
;   1. 快捷欄找得到起點卡與前點卡、傳送卡冷卻讀得到而且沒在冷卻 → 才開始（切到前景後再檢查一次）；
;   2. 先記下「待救援」（也寫進設定檔，管理程式重開也找得回來）再按起點卡 → 等地圖換掉。
;      地圖沒換：冷卻表顯示起點卡已被消耗 → 只是地圖很慢，保留待救援；沒被消耗 → 起點卡沒生效，清掉待救援，什麼都不再按；
;   3. 讀冷卻：起點卡與前點卡共用同一個冷卻類型（實機 10 秒），冷卻結束（多留 1 秒）才按前點卡（過圖花得比 10 秒久就馬上按）；
;   4. 前點卡只在「確定角色在城裡 / 安全區、而且不是原本的野外地圖」時才按；按完等地圖換掉、確認回到原本的野外地圖。
;      沒回去（冷卻還沒結束被擋、或到了城裡 / 一般區）→ 重新讀冷卻再按，一輪最多 3 次、整個過程最多 4 分鐘；
;   5. 一輪都沒回去 → 通知 Discord（附畫面），每 2 分鐘（等沒有其他動作、你沒在操作時）再試一輪，最多 3 輪；
;      3 輪都失敗 → 放棄，這個視窗停用 24 小時並通知；待救援超過 30 分鐘沒機會處理也會通知；
;      角色被發現在別張野外地圖（你自己走過去了）→ 不再按任何鍵，結束救援並通知；
;   6. 回去後補做：過圖前自動攻擊（F6）是開的才補開（連續 3 秒都是關才按）、過圖前在外面的寵物 / 雇傭兵等 10 秒還沒回來才叫出來；
;   7. 過圖後再量 3 次視窗回應，寫「過圖前 → 過圖後」。連續 2 次沒有改善 → 這個視窗暫停 6 小時並通知。
; 中途被停止鍵 / 其他功能 / 你開始操作打斷：角色若已在城裡，列入「待救援」等空檔再按前點卡，不會把角色留在城裡。
; 沿用組隊的切換視窗 / 守門 / 收尾機制（ApActivate、ApKey、ApGuardAny、ApCleanup），和組隊、寵物雇傭兵監測共用 apBusy。
; ============================================================================

LfIniInt(key, def, lo, hi) {
    global INI
    v := IniRead(INI, "LagFix", key, def)
    return IsInteger(v) ? Min(hi, Max(lo, Integer(v))) : def   ; 設定檔被改壞時用預設
}
global LF_ENABLED := LfIniInt("Enabled", 0, 0, 1)
global LF_PING_MS := LfIniInt("PingMs", 100, 30, 2000)
global LF_SAMPLES := 6, LF_STALE_MS := 480000
global LF_GAP_MS := 60000, LF_WINDOW_GAP_MS := 3600000
global LF_COOL_WAIT_MS := 45000, LF_MAP_WAIT_MS := 20000, LF_UNREADABLE_COOL_MS := 12000
global LF_RESCUE_RETRY_MS := 120000, LF_RESCUE_MAX_ROUNDS := 3, LF_RESCUE_MAX_AGE_MS := 1800000
global LF_PAUSE_FAIL_MS := 86400000, LF_PAUSE_INEFFECTIVE_MS := 21600000
global LF_TOTAL_MAX_MS := 240000, LF_COMPANION_WAIT_MS := 10000, LF_COMPANION_COOLDOWN_MS := 120000, LF_MANUAL_WAIT_MS := 90000
global lfBusy := false, lfNextGlobal := 0
; 時間與等待都經過這兩個函式：單元測試可以掛假的時鐘，不用真的等 10 秒的冷卻。
global lfTestDriver := 0
LfNow() {
    global lfTestDriver
    return IsObject(lfTestDriver) ? lfTestDriver.Now() : A_TickCount
}
LfSleep(ms) {
    global lfTestDriver
    if IsObject(lfTestDriver)
        return lfTestDriver.Sleep(ms)
    Sleep ms
}

LfState(p) {
    if !p.HasOwnProp("lf")
        p.lf := {next: 0, pauseUntil: 0, rescue: 0, text: "", before: 0, verify: 0, ineff: 0, runs: 0, skipAt: -1, manual: 0, restored: false, reqCb: 0, reqDeadline: 0, reqTimes: []}
    return p.lf
}

LfMedian(arr) {
    s := []
    for v in arr {
        i := s.Length + 1
        while i > 1 && s[i - 1] > v
            i -= 1
        s.InsertAt(i, v)
    }
    n := s.Length
    return n = 0 ? "" : (Mod(n, 2) ? s[(n + 1) // 2] : (s[n // 2] + s[n // 2 + 1]) / 2)
}

; 最近 LF_SAMPLES 次視窗回應的中位數；資料不夠或太舊回傳 ""。
LfSlowMedian(p) {
    global LF_SAMPLES, LF_STALE_MS
    if !p.HasOwnProp("lagHist") || p.lagHist.Length < LF_SAMPLES
        return ""
    vals := [], n := p.lagHist.Length
    Loop LF_SAMPLES {
        e := p.lagHist[n - A_Index + 1]
        if LfNow() - e.tick > LF_STALE_MS
            return ""
        vals.Push(e.v)
    }
    return LfMedian(vals)
}

; 在野外地圖（非安全區、非學院）回傳地圖 ID，否則 ""（讀不到地圖資料也是 ""，不能當成野外）。
LfFieldMap(pid) {
    m := ""
    try m := ReadGameMapId(pid)
    if m = ""
        return ""
    info := 0
    try info := GameMapInfo(pid, m)
    if !IsObject(info) || info.peace || InStr(info.name, "學院")
        return ""
    return m
}

; 「確定」在城裡 / 安全區：地圖資訊讀得到，而且是安全區或學院。讀不到不算。
LfTownMap(pid) {
    m := ""
    try m := ReadGameMapId(pid)
    if m = ""
        return false
    info := 0
    try info := GameMapInfo(pid, m)
    return IsObject(info) && (info.peace || InStr(info.name, "學院")) ? true : false
}

; 起點卡 / 前點卡共用冷卻：回傳還要等幾秒（0 = 可以用）；讀不到 -1。
; 兩張卡的冷卻紀錄都沒有時：missingReady = true（從來沒用過）當成 0；false（剛按過卻沒有紀錄 = 不正常）當成讀不到。
LfCoolRemain(pid, sId, rId, missingReady) {
    a := GameCoolInfoByItem(pid, sId)
    b := GameCoolInfoByItem(pid, rId)
    if a = "" || b = ""
        return -1
    if !IsObject(a) && !IsObject(b)
        return missingReady ? 0 : -1
    best := 0
    for x in [a, b]
        if IsObject(x)
            best := Max(best, x.remain)
    return best
}

LfIsHome(pid, rs) => ReadGameMapId(pid) = rs.mapB && LfFieldMap(pid) != ""

; 起點卡這次真的被消耗了（冷卻表裡起點卡的使用時間不早於按鍵當下的伺服器時間）
LfStartConsumed(pid, rs) {
    if !rs.srvPress || rs.sId = ""
        return false
    info := GameCoolInfoByItem(pid, rs.sId)
    return IsObject(info) && info.use >= rs.srvPress - 1
}

; ---------------------------------------------------------------- 待救援（記憶體 + 設定檔）
LfSavePending(p, rs) {
    global INI
    try IniWrite(rs.mapB, INI, "LagFixPending", p.name)
}
LfClearPending(p) {
    global INI
    try IniDelete(INI, "LagFixPending", p.name)
}
; ok：這次過圖有沒有完成。其他功能（命運箱子）請求過圖時，用 reqCb 通知結果（只通知一次）。
LfClearRescue(p, st, ok := false) {
    st.rescue := 0
    LfClearPending(p)
    LfFinishReq(p, st, ok)
}
LfFinishReq(p, st, ok) {
    cb := st.reqCb
    if IsObject(cb)
        st.manual := 0   ; 請求結束（不論成敗）：排隊的過圖一併取消，不要之後又多過一次
    st.reqCb := 0
    if IsObject(cb)
        try cb(p, ok)
}

; 其他功能請求「馬上過圖」（略過變慢判斷）：命運箱子按鍵卡住時用。需要「變慢自動過圖」開著；排隊等鍵盤滑鼠閒置，最久等 10 分鐘。
; 回傳是否接受；結果用 cb(p, ok) 通知（ok = 已完成過圖並回到原地）。
; 排隊逾時 timeoutMs（預設 10 分鐘）。遵守暫停（失敗 24 小時 / 沒效果 6 小時）；每個視窗 24 小時內最多 2 次請求。
LagFixRequest(p, reason, cb, timeoutMs := 600000) {
    global LF_ENABLED
    st := LfState(p)
    now := LfNow()
    if !LF_ENABLED || IsObject(st.rescue) || st.manual || IsObject(st.reqCb) || now < st.pauseUntil
        return false
    while st.reqTimes.Length && now - st.reqTimes[1] > 86400000
        st.reqTimes.RemoveAt(1)
    if st.reqTimes.Length >= 2
        return false
    st.reqTimes.Push(now)
    st.reqDeadline := now + timeoutMs, st.manual := st.reqDeadline, st.reqCb := cb
    st.text := "「" reason "」請求過圖：等你停止操作鍵盤滑鼠後執行"
    EventLog(p.name, "LAGFIX_REQUEST", "其他功能請求過圖：" reason)
    return true
}

; 管理程式重開後：設定檔裡還有「待救援」的角色，確認角色的位置再決定要不要恢復救援。
LfRestorePending(p, st) {
    global INI
    st.restored := true
    mapB := ""
    try mapB := IniRead(INI, "LagFixPending", p.name, "")
    if mapB = "" || IsObject(st.rescue)
        return
    if LfFieldMap(p.pid) != "" {
        LfClearPending(p)
        EventLog(p.name, "LAGFIX_SKIP", "重開後角色已在野外地圖，清除舊的待救援紀錄")
        return
    }
    if !LfTownMap(p.pid) {
        LfClearPending(p)
        return
    }
    st.rescue := {mapB: mapB, sId: "", rId: "", since: LfNow(), rounds: 0, tries: 0, notified: false, nextTry: 0, pressTick: 0
        , pet: -1, merc: -1, auto: -1, startAt: LfNow(), left: true, srvPress: 0, type: "", manual: false}
    EventLog(p.name, "LAGFIX_RESTORE", "管理程式重開後發現角色還在城裡（原本在 " mapB "），恢復救援")
}

; ---------------------------------------------------------------- 排程
LagFixTick() {
    global profiles, LF_ENABLED, lfBusy, apBusy, lfNextGlobal, LF_PING_MS, LF_RESCUE_MAX_AGE_MS
    if lfBusy || apBusy
        return
    LagFixVerify()
    now := LfNow()
    for p in profiles {
        st := LfState(p)
        if !st.restored && p.enabled && p.pid && ProfileGameAlive(p) && ApReady(p)
            try LfRestorePending(p, st)
    }
    ; 救援優先：已經按過起點卡、角色可能還在城裡 —— 即使功能被關掉也要把人送回去
    for p in profiles {
        st := LfState(p)
        if !IsObject(st.rescue)
            continue
        if now - st.rescue.since > LF_RESCUE_MAX_AGE_MS {
            LfClearRescue(p, st)
            EventLog(p.name, "LAGFIX_GIVEUP", "待救援超過 " Round(LF_RESCUE_MAX_AGE_MS / 60000) " 分鐘沒機會處理，放棄")
            AddRecentEvent("⚠ " p.name " 自動過圖後待救援超過 " Round(LF_RESCUE_MAX_AGE_MS / 60000) " 分鐘沒處理，已放棄，角色可能還在城裡")
            try ReportEventShot(p, "⚠️ HIHIYONG 自動過圖後角色可能還在城裡`n角色：" p.name "`n待救援超過 " Round(LF_RESCUE_MAX_AGE_MS / 60000) " 分鐘一直沒有機會處理（有其他動作或你持續在操作電腦），已放棄。請人工確認。（附上當下畫面）")
            continue
        }
        if now < st.rescue.nextTry || !p.enabled || !p.pid || !ProfileGameAlive(p)
            continue
        if !ApReady(p) {
            st.text := "待救援｜等角色回到遊戲世界（或復活）"
            continue
        }
        if ApBlocker() != ""
            return
        LagFixExec(p)
        return
    }
    ; 玩家按了「現在過圖」：等到鍵盤滑鼠閒置、沒有其他動作時執行
    for p in profiles {
        st := LfState(p)
        if !st.manual
            continue
        if now > (IsObject(st.reqCb) ? st.reqDeadline : st.manual) {
            st.manual := 0
            st.text := "「現在過圖」等不到空檔，已取消"
            LfFinishReq(p, st, false)
            continue
        }
        if IsObject(st.rescue) || ApBlocker() != ""
            continue
        LagFixExec(p, true)
        return
    }
    if !LF_ENABLED || now < lfNextGlobal
        return
    best := 0, bestMed := 0
    for p in profiles {
        st := LfState(p)
        if !p.enabled || !p.pid || p.state != "監控中" || !ProfileGameAlive(p) || now < st.next || now < st.pauseUntil
            continue
        if IsObject(st.rescue)
            continue   ; 待救援的視窗只走上面的救援流程（還沒到下一輪的時間就等）
        med := LfSlowMedian(p)
        if med = "" || med < LF_PING_MS {
            if !IsObject(st.verify)
                st.text := med = "" ? "" : "視窗回應 " Round(med) " ms（正常）"
            continue
        }
        st.text := "視窗回應 " Round(med) " ms｜偏慢"
        if med > bestMed
            best := p, bestMed := med
    }
    if !best
        return
    why := ApBlocker()
    if why != "" {
        LfState(best).text := "視窗回應 " Round(bestMed) " ms｜偏慢｜等待：" why
        return
    }
    LagFixExec(best)
}

; 玩家按「現在過圖」：略過「是否變慢 / 功能開關 / 每小時一次」，其餘守門全部照常。
; 按按鈕當下鍵盤滑鼠一定不閒置，所以先排隊，等閒置再執行（最多等 LF_MANUAL_WAIT_MS）。
LagFixManual(idx) {
    global profiles, LF_MANUAL_WAIT_MS
    if !profiles.Has(idx)
        return
    p := profiles[idx]
    st := LfState(p)
    st.manual := Max(LfNow() + LF_MANUAL_WAIT_MS, IsObject(st.reqCb) ? st.reqDeadline : 0)
    st.text := "「現在過圖」已排隊：等你停止操作鍵盤滑鼠後執行（最多等 " Round(LF_MANUAL_WAIT_MS / 1000) " 秒）"
}

; ---------------------------------------------------------------- 開始前的檢查（只讀記憶體，還沒碰遊戲視窗）
LagFixPlan(p) {
    pid := p.pid
    if !ApReady(p)
        return {err: "還沒進遊戲世界（或死亡中）"}
    mapB := LfFieldMap(pid)
    if mapB = ""
        return {err: "不在野外地圖（在城裡，或讀不到地圖資料）"}
    s := DailyQuickInfo(pid, "起點傳送卡"), r := DailyQuickInfo(pid, "前點傳送卡")
    if s = "" || r = ""
        return {err: "讀不到道具快捷欄"}
    if !IsObject(s) || s.key = "" || !s.HasOwnProp("id")
        return {err: "快捷欄沒有起點傳送卡（或不知道是哪個鍵）"}
    if !IsObject(r) || r.key = "" || !r.HasOwnProp("id")
        return {err: "快捷欄沒有前點傳送卡（或不知道是哪個鍵）"}
    sId := GameItemKeyToId(s.id), rId := GameItemKeyToId(r.id)
    if sId = "" || rId = ""
        return {err: "認不得傳送卡的道具編號"}
    cd := LfCoolRemain(pid, sId, rId, true)
    if cd < 0
        return {err: "讀不到傳送卡冷卻（不開始：回程時沒辦法確認冷卻）"}
    if cd > 0
        return {err: "傳送卡冷卻中（還要 " cd " 秒）", retryMs: (cd + 3) * 1000}
    pet := -1, merc := -1, auto := -1
    try pet := ReadGamePetOut(pid)
    try merc := ReadGameSummonOut(pid)
    try auto := ReadGameAutoAttack(pid)
    return {err: "", mapB: mapB, sKey: s.key, rKey: r.key, sId: sId, rId: rId, pet: pet, merc: merc, auto: auto}
}

; ---------------------------------------------------------------- 執行
LagFixExec(p, manual := false) {
    global lfBusy, apBusy, foregroundOwner, apRunStart, apLastOwn, lfNextGlobal, LF_GAP_MS, LF_MAP_WAIT_MS
    if lfBusy || apBusy
        return
    lfBusy := true      ; 一進來就占住：預檢和切視窗之間，別的計時器不能插隊
    st := LfState(p)
    st.manual := 0
    prev := 0, cursor := 0, minimized := [], stopped := false, owned := false
    try {
        rescueOnly := IsObject(st.rescue)
        plan := 0, before := ""
        if !rescueOnly {
            plan := LagFixPlan(p)
            if plan.err != "" {
                st.text := "偏慢｜不過圖：" plan.err
                if manual && IsObject(st.reqCb) && plan.HasOwnProp("retryMs") && LfNow() + plan.retryMs < st.reqDeadline {
                    st.manual := LfNow() + plan.retryMs + 3000   ; 其他功能的請求：只是傳送卡冷卻中，等它結束再來（截止時間不變）
                    return
                }
                if manual
                    LfFinishReq(p, st, false)
                st.next := LfNow() + (plan.HasOwnProp("retryMs") ? plan.retryMs : 300000)
                if st.skipAt < 0 || LfNow() - st.skipAt > 1800000 || manual {
                    st.skipAt := LfNow()
                    EventLog(p.name, "LAGFIX_SKIP", "視窗偏慢，但不過圖｜" plan.err)
                }
                return
            }
            before := LfSlowMedian(p)
        }
        apBusy := true, foregroundOwner := "companion", apRunStart := LfNow(), apLastOwn := A_TickCount, owned := true
        prev := ApForeground(), cursor := ApCursor()
        if ApIsMinimized(p)
            minimized.Push(p)
        if !ApActivate(p) {
            st.next := LfNow() + 60000
            st.text := "切不到遊戲視窗，稍後再試"
            if rescueOnly
                st.rescue.nextTry := LfNow() + 30000
            else
                LfFinishReq(p, st, false)
            return
        }
        if !rescueOnly {
            ; 切到前景後整個預檢重做一次（中間狀態可能變了：地圖、冷卻、快捷欄、死亡）
            plan := LagFixPlan(p)
            if plan.err != ""
                throw Error("切到視窗後狀態改變，這次不過圖：" plan.err, , "skip")
            ; 先記下「待救援」再按：按了起點卡之後任何中斷，都要有人把角色送回去
            srv := 0
            try ReadGameServerTime(p.pid, &srv)
            st.rescue := {mapB: plan.mapB, sId: plan.sId, rId: plan.rId, since: LfNow(), rounds: 0, tries: 0, notified: false
                , nextTry: 0, pressTick: 0, pet: plan.pet, merc: plan.merc, auto: plan.auto, startAt: LfNow(), left: false, srvPress: srv, type: "", manual: manual}
            LfSavePending(p, st.rescue)
            st.before := before
            ApKey(p, plan.sKey)
            st.rescue.pressTick := LfNow()
            EventLog(p.name, "LAGFIX_START", (manual || before = "" ? "手動" : "視窗回應 " Round(before) " ms 偏慢") "｜按起點卡 " StrUpper(plan.sKey) "｜原地圖 " plan.mapB)
            mapB := plan.mapB
            moved := ApWait(() => (ApGuardAny(), (m := ReadGameMapId(p.pid)) != "" && m != mapB && GameCharacterLoaded(p.pid)), LF_MAP_WAIT_MS)
            if !moved   ; 再多等一下：地圖有時很慢才換
                moved := ApWait(() => (ApGuardAny(), (m := ReadGameMapId(p.pid)) != "" && m != mapB && GameCharacterLoaded(p.pid)), 8000)
            if !moved {
                if LfStartConsumed(p.pid, st.rescue) {
                    ; 起點卡已經用掉了，只是地圖很慢才換：不能清掉待救援，不然傳送完成後角色會留在城裡
                    st.rescue.nextTry := LfNow() + 10000
                    st.text := "起點卡已生效，但地圖還沒換，列入待救援"
                    EventLog(p.name, "LAGFIX_WAIT", "按起點卡 " StrUpper(plan.sKey) " 後 " Round((LF_MAP_WAIT_MS + 8000) / 1000) " 秒地圖還沒換，但冷卻表顯示起點卡已被使用｜列入待救援，等地圖換了再回去")
                    AddRecentEvent("⚠ " p.name " 起點卡已生效但地圖很慢才換，列入待救援")
                    return
                }
                LfClearRescue(p, st)
                st.next := LfNow() + 600000
                st.text := "⚠ 按了起點卡但地圖沒有改變，這次放棄（沒有再按任何鍵）"
                EventLog(p.name, "LAGFIX_FAIL", "按起點卡 " StrUpper(plan.sKey) " 後 " Round((LF_MAP_WAIT_MS + 8000) / 1000) " 秒地圖沒有改變，冷卻表也沒有使用紀錄（被擋住、對話框或沒按到）｜沒有再按任何鍵｜10 分鐘後再評估")
                AddRecentEvent("⚠ " p.name " 自動過圖：起點卡沒有生效，已放棄")
                return
            }
            st.rescue.left := true
            LfSleep(1500)
        }
        LagFixReturn(p, st)
    } catch as e {
        if e.Extra = "stop" {
            stopped := true
            st.next := Max(st.next, LfNow() + 20000)
            st.text := "⏸ " e.Message "（稍後再試）"
            if !IsObject(st.rescue) && IsObject(st.reqCb) {
                ; 還沒按任何鍵就被打斷：其他功能的請求不能被丟掉，截止前重新排隊，過了截止就回報失敗
                if LfNow() < st.reqDeadline
                    st.manual := LfNow() + 10000
                else
                    LfFinishReq(p, st, false)
            }
            EventLog(p.name, "LAGFIX_STOP", e.Message (IsObject(st.rescue) ? "｜角色可能還在城裡，列入待救援" : ""))
            if IsObject(st.rescue) {
                st.rescue.nextTry := LfNow() + 15000
                AddRecentEvent("⏸ " p.name " 自動過圖被打斷（" e.Message "），等空檔再把角色送回去")
            }
        } else if e.Extra = "skip" {
            st.next := LfNow() + 120000
            st.text := e.Message
            EventLog(p.name, "LAGFIX_SKIP", e.Message)
            if !IsObject(st.rescue) {
                if IsObject(st.reqCb) && LfNow() + 15000 < st.reqDeadline
                    st.manual := LfNow() + 15000   ; 切到前景後的預檢失敗（例如剛好又進冷卻）：請求截止前再試
                else
                    LfFinishReq(p, st, false)
            }
        } else {
            st.next := Max(st.next, LfNow() + 600000)
            st.text := "⚠ " e.Message
            EventLog(p.name, "LAGFIX_ERROR", e.Message (IsObject(st.rescue) ? "｜列入待救援" : ""))
            if IsObject(st.rescue)
                st.rescue.nextTry := LfNow() + 30000
            else
                LfFinishReq(p, st, false)
        }
    } finally {
        if owned
            try ApCleanup(p, false, minimized, prev, cursor, stopped)
        if owned
            foregroundOwner := "", apBusy := false, apRunStart := 0
        lfBusy := false
        lfNextGlobal := LfNow() + LF_GAP_MS
    }
}

; 在城裡（或剛按完起點卡）→ 讀冷卻 → 前點卡 → 確認回到原本的野外地圖。一輪最多 3 次。
LagFixReturn(p, st) {
    global apRunStart, LF_MAP_WAIT_MS, LF_TOTAL_MAX_MS
    rs := st.rescue
    pid := p.pid
    execStart := LfNow()
    Loop 3 {
        apRunStart := LfNow()
        ApGuardAny()
        if LfNow() - execStart > LF_TOTAL_MAX_MS {
            LagFixReturnFail(p, st, "整個過程超過 " Round(LF_TOTAL_MAX_MS / 60000) " 分鐘")
            return
        }
        if !ApReady(p)
            throw Error("角色不在遊戲世界或死亡中", , "stop")
        cur := ReadGameMapId(pid)
        if cur = ""
            throw Error("讀不到目前地圖，先不按鍵", , "stop")
        if cur != rs.mapB
            rs.left := true
        if LfIsHome(pid, rs) {
            if rs.left
                return LagFixDone(p, st, "")
            ; 角色一直在原地圖：起點卡沒有生效（或地圖還沒換）。剛按完又確定用掉了就再等，否則不補做、不記成功
            if rs.pressTick && LfNow() - rs.pressTick < 120000 && LfStartConsumed(pid, rs) {
                rs.nextTry := LfNow() + 8000
                st.text := "起點卡已生效，等地圖切換"
                return
            }
            LfClearRescue(p, st)
            EventLog(p.name, "LAGFIX_SKIP", "待救援時角色一直在原本的野外地圖，起點卡沒有生效｜不補做、不記成功")
            return
        }
        if !LfTownMap(pid) {
            ; 不在城裡、也不是原地圖 = 別張野外地圖（你自己走過去了，或副本）：前點卡在野外會把角色帶回城裡，絕對不按
            LfClearRescue(p, st)
            EventLog(p.name, "LAGFIX_GIVEUP", "角色不在城裡，也不在原本的野外地圖（目前 " cur "，原本 " rs.mapB "）｜不再按任何鍵，結束救援")
            AddRecentEvent("⚠ " p.name " 自動過圖後角色在別張地圖（" cur "），已結束救援，請確認位置")
            try SendDiscordMessage("⚠️ HIHIYONG 自動過圖後角色在別張地圖`n角色：" p.name "`n目前地圖：" NotificationLocationText(p) "（原本在 " rs.mapB "）`n程式不會再按傳送卡，請確認角色位置。")
            return
        }
        info := DailyQuickInfo(pid, "前點傳送卡")
        if !IsObject(info) || info.key = "" || !info.HasOwnProp("id") {
            LagFixReturnFail(p, st, info = "" ? "讀不到道具快捷欄" : "快捷欄找不到前點傳送卡（沒放或已用完）")
            return
        }
        id := GameItemKeyToId(info.id)
        if id != ""
            rs.rId := id
        if rs.sId = "" {
            s := DailyQuickInfo(pid, "起點傳送卡")
            if IsObject(s) && s.HasOwnProp("id")
                rs.sId := GameItemKeyToId(s.id)
        }
        waited := LagFixWaitCool(p, rs)
        ApGuardAny()
        if !ApReady(p)
            throw Error("角色不在遊戲世界或死亡中", , "stop")
        ; 按鍵前最後一次確認：等冷卻的這段時間地圖可能變了（剛好到家 / 被你移動）
        if LfIsHome(pid, rs)
            return LagFixDone(p, st, "")
        if !LfTownMap(pid) {
            LfClearRescue(p, st)
            EventLog(p.name, "LAGFIX_GIVEUP", "等冷卻時角色離開了城裡（目前 " ReadGameMapId(pid) "）｜不再按任何鍵，結束救援")
            AddRecentEvent("⚠ " p.name " 自動過圖等冷卻時角色換了地圖，已結束救援，請確認位置")
            return
        }
        info := DailyQuickInfo(pid, "前點傳送卡")   ; 等了這麼久，鍵再讀一次
        if !IsObject(info) || info.key = "" {
            LagFixReturnFail(p, st, "快捷欄找不到前點傳送卡（沒放或已用完）")
            return
        }
        cur2 := ReadGameMapId(pid)
        ApKey(p, info.key)
        rs.tries += 1
        EventLog(p.name, "LAGFIX_RETURN", "按前點卡 " StrUpper(info.key) "｜第 " rs.tries " 次｜" waited "｜目前地圖 " cur2)
        arrived := ApWait(() => (ApGuardAny(), (m := ReadGameMapId(pid)) != "" && m != cur2 && GameCharacterLoaded(pid)), LF_MAP_WAIT_MS)
        if arrived {
            LfSleep(1500)
            if LfIsHome(pid, rs)
                return LagFixDone(p, st, "")
            m := ReadGameMapId(pid)
            if LfFieldMap(pid) != ""
                return LagFixDone(p, st, "前點卡把角色帶到另一張野外地圖 " m "（原本 " rs.mapB "），請確認位置")
            EventLog(p.name, "LAGFIX_RETRY", "前點卡後地圖變成 " m "，不是原本的野外地圖 " rs.mapB "（城裡 / 一般區）｜再試")
        } else
            EventLog(p.name, "LAGFIX_RETRY", "按前點卡後 " Round(LF_MAP_WAIT_MS / 1000) " 秒地圖沒有改變（冷卻還沒結束，或被畫面上的視窗擋住）｜重新讀冷卻再試")
    }
    LagFixReturnFail(p, st, "3 次前點卡都沒有回到原本的野外地圖")
}

; 等傳送卡冷卻結束（起點卡 / 前點卡共用）。回傳說明文字。
; 第一次查到起點卡的冷卻紀錄就記下冷卻類型，之後直接看這個類型（不會因為別張卡覆寫紀錄就讀不到）。
; 伺服器時間是整秒：讀到 0 之後再多等 1.1 秒確認，避免卡在同一秒的邊界被遊戲擋掉。
LagFixWaitCool(p, rs) {
    global LF_COOL_WAIT_MS, LF_UNREADABLE_COOL_MS
    start := LfNow(), zeros := 0
    Loop {
        ApGuardAny()
        if rs.type = "" && rs.sId != "" {
            info := GameCoolInfoByItem(p.pid, rs.sId)
            if IsObject(info)
                rs.type := info.type
        }
        r := rs.type != "" ? GameCoolRemainByType(p.pid, rs.type) : LfCoolRemain(p.pid, rs.sId, rs.rId, false)
        if r = 0 {
            zeros += 1
            if zeros >= 2
                return "冷卻已結束"
        } else
            zeros := 0
        if r < 0 && LfNow() - rs.pressTick >= LF_UNREADABLE_COOL_MS
            return "讀不到冷卻，改等滿 " Round(LF_UNREADABLE_COOL_MS / 1000) " 秒"
        if LfNow() - start >= LF_COOL_WAIT_MS
            return "等冷卻逾時 " Round(LF_COOL_WAIT_MS / 1000) " 秒"
        LfSleep(r = 0 ? 1100 : 400)
    }
}

LagFixReturnFail(p, st, why) {
    global LF_RESCUE_RETRY_MS, LF_RESCUE_MAX_ROUNDS, LF_PAUSE_FAIL_MS
    rs := st.rescue
    rs.rounds += 1
    rs.nextTry := LfNow() + LF_RESCUE_RETRY_MS
    st.text := "⚠ 過圖後回不去：" why "｜第 " rs.rounds " 輪"
    EventLog(p.name, "LAGFIX_RETURN_FAIL", why "｜第 " rs.rounds "/" LF_RESCUE_MAX_ROUNDS " 輪｜目前地圖 " ReadGameMapId(p.pid))
    giveUp := rs.rounds >= LF_RESCUE_MAX_ROUNDS
    if !rs.notified || giveUp {
        rs.notified := true
        msg := "⚠️ HIHIYONG 自動過圖後角色沒有回到怪物區`n角色：" p.name "`n狀況：" why "`n目前地圖：" NotificationLocationText(p)
            . (giveUp ? "`n已試 " LF_RESCUE_MAX_ROUNDS " 輪，放棄；這個視窗的自動過圖停用 24 小時，請人工把角色送回去。" : "`n程式會每 2 分鐘再試一輪（最多 " LF_RESCUE_MAX_ROUNDS " 輪）。")
        AddRecentEvent("⚠ " p.name " 自動過圖後沒回到怪物區：" why)
        try ReportEventShot(p, msg "（附上當下畫面）")
    }
    if giveUp {
        LfClearRescue(p, st)
        st.pauseUntil := LfNow() + LF_PAUSE_FAIL_MS
        st.next := st.pauseUntil
        EventLog(p.name, "LAGFIX_GIVEUP", "待救援 " LF_RESCUE_MAX_ROUNDS " 輪都失敗，放棄｜這個視窗的自動過圖停用 24 小時")
    }
}

LagFixDone(p, st, note) {
    global LF_WINDOW_GAP_MS
    rs := st.rescue
    LfClearRescue(p, st, true)     ; 先清掉：已經回到原地，後面補做被打斷也不再重按傳送卡
    st.runs += 1
    st.next := LfNow() + LF_WINDOW_GAP_MS
    if rs.manual
        st.pauseUntil := 0   ; 手動過圖成功才解除暫停（失敗不解除）
    secs := Round((LfNow() - rs.startAt) / 1000)
    p.lagHist := [], p.lagQuietUntil := LfNow() + 45000   ; 換圖當下的回應不算，過圖後重新累積
    st.verify := {since: LfNow(), before: st.before}
    extra := ""
    if note = ""
        try extra := LagFixPostActions(p, rs)   ; 到了別張地圖就不補做（不熟悉的地圖不要亂開自動攻擊 / 叫寵物）
    st.text := "✓ " FormatTime(, "HH:mm:ss") " 已過圖（" secs " 秒）" (note != "" ? "｜" note : "")
    EventLog(p.name, "LAGFIX_OK", "過圖完成｜起點→前點共 " secs " 秒｜前點卡 " rs.tries " 次｜過圖前回應 " (st.before = "" ? "?" : Round(st.before)) " ms"
        . (extra != "" ? "｜補做：" extra : "") (note != "" ? "｜" note : ""))
    AddRecentEvent("🔄 " p.name " 視窗變慢，已自動過圖（" secs " 秒）" (extra != "" ? "｜" extra : "") (note != "" ? "｜" note : ""))
    if note != ""
        try SendDiscordMessage("⚠️ HIHIYONG 自動過圖完成，但位置不同`n角色：" p.name "`n" note)
}

; 回到原地後補做：過圖前自動攻擊（F6）是開的、現在連續 3 秒都是關才補開；
; 過圖前在外面的寵物 / 雇傭兵（並且玩家有開啟監測）等 10 秒還沒回來才叫出來。
LagFixPostActions(p, rs) {
    pid := p.pid
    done := []
    if rs.auto = 1 {
        ; 換圖後旗標可能比實際狀態慢：3 秒內只要有一刻不是「關」就不按
        if !ApWait(() => (ApGuardAny(), ReadGameAutoAttack(pid) != 0), 3000) {
            ApKey(p, "F6")
            done.Push(ApWait(() => (ApGuardAny(), ReadGameAutoAttack(pid) = 1), 3000) ? "開啟自動攻擊" : "按 F6 後自動攻擊仍未開啟")
        }
    }
    for kind in ["pet", "merc"] {
        was := kind = "pet" ? rs.pet : rs.merc
        if was != 1 || !CwOn(kind)
            continue   ; 過圖前就不在外面的（玩家沒在用）、或寵物雇傭兵監測沒開的不要叫出來
        t := LfEnsureCompanion(p, kind)
        if t != ""
            done.Push(t)
    }
    out := ""
    for s in done
        out .= (out = "" ? "" : "、") s
    return out
}

LfEnsureCompanion(p, kind) {
    global LF_COMPANION_WAIT_MS, LF_COMPANION_COOLDOWN_MS
    ; 換地圖時寵物 / 雇傭兵會暫時消失（寵物雇傭兵監測也是連續確認 10 秒才算）：先等它自己出現，還是不在外面才按
    if CwRead(p, kind) < 0
        return ""
    if ApWait(() => (ApGuardAny(), CwRead(p, kind) != 0), LF_COMPANION_WAIT_MS)
        return ""
    if !ApReady(p) || CwRead(p, kind) != 0
        return ""
    info := DailyQuickInfo(p.pid, CwCard(kind))
    if !IsObject(info) || info.key = ""
        return ""
    if kind = "pet" && CwPetPressedRecently(p)
        return ""
    ApKey(p, info.key)
    CwState(p, kind).next := LfNow() + LF_COMPANION_COOLDOWN_MS   ; 寵物雇傭兵監測也休息，不要接著再按一次
    if kind = "pet"
        p.petPressedPid := p.pid, p.petPressedAt := LfNow()
    return ApWait(() => (ApGuardAny(), CwRead(p, kind) = 1), 8000) ? "叫出" CwLabel(kind) : CwLabel(kind) "仍不在外面"
}

; 過圖後累積 3 次視窗回應 → 寫「過圖前 → 過圖後」；連續 2 次沒改善就暫停這個視窗。
LagFixVerify() {
    global profiles, LF_PING_MS, LF_PAUSE_INEFFECTIVE_MS
    for p in profiles {
        st := LfState(p)
        v := st.verify
        if !IsObject(v)
            continue
        if LfNow() - v.since > 900000 {
            st.verify := 0
            continue
        }
        if !p.HasOwnProp("lagHist") || p.lagHist.Length < 3
            continue
        vals := []
        for e in p.lagHist
            vals.Push(e.v)
        after := LfMedian(vals)
        st.verify := 0
        good := after < LF_PING_MS
        st.ineff := good ? 0 : st.ineff + 1
        EventLog(p.name, "LAGFIX_RESULT", "視窗回應 過圖前 " (v.before = "" ? "?" : Round(v.before)) " ms → 過圖後 " Round(after) " ms｜" (good ? "有改善" : "沒有明顯改善（連續第 " st.ineff " 次）"))
        st.text := "過圖後回應 " Round(after) " ms（過圖前 " (v.before = "" ? "?" : Round(v.before)) " ms）" (good ? "" : "｜沒改善")
        if st.ineff >= 2 {
            st.ineff := 0
            st.pauseUntil := LfNow() + LF_PAUSE_INEFFECTIVE_MS
            st.next := st.pauseUntil
            EventLog(p.name, "LAGFIX_PAUSE", "連續 2 次過圖後回應都沒有改善，這個視窗暫停自動過圖 6 小時")
            AddRecentEvent("⚠ " p.name " 過圖兩次都沒有改善，暫停自動過圖 6 小時")
            try SendDiscordMessage("⚠️ HIHIYONG 自動過圖沒有效果`n角色：" p.name "`n連續 2 次過圖後視窗回應仍偏慢（" Round(after) " ms），這個視窗暫停自動過圖 6 小時。請到「功能 → 流暢度偵測」查看，或匯出診斷包。")
        }
    }
}

; ---------------------------------------------------------------- 設定 / 畫面
; 取消排隊中的請求（不呼叫回呼；呼叫端自己已經不需要結果）。待救援不動。
LagFixCancelRequest(p) {
    st := LfState(p)
    if IsObject(st.reqCb) {
        st.reqCb := 0, st.manual := 0
        st.text := "過圖請求已取消"
    }
}

LagFixSet(rawValue) {
    global INI, LF_ENABLED, LF_PING_MS, profiles
    parts := StrSplit(rawValue, "~")
    if parts.Length < 2 || !IsInteger(parts[1]) || !IsInteger(parts[2])
        return
    LF_ENABLED := Integer(parts[1]) ? 1 : 0
    LF_PING_MS := Min(2000, Max(30, Integer(parts[2])))
    IniWrite LF_ENABLED, INI, "LagFix", "Enabled"
    IniWrite LF_PING_MS, INI, "LagFix", "PingMs"
    if !LF_ENABLED
        for p in profiles
            if IsObject(LfState(p).reqCb) && !IsObject(LfState(p).rescue) {
                cb := LfState(p).reqCb
                LagFixCancelRequest(p)
                try cb(p, false)   ; 關掉功能：排隊中的請求視為沒完成，請求方照原規則處理
            }
    AddRecentEvent("🔄 變慢自動過圖：" (LF_ENABLED ? "開啟" : "關閉") "｜視窗回應 ≥ " LF_PING_MS " ms 視為變慢")
}

LagFixPushWeb() {
    global webReady, WVCore, profiles, LF_ENABLED, LF_PING_MS
    if !webReady || !WVCore
        return
    rows := ""
    for i, p in profiles {
        if !p.enabled
            continue
        st := LfState(p)
        if !p.pid || !ProfileGameAlive(p) {
            if !IsObject(st.rescue)
                continue
        }
        med := LfSlowMedian(p)
        text := st.text
        if IsObject(st.rescue)
            text := "待救援｜" text
        else if LfNow() < st.pauseUntil
            text := "暫停 " Ceil((st.pauseUntil - LfNow()) / 60000) " 分鐘｜" text
        rows .= (rows = "" ? "" : ",") '{"index":' i ',"name":"' JsonEscapeWeb(p.name) '","med":' (med = "" ? "null" : Round(med, 1)) ',"text":"' JsonEscapeWeb(text) '","runs":' st.runs '}'
    }
    try WVCore.PostWebMessageAsJson('{"type":"lagfix","data":{"enabled":' (LF_ENABLED ? "true" : "false") ',"pingMs":' LF_PING_MS ',"rows":[' rows ']}}')
}
