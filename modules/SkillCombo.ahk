; ============================================================================
; H-027 技能組合快速施法：按一個鍵，用最快速度連續送出幾個技能鍵（例如按 1 → 1、2、3 一起放出去）。
; - 預設關閉。只在「前景是遊戲視窗」、而且沒有其他自動操作在用遊戲視窗時才攔截；其他時候按鍵照常交給遊戲。
; - 觸發鍵會被攔下來（$ 前綴，不會被自己送出的鍵重複觸發），換成設定的鍵序列。
; - 兩種送法：「依序」＝一個一個按（按住 hold 毫秒、間隔 gap 毫秒）；「同時」＝一起按下、一起放開（最快，
;   但遊戲可能只收第一個，要看實際遊戲能不能吃；所以兩種都留給你選）。
; - 「按住連發」：按住觸發鍵就一直重複，放開停止。
; - 緊急停止（F10 / 停止監控）後不再觸發。「暫停鍵」可以臨時關掉（打字聊天時用），再按一次恢復。
; INI：[SkillCombo] Enabled / PauseKey / Count / Combo1…N = 開~觸發鍵~鍵序列(逗號)~模式~hold~gap~連發~名稱
; ============================================================================

global SC_ENABLED := Integer(IniRead(INI, "SkillCombo", "Enabled", "0"))
global SC_PAUSE_KEY := Trim(IniRead(INI, "SkillCombo", "PauseKey", ""))
global scPaused := false
global scCombos := []          ; [{on, trigger, keys:[], mode, hold, gap, repeat, label, err}]
global scActive := Map()       ; 目前已登記的觸發鍵（小寫）→ 組合
global scPauseApplied := ""
global scBusy := false
global scFired := 0
; 測試：設成物件時，登記熱鍵 / 送鍵 / 查詢按鍵狀態 / 判斷前景都交給它
global scTestDriver := 0

global SC_MAX_COMBOS := 12, SC_MAX_KEYS := 8, SC_HOLD_MIN := 30, SC_HOLD_MAX := 500, SC_GAP_MIN := 0, SC_GAP_MAX := 1000

; 緊急停止鍵（F7 / F10）不能被拿來當觸發鍵或技能鍵
SkillComboKeyOk(k) {
    k := Trim(k)
    if k = ""
        return false
    if RegExMatch(k, "i)^(F7|F10)$")
        return false
    return RegExMatch(k, "i)^([a-z0-9]|F([1-9]|1[0-2])|Space|Tab|Numpad[0-9]|XButton[12]|MButton|[-=,./;'\[\]\\])$") ? true : false
}
; 觸發鍵可以是滑鼠側鍵 / 中鍵；技能鍵只能是鍵盤鍵（要送給遊戲的）
SkillComboSendKeyOk(k) => SkillComboKeyOk(k) && !RegExMatch(Trim(k), "i)^(XButton[12]|MButton)$")

; 一筆組合：驗證並整理；有問題 err 不是空字串（不會被登記）
SkillComboParse(raw) {
    global SC_MAX_KEYS, SC_HOLD_MIN, SC_HOLD_MAX, SC_GAP_MIN, SC_GAP_MAX
    p := StrSplit(raw, "~", , 8)
    c := {on: 0, trigger: "", keys: [], mode: "seq", hold: 40, gap: 10, repeat: 0, label: "", err: "", regErr: ""}
    if p.Length < 7 {
        c.err := "資料不完整"
        return c
    }
    c.on := (p[1] = "1") ? 1 : 0
    c.trigger := Trim(p[2])
    for k in StrSplit(p[3], ",") {
        k := Trim(k)
        if k != ""
            c.keys.Push(k)
    }
    c.mode := (p[4] = "all") ? "all" : "seq"
    c.hold := IsInteger(p[5]) ? Max(SC_HOLD_MIN, Min(SC_HOLD_MAX, Integer(p[5]))) : 40
    c.gap := IsInteger(p[6]) ? Max(SC_GAP_MIN, Min(SC_GAP_MAX, Integer(p[6]))) : 10
    c.repeat := (p[7] = "1") ? 1 : 0
    c.label := p.Length >= 8 ? RegExReplace(Trim(p[8]), "[~|\r\n]", "") : ""
    if !SkillComboKeyOk(c.trigger)
        c.err := "觸發鍵「" c.trigger "」不能用（F7 / F10 是停止鍵）"
    else if !c.keys.Length
        c.err := "還沒有設定要送出的技能鍵"
    else if c.keys.Length > SC_MAX_KEYS
        c.err := "技能鍵最多 " SC_MAX_KEYS " 個"
    else
        for k in c.keys
            if !SkillComboSendKeyOk(k) {
                c.err := "技能鍵「" k "」不能用"
                break
            }
    return c
}

