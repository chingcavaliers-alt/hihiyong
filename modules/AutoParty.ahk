; ============================================================================
; H-018 自動組隊：全部角色登入完成後，由「隊長」把設定好的隊員邀進隊伍（工具 → 🤝 自動組隊）。
; 做法（和手動一樣）：隊長視窗按 F 開好友名單 → 點隊員那一列 → 按「組隊」→ 確認；
;   隊員視窗跳出邀請 → 按 Enter。遊戲不接受背景按鍵與滑鼠，所以每次都要把視窗切到前面，做完切回原本的視窗。
; 每一步都先讀遊戲記憶體確認才做下一步（不盲按）：
;   - 好友名單用「角色 ID」找那一列（名單依上線狀態排序，位置會變；畫面文字的字型也和資料不同）。
;   - 點完確認選到的是那個人，再按「組隊」；確認視窗跳出才按確認；隊員收到邀請才按 Enter；
;   - 最後讀隊伍資料確認隊員真的進來了。任何一步對不上就停手，不再按下一個鍵。
; 規則：隊員已在別人的隊伍 / 離線 / 不在好友名單 / 還沒登入完成 → 跳過並通知（不會叫對方退隊）。
; 重新登入、換每日道具、背包清理、命運箱子、示範錄製、輪流切換視窗執行中、緊急停止、你正在操作電腦時不動作。
; ============================================================================

global AP_ENABLED := Integer(IniRead(INI, "AutoParty", "Enabled", "0"))
; 鍵盤滑鼠要停這麼多秒才切視窗；全部登入完成後再等 SETTLE 秒才開始邀請
global AP_IDLE_SEC := Max(0, Integer(IniRead(INI, "AutoParty", "IdleSec", "5")))
global AP_SETTLE_SEC := Max(0, Integer(IniRead(INI, "AutoParty", "SettleSec", "30")))
global AP_RETRY_SEC := 60, AP_GIVEUP_SEC := 600, AP_MAX_TRIES := 3, AP_STEP_MS := 2500, AP_INVITE_EXTRA_MS := 1500, AP_RECHECK_SEC := 15, AP_OWN_GRACE_MS := 150
global apLastActive := 0, apManualAt := 0, AP_MANUAL_TTL_MS := 60000
; 遠端隊員：送出邀請後最多等這麼久看對方有沒有加入；接受邀請失敗 / 不符合條件後，這麼久內不再試同一個角色
global AP_REMOTE_WAIT_MS := 15000, AP_ACCEPT_BACKOFF_MS := 30000, apAcceptPeekAt := 0
global apBusy := false, apManual := 0, apSettleSince := 0, apLastOwn := 0, apRunStart := 0
; 一輪最長時間（隊員很多時不能一直佔用前景）；手動「立即組隊」要先放開鍵盤滑鼠這麼久才開始；遊戲畫面的設計大小
global AP_RUN_MAX_MS := 120000, AP_MANUAL_IDLE_MS := 1500, AP_DESIGN_W := 1024, AP_DESIGN_H := 768
; 測試用：設成物件時，讀記憶體 / 切視窗 / 按鍵 / 點擊都交給它（不動真正的遊戲、視窗與鍵盤）。
global apTestDriver := 0
global apIdleMs := () => A_TimeIdlePhysical

ApIsLeader(p) => p.HasOwnProp("partyLeader") && p.partyLeader
; 「名稱1|名稱2」→ 陣列
ApMemberNames(p) {
    out := []
    if !p.HasOwnProp("partyMembers")
        return out
    for n in StrSplit(p.partyMembers, "|") {
        n := Trim(n)
        if n != ""
            out.Push(n)
    }
    return out
}
; 「遠端隊員」：在另一台電腦上的角色（遊戲內角色名稱）。隊長這台只負責送邀請，對方那台自己接受（見 ApAcceptTick）。
; 名單的分隔符號：| , ， 、 ; ； 或換行都可以（存檔時統一成 |）。名字裡的空白不當分隔，避免名字被切開。
ApSplitNames(raw) {
    out := []
    for n in StrSplit(RegExReplace(raw, "[,，、;；`r`n]", "|"), "|") {
        n := Trim(n)
        if n != ""
            out.Push(n)
    }
    return out
}
ApRemoteNames(p) => p.HasOwnProp("partyRemote") ? ApSplitNames(p.partyRemote) : []
ApAcceptFromNames(p) => p.HasOwnProp("partyAcceptFrom") ? ApSplitNames(p.partyAcceptFrom) : []
ApHasName(list, name) {
    for n in list
        if n = name
            return true
    return false
}
; 這個角色是不是正在這台電腦上執行（有遊戲視窗）。兩台電腦共用同一份角色清單時，另一台跑的角色在這台只是「沒開」。
ApRunsLocally(q) => q.enabled && q.pid && ProfileGameAlive(q)
; 這個遊戲內角色名稱是不是這台電腦上正在執行的角色（線上讀到的名稱；記錄的舊名稱可能是別台電腦留下的，不算）。
ApIsLocalChar(name) {
    global profiles
    for q in profiles {
        if ApRunsLocally(q) {
            cn := ""
            try cn := ApCharName(q.pid)
            if cn = name
                return true
        }
    }
    return false
}
ApProfileByName(name) {
    global profiles
    for p in profiles
        if p.name = name
            return p
    return 0
}

; ---------------------------------------------------------------- 狀態判斷
; 現在不能動的原因，不含「使用者正在操作」（空字串 = 可以）。
ApBlockerRaw() {
    global abortRequested, emergencyStop, processingQueue, activeRecoveryHwnd, foregroundOwner, dailyRunning, recorder
    global autoSwitchRunning, setupMode, invRunning, fastLoginCritical, asyncLoadingEntries, recoveryQueue, profiles
    if abortRequested || emergencyStop
        return "自動化已停止"
    if processingQueue || activeRecoveryHwnd || fastLoginCritical || recoveryQueue.Length
        return "重新登入中"
    try if asyncLoadingEntries.Count
        return "有角色正在載入"
    for p in profiles
        if p.enabled && (p.state = "排隊中" || p.state = "載入中" || p.state = "恢復中")
            return "有角色還沒登入完成"
    if dailyRunning != ""
        return "更換每日道具中"
    if invRunning
        return "背包清理中"
    if foregroundOwner != "" && foregroundOwner != "party"
        return "其他功能正在操作遊戲視窗"
    if IsObject(recorder)
        return "示範錄製中"
    if autoSwitchRunning
        return "「遊戲視窗自動切換」執行中（兩個一起用會互搶視窗，請先停止輪流切換）"
    if setupMode
        return "座標設定中"
    return ""
}

ApBlocker() {
    global AP_IDLE_SEC, apIdleMs
    why := ApBlockerRaw()
    if why != ""
        return why
    if apIdleMs() < AP_IDLE_SEC * 1000
        return "等你停止操作鍵盤滑鼠 " AP_IDLE_SEC " 秒"
    return ""
}

; 這個角色是否真的在遊戲世界裡、可以操作（選角畫面、死亡中都不算）。
ApReady(p) {
    return p.enabled && p.pid && ProfileGameAlive(p) && p.state = "監控中"
        && GameOffsetsReady(p.pid) && GameInWorld(p.pid) && !(p.HasOwnProp("hpEventOpen") && p.hpEventOpen)
}

; 自己動作之後 0.15 秒內的「鍵鼠閒置時間變短」不算使用者操作；每一輪開始時也先算一次「自己的動作」。
ApUserActive() {
    global apIdleMs, apLastOwn, AP_OWN_GRACE_MS
    sinceOwn := apLastOwn ? A_TickCount - apLastOwn : 99999
    return apIdleMs() + AP_OWN_GRACE_MS < sinceOwn   ; 我們最後一次動作之後有任何鍵鼠輸入（不限多久以前）
}

