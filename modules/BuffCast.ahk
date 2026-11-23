; ============================================================================
; 一鍵施法（v1.3.90.80 一鍵上狀態；v1.3.90.87 改名、改成每個角色多組）：手動玩的時候，觸發一次就幫「現在在最前面的那隻角色」
; 把一組技能一個一個放完。跟自動掛機無關：不會自己定時放、不會在登入 / 復活後補放、不碰 F6；有其他自動操作在用遊戲視窗時不動作。
;
; 每個角色最多 6 組，每組自己選觸發鍵：滑鼠後退鍵（XButton1）、前進鍵（XButton2）、Ctrl＋左鍵，或一個鍵盤鍵（a～z、` - = [ ] , . / ' \、數字鍵盤）。
;   例如 後退鍵＝F1 的 1～3、前進鍵＝F1 的 4～6、Z＝F2 的 1～8。每組各自設技能欄、施放順序（可以自己排，例如 2,3,4,5,6,7,8,1）、
;   要不要等施法動作結束、再多等幾毫秒、放完要不要切回攻擊技能。熱鍵只在前景是遊戲視窗、而且有角色用到那個鍵時才登記；
;   登記了的鍵在遊戲視窗裡不會再送給遊戲（所以要挑遊戲沒在用的）。數字 1～0、F1～F10 是選技能 / 切技能欄用的，不能當觸發鍵。
;   v1.3.90.88：拿掉小窗按鈕（改用鍵盤快捷鍵）。
; 流程：按 F<技能欄> 切到那一排 → 照順序每一格：按數字鍵（1～9、0）選技能 → 讀回右鍵技能確認 → 人物在走路就等停下來 →
;       游標原地按右鍵（點小窗觸發時游標不在遊戲畫面裡，才移到角色身上）→（等施法動作結束）→ 再多等設定的毫秒 → 下一格。
;       空格 / 選不到的格子跳過。放到一半再觸發一次 = 中止（開始 0.8 秒內的重複觸發不算，避免側鍵一下送兩次就中止）。
; 設定檔 [BuffCast]「角色名|G1～G6|Key / On / Bar / Order / Gap / Wait / RetBar / RetSlot」，Key = XButton1 / XButton2 / ^LButton / 鍵盤鍵。
;   v1.3.90.86 以前的單組設定（角色名|Bar / Slots / Gap / WaitCast / RetBar / RetSlot ＋ 全域 CtrlClick / Side）第一次讀到時變成 G1 / G2。
; ============================================================================
global BC_GROUPS := 6
global BC_KEYS_OK := "abcdefghijklmnopqrstuvwxyz``-=[],./'\"   ; 可以當觸發鍵的鍵盤鍵（加上數字鍵盤 Numpad0～9）
global BC_OLD_CTRL := Integer(IniRead(INI, "BuffCast", "CtrlClick", "0"))
global BC_OLD_SIDE := Trim(IniRead(INI, "BuffCast", "Side", ""))
global BC_MINI := 0   ; 小窗按鈕（v1.3.90.88 拿掉；小窗看這個值決定要不要顯示）
; 開關（v1.3.90.93）：全部角色一個總開關（[BuffCast] Enabled，小窗第 3 頁 / 一鍵施法頁最上面）＋每個角色一個（角色名|Enabled），預設都開。
; 關掉時觸發鍵都不攔（打字按 Z 就是 Z）。
global BC_ON := IniRead(INI, "BuffCast", "Enabled", "1") != "0"
global bcBusy := false, bcCancel := false, bcStart := 0, bcHotkeys := []
global bcTestDriver := 0   ; 測試：{GameHwnd(), Key(k), Aim(p,x,y), Right(), Sleep(ms)}

; 觸發鍵是否可用；回傳正規化後的寫法（"" = 不能用）
BcKeyNorm(k) {
    global BC_KEYS_OK
    k := Trim(k)
    if k = "XButton1" || k = "XButton2" || k = "^LButton"
        return k
    if RegExMatch(k, "i)^Numpad[0-9]$")
        return "Numpad" SubStr(k, 7)
    if StrLen(k) = 1 && InStr(BC_KEYS_OK, StrLower(k), true)
        return StrLower(k)
    return ""
}
BcKeyLabel(k) => k = "XButton1" ? "後退鍵" : k = "XButton2" ? "前進鍵" : k = "^LButton" ? "Ctrl＋左鍵" : k = "" ? "（沒設鍵）" : StrUpper(k)
BcTrigLabel(k) => BcKeyLabel(k)
BcParseOrder(text) {
    out := [], seen := Map()
    for x in StrSplit(RegExReplace(text, "[，、;；\s]+", ","), ",") {
        x := Trim(x)
        if !IsInteger(x)
            continue
        n := Integer(x) = 0 ? 10 : Integer(x)   ; 「0」= 第 10 格
        if n >= 1 && n <= 10 && !seen.Has(n)
            seen[n] := 1, out.Push(n)
    }
    return out
}
; 第 gi 組（1～6）
BcCfg(name, gi) {
    global INI, BC_OLD_SIDE, BC_OLD_CTRL
    g(k, d) => IniRead(INI, "BuffCast", name "|G" gi "|" k, d)
    o(k, d) => IniRead(INI, "BuffCast", name "|" k, d)
    key := g("Key", "")
    if key = "" && g("On", "") = "" {   ; 這一組還沒存過：舊版（單組）有設定 → G1 = 當時的側鍵、G2 = 當時的 Ctrl＋左鍵
        oldKey := gi = 1 ? (BC_OLD_SIDE = "XButton1" || BC_OLD_SIDE = "XButton2" ? BC_OLD_SIDE : "") : gi = 2 && BC_OLD_CTRL ? "^LButton" : ""
        hasOld := o("Slots", "") != "" && oldKey != ""
        return {gi: gi, key: hasOld ? oldKey : "", on: hasOld, bar: Min(10, Max(1, Integer(o("Bar", "2")))), order: BcParseOrder(o("Slots", "1,2,3,4,5,6,7,8"))
            , delay: Min(3000, Max(0, Integer(o("Gap", "150")))), waitCast: o("WaitCast", "1") != "0", clicks: 1
            , retBar: Min(10, Max(0, Integer(o("RetBar", "0")))), retSlot: Min(10, Max(1, Integer(o("RetSlot", "1"))))}
    }
    return {gi: gi, key: BcKeyNorm(key), on: g("On", "0") = "1" && BcKeyNorm(key) != "", bar: Min(10, Max(1, Integer(g("Bar", "2")))), order: BcParseOrder(g("Order", "1,2,3,4,5,6,7,8"))
        , delay: Min(3000, Max(0, Integer(g("Gap", "150")))), waitCast: g("Wait", "1") != "0", clicks: Min(6, Max(1, Integer(g("Clicks", "1"))))
        , retBar: Min(10, Max(0, Integer(g("RetBar", "0")))), retSlot: Min(10, Max(1, Integer(g("RetSlot", "1"))))}
}
BcCharOn(name) {
    global INI, BC_ON
    return BC_ON && IniRead(INI, "BuffCast", name "|Enabled", "1") != "0"
}
BcSetCharOn(name, on, src := "") {
    global INI
    IniWrite on ? "1" : "0", INI, "BuffCast", name "|Enabled"
    EventLog(name, "BUFF_CFG", "一鍵施法總開關：" (on ? "開" : "關") (src != "" ? "｜" src : ""))
    try BuffCastPushWeb()
}
; 這個角色用這個鍵的那一組（沒有回傳 0；總開關關著也回傳 0）
BcCfgByKey(name, key) {
    global BC_GROUPS
    if !BcCharOn(name)
        return 0
    Loop BC_GROUPS {
        c := BcCfg(name, A_Index)
        if c.on && c.key = key
            return c
    }
    return 0
}
BcCfgText(c) => "F" c.bar " 順序 " BcSlotsText(c.order) "｜" (c.clicks > 1 ? "右鍵連按 " c.clicks " 下｜" : "") (c.waitCast ? "等施法動作結束再多等 " : "每格間隔 ") c.delay " 毫秒｜" (c.retBar ? "放完切回 F" c.retBar " 第 " BcKey(c.retSlot) " 格" : "放完不切回")
; 頁面：角色名~組|組|…（6 組），組 = 鍵;開(0/1);技能欄;順序(逗號);毫秒;等施法(0/1);切回欄(0=不切回);切回格;右鍵連按幾下
; 同一個角色兩組用同一個鍵：後面那組關掉（記一筆）
BuffCastCharSet(rawValue) {
    global INI, BC_GROUPS
    cut := InStr(rawValue, "~")
    if !cut
        return
    name := Trim(SubStr(rawValue, 1, cut - 1))
    if name = ""
        return
    used := Map(), dup := ""
    for gi, grp in StrSplit(SubStr(rawValue, cut + 1), "|") {
        if gi > BC_GROUPS
            break
        f := StrSplit(grp, ";")
        if f.Length < 8
            continue
        key := BcKeyNorm(f[1]), on := f[2] = "1" && key != ""
        if on && used.Has(key)
            on := false, dup .= (dup = "" ? "" : "、") BcKeyLabel(key)
        if on
            used[key] := 1
        k := name "|G" gi "|"
        order := ""
        for n in BcParseOrder(f[4])
            order .= (order = "" ? "" : ",") n
        IniWrite key, INI, "BuffCast", k "Key"
        IniWrite on ? "1" : "0", INI, "BuffCast", k "On"
        IniWrite IsInteger(f[3]) ? Min(10, Max(1, Integer(f[3]))) : 2, INI, "BuffCast", k "Bar"
        IniWrite order, INI, "BuffCast", k "Order"
        IniWrite IsInteger(f[5]) ? Min(3000, Max(0, Integer(f[5]))) : 150, INI, "BuffCast", k "Gap"
        IniWrite f[6] = "0" ? "0" : "1", INI, "BuffCast", k "Wait"
        IniWrite IsInteger(f[7]) ? Min(10, Max(0, Integer(f[7]))) : 0, INI, "BuffCast", k "RetBar"
        IniWrite IsInteger(f[8]) ? Min(10, Max(1, Integer(f[8]))) : 1, INI, "BuffCast", k "RetSlot"
        IniWrite f.Length >= 9 && IsInteger(f[9]) ? Min(6, Max(1, Integer(f[9]))) : 1, INI, "BuffCast", k "Clicks"
    }
    txt := ""
    Loop BC_GROUPS {
        c := BcCfg(name, A_Index)
        if c.on
            txt .= (txt = "" ? "" : "｜") BcKeyLabel(c.key) "：" BcCfgText(c)
    }
    EventLog(name, "BUFF_CFG", "一鍵施法：" (txt = "" ? "都沒有開" : txt) (dup != "" ? "｜重複的鍵沒開：" dup : ""))
    BuffCastApply()
}
; 全部角色的總開關（頁面 / 小窗）：0 / 1
BuffCastSetGlobal(rawValue) {
    global INI, BC_ON
    BC_ON := Trim(rawValue) = "1" ? 1 : 0
    IniWrite BC_ON, INI, "BuffCast", "Enabled"
    EventLog("GLOBAL", "BUFF_CFG", "一鍵施法總開關（所有角色）：" (BC_ON ? "開" : "關"))
    BuffCastApply()
    try BuffCastPushWeb()
}
; 頁面：角色名~0/1
BuffCastCharOnSet(rawValue) {
    p := StrSplit(rawValue, "~")
    if p.Length >= 2 && Trim(p[1]) != ""
        BcSetCharOn(Trim(p[1]), p[2] = "1", "頁面")
}

BcKey(n) => n = 10 ? "0" : String(n)
BcSlotsText(slots) {
    t := ""
    for n in slots
        t .= (t = "" ? "" : "、") BcKey(n)
    return t = "" ? "（沒有設）" : t
}

; ---- 熱鍵 ----
; 只有「最前面那隻角色有開這個鍵的那一組」時才攔：別的角色按 Z 照常打字（11/23 19:5x 欸等設了 Z，別的視窗打字按 Z 被吃掉、跳出「沒有設 Z」）
BcCtx(hk := "") {
    global foregroundOwner, abortRequested, emergencyStop, bcBusy
    if abortRequested || (IsSet(emergencyStop) && emergencyStop)
        return false
    hw := WinExist("A")
    if !hw
        return false
    isGame := false
    try isGame := StrLower(WinGetProcessName("ahk_id " hw)) = "game.exe"
    if !isGame
        return false
    if bcBusy || hk = ""   ; 施法中：讓同一個鍵進來中止
        return true
    p := BcProfileOf(hw)
    return IsObject(p) && IsObject(BcCfgByKey(p.name, RegExReplace(hk, "^\$")))
}
; 有角色用到的鍵才登記熱鍵（沒人用 Ctrl＋左鍵就不攔、沒人用 Z 就照常交給遊戲）
BuffCastApply() {
    global BC_GROUPS, bcHotkeys, profiles
    used := Map()
    if IsSet(profiles) && IsObject(profiles)
        for p in profiles
            if p.enabled
                Loop BC_GROUPS {
                    c := BcCfg(p.name, A_Index)
                    if c.on
                        used[c.key] := 1
                }
    HotIf(BcCtx)
    for k in bcHotkeys
        try Hotkey k, "Off"
    bcHotkeys := []
    for key, _ in used {
        hk := (key = "^LButton" ? "" : "$") key
        try {
            Hotkey hk, BcHotkey, "On T2"   ; T2：放到一半再按一次可以進來中止
            bcHotkeys.Push(hk)
        } catch as e {
            EventLog("GLOBAL", "BUFF_ERROR", "一鍵施法熱鍵 " BcKeyLabel(key) " 登記失敗：" e.Message)
        }
    }
    HotIf()
}
; 11/23 18:30 欸等：側鍵還壓著時遊戲不收右鍵 → 等觸發的鍵放開才開始
BcHotkey(thisHotkey) {
    global bcBusy
    key := RegExReplace(thisHotkey, "^\$")
    if !bcBusy {
        try KeyWait RegExReplace(key, "[~$*^!+#]"), "T1"
        if InStr(key, "^")
            try KeyWait "Ctrl", "T1"
    }
    BuffCastNow("熱鍵", key)
}
BuffCastInit() {
    try BuffCastApply()
}

; ---- 施放 ----
BcGameHwnd() {
    global bcTestDriver
    if IsObject(bcTestDriver)
        return bcTestDriver.GameHwnd()
    hw := WinExist("A")
    try {
        if hw && StrLower(WinGetProcessName("ahk_id " hw)) = "game.exe"
            return hw
    }
    return 0
}
BcProfileOf(hw) {
    global profiles
    pid := 0
    try pid := WinGetPID("ahk_id " hw)
    for p in profiles
        if (p.hwnd && p.hwnd = hw) || (pid && p.pid = pid)
            return p
    return 0
}
BcKeyPress(k) {
    global bcTestDriver
    if IsObject(bcTestDriver)
        return bcTestDriver.Key(k)
    Send "{" k " down}"
    Sleep 30   ; v1.3.90.94：0.06 → 0.03 秒（11/23 欸等第 1 組攻擊技要更快）
    Send "{" k " up}"
}
BcAim(p, x, y) {
    global bcTestDriver, AP_DESIGN_W, AP_DESIGN_H
    if IsObject(bcTestDriver)
        return bcTestDriver.Aim(p, x, y)
    WinGetClientPos(&cx, &cy, &cw, &ch, "ahk_id " p.hwnd)
    if cw < 100 || ch < 100
        return false
    DllCall("SetCursorPos", "Int", cx + Round(x * cw / AP_DESIGN_W), "Int", cy + Round(y * ch / AP_DESIGN_H))
    return true
}
; 游標原地先動一下（遊戲更新游標底下的東西），再按住右鍵 0.06 秒（mouse_event：11/23 18:37 實測吃得到；v1.3.90.94 從 0.1 縮短）
BcRightClick() {
    global bcTestDriver
    if IsObject(bcTestDriver)
        return bcTestDriver.Right()
    DllCall("mouse_event", "UInt", 0x0001, "Int", 2, "Int", 0, "UInt", 0, "UPtr", 0)    ; MOVE（相對）
    Sleep 10
    DllCall("mouse_event", "UInt", 0x0001, "Int", -2, "Int", 0, "UInt", 0, "UPtr", 0)
    Sleep 10
    DllCall("mouse_event", "UInt", 0x0008, "Int", 0, "Int", 0, "UInt", 0, "UPtr", 0)    ; RIGHTDOWN
    Sleep 60
    DllCall("mouse_event", "UInt", 0x0010, "Int", 0, "Int", 0, "UInt", 0, "UPtr", 0)    ; RIGHTUP
}
; 游標在不在這個遊戲視窗的畫面裡（在小窗上按按鈕時不在，要先移進去）
BcCursorInGame(p) {
    global bcTestDriver
    if IsObject(bcTestDriver)
        return bcTestDriver.HasOwnProp("CursorIn") ? bcTestDriver.CursorIn() : true
    CoordMode "Mouse", "Screen"
    MouseGetPos(&x, &y)
    WinGetClientPos(&cx, &cy, &cw, &ch, "ahk_id " p.hwnd)
    return x >= cx && x < cx + cw && y >= cy && y < cy + ch
}
BcSleep(ms) {
    global bcTestDriver
    if IsObject(bcTestDriver)
        return bcTestDriver.Sleep(ms)
    Sleep ms
}
BcRunSkill(pid) {
    me := 0
    try me := MiningCharState(pid)
    return IsObject(me) ? me : 0
}
; 這一排技能欄每一格的技能代碼：Map(格 → 代碼)
BcBarSkills(pid, bar) {
    out := Map()
    try {
        for s in MiningSkillSlots(pid)
            if s.bar = bar && s.id != ""
                out[s.key] := s.id
    }
    return out
}
; 等這一下施法結束（11/23 18:42 實測固定間隔從 150 調到 1200 毫秒還是有技能沒放出來：要等前一個施法動作做完；
; 磁極施法約 2.5 秒，排在它後面的生體加速一直放不出來）：人物動作進入「技能」(3) 後變回別的就結束；0.25 秒內沒進入 = 瞬發，直接下一格；最多等 3 秒
BcWaitCast(p) {
    global bcCancel
    start := A_TickCount, seen := false
    while A_TickCount - start < 3000 && !bcCancel {
        me := BcRunSkill(p.pid)
        act := IsObject(me) && me.HasOwnProp("action") ? me.action : -1
        if act = 3
            seen := true
        else if seen
            return true
        else if A_TickCount - start > 250   ; v1.3.90.94：0.45 → 0.25 秒沒進入施法 = 瞬發
            return false
        BcSleep(25)
    }
    return seen
}
; 人物在走路就先等他停下來（最多 1 秒）
BcWaitStill(p) {
    global bcCancel
    start := A_TickCount
    while A_TickCount - start < 1000 && !bcCancel {
        me := BcRunSkill(p.pid)
        if !IsObject(me) || !me.HasOwnProp("action") || me.action != 1   ; 1 = 移動
            return
        BcSleep(50)
    }
}
; 按數字鍵，讀回右鍵技能是不是 want：每 0.02 秒讀一次、最多 0.4 秒；選不到就重按 F<欄> 再試一次。
; pressBar = 先按 F<欄>（第一格 / 切回攻擊技能時）
BcSelect(p, bar, n, want, pressBar := false) {
    Loop 2 {
        if pressBar || A_Index > 1 {
            BcKeyPress("F" bar)
            BcSleep(60)
        }
        BcKeyPress(BcKey(n))
        t0 := A_TickCount
        Loop {
            me := BcRunSkill(p.pid)
            if IsObject(me) && me.runSkill = want
                return me
            if A_TickCount - t0 >= 400
                break
            BcSleep(20)
        }
    }
    return 0
}

; src = 從哪裡觸發；key = 觸發鍵（XButton1 / XButton2 / ^LButton / 鍵盤鍵）
BuffCastNow(src := "", key := "") {
    global bcBusy, bcCancel, bcStart, foregroundOwner, bcTestDriver
    if bcBusy {   ; 放到一半再觸發 = 中止；剛開始 0.8 秒內的不算（側鍵一下送兩次）
        if A_TickCount - bcStart >= 800
            bcCancel := true
        return
    }
    lb := BcKeyLabel(key)
    hw := BcGameHwnd()
    if !hw {
        BcTip("一鍵施法：前景不是遊戲視窗")
        return
    }
    p := BcProfileOf(hw)
    if !IsObject(p) || !p.pid {
        BcTip("一鍵施法：這個遊戲視窗還沒綁定角色")
        return
    }
    if foregroundOwner != "" {
        BcTip("一鍵施法：" p.name " 有自動操作正在使用視窗，這次不放")
        return
    }
    c := BcCfgByKey(p.name, key)
    if !IsObject(c) || !c.order.Length {
        BcTip("一鍵施法：" p.name " 沒有設「" lb "」這一組")
        return
    }
    bcBusy := true, bcCancel := false, bcStart := A_TickCount, foregroundOwner := "buff"
    done := [], skipped := [], cancelled := false, ret := ""
    CoordMode "Mouse", "Screen"
    MouseGetPos(&mx, &my)
    try {
        skills := BcBarSkills(p.pid, c.bar)
        first := true
        for n in c.order {
            if bcCancel {
                cancelled := true
                break
            }
            want := skills.Has(n) ? skills[n] : ""
            if want = "" {
                skipped.Push(BcKey(n) "（空）")
                continue
            }
            me := BcSelect(p, c.bar, n, want, first)
            first := false
            if !IsObject(me) {
                skipped.Push(BcKey(n) "（選不到）")
                continue
            }
            ; 游標在遊戲畫面裡就原地按（不用對準角色）；不在（點小窗按鈕時）才移到角色身上，免得按到小窗
            if !BcCursorInGame(p) {
                sp := {x: -1, y: -1}
                try sp := MnScreenPt(p.pid, me.x, me.y + 9, me.z)
                if sp.x < 0 || sp.y < 0
                    sp := {x: 512, y: 400}
                if !BcAim(p, sp.x, sp.y) {
                    skipped.Push(BcKey(n) "（視窗大小不對）")
                    continue
                }
            }
            BcWaitStill(p)
            ; 每格右鍵連按幾下（11/23 欸等 F1 第 3 招乾坤震爆按一下常常沒放出來；手動時也是連按右鍵）
            Loop c.clicks {
                if A_Index > 1
                    BcSleep(100)
                BcRightClick()
            }
            done.Push(BcKey(n))
            if c.waitCast
                BcWaitCast(p)
            BcSleep(c.delay)
        }
        if c.retBar && !cancelled {
            want := BcBarSkills(p.pid, c.retBar).Get(c.retSlot, "")
            ret := want = "" ? "｜切回的那一格是空的" : IsObject(BcSelect(p, c.retBar, c.retSlot, want, true)) ? "｜已切回 F" c.retBar " 第 " BcKey(c.retSlot) " 格" : "｜切不回 F" c.retBar " 第 " BcKey(c.retSlot) " 格"
        }
    } catch as e {
        skipped.Push("出錯：" e.Message)
        ret := ""
    } finally {
        if !IsObject(bcTestDriver)
            try DllCall("SetCursorPos", "Int", mx, "Int", my)
        foregroundOwner := "", bcBusy := false, bcCancel := false
    }
    msg := (cancelled ? "中止｜" : "") lb "｜F" c.bar " 放了 " done.Length " 個（" BcSlotsText(done) "）" (skipped.Length ? "｜略過 " BcJoin(skipped) : "") ret
    EventLog(p.name, "BUFF_CAST", msg (src != "" ? "｜" src : ""))
    BcTip("✨ " p.name "：" msg)
    return {done: done, skipped: skipped, cancelled: cancelled}
}
BcJoin(arr) {
    t := ""
    for x in arr
        t .= (t = "" ? "" : "、") x
    return t
}
BcTip(text) {
    global bcTestDriver
    if IsObject(bcTestDriver)
        return
    ToolTip text
    SetTimer () => ToolTip(), -2500
}

; ---- 頁面資料 ----
; 每個角色：6 組設定、技能欄 1～10 每一排每一格的技能名稱（讀記憶體）
BuffCastPushWeb() {
    global webReady, WVCore, profiles, BC_GROUPS, INI
    if !webReady || !WVCore
        return
    rows := ""
    for p in profiles {
        if !p.enabled
            continue
        bars := ""
        alive := false
        try alive := p.pid && ProfileGameAlive(p)
        if alive {
            names := Map()
            try {
                for s in MiningSkillSlots(p.pid)
                    names[s.bar "-" s.key] := s.name != "" ? s.name : s.id
            }
            Loop 10 {
                b := A_Index, row := ""
                Loop 10
                    row .= (row = "" ? "" : ",") '"' JsonEscapeWeb(names.Get(b "-" A_Index, "")) '"'
                bars .= (bars = "" ? "" : ",") "[" row "]"
            }
        }
        gs := ""
        Loop BC_GROUPS {
            c := BcCfg(p.name, A_Index)
            od := ""
            for n in c.order
                od .= (od = "" ? "" : ",") n
            gs .= (gs = "" ? "" : ",") '{"key":"' JsonEscapeWeb(c.key) '","on":' (c.on ? "true" : "false") ',"bar":' c.bar ',"order":[' od '],"delay":' c.delay ',"waitCast":' (c.waitCast ? "true" : "false") ',"clicks":' c.clicks ',"retBar":' c.retBar ',"retSlot":' c.retSlot '}'
        }
        rows .= (rows = "" ? "" : ",") '{"name":"' JsonEscapeWeb(p.name) '","alive":' (alive ? "true" : "false") ',"enabled":' (IniRead(INI, "BuffCast", p.name "|Enabled", "1") != "0" ? "true" : "false") ',"names":[' bars '],"groups":[' gs ']}'
    }
    global BC_ON
    try WVCore.PostWebMessageAsJson('{"type":"buffcast","data":{"on":' (BC_ON ? "true" : "false") ',"chars":[' rows ']}}')
}