SkillComboSerialize(c) => (c.on ? 1 : 0) "~" c.trigger "~" SkillComboJoin(c.keys) "~" c.mode "~" c.hold "~" c.gap "~" (c.repeat ? 1 : 0) "~" c.label
SkillComboJoin(arr) {
    s := ""
    for k in arr
        s .= (s = "" ? "" : ",") k
    return s
}

SkillComboInit() {
    global INI, scCombos, SC_MAX_COMBOS
    scCombos := []
    n := Integer(IniRead(INI, "SkillCombo", "Count", "0"))
    Loop Min(n, SC_MAX_COMBOS)
        scCombos.Push(SkillComboParse(IniRead(INI, "SkillCombo", "Combo" A_Index, "")))
    SkillComboApply()
}

SkillComboSave() {
    global INI, scCombos, SC_ENABLED, SC_PAUSE_KEY
    try {
        IniWrite SC_ENABLED, INI, "SkillCombo", "Enabled"
        IniWrite SC_PAUSE_KEY, INI, "SkillCombo", "PauseKey"
        IniWrite scCombos.Length, INI, "SkillCombo", "Count"
        for i, c in scCombos
            IniWrite SkillComboSerialize(c), INI, "SkillCombo", "Combo" i
    }
}

; ---------------------------------------------------------------- 熱鍵登記（測試時交給 scTestDriver）
ScHotkeyOn(key, cb, on := true) {
    global scTestDriver
    if IsObject(scTestDriver)
        return scTestDriver.Hotkey(key, cb, on)
    HotIf(SkillComboCtx)
    try Hotkey "$" key, cb, on ? "On" : "Off"
    catch as e {
        HotIf()
        throw e
    }
    HotIf()
}

; 先把舊的全部關掉，再登記目前啟用的組合（同一個觸發鍵只登記第一個，其他標示重複）
SkillComboApply() {
    global scCombos, scActive, SC_ENABLED, SC_PAUSE_KEY, scPauseApplied
    for key, c in scActive
        try ScHotkeyOn(key, SkillComboHotkey, false)
    scActive := Map()
    if scPauseApplied != "" {
        try ScPauseKeyOn(scPauseApplied, false)
        scPauseApplied := ""
    }
    for c in scCombos
        c.regErr := ""
    if SC_ENABLED {
        for c in scCombos {
            if !c.on || c.err != ""
                continue
            lk := StrLower(c.trigger)
            if scActive.Has(lk) {
                c.regErr := "觸發鍵「" c.trigger "」和前面的組合重複，這組不會作用"
                continue
            }
            try {
                ScHotkeyOn(lk, SkillComboHotkey, true)
                scActive[lk] := c
            } catch as e {
                c.regErr := "登記失敗：" e.Message
            }
        }
    }
    ; 暫停鍵（不受啟用與否影響：關掉組合也能用它切換，但只有啟用時有意義）
    if SC_ENABLED && SC_PAUSE_KEY != "" && SkillComboKeyOk(SC_PAUSE_KEY) && !scActive.Has(StrLower(SC_PAUSE_KEY)) {
        try {
            ScPauseKeyOn(SC_PAUSE_KEY, true)
            scPauseApplied := SC_PAUSE_KEY
        }
    }
}

ScPauseKeyOn(key, on) {
    global scTestDriver
    if IsObject(scTestDriver)
        return scTestDriver.PauseKey(key, on)
    try Hotkey "~" key, SkillComboTogglePause, on ? "On" : "Off"   ; ~ = 不吃掉原本的按鍵
}

SkillComboTogglePause(*) {
    global scPaused
    scPaused := !scPaused
    AddRecentEvent("⚡ 技能組合 " (scPaused ? "已暫停（再按一次恢復）" : "已恢復"))
}

; ---------------------------------------------------------------- 什麼時候才攔截
SkillComboGameActive() {
    global scTestDriver
    if IsObject(scTestDriver)
        return scTestDriver.GameActive()
    hw := WinExist("A")
    if !hw
        return false
    try return StrLower(WinGetProcessName("ahk_id " hw)) = "game.exe"
    return false
}

SkillComboCtx(*) {
    global SC_ENABLED, scPaused, abortRequested, emergencyStop, foregroundOwner, setupMode
    if !SC_ENABLED || scPaused || abortRequested || emergencyStop
        return false
    if foregroundOwner != "" || setupMode   ; 其他自動操作正在用遊戲視窗：不要插進去
        return false
    return SkillComboGameActive()
}