; ---------------------------------------------------------------- 讀遊戲記憶體（測試時交給 apTestDriver）
; 這個遊戲版本有沒有隊伍 / 好友 / 介面的位置（resolve_game_offsets.py v14；解析失敗時整組沒有）。
ApReadable(pid) {
    global apTestDriver
    if IsObject(apTestDriver)
        return apTestDriver.Readable(pid)
    return GameOffsetsReady(pid) && GameOffset("PartyInstanceRva") && GameOffset("FriendInstanceRva") && GameOffset("InnerInterfaceRva") ? true : false
}
ApCharName(pid) {
    global apTestDriver
    if IsObject(apTestDriver)
        return apTestDriver.CharName(pid)
    return ReadGameCharName(pid)
}
; 隊伍：{id（沒有隊伍 = -1）, leader, members:[名字…]}；讀不到回傳 0。隊長本人不在 members 裡。
ApParty(pid) {
    global apTestDriver
    if IsObject(apTestDriver)
        return apTestDriver.Party(pid)
    return ApRealParty(pid)
}
; 好友：{id, online}；不在名單裡回傳 ""；讀不到回傳 0。
ApFriendFind(pid, name) {
    global apTestDriver
    if IsObject(apTestDriver)
        return apTestDriver.FriendFind(pid, name)
    return ApRealFriendFind(pid, name)
}
; 介面：{friendOpen, selIndex, selId, rows:[{id,index,vis,x,y}], partyBtn:{x,y}|0, modalOpen, modalText, okBtn:{x,y}|0}；讀不到回傳 0。
; 座標是遊戲畫面（Client）內的像素。
ApUi(pid) {
    global apTestDriver
    if IsObject(apTestDriver)
        return apTestDriver.Ui(pid)
    return ApRealUi(pid)
}

ApModule(pid) {
    h := GameProcHandle(pid)
    base := h ? GetGameModuleBase(pid, h) : 0
    return base ? {h: h, addr: base} : 0   ; （屬性不能叫 base：那是 AHK 物件的保留屬性）
}
ApPtr(h, addr) {
    v := GameReadNum(h, addr, "Ptr")
    return v = "" ? 0 : v
}
; 有號 32 位元整數（GameReadNum 只有無號）；讀不到回傳 ""。
ApI32(h, addr) {
    v := GameReadNum(h, addr, "UInt")
    return v = "" ? "" : (v >= 0x80000000 ? v - 0x100000000 : v)
}
ApByte(h, addr) {
    b := GameReadBuf(h, addr, 1)
    return b ? NumGet(b, 0, "UChar") : ""
}
; 以 0 結尾的字串。字串剛好在記憶體頁尾端時一次讀太多會整個失敗，所以失敗就改讀短一點。
ApCStr(h, addr, n := 64) {
    for sz in [n, 32, 16, 8] {
        if sz > n
            continue
        b := GameReadBuf(h, addr, sz)
        if b {
            s := StrGet(b, sz, "CP950")
            RegExMatch(s, "^[^\x00]*", &m)   ; 取到第一個 0 為止（InStr(s, Chr(0)) 會把 Chr(0) 當成空字串，不能用）
            return Trim(m[0])
        }
    }
    return ""
}
ApRectAt(h, addr) {
    buf := GameReadBuf(h, addr, 16)   ; UIRECT：left, right, top, bottom（float）
    if !buf
        return 0
    l := NumGet(buf, 0, "Float"), rt := NumGet(buf, 4, "Float"), t := NumGet(buf, 8, "Float"), bt := NumGet(buf, 12, "Float")
    for v in [l, rt, t, bt]
        if !IsNumber(v) || v != v || Abs(v) > 5000   ; NaN（NaN != NaN）/ 無限大 / 垃圾值：不能拿去算要點的座標
            return 0
    if rt < l || bt < t
        return 0
    return {l: l, r: rt, t: t, b: bt}
}
ApCenter(r) => {x: Round((r.l + r.r) / 2), y: Round((r.t + r.b) / 2)}
ApVisible(h, ctl) => GameReadNum(h, ctl + GameOffset("UiVisibleOffset"), "UInt") = 1
ApVftableOk(rva) {
    global gameOffsets
    for s in StrSplit(gameOffsets.Get("InnerInterfaceVftableRvas", ""), "|")
        if s != "" && Integer(s) = rva
            return true
    return false
}

ApRealParty(pid) {
    m := ApModule(pid)
    if !m || !GameOffset("PartyInstanceRva")
        return 0
    h := m.h, pc := m.addr + GameOffset("PartyInstanceRva")
    id := GameReadNum(h, pc + GameOffset("PartyIdOffset"), "UInt")
    if id = ""
        return 0
    res := {id: id = 0xFFFFFFFF ? -1 : id, leader: "", members: []}
    if res.id = -1
        return res
    res.leader := ApCStr(h, pc + GameOffset("PartyMasterOffset") + GameOffset("PartyMemberNameOffset"), 34)
    vecAt := pc + GameOffset("PartyMapOffset")
    vb := GameReadNum(h, vecAt, "Ptr"), ve := GameReadNum(h, vecAt + 8, "Ptr"), sz := GameOffset("PartyEntrySize")
    if vb = "" || ve = "" || !sz || ve < vb || (ve - vb) > sz * 16
        return 0
    e := vb
    while e < ve {
        res.members.Push(ApCStr(h, e + GameOffset("PartyEntryDataOffset") + GameOffset("PartyMemberNameOffset"), 34))
        e += sz
    }
    return res
}

; std::map<std::string, SFRIEND> 依名字排序：節點 +0x19 isnil、+0x20 key、+0x40 SFRIEND。
ApRealFriendFind(pid, name) {
    global STDMAP_STR_KEY, STDMAP_STR_VALUE
    m := ApModule(pid)
    if !m || !GameOffset("FriendInstanceRva")
        return 0
    h := m.h, mapAt := m.addr + GameOffset("FriendInstanceRva") + GameOffset("FriendMapOffset")
    head := GameReadNum(h, mapAt, "Ptr"), cnt := GameReadNum(h, mapAt + 8, "Ptr")
    if !head || cnt = "" || cnt > 600
        return 0
    if cnt = 0
        return ""
    stack := [ApPtr(h, head + 8)], seen := 0
    while stack.Length && seen < 700 {
        node := stack.Pop()
        if !node
            continue
        nb := GameReadBuf(h, node, 0x80)
        if !nb || NumGet(nb, 0x19, "UChar")
            continue
        seen += 1
        if ReadStdString(h, node + STDMAP_STR_KEY, "CP950") = name
            return {id: NumGet(nb, STDMAP_STR_VALUE + GameOffset("FriendCharIdOffset"), "UInt")
                , online: NumGet(nb, STDMAP_STR_VALUE + GameOffset("FriendOnlineOffset"), "UChar") != 0}
        stack.Push(NumGet(nb, 0, "Ptr")), stack.Push(NumGet(nb, 0x10, "Ptr"))
    }
    return ""
}

; MSVC std::deque（元素比 8 位元組大時每塊 1 個元素）：+8 _Map、+0x10 _Mapsize、+0x18 _Myoff、+0x20 _Mysize。
ApDequeAt(h, dq, i) {
    map := GameReadNum(h, dq + 0x8, "Ptr"), msz := GameReadNum(h, dq + 0x10, "Ptr"), off := GameReadNum(h, dq + 0x18, "Ptr")
    if !map || !msz || off = ""
        return 0
    return ApPtr(h, map + Mod(off + i, msz) * 8)
}

; 文字框 → {parts:[{data, text, rect}], visible, cur}；讀不到回傳 0。
ApReadTextBox(h, tb, maxParts := 60) {
    dq := tb + GameOffset("TextBoxPartsOffset")   ; （避免和物件的 base 屬性混淆）
    cnt := GameReadNum(h, dq + 0x20, "Ptr")
    if cnt = "" || cnt > 400
        return 0
    wsz := GameOffset("TextWordSize"), linesAt := GameOffset("TextPartLinesOffset"), wordsAt := GameOffset("TextLineWordsOffset")
    parts := []
    Loop Min(cnt, maxParts) {
        part := ApDequeAt(h, dq, A_Index - 1)
        if !part
            break
        text := ""
        lines := GameReadNum(h, part + linesAt + 0x20, "Ptr")
        Loop Min(lines = "" ? 0 : lines, 4) {
            ln := ApDequeAt(h, part + linesAt, A_Index - 1)
            wb := ln ? GameReadNum(h, ln + wordsAt, "Ptr") : 0
            we := ln ? GameReadNum(h, ln + wordsAt + 8, "Ptr") : 0
            if !wb || we = "" || we < wb || !wsz || (we - wb) > wsz * 32
                continue
            w := wb
            while w < we {
                sp := ApPtr(h, w + GameOffset("TextWordStrOffset"))
                text .= sp ? ApCStr(h, sp, 96) : ""
                w += wsz
            }
        }
        parts.Push({data: GameReadNum(h, part + GameOffset("TextPartDataOffset"), "Int64"), text: text
            , rect: ApRectAt(h, part + GameOffset("TextPartRectOffset"))})
    }
    vis := ApI32(h, tb + GameOffset("TextBoxVisibleLineOffset")), cur := ApI32(h, tb + GameOffset("TextBoxCurLineOffset"))
    return {parts: parts, visible: vis = "" ? 0 : vis, cur: cur = "" ? 0 : cur}
}

ApRealUi(pid) {
    m := ApModule(pid)
    if !m || !GameOffset("InnerInterfaceRva")
        return 0
    h := m.h, inner := m.addr + GameOffset("InnerInterfaceRva")
    vf := GameReadNum(h, inner, "Ptr")
    if vf = "" || !ApVftableOk(vf - m.addr)
        return 0
    ui := {friendOpen: false, selIndex: -1, selId: 0, rows: [], partyBtn: 0, modalOpen: false, modalText: "", okBtn: 0}
    fw := ApPtr(h, inner + GameOffset("InnerFriendWindowOffset"))
    if fw && GameReadNum(h, fw + GameOffset("UiVisibleOffset"), "UInt") = 1 {
        page := ApPtr(h, fw + GameOffset("FriendWindowPageOffset"))
        lst := page ? ApPtr(h, page + GameOffset("FriendPageListOffset")) : 0
        tb := lst ? ApReadTextBox(h, lst) : 0
        if !IsObject(tb)
            return 0
        ui.friendOpen := true
        ui.selIndex := ApI32(h, page + GameOffset("FriendPageSelectOffset"))
        ui.selId := GameReadNum(h, page + GameOffset("FriendPageCharIdOffset"), "UInt")   ; 無號 32 位元（和好友 ID 同型別）
        area := ApRectAt(h, lst + GameOffset("UiRectOffset"))
        for i, part in tb.parts {
            r := part.rect
            vis := IsObject(r) && IsObject(area) && i - 1 >= tb.cur && i - 1 < tb.cur + tb.visible
                && r.t >= area.t - 1 && r.b <= area.b + 1
            c := IsObject(r) ? ApCenter(r) : {x: 0, y: 0}
            ui.rows.Push({id: IsInteger(part.data) ? part.data & 0xFFFFFFFF : -1, index: i - 1, vis: vis, x: c.x, y: c.y})
        }
        btn := ApPtr(h, page + GameOffset("FriendPagePartyBtnOffset"))
        br := btn ? ApRectAt(h, btn + GameOffset("UiRectOffset")) : 0
        ui.partyBtn := IsObject(br) && ApVisible(h, btn) ? ApCenter(br) : 0   ; 按鈕自己也要是「可見」才點
    }
    md := ApPtr(h, inner + GameOffset("InnerPartyModalOffset"))
    if md && GameReadNum(h, md + GameOffset("UiVisibleOffset"), "UInt") = 1 {
        ui.modalOpen := true
        tbm := ApPtr(h, md + GameOffset("PartyModalTextOffset"))
        mt := tbm ? ApReadTextBox(h, tbm, 6) : 0
        if IsObject(mt)
            for part in mt.parts
                ui.modalText .= part.text
        ok := ApPtr(h, md + GameOffset("PartyModalOkOffset"))
        okr := ok ? ApRectAt(h, ok + GameOffset("UiRectOffset")) : 0
        ui.okBtn := IsObject(okr) && ApVisible(h, ok) ? ApCenter(okr) : 0
    }
    return ui
}

; ---------------------------------------------------------------- 視窗 / 按鍵 / 滑鼠（測試時交給 apTestDriver）
ApForeground() {
    global apTestDriver
    if IsObject(apTestDriver)
        return apTestDriver.Foreground()
    try return WinGetID("A")
    return 0
}
ApIsActive(p) {
    global apTestDriver
    if IsObject(apTestDriver)
        return apTestDriver.Foreground() = p.hwnd
    return WinActive("ahk_id " p.hwnd) != 0
}
ApIsMinimized(p) {
    global apTestDriver
    if IsObject(apTestDriver)
        return apTestDriver.IsMinimized(p)
    return WinGetMinMax("ahk_id " p.hwnd) = -1
}
; 最小化的遊戲視窗不會更新畫面（收不到邀請視窗）：先還原（不搶焦點），做完再縮回去。
ApUnminimize(p) {
    global apTestDriver, apLastOwn
    if IsObject(apTestDriver)
        return apTestDriver.Unminimize(p)
    DllCall("ShowWindow", "Ptr", p.hwnd, "Int", 4)   ; SW_SHOWNOACTIVATE
    apLastOwn := A_TickCount
}
ApMinimize(p) {
    global apTestDriver, apLastOwn
    if IsObject(apTestDriver)
        return apTestDriver.Minimize(p)
    DllCall("ShowWindow", "Ptr", p.hwnd, "Int", 7)   ; SW_SHOWMINNOACTIVE
    apLastOwn := A_TickCount
}
ApActivate(p) {
    global apTestDriver, apLastOwn, apLastActive
    ApGuardAny()   ; 切換視窗本身也是一個動作：停止鍵 / 其他功能 / 使用者操作 / 時間上限
    if IsObject(apTestDriver) {
        ok := apTestDriver.Activate(p)
        if ok
            apLastActive := p.hwnd
        return ok
    }
    if WinGetMinMax("ahk_id " p.hwnd) = -1
        WinRestore "ahk_id " p.hwnd
    WinActivate "ahk_id " p.hwnd
    ok := WinWaitActive("ahk_id " p.hwnd, , 2)
    Sleep 150   ; 遊戲剛拿到焦點時第一個按鍵 / 點擊偶爾收不到
    apLastOwn := A_TickCount   ; WinActivate 切不過去時 AHK 會自己送 Alt 鍵：那不是使用者
    apLastActive := p.hwnd
    return ok ? true : false
}
ApRestoreFocus(hwnd) {
    global apTestDriver, apLastOwn
    if IsObject(apTestDriver)
        return apTestDriver.Restore(hwnd)
    if hwnd && WinExist("ahk_id " hwnd) {
        try WinActivate "ahk_id " hwnd
        apLastOwn := A_TickCount
    }
}
ApCursor() {
    global apTestDriver
    if IsObject(apTestDriver)
        return 0
    ; 螢幕座標（可能是負數：副螢幕在左邊）。不用 MouseGetPos：它預設回傳「相對於作用中視窗」的座標，
    ; 拿去 SetCursorPos 會跑到錯的地方（實機測試時發現滑鼠沒有還原）。
    pt := Buffer(8, 0)
    DllCall("GetCursorPos", "Ptr", pt)
    return {x: NumGet(pt, 0, "Int"), y: NumGet(pt, 4, "Int")}
}
ApMoveCursorBack(c) {
    if IsObject(c)
        DllCall("SetCursorPos", "Int", c.x, "Int", c.y)
}

; 每個動作之前：停止鍵、其他功能開始動作、使用者開始操作 → 丟出 stop 錯誤中止整輪。
ApStop(msg) {
    throw Error(msg, , "stop")
}
ApGuardAny() {
    global abortRequested, emergencyStop, apRunStart, AP_RUN_MAX_MS
    if abortRequested || emergencyStop
        ApStop("已按停止")
    why := ApBlockerRaw()
    if why != ""
        ApStop("中途有其他動作開始：" why)
    if ApUserActive()
        ApStop("你開始操作電腦，先暫停")
    if apRunStart && A_TickCount - apRunStart > AP_RUN_MAX_MS
        ApStop("這一輪超過 " Round(AP_RUN_MAX_MS / 1000) " 秒，先停")
}
ApGuard(p) {
    ApGuardAny()
    if !ApIsActive(p)
        ApStop(p.name " 的視窗不在前面")
}