; ---------------------------------------------------------------- 送鍵（測試時交給 scTestDriver）
ScSend(text) {
    global scTestDriver
    if IsObject(scTestDriver)
        return scTestDriver.Send(text)
    SendEvent text
}
ScSleep(ms) {
    global scTestDriver
    if IsObject(scTestDriver)
        return scTestDriver.Sleep(ms)
    if ms > 0
        Sleep ms
}
ScKeyWait(trigger, sec) {
    global scTestDriver
    if IsObject(scTestDriver)
        return scTestDriver.KeyWait(trigger)
    try KeyWait trigger, "T" sec
}
ScKeyDown(trigger) {
    global scTestDriver
    if IsObject(scTestDriver)
        return scTestDriver.KeyDown(trigger)
    return GetKeyState(trigger, "P")
}
; Space 等具名鍵在 {} 裡可以直接用；單一字元要小寫以免被當成 Shift+字母
ScKeyText(k) => StrLen(k) = 1 ? StrLower(k) : k

SkillComboHotkey(thisHotkey) {
    global scActive
    lk := StrLower(LTrim(thisHotkey, "$~*"))
    if !scActive.Has(lk)
        return
    SkillComboRun(scActive[lk])
}

; 送出一次組合。回傳實際送了幾個鍵（測試用）。同時只會有一個在跑（連按不會疊加）。
SkillComboRun(c) {
    global scBusy, scFired, abortRequested, emergencyStop
    if scBusy
        return 0
    scBusy := true
    sent := 0
    try {
        loop {
            if abortRequested || emergencyStop
                break
            sent += SkillComboSendOnce(c)
            scFired += 1
            if !c.repeat || !ScKeyDown(c.trigger)
                break
        }
        if !c.repeat
            ScKeyWait(c.trigger, 3)   ; 按住不放只觸發一次（不然會跟著鍵盤的重複輸入一直觸發）
    } finally {
        ; 不管怎麼結束，都不能讓任何鍵卡在按下
        for k in c.keys
            try ScSend("{" ScKeyText(k) " up}")
        scBusy := false
    }
    return sent
}

SkillComboSendOnce(c) {
    n := 0
    if c.mode = "all" {
        for k in c.keys {
            ScSend("{" ScKeyText(k) " down}")
            n += 1
        }
        ScSleep(c.hold)
        for k in c.keys
            ScSend("{" ScKeyText(k) " up}")
    } else {
        for i, k in c.keys {
            ScSend("{" ScKeyText(k) " down}")
            ScSleep(c.hold)
            ScSend("{" ScKeyText(k) " up}")
            n += 1
            if i < c.keys.Length
                ScSleep(c.gap)
        }
    }
    return n
}

; ---------------------------------------------------------------- 網頁
; 「開~暫停鍵」
SkillComboSetGlobal(rawValue) {
    global SC_ENABLED, SC_PAUSE_KEY, scPaused
    parts := StrSplit(rawValue, "~", , 2)
    if parts.Length < 2 || !IsInteger(parts[1])
        return
    SC_ENABLED := Integer(parts[1]) ? 1 : 0
    pk := Trim(parts[2])
    SC_PAUSE_KEY := (pk = "" || SkillComboKeyOk(pk)) ? pk : SC_PAUSE_KEY
    if !SC_ENABLED
        scPaused := false
    SkillComboApply()
    SkillComboSave()
    AddRecentEvent("⚡ 技能組合：" (SC_ENABLED ? "開啟" : "關閉") (SC_PAUSE_KEY != "" ? "｜暫停鍵 " SC_PAUSE_KEY : ""))
}

; 整份清單：每筆用 | 分隔，欄位用 ~ 分隔（和 SkillComboSerialize 一致）
SkillComboSetList(rawValue) {
    global scCombos, SC_MAX_COMBOS
    scCombos := []
    for item in StrSplit(rawValue, "|") {
        if Trim(item) = "" || scCombos.Length >= SC_MAX_COMBOS
            continue
        scCombos.Push(SkillComboParse(item))
    }
    SkillComboApply()
    SkillComboSave()
    AddRecentEvent("⚡ 技能組合已更新：" scCombos.Length " 組")
}

SkillComboPushWeb() {
    global webReady, WVCore, scCombos, SC_ENABLED, SC_PAUSE_KEY, scPaused, scFired
    if !webReady || !WVCore
        return
    rows := ""
    for c in scCombos {
        rows .= (rows = "" ? "" : ",") '{"on":' (c.on ? "true" : "false") ',"trigger":"' JsonEscapeWeb(c.trigger) '","keys":"' JsonEscapeWeb(SkillComboJoin(c.keys))
            . '","mode":"' c.mode '","hold":' c.hold ',"gap":' c.gap ',"repeat":' (c.repeat ? "true" : "false")
            . ',"label":"' JsonEscapeWeb(c.label) '","err":"' JsonEscapeWeb(c.err != "" ? c.err : c.regErr) '"}'
    }
    try WVCore.PostWebMessageAsJson('{"type":"skillcombo","data":{"enabled":' (SC_ENABLED ? "true" : "false") ',"paused":' (scPaused ? "true" : "false")
        . ',"pauseKey":"' JsonEscapeWeb(SC_PAUSE_KEY) '","fired":' scFired ',"combos":[' rows ']}}')
}