; 按一個鍵（按住 70 毫秒；實測遊戲接得到）。
ApKey(p, k) {
    global apTestDriver, apLastOwn
    Critical "On"
    try {
        ApGuard(p)
        if IsObject(apTestDriver)
            apTestDriver.Key(p, k)
        else {
            Send "{" k " down}"
            apLastOwn := A_TickCount
            Sleep 70
            Send "{" k " up}"
        }
    } finally {
        Critical "Off"
    }
    apLastOwn := A_TickCount
}

; 在遊戲畫面（Client）座標 x,y 點一下（實測可用：先靠近再移上去，按住 90 毫秒）。
ApClick(p, x, y) {
    global apTestDriver, apLastOwn, AP_DESIGN_W, AP_DESIGN_H
    Critical "On"
    try {
        ApGuard(p)
        if IsObject(apTestDriver)
            apTestDriver.Click(p, x, y)
        else {
            if !IsNumber(x) || !IsNumber(y)
                ApStop("要點的座標不是數字")
            ; 遊戲畫面的座標是 1024x768 的；Windows 顯示縮放不是 100% 時畫面像素會等比例放大，要換算
            WinGetClientPos(&cx, &cy, &cw, &ch, "ahk_id " p.hwnd)
            sx := cw / AP_DESIGN_W, sy := ch / AP_DESIGN_H
            dpi := A_ScreenDPI / 96   ; 遊戲畫面本身一定要是 1024x768（顯示縮放不是 100% 時等比例放大）；別的解析度座標會對不上，不點
            if Abs(cw - AP_DESIGN_W * dpi) > 4 || Abs(ch - AP_DESIGN_H * dpi) > 4
                ApStop(p.name " 的遊戲畫面不是 1024x768（" cw "x" ch "，顯示縮放 " Round(dpi * 100) "%）")
            if x < 0 || x >= AP_DESIGN_W || y < 0 || y >= AP_DESIGN_H
                ApStop("要點的座標超出遊戲畫面（" x "," y "）")
            px := cx + Round(x * sx), py := cy + Round(y * sy)
            DllCall("SetCursorPos", "Int", px - 6, "Int", py - 3)
            apLastOwn := A_TickCount
            Sleep 80
            DllCall("SetCursorPos", "Int", px, "Int", py)
            apLastOwn := A_TickCount
            Sleep 150
            ; 按下去之前最後確認一次：視窗還在前面、游標真的在目標位置、游標下面的視窗就是這個遊戲視窗
            ApGuard(p)
            if !ApCursorOn(p, px, py)
                ApStop("游標不在預期位置，或游標下面不是 " p.name " 的遊戲視窗（被別的視窗蓋住？）")
            DllCall("mouse_event", "UInt", 0x0002, "Int", 0, "Int", 0, "UInt", 0, "UPtr", 0)
            Sleep 90
            DllCall("mouse_event", "UInt", 0x0004, "Int", 0, "Int", 0, "UInt", 0, "UPtr", 0)
        }
    } finally {
        Critical "Off"
    }
    apLastOwn := A_TickCount
}

; 游標現在在 (px,py)，而且那一點最上層的視窗屬於這個遊戲視窗。
ApCursorOn(p, px, py) {
    pt := Buffer(8, 0)
    DllCall("GetCursorPos", "Ptr", pt)
    cx := NumGet(pt, 0, "Int"), cy := NumGet(pt, 4, "Int")
    if Abs(cx - px) > 2 || Abs(cy - py) > 2
        return false
    hw := DllCall("WindowFromPoint", "Int64", (cy << 32) | (cx & 0xFFFFFFFF), "Ptr")
    return hw && DllCall("GetAncestor", "Ptr", hw, "UInt", 2, "Ptr") = p.hwnd   ; GA_ROOT
}

; 條件成立才算過關：每 0.1 秒看一次，最多等 ms 毫秒。
ApWait(fn, ms := 0) {
    global AP_STEP_MS, abortRequested
    ms := ms ? ms : AP_STEP_MS
    start := A_TickCount
    Loop {
        if fn()
            return true
        if abortRequested
            ApStop("已按停止")   ; 等的時候按停止 = 中止整輪，不是「這個人失敗」
        if A_TickCount - start >= ms
            return false
        Sleep 100
    }
}

; ---------------------------------------------------------------- 規劃：誰要被邀請
; 回傳 {todo:[隊員角色…], notes:[{key,text}…], inParty:數量, total:設定的隊員數}；讀不到時 err 不是空字串。
ApPlan(leader) {
    res := {todo: [], notes: [], inParty: 0, total: 0, err: ""}
    if !ApReadable(leader.pid) {
        res.err := "這個遊戲版本讀不到隊伍 / 好友資料（等管理程式重新解析遊戲位置）"
        return res
    }
    if !ApReady(leader) {
        res.err := leader.name " 還沒登入完成或正在死亡中"
        return res
    }
    own := ApCharName(leader.pid)
    lp := ApParty(leader.pid)
    if !IsObject(lp) || own = "" {
        res.err := "讀不到 " leader.name " 的隊伍資料"
        return res
    }
    if lp.id != -1 && lp.leader != own {
        res.err := leader.name " 目前在「" lp.leader "」的隊伍裡，不能邀請別人"
        return res
    }
    remoteNames := ApRemoteNames(leader)
    for name in ApMemberNames(leader) {
        mp := ApProfileByName(name)
        ; 同一個名字也填在「另一台電腦的角色」、而且它不在這台電腦上執行：交給遠端那段處理，這裡不當成沒登入完成
        if mp && mp != leader && ApHasName(remoteNames, name) && !ApRunsLocally(mp)
            continue
        if !mp || mp = leader {
            res.notes.Push({key: "missing|" name, text: "設定的隊員「" name "」不在角色清單裡"})
            continue
        }
        res.total += 1
        if !ApReady(mp) || !ApReadable(mp.pid) {
            res.notes.Push({key: "notready|" name, text: name " 還沒登入完成，等它好了再邀", soft: true})
            continue
        }
        mparty := ApParty(mp.pid)
        if !IsObject(mparty) {
            res.notes.Push({key: "unread|" name, text: "讀不到 " name " 的隊伍資料"})
            continue
        }
        if mparty.id != -1 {
            if lp.id != -1 && mparty.id = lp.id
                res.inParty += 1
            else
                res.notes.Push({key: "other|" name, text: name " 已經在「" mparty.leader "」的隊伍裡，跳過（不會叫它退隊）"})
            continue
        }
        res.todo.Push(mp)
    }
    ; 遠端隊員：不在這台電腦上，讀不到對方的資料；上線與否看隊長自己的好友名單，加入與否看隊長自己的隊伍名單。
    for name in remoteNames {
        lq := ApProfileByName(name)
        if name = own || (lq && ApRunsLocally(lq)) || ApIsLocalChar(name) {
            res.notes.Push({key: "remotedup|" name, text: "遠端隊員「" name "」和本機角色或隊長自己重複，跳過"})
            continue
        }
        res.total += 1
        if lp.id != -1 && ApHasName(lp.members, name) {
            res.inParty += 1
            continue
        }
        res.todo.Push({name: name, remote: true, pid: 0})
    }
    return res
}

; ---------------------------------------------------------------- 主迴圈
ApTick() {
    global profiles, AP_ENABLED, AP_SETTLE_SEC, AP_IDLE_SEC, AP_MANUAL_IDLE_MS, AP_MANUAL_TTL_MS, apBusy, apManual, apManualAt, apSettleSince, apIdleMs
    if !AP_ENABLED || apBusy
        return
    leaders := []
    for i, p in profiles
        if p.enabled && ApIsLeader(p) && (ApMemberNames(p).Length || ApRemoteNames(p).Length)
            leaders.Push(i)
    if !leaders.Length {
        apManual := 0
        return
    }
    if apManual && A_TickCount - apManualAt > AP_MANUAL_TTL_MS
        apManual := 0   ; 請求超過 60 秒沒執行（一直被擋住）就作廢，不要等很久之後才突然開始
    manual := apManual   ; 請求先留著：被擋住或使用者還沒放開滑鼠時，不能把它吃掉
    why := ApBlockerRaw()
    if why != "" {
        apSettleSince := 0
        for i in leaders
            profiles[i].partyStatus := "等待中：" why
        return
    }
    if !apSettleSince
        apSettleSince := A_TickCount
    if manual {
        ; 手動：不等 SETTLE，閒置只要 1.5 秒（按按鈕的人剛放開滑鼠）；進行中的使用者偵測照常
        if apIdleMs() < AP_MANUAL_IDLE_MS {
            for i in leaders
                profiles[i].partyStatus := "請放開鍵盤滑鼠，" Round(AP_MANUAL_IDLE_MS / 1000, 1) " 秒後開始"
            return
        }
        apManual := 0
    } else {
        ; 全部登入完成（上面沒有任何重新登入 / 載入）後，再等 SETTLE 秒才開始
        if A_TickCount - apSettleSince < AP_SETTLE_SEC * 1000 {
            for i in leaders
                profiles[i].partyStatus := "全部登入完成，再等 " Ceil((AP_SETTLE_SEC * 1000 - (A_TickCount - apSettleSince)) / 1000) " 秒開始"
            return
        }
        if apIdleMs() < AP_IDLE_SEC * 1000 {
            for i in leaders
                profiles[i].partyStatus := "等你停止操作鍵盤滑鼠 " AP_IDLE_SEC " 秒"
            return
        }
    }
    pick := 0, now := A_TickCount
    if manual && profiles.Has(manual) && ApIsLeader(profiles[manual])
        pick := manual
    else
        for i in leaders {
            at := profiles[i].HasOwnProp("partyCheckAt") ? profiles[i].partyCheckAt : 0
            if at <= now {
                pick := i
                break
            }
        }
    if pick
        ApRun(pick, pick = manual)
}

; 提示去重：同一件事（同一個 key + 同樣文字）只提示一次；狀況改變才再提示。
ApNote(p, k, text, discord := false) {
    if !p.HasOwnProp("partyNoted")
        p.partyNoted := Map()
    if p.partyNoted.Get(k, "") = text
        return
    p.partyNoted[k] := text
    EventLog(p.name, "PARTY_NOTE", text)
    AddRecentEvent("🤝 " p.name "：" text)
    if discord
        try SendDiscordMessage("⚠️ HIHIYONG 自動組隊：" p.name "｜" text)
}

; 一位隊長做一輪：規劃 → 切視窗邀請每個人 → 切回原本的視窗。
ApRun(idx, manual := false) {
    global profiles, apBusy, foregroundOwner, apRunStart, apLastOwn, AP_RECHECK_SEC, AP_REMOTE_WAIT_MS
    p := profiles[idx]
    apBusy := true, foregroundOwner := "party", apRunStart := A_TickCount, apLastOwn := A_TickCount
    prev := 0, cursor := 0, opened := false, minimized := [], stopped := false
    if !p.HasOwnProp("partyTries")
        p.partyTries := Map(), p.partyWait := Map()
    try {
        plan := ApPlan(p)
        if plan.err != "" {
            p.partyStatus := "⚠ " plan.err, p.partyCheckAt := A_TickCount + AP_RECHECK_SEC * 1000
            return
        }
        for n in plan.notes
            ApNote(p, n.key, n.text)
        ; 冷卻中的先不邀（手動「立即組隊」不受冷卻限制）
        todo := []
        for mp in plan.todo
            if manual || p.partyWait.Get(mp.name, 0) <= A_TickCount
                todo.Push(mp)
        if !todo.Length {
            p.partyCheckAt := A_TickCount + AP_RECHECK_SEC * 1000
            p.partyStatus := plan.todo.Length ? "⏳ 等下一次重試" : ApSummary(plan)
            return
        }
        prev := ApForeground()
        cursor := ApCursor()
        if ApIsMinimized(p)
            minimized.Push(p)   ; 隊長視窗原本是最小化的：做完縮回去
        done := 0, failed := 0, sent := []
        for mp in todo {
            try {
                r := ApInviteOne(p, mp, &opened, &minimized)
            } catch as e {
                if e.Extra = "stop" {
                    stopped := true
                    p.partyStatus := "⏸ " e.Message "（稍後再試）", p.partyCheckAt := A_TickCount + 20000
                    EventLog(p.name, "PARTY_STOP", e.Message)
                    if mp.HasOwnProp("sentAt")
                        sent.Push(mp)
                    ApHoldSent(p, sent)
                    return
                }
                r := "fail|" e.Message
            }
            if r = "sent" {
                sent.Push(mp)   ; 遠端隊員：邀請已送出，等對方那台接受，最後一起確認
                continue
            }
            k := ApApplyResult(p, mp, r)
            if k = 1
                done += 1
            else if k = 2
                failed += 1
        }
        if sent.Length {
            try {
                ; 等的時候也要照守門規則：使用者開始操作 / 其他功能開始 / 按停止就中止
                ApWait(() => (ApGuardAny(), ApAllInParty(p, sent)), AP_REMOTE_WAIT_MS)
            } catch as e {
                if e.Extra != "stop"
                    throw e
                stopped := true
                p.partyStatus := "⏸ " e.Message "（稍後再試）", p.partyCheckAt := A_TickCount + 20000
                EventLog(p.name, "PARTY_STOP", e.Message)
                ApHoldSent(p, sent)
                return
            }
            lp := ApParty(p.pid)
            if !IsObject(lp) {
                Sleep 300
                lp := ApParty(p.pid)   ; 剛好讀失敗一次不能算所有人都沒加入
            }
            if !IsObject(lp) {
                for mp in sent
                    ApApplyResult(p, mp, "skip|讀不到隊伍資料，稍後再確認")
                p.partyCheckAt := A_TickCount + AP_RECHECK_SEC * 1000
                p.partyStatus := "⚠ 讀不到隊伍資料"
                return
            }
            for mp in sent {
                joined := IsObject(lp) && ApHasName(lp.members, mp.name)
                k := ApApplyResult(p, mp, joined ? "" : "fail|邀請已送出，" Round(AP_REMOTE_WAIT_MS / 1000) " 秒內對方沒有加入（對方那台要開著管理程式並勾選「自動接受邀請」，或手動按 Enter）")
                if k = 1
                    done += 1
                else if k = 2
                    failed += 1
            }
        }
        p.partyCheckAt := A_TickCount + AP_RECHECK_SEC * 1000
        p.partyStatus := (failed ? "⚠ " : "✓ ") FormatTime(, "HH:mm:ss") " 邀請 " todo.Length " 人：成功 " done "、失敗 " failed
    } catch as e {
        p.partyStatus := "⚠ " e.Message, p.partyCheckAt := A_TickCount + 30000
        EventLog(p.name, "PARTY_ERROR", e.Message)
    } finally {
        ApCleanup(p, opened, minimized, prev, cursor, stopped)
        foregroundOwner := "", apBusy := false, apRunStart := 0
    }
}

; 處理一個隊員的邀請結果。回傳 1＝已加入、2＝失敗（會重試）、0＝跳過。
ApApplyResult(p, mp, r) {
    global AP_RETRY_SEC, AP_GIVEUP_SEC, AP_MAX_TRIES
    if r = "" {
        ApMapDel(p.partyTries, mp.name), ApMapDel(p.partyWait, mp.name)
        if p.HasOwnProp("partyGaveUp")
            ApMapDel(p.partyGaveUp, mp.name)
        EventLog(p.name, "PARTY_JOIN", mp.name " 加入隊伍")
        AddRecentEvent("🤝 " p.name " 邀請 " mp.name "：已加入隊伍")
        if p.HasOwnProp("partyNoted")
            ApMapDel(p.partyNoted, "fail|" mp.name)
        return 1
    }
    if SubStr(r, 1, 9) = "skiplong|" {
        ; 會一直這樣的狀況（例如名單太長要捲動）：不要每分鐘開關好友視窗，隔很久再看
        ApNote(p, "skip|" mp.name, mp.name "：" SubStr(r, 10))
        p.partyWait[mp.name] := A_TickCount + AP_GIVEUP_SEC * 1000
        return 0
    }
    if SubStr(r, 1, 5) = "skip|" {
        ApNote(p, "skip|" mp.name, mp.name "：" SubStr(r, 6))
        p.partyWait[mp.name] := A_TickCount + AP_RETRY_SEC * 1000
        return 0
    }
    why := SubStr(r, 6)
    n := p.partyTries.Get(mp.name, 0) + 1
    p.partyTries[mp.name] := n
    EventLog(p.name, "PARTY_FAIL", mp.name "｜第 " n " 次｜" why)
    if n >= AP_MAX_TRIES {
        ApMapDel(p.partyTries, mp.name)
        ; 放棄之後休息的時間一次比一次長（最長 6 倍）：遠端隊員的隊伍狀態讀不到，對方一直接受不了時不要無限循環打擾
        if !p.HasOwnProp("partyGaveUp")
            p.partyGaveUp := Map()
        g := Min(6, p.partyGaveUp.Get(mp.name, 0) + 1)
        p.partyGaveUp[mp.name] := g
        p.partyWait[mp.name] := A_TickCount + AP_GIVEUP_SEC * 1000 * g
        ApNote(p, "fail|" mp.name, mp.name " 連續 " n " 次沒邀請成功：" why "（" Round(AP_GIVEUP_SEC * g / 60) " 分鐘後再試；可能隊伍滿了、對方已在別的隊伍或遊戲畫面有別的視窗擋住）", true)
    } else
        p.partyWait[mp.name] := A_TickCount + AP_RETRY_SEC * 1000
    return 2
}

; 已經送出邀請的遠端隊員：中途中止時也記下冷卻，不要稍後馬上又送一次。
ApHoldSent(p, sent) {
    global AP_RETRY_SEC
    for mp in sent
        p.partyWait[mp.name] := A_TickCount + AP_RETRY_SEC * 1000
}

; 遠端隊員是否都已經在隊長的隊伍裡。
ApAllInParty(p, list) {
    lp := ApParty(p.pid)
    if !IsObject(lp)
        return false
    for mp in list
        if !ApHasName(lp.members, mp.name)
            return false
    return true
}

ApSummary(plan) {
    if !plan.total
        return "沒有設定隊員"
    if plan.inParty >= plan.total
        return "✓ 隊員都在隊伍裡（" plan.inParty "/" plan.total "）"
    return "隊伍 " plan.inParty "/" plan.total "（其餘被跳過，見最近事件）"
}

; 收尾：自己開的好友視窗關掉、最小化的隊員縮回去、切回原本的視窗與滑鼠位置。
; 使用者正在操作時不再送鍵（只切回視窗）。
ApCleanup(p, opened, minimized, prev, cursor, stopped := false) {
    global apLastActive
    userBusy := false
    try userBusy := ApUserActive()
    ; 正常結束、而且你沒在操作：把自己開的好友視窗關掉（中止時、你在操作時都不再送鍵）
    if !stopped && !userBusy && opened {
        try {
            if !ApBlockerRaw() && ApActivate(p) {
                ui := ApUi(p.pid)
                if IsObject(ui) && ui.friendOpen && !ui.modalOpen {
                    ApKey(p, "f")
                    ; 按完要等遊戲處理（實機：按鍵後要下一個畫面才會關），確認真的關了才算收尾完成
                    if !ApWait(() => (u := ApUi(p.pid), !IsObject(u) || !u.friendOpen), 1500)
                        EventLog(p.name, "PARTY_NOTE", "收尾：好友視窗沒有關上")
                }
            }
        }
    }
    if !userBusy   ; 你在操作：不要把你剛點進去用的視窗縮小
        for mp in minimized
            try ApMinimize(mp)
    ; 切回原本的視窗。中止時只有「前景還是遊戲視窗」才切：你自己切去別處就不動你
    fg := 0
    try fg := ApForeground()
    if prev && fg != prev && (!stopped || (fg = apLastActive && !userBusy))
        try ApRestoreFocus(prev)
    if !stopped && !userBusy
        try ApMoveCursorBack(cursor)
}

ApIsGameWindow(hwnd) {
    global profiles
    for q in profiles
        if q.hwnd = hwnd
            return true
    return false
}

; 邀請一個人。回傳 ""＝已加入；"skip|原因"＝跳過；"fail|原因"＝失敗（會重試）。
; 中途遇到停止 / 其他功能開始 / 使用者操作會丟出 stop 錯誤。
ApInviteOne(L, M, &opened, &minimized) {
    global AP_STEP_MS
    remote := M.HasOwnProp("remote") && M.remote   ; 遠端隊員：只做隊長這一半
    name := remote ? M.name : ApCharName(M.pid)
    if name = ""
        return "fail|讀不到隊員的角色名稱"
    f := ApFriendFind(L.pid, name)
    if f = 0
        return "fail|讀不到好友名單"
    if f = ""
        return "skip|不在 " L.name " 的好友名單裡（要先加好友）"
    if !f.online
        return "skip|好友名單顯示離線"
    ; 隊員畫面上如果還留著舊的 / 別人的邀請，按 Enter 會加入別人的隊伍：有就先不動。
    ; 一定要在動任何視窗之前檢查：等到隊長的確認視窗都打開了才發現，就會把確認視窗留在畫面上卡死。
    if !remote {
        um := ApUi(M.pid)
        if IsObject(um) && um.modalOpen
            return "fail|" M.name " 畫面上已經有別的組隊視窗，先不動"
    }

    ; --- 隊長視窗：好友名單 → 選人 → 組隊 → 確認 ---
    ul := ApUi(L.pid)   ; 先唯讀看一眼：確認視窗還留著就不要又去搶前景
    if IsObject(ul) && ul.modalOpen
        return "fail|" L.name " 畫面上已經有組隊確認視窗，先不動"
    if !ApActivate(L)
        return "fail|無法把 " L.name " 的視窗切到前面"
    ui := ApUi(L.pid)
    if !IsObject(ui)
        return "fail|讀不到 " L.name " 的畫面資料"
    if ui.modalOpen
        return "fail|" L.name " 畫面上已經有組隊確認視窗，先不動"
    if !ui.friendOpen {
        ApKey(L, "f")
        opened := true
        if !ApWait(() => (u := ApUi(L.pid), IsObject(u) && u.friendOpen))
            return "fail|好友視窗沒有打開"
        ui := ApUi(L.pid)
    }
    row := ApFindRow(ui, f.id)
    if !IsObject(row)
        return "fail|好友名單裡找不到那一列"
    if !row.vis
        return "skiplong|" name " 在好友名單的下方，要捲動才看得到（尚未支援；先不一直試）"
    ApClick(L, row.x, row.y)
    if !ApWait(() => (u := ApUi(L.pid), IsObject(u) && u.selId = f.id))
        return "fail|點選後選到的不是 " name
    ui := ApUi(L.pid)
    if !IsObject(ui.partyBtn)
        return "fail|讀不到「組隊」按鈕的位置"
    Sleep 300   ; 剛選完人，「組隊」按鈕要一下子才會啟用（實測：一輪裡的第一個人常在這裡被吃掉）
    ui := ApUi(L.pid)
    if !IsObject(ui) || !IsObject(ui.partyBtn) || ui.selId != f.id
        return "fail|讀不到「組隊」按鈕的位置"
    ApClick(L, ui.partyBtn.x, ui.partyBtn.y)
    if !ApWait(() => (u := ApUi(L.pid), IsObject(u) && u.modalOpen && IsObject(u.okBtn))) {
        ; 第一下常被遊戲吃掉：確認視窗沒開、名單還開著、選的還是這個人，才重讀按鈕位置再按一次（只補一次）
        ui := ApUi(L.pid)
        if !(IsObject(ui) && !ui.modalOpen && ui.friendOpen && ui.selId = f.id && IsObject(ui.partyBtn))
            return "fail|按了「組隊」但沒有跳出確認視窗"
        EventLog(L.name, "PARTY_RETRY_CLICK", "按了「組隊」沒有反應，再按一次｜" name)
        ApClick(L, ui.partyBtn.x, ui.partyBtn.y)
        if !ApWait(() => (u := ApUi(L.pid), IsObject(u) && u.modalOpen && IsObject(u.okBtn)))
            return "fail|按了「組隊」但沒有跳出確認視窗（按了兩次）"
    }
    ui := ApUi(L.pid)
    if !InStr(ui.modalText, "組隊")
        return "fail|跳出來的視窗不是組隊確認（" SubStr(ui.modalText, 1, 30) "）"
    ; 選到的 ID 已經確認過；文字只做提醒（遊戲字型和資料的字不同，例如「勞」）
    if !InStr(ui.modalText, name)
        EventLog(L.name, "PARTY_TEXT", "確認視窗文字與角色名不同（遊戲字型），以角色 ID 為準｜" ui.modalText)
    ApClick(L, ui.okBtn.x, ui.okBtn.y)
    if remote
        M.sentAt := A_TickCount   ; 邀請已經送出：之後任何地方中止都要記下冷卻
    if !ApWait(() => (u := ApUi(L.pid), IsObject(u) && !u.modalOpen))
        return "fail|按了確認但確認視窗沒有關"
    if remote
        return "sent"   ; 對方在另一台電腦：由那台的「自動接受邀請」按 Enter，這裡不碰它的視窗

    ; --- 隊員視窗：邀請視窗 → Enter ---
    if ApIsMinimized(M) {
        ApUnminimize(M)
        minimized.Push(M)
    }
    if !ApActivate(M)
        return "fail|無法把 " M.name " 的視窗切到前面"
    if !ApWait(() => (u := ApUi(M.pid), IsObject(u) && u.modalOpen), AP_STEP_MS + AP_INVITE_EXTRA_MS)
        return "fail|" M.name " 沒有跳出邀請視窗"
    ui := ApUi(M.pid)
    if !InStr(ui.modalText, "組隊")
        return "fail|" M.name " 跳出的不是組隊邀請（" SubStr(ui.modalText, 1, 30) "）"
    ApKey(M, "Enter")
    if !ApWait(() => (a := ApParty(M.pid), b := ApParty(L.pid), IsObject(a) && IsObject(b) && a.id != -1 && a.id = b.id))
        return "fail|按了 Enter 但 " M.name " 沒有進到 " L.name " 的隊伍（隊伍滿了？）"
    return ""
}

ApMapDel(m, k) {
    if m.Has(k)
        m.Delete(k)
}

ApFindRow(ui, id) {
    for r in ui.rows
        if r.id = id
            return r
    return 0
}

; ---------------------------------------------------------------- 隊員這一半：自動接受邀請（給「隊長在另一台電腦」用）
; 這個角色勾了「自動接受邀請」、而且畫面上跳出組隊邀請時，把視窗切到前面按 Enter。
; 條件（每一項不符就不按鍵）：登入完成且在遊戲世界裡、自己目前沒有隊伍、視窗上是組隊邀請（不是離開隊伍之類的視窗）、
; 如果有填「只接受這些隊長」，邀請文字裡要有其中一位的名字；使用者正在操作、重新登入中等同組隊邀請的規則。
; 回傳空字串＝可以按 Enter；否則是不按的原因。
ApAcceptCheck(p, ui) {
    if !IsObject(ui) || !ui.modalOpen
        return "畫面上沒有邀請視窗"
    t := ui.modalText
    if !InStr(t, "組隊") || RegExMatch(t, "離開|解散|退出|踢")
        return "視窗不是組隊邀請（" SubStr(t, 1, 30) "）"
    if ApIsLeader(p)
        return "這個角色是隊長（它的組隊確認視窗和邀請長得很像），不自動接受"
    from := ApAcceptFromNames(p)
    if !from.Length
        return "還沒填「只接受這些隊長」（一定要填，避免被陌生人拉進隊伍）"
    ; 邀請文字像「您要與'名字'組隊嗎?」：抓出引號裡的名字完全比對；文字裡沒有引號時才退回「文字裡含有名字」
    if RegExMatch(t, "['’‘「]([^'’‘」]+)['’」]", &m) {
        if !ApHasName(from, Trim(m[1]))
            return "邀請人「" m[1] "」不在設定的隊長名單裡"
    } else {
        found := false
        for n in from
            if InStr(t, n) {
                found := true
                break
            }
        if !found
            return "邀請文字裡沒有設定的隊長名字（" SubStr(t, 1, 30) "）"
    }
    mine := ApParty(p.pid)
    if !IsObject(mine)
        return "讀不到自己的隊伍資料"
    if mine.id != -1
        return "自己已經在隊伍裡"
    return ""
}

ApAcceptTick() {
    global profiles, AP_ENABLED, apBusy, apAcceptPeekAt
    if !AP_ENABLED || apBusy
        return
    anyOn := false
    for p in profiles
        if p.enabled && p.HasOwnProp("partyAccept") && p.partyAccept {
            anyOn := true
            if !p.pid || !ProfileGameAlive(p)
                p.acceptStatus := "這個角色還沒綁定到遊戲視窗（要先登入進遊戲並由管理程式綁定）"
        }
    if !anyOn
        return
    ; 現在本來就不能動（使用者在操作、重新登入中…）：每 3 秒才看一次有沒有邀請，只為了把原因記下來，不必每秒讀遊戲記憶體
    blocker := ApBlocker()
    if blocker != "" {
        if A_TickCount - apAcceptPeekAt < 3000
            return
        apAcceptPeekAt := A_TickCount
    }
    for p in profiles {
        if !p.enabled || !p.HasOwnProp("partyAccept") || !p.partyAccept || !p.pid || !ProfileGameAlive(p)
            continue
        if p.HasOwnProp("acceptNextAt") && p.acceptNextAt > A_TickCount
            continue
        if !ApAcceptFromNames(p).Length || ApIsLeader(p) {
            p.acceptStatus := ApIsLeader(p) ? "隊長不自動接受邀請" : "請先填「只接受這些隊長」"
            continue
        }
        ; 先唯讀看一眼有沒有邀請視窗：沒有就什麼都不動、不切視窗
        if !ApReady(p) {
            p.acceptStatus := "角色還沒進到遊戲世界、已死亡或視窗標題不對，暫時不能接受"
            continue
        }
        if !ApReadable(p.pid) {
            p.acceptStatus := "讀不到這個遊戲版本的隊伍 / 介面位置（沒有 Game.pdb 又不在已知版本表裡？）"
            continue
        }
        if ApIsMinimized(p) {
            p.acceptStatus := "視窗最小化，收不到邀請（請不要縮小）"
            continue
        }
        ui := ApUi(p.pid)
        if !IsObject(ui) {
            p.acceptStatus := "讀不到遊戲畫面資料"
            continue
        }
        if p.HasOwnProp("acceptStatus") && RegExMatch(p.acceptStatus, "還沒綁定|還沒進到遊戲世界|讀不到這個遊戲版本|視窗最小化|讀不到遊戲畫面|^等待中")   ; 暫時性的診斷訊息：現在一切正常就清掉
            p.acceptStatus := "待命中：有組隊邀請會自動接受"
        if !ui.modalOpen || !InStr(ui.modalText, "組隊")
            continue
        if !p.HasOwnProp("acceptSeenAt") || A_TickCount - p.acceptSeenAt > 20000 {
            p.acceptSeenAt := A_TickCount
            EventLog(p.name, "PARTY_ACCEPT_SEEN", "看到組隊邀請視窗｜" SubStr(ui.modalText, 1, 40) (blocker != "" ? "｜目前不能動：" blocker : ""))
        }
        if blocker != "" {
            p.acceptStatus := "等待中：" blocker
            return
        }
        ApAcceptRun(p)
        return   ; 一次只處理一個角色
    }
}

ApAcceptRun(p) {
    global apBusy, foregroundOwner, apRunStart, apLastOwn, AP_ACCEPT_BACKOFF_MS, AP_STEP_MS, AP_INVITE_EXTRA_MS
    why := ApBlocker()
    if why != "" {
        p.acceptStatus := "等待中：" why
        return
    }
    why := ApAcceptCheck(p, ApUi(p.pid))
    if why != "" {
        p.acceptStatus := "沒有接受：" why, p.acceptNextAt := A_TickCount + AP_ACCEPT_BACKOFF_MS
        ApNote(p, "accept", "沒有自動接受邀請：" why)
        return
    }
    apBusy := true, foregroundOwner := "party", apRunStart := A_TickCount, apLastOwn := A_TickCount
    prev := ApForeground(), stopped := false
    try {
        if !ApActivate(p) {
            p.acceptStatus := "⚠ 無法把視窗切到前面", p.acceptNextAt := A_TickCount + AP_ACCEPT_BACKOFF_MS
            return
        }
        why := ApAcceptCheck(p, ApUi(p.pid))   ; 切過去之後再確認一次，才按鍵
        if why != "" {
            p.acceptStatus := "沒有接受：" why, p.acceptNextAt := A_TickCount + AP_ACCEPT_BACKOFF_MS
            return
        }
        ApKey(p, "Enter")
        if ApWait(() => (m := ApParty(p.pid), IsObject(m) && m.id != -1), AP_STEP_MS + AP_INVITE_EXTRA_MS) {
            p.acceptStatus := "✓ " FormatTime(, "HH:mm:ss") " 已接受邀請"
            EventLog(p.name, "PARTY_ACCEPT", "接受組隊邀請")
            AddRecentEvent("🤝 " p.name " 已接受組隊邀請")
        } else {
            p.acceptStatus := "⚠ 按了 Enter 但沒有進到隊伍", p.acceptNextAt := A_TickCount + AP_ACCEPT_BACKOFF_MS
            EventLog(p.name, "PARTY_ACCEPT_FAIL", "按了 Enter 但沒有進到隊伍")
        }
    } catch as e {
        if e.Extra = "stop" {
            stopped := true
            p.acceptStatus := "⏸ " e.Message, p.acceptNextAt := A_TickCount + 20000
            EventLog(p.name, "PARTY_STOP", e.Message)
        } else {
            p.acceptStatus := "⚠ " e.Message, p.acceptNextAt := A_TickCount + AP_ACCEPT_BACKOFF_MS
            EventLog(p.name, "PARTY_ERROR", e.Message)
        }
    } finally {
        ApCleanup(p, false, [], prev, 0, stopped)
        foregroundOwner := "", apBusy := false, apRunStart := 0
    }
}

; ---------------------------------------------------------------- 設定 / 網頁
ApSetGlobal(rawValue) {
    global INI, AP_ENABLED, AP_SETTLE_SEC
    parts := StrSplit(rawValue, "~")
    if parts.Length < 2 || !IsInteger(parts[1]) || !IsInteger(parts[2])
        return
    AP_ENABLED := Integer(parts[1]) ? 1 : 0
    AP_SETTLE_SEC := Max(0, Min(600, Integer(parts[2])))
    IniWrite AP_ENABLED, INI, "AutoParty", "Enabled"
    IniWrite AP_SETTLE_SEC, INI, "AutoParty", "SettleSec"
    AddRecentEvent("自動組隊：" (AP_ENABLED ? "開啟" : "關閉") "｜全部登入完成後再等 " AP_SETTLE_SEC " 秒")
}

; 「編號~是否隊長~隊員（| 分隔）~角色名稱」（名稱在最後，可含 ~）
ApSetRole(rawValue) {
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
        return AddRecentEvent("⚠ 自動組隊設定沒有儲存：角色清單已變動，請重新整理畫面")
    ; 隊員只能是角色清單裡的其他角色；去掉重複、自己
    seen := Map(), keep := ""
    for n in StrSplit(parts[3], "|") {
        n := Trim(n)
        q := n != "" ? ApProfileByName(n) : 0
        if !q || q = p || seen.Has(n)
            continue
        seen[n] := 1
        keep .= (keep = "" ? "" : "|") n
    }
    p.partyLeader := Integer(parts[2] = "1")
    p.partyMembers := keep
    p.partyCheckAt := 0, p.partyTries := Map(), p.partyWait := Map(), p.partyNoted := Map()
    SaveProfiles()
    AddRecentEvent(p.name " → 自動組隊 " (p.partyLeader ? "隊長｜隊員：" (keep = "" ? "（無）" : StrReplace(keep, "|", "、")) : "不是隊長"))
}

; 「編號~遠端隊員（| 分隔）~角色名稱」
ApSetRemote(rawValue) {
    global profiles
    parts := StrSplit(rawValue, "~")
    if parts.Length < 3 || !IsInteger(parts[1])
        return
    idx := Integer(parts[1])
    if idx < 1 || idx > profiles.Length
        return
    name := parts[3]
    Loop parts.Length - 3
        name .= "~" parts[3 + A_Index]
    p := profiles[idx]
    if name != p.name
        return AddRecentEvent("⚠ 遠端隊員沒有儲存：角色清單已變動，請重新整理畫面")
    seen := Map(), keep := ""
    for n in ApSplitNames(parts[2]) {
        if seen.Has(n)
            continue
        seen[n] := 1
        keep .= (keep = "" ? "" : ",") n   ; 使用者看得到的名單統一用半形逗號（讀入時各種分隔符號都認得，含舊的 |）
    }
    p.partyRemote := keep
    p.partyCheckAt := 0, p.partyTries := Map(), p.partyWait := Map(), p.partyNoted := Map()
    SaveProfiles()
    AddRecentEvent(p.name " → 遠端隊員：" (keep = "" ? "（無）" : keep))
}

; 「編號~是否自動接受~只接受這些隊長（| 分隔，空白＝任何人）~角色名稱」
ApSetAccept(rawValue) {
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
        return AddRecentEvent("⚠ 自動接受設定沒有儲存：角色清單已變動，請重新整理畫面")
    keep := ""
    for n in ApSplitNames(parts[3])
        keep .= (keep = "" ? "" : ",") n
    if parts[2] = "1" && keep = "" {
        p.partyAccept := 0
        SaveProfiles()
        return AddRecentEvent("⚠ " p.name "：要先填「只接受這些隊長」才能開啟自動接受邀請（避免被陌生人拉進隊伍）")
    }
    p.partyAccept := Integer(parts[2] = "1")
    p.partyAcceptFrom := keep
    p.acceptNextAt := 0, p.acceptStatus := ""
    if p.HasOwnProp("partyNoted")
        ApMapDel(p.partyNoted, "accept")
    SaveProfiles()
    AddRecentEvent(p.name " → 自動接受邀請 " (p.partyAccept ? "開啟｜" (keep = "" ? "接受任何人的邀請" : "只接受：" keep) : "關閉"))
}

; 「立即組隊」：下一次檢查就做，不等 SETTLE 與使用者閒置（按按鈕的人當然在用電腦），其他保護照舊。
ApRequestNow(idx) {
    global profiles, apManual, apManualAt
    if idx >= 1 && idx <= profiles.Length && ApIsLeader(profiles[idx]) {
        apManual := idx, apManualAt := A_TickCount
        p := profiles[idx]
        p.partyCheckAt := 0, p.partyTries := Map(), p.partyWait := Map()   ; 手動不受重試冷卻限制
        p.partyStatus := "已排入：放開鍵盤滑鼠後馬上開始"
    }
}

ApPushWeb() {
    global webReady, WVCore, profiles, AP_ENABLED, AP_SETTLE_SEC
    if !webReady || !WVCore
        return
    roles := "", names := ""
    for i, p in profiles {
        if !p.enabled
            continue
        names .= (names = "" ? "" : ",") '"' JsonEscapeWeb(p.name) '"'
        mem := ""
        for n in ApMemberNames(p)
            mem .= (mem = "" ? "" : ",") '"' JsonEscapeWeb(n) '"'
        roles .= (roles = "" ? "" : ",") '{"index":' i ',"name":"' JsonEscapeWeb(p.name) '","alive":' (p.pid && ProfileGameAlive(p) ? "true" : "false")
            . ',"leader":' (ApIsLeader(p) ? "true" : "false") ',"members":[' mem ']'
            . ',"remote":"' JsonEscapeWeb(p.HasOwnProp("partyRemote") ? p.partyRemote : "") '"'
            . ',"accept":' (p.HasOwnProp("partyAccept") && p.partyAccept ? "true" : "false")
            . ',"acceptFrom":"' JsonEscapeWeb(p.HasOwnProp("partyAcceptFrom") ? p.partyAcceptFrom : "") '"'
            . ',"acceptStatus":"' JsonEscapeWeb(p.HasOwnProp("acceptStatus") ? p.acceptStatus : "") '"'
            . ',"status":"' JsonEscapeWeb(p.HasOwnProp("partyStatus") ? p.partyStatus : "") '"}'
    }
    try WVCore.PostWebMessageAsJson('{"type":"party","data":{"enabled":' (AP_ENABLED ? "true" : "false") ',"settle":' AP_SETTLE_SEC
        . ',"blocker":"' JsonEscapeWeb(ApBlocker()) '","names":[' names '],"roles":[' roles ']}}')
}
