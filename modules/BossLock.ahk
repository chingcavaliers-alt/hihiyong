; 多開卡右鍵打王（v1.3.90.99）：幾隻角色的視窗疊在一起，每隻都「卡住右鍵」連續放同一個 0 CD 技能，游標放在王身上就一起打。
; 遊戲的卡右鍵：在遊戲畫面按住右鍵 → 拖出視窗外放開 → 遊戲沒收到「放開」，一直當作右鍵壓著（每個視窗各自記）。
; 程式做法：每隻角色輪流叫到前面 → 按 F<欄> + 數字選技能（讀回確認）→ 在游標位置按下右鍵 → 在游標底下蓋一塊管理程式自己的小方塊，
; 「放開」送到小方塊而不是遊戲（等於拖出視窗外放開，游標不用真的移出去）→ 拿掉小方塊。全部卡好後叫回原本最前面的視窗、游標放回原位。
; 全部放開：每隻叫到前面在游標位置正常按一下右鍵（遊戲收到放開就不卡了）。
; 設定：[BossLock] 角色名|On（0/1）、角色名|Bar（1～4）、角色名|Slot（1～10，10 = 0 鍵）、Method（drag = 預設，拖到遊戲畫面外放開；cover = 舊的蓋小方塊）
global BL_STATE := "idle"      ; idle / waiting（等滑鼠停 2 秒）/ running / locked
global BL_TEXT := ""
global blLocked := Map()       ; 角色名 → 卡住的時間
global blWaitSince := 0, blCoverGui := 0
global blTestDriver := 0       ; 測試：{Activate(p), Foreground(), Key(k), Cursor(), SetCursor(x,y), Down(), Up(), Cover(x,y), Uncover(), ClientRect(p), Idle(), Sleep(ms)}
global BL_IDLE_MS := 2000

BlCfg(name) {
    global INI
    g(k, d) => IniRead(INI, "BossLock", name "|" k, d)
    bar := g("Bar", "1"), slot := g("Slot", "1")
    return {on: g("On", "0") = "1"
        , bar: IsInteger(bar) ? Min(4, Max(1, Integer(bar))) : 1
        , slot: IsInteger(slot) ? Min(10, Max(1, Integer(slot))) : 1}
}
; 頁面：角色名~開(0/1)~欄~格
BossLockCharSet(rawValue) {
    global INI
    f := StrSplit(rawValue, "~")
    if f.Length < 4 || Trim(f[1]) = ""
        return
    name := Trim(f[1])
    IniWrite f[2] = "1" ? "1" : "0", INI, "BossLock", name "|On"
    IniWrite IsInteger(f[3]) ? Min(4, Max(1, Integer(f[3]))) : 1, INI, "BossLock", name "|Bar"
    IniWrite IsInteger(f[4]) ? Min(10, Max(1, Integer(f[4]))) : 1, INI, "BossLock", name "|Slot"
    c := BlCfg(name)
    EventLog(name, "BL_CFG", "卡右鍵打王：" (c.on ? "參加｜F" c.bar " 第 " BcKey(c.slot) " 格" : "不參加"))
}

; ---- 小工具（測試時換成替身）----
BlSleep(ms) {
    global blTestDriver
    if IsObject(blTestDriver)
        return blTestDriver.Sleep(ms)
    Sleep ms
}
BlIdle() {
    global blTestDriver
    if IsObject(blTestDriver)
        return blTestDriver.Idle()
    return A_TimeIdlePhysical
}
BlForeground() {
    global blTestDriver
    if IsObject(blTestDriver)
        return blTestDriver.Foreground()
    return WinExist("A")
}
BlActivate(p) {
    global blTestDriver, apLastOwn
    if IsObject(blTestDriver)
        return blTestDriver.Activate(p)
    apLastOwn := A_TickCount
    if WinGetMinMax("ahk_id " p.hwnd) = -1
        WinRestore "ahk_id " p.hwnd
    WinActivate "ahk_id " p.hwnd
    ok := WinWaitActive("ahk_id " p.hwnd, , 2)
    Sleep 150   ; 遊戲剛拿到焦點時第一個按鍵偶爾收不到
    apLastOwn := A_TickCount
    return ok ? true : false
}
BlCursor() {
    global blTestDriver
    if IsObject(blTestDriver)
        return blTestDriver.Cursor()
    pt := Buffer(8, 0)
    DllCall("GetCursorPos", "Ptr", pt)
    return {x: NumGet(pt, 0, "Int"), y: NumGet(pt, 4, "Int")}
}
BlSetCursor(x, y) {
    global blTestDriver, apLastOwn
    if IsObject(blTestDriver)
        return blTestDriver.SetCursor(x, y)
    DllCall("SetCursorPos", "Int", x, "Int", y)
    apLastOwn := A_TickCount
}
BlRight(down) {
    global blTestDriver, apLastOwn
    if IsObject(blTestDriver)
        return down ? blTestDriver.Down() : blTestDriver.Up()
    DllCall("mouse_event", "UInt", down ? 0x0008 : 0x0010, "Int", 0, "Int", 0, "UInt", 0, "UPtr", 0)
    apLastOwn := A_TickCount
}
BlLeft(down) {
    global blTestDriver, apLastOwn
    if IsObject(blTestDriver)
        return down ? blTestDriver.LDown() : blTestDriver.LUp()
    DllCall("mouse_event", "UInt", down ? 0x0002 : 0x0004, "Int", 0, "Int", 0, "UInt", 0, "UPtr", 0)
    apLastOwn := A_TickCount
}
; 遊戲畫面在螢幕上的範圍
BlClientRect(p) {
    global blTestDriver
    if IsObject(blTestDriver)
        return blTestDriver.ClientRect(p)
    try {
        WinGetClientPos(&cx, &cy, &cw, &ch, "ahk_id " p.hwnd)
        return {x: cx, y: cy, w: cw, h: ch}
    }
    return 0
}
; 管理程式自己的小方塊（不搶焦點、永遠在最上面、幾乎透明）：放開右鍵時蓋在游標底下，「放開」就不會送到遊戲
BlCover(x, y) {
    global blTestDriver, blCoverGui
    if IsObject(blTestDriver)
        return blTestDriver.Cover(x, y)
    if !IsObject(blCoverGui) {
        blCoverGui := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x08000000")   ; WS_EX_NOACTIVATE
        blCoverGui.BackColor := "000000"
    }
    blCoverGui.Show("NA x" (x - 30) " y" (y - 30) " w60 h60")
    try WinSetTransparent 1, "ahk_id " blCoverGui.Hwnd
}
BlUncover() {
    global blTestDriver, blCoverGui
    if IsObject(blTestDriver)
        return blTestDriver.Uncover()
    if IsObject(blCoverGui)
        try blCoverGui.Hide()
}
; 遊戲畫面外面、離邊 40 像素（跨過視窗邊框）、在螢幕上的點（先找左邊，再右、上、下）
BlOutsidePoint(r, pt) {
    for c in [{x: r.x - 40, y: pt.y}, {x: r.x + r.w + 40, y: pt.y}, {x: pt.x, y: r.y - 40}, {x: pt.x, y: r.y + r.h + 40}]
        if BlOnScreen(c.x, c.y)
            return c
    return 0
}
BlOnScreen(x, y) {
    global blTestDriver
    if IsObject(blTestDriver)
        return blTestDriver.HasOwnProp("OnScreen") ? blTestDriver.OnScreen(x, y) : true
    return DllCall("MonitorFromPoint", "Int64", (y << 32) | (x & 0xFFFFFFFF), "UInt", 0, "Ptr") != 0   ; MONITOR_DEFAULTTONULL
}
; 遊戲畫面裡、游標底下真的是這個遊戲視窗的點（沒有被管理程式 / 小窗 / 別的視窗蓋住）
BlPointOnGame(p, r, pref) {
    cands := []
    if pref.x >= r.x && pref.x < r.x + r.w && pref.y >= r.y && pref.y < r.y + r.h
        cands.Push(pref)
    cands.Push({x: r.x + r.w // 2, y: r.y + r.h // 2})
    for f in [[0.3, 0.3], [0.7, 0.3], [0.3, 0.6], [0.7, 0.6], [0.5, 0.2], [0.5, 0.7]]
        cands.Push({x: r.x + Round(r.w * f[1]), y: r.y + Round(r.h * f[2])})
    for c in cands
        if BlWindowAt(c.x, c.y) = p.hwnd
            return c
    return 0
}
BlWindowAt(x, y) {
    global blTestDriver
    if IsObject(blTestDriver)
        return blTestDriver.HasOwnProp("WindowAt") ? blTestDriver.WindowAt(x, y) : blTestDriver.Foreground()
    hw := DllCall("WindowFromPoint", "Int64", (y << 32) | (x & 0xFFFFFFFF), "Ptr")
    return hw ? DllCall("GetAncestor", "Ptr", hw, "UInt", 2, "Ptr") : 0   ; GA_ROOT
}
; 游標原地動一下（遊戲 / Windows 更新游標底下是哪個視窗）
BlNudge(c) {
    BlSetCursor(c.x + 1, c.y)
    BlSleep(15)
    BlSetCursor(c.x, c.y)
    BlSleep(15)
}

; ---- 視窗疊在一起（v1.3.90.129）----
; 參加的角色視窗搬到 anchor 的位置、同樣大小（完全重疊）。回傳搬了幾個；已經重疊的不動
BlStackWindows(list, anchor := 0) {
    global blTestDriver
    if IsObject(blTestDriver) || !list.Length
        return 0
    if !IsObject(anchor)
        anchor := list[1]
    if !anchor.hwnd || !WinExist("ahk_id " anchor.hwnd)
        return 0
    try {
        if WinGetMinMax("ahk_id " anchor.hwnd) = -1
            WinRestore "ahk_id " anchor.hwnd
        WinGetPos(&ax, &ay, &aw, &ah, "ahk_id " anchor.hwnd)
    } catch
        return 0
    moved := []
    for p in list {
        if p = anchor || !p.hwnd || !WinExist("ahk_id " p.hwnd)
            continue
        try {
            if WinGetMinMax("ahk_id " p.hwnd) = -1
                WinRestore "ahk_id " p.hwnd
            WinGetPos(&x, &y, &w, &h, "ahk_id " p.hwnd)
            if Abs(x - ax) <= 2 && Abs(y - ay) <= 2 && Abs(w - aw) <= 2 && Abs(h - ah) <= 2
                continue
            WinMove ax, ay, aw, ah, "ahk_id " p.hwnd
            moved.Push(p.name)
        } catch as e {
            EventLog(p.name, "BL_STACK", "視窗疊不上去：" e.Message)
        }
    }
    if moved.Length
        EventLog("GLOBAL", "BL_STACK", "參加的角色視窗疊到 " anchor.name " 的位置（" ax "," ay " " aw "x" ah "）：" BcJoin(moved))
    return moved.Length
}
; ---- 開始 / 放開 ----
BlTip(text) {
    global blTestDriver
    if IsObject(blTestDriver)
        return
    ToolTip text
    SetTimer () => ToolTip(), -3000
}
BlSetState(state, text := "") {
    global BL_STATE, BL_TEXT
    BL_STATE := state, BL_TEXT := text
    try BossLockPushWeb()
}
; 參加的角色（遊戲視窗還在的，照帳號清單順序）
BlChars() {
    global profiles
    out := []
    for p in profiles {
        if !p.enabled || !p.hwnd || !BlCfg(p.name).on
            continue
        alive := false
        try alive := ProfileGameAlive(p)
        if alive
            out.Push(p)
    }
    return out
}
; 頁面 / 小窗按「開始」：等滑鼠停 2 秒（讓你把游標移到王身上）再開始
BossLockStart() {
    global BL_STATE, blWaitSince, blTestDriver
    if BL_STATE = "running" || BL_STATE = "waiting"
        return
    if !BlChars().Length {
        BlSetState("idle", "沒有勾選參加的角色（或遊戲視窗沒開）")
        return
    }
    ; 參加的角色視窗先疊在一起（疊在現在最前面的那隻上；最前面不是參加的角色就疊在第一隻上）
    chars := BlChars(), anchor := 0, fg := BlForeground()
    for p in chars
        if p.hwnd = fg
            anchor := p
    BlStackWindows(chars, anchor)
    blWaitSince := A_TickCount
    BlSetState("waiting", "把游標移到王身上，滑鼠停 2 秒就開始卡右鍵（30 秒內）")
    if !IsObject(blTestDriver)
        SetTimer BlWaitTick, 100
}
BlWaitTick() {
    global BL_STATE, blWaitSince, BL_IDLE_MS
    if BL_STATE != "waiting" {
        SetTimer BlWaitTick, 0
        return
    }
    if A_TickCount - blWaitSince > 30000 {
        SetTimer BlWaitTick, 0
        BlSetState("idle", "30 秒內滑鼠一直在動，沒有開始")
        return
    }
    if A_TickCount - blWaitSince >= 500 && BlIdle() >= BL_IDLE_MS {
        SetTimer BlWaitTick, 0
        BossLockRun()
    }
}
; 一隻角色：選技能 → 卡右鍵。回傳空字串 = 成功，不然是原因
BlLockOne(p, aim) {
    global INI
    c := BlCfg(p.name)
    if !BlActivate(p)
        return "叫不到前面"
    r := BlClientRect(p)
    if !IsObject(r) || r.w < 100
        return "讀不到遊戲畫面位置"
    ; 游標在這個視窗的畫面裡就照原位（王的位置），不在就放畫面中間
    pt := BlPointOnGame(p, r, aim)
    if !IsObject(pt)
        return "遊戲畫面都被別的視窗蓋住，找不到地方按右鍵"
    ; 選技能：F<欄> + 數字，讀回右鍵技能確認
    ; 讀技能欄偶爾讀不到（11/24 13:35 欸等等「沒有技能」，下一次又正常）：最多讀 4 次
    want := ""
    Loop 4 {
        want := BcBarSkills(p.pid, c.bar).Get(c.slot, "")
        if want != ""
            break
        BlSleep(250)
    }
    if want = ""
        return "F" c.bar " 第 " BcKey(c.slot) " 格沒有技能"
    if !IsObject(BcSelect(p, c.bar, c.slot, want, true))
        return "選不到 F" c.bar " 第 " BcKey(c.slot) " 格的技能"
    BlSetCursor(pt.x, pt.y)
    BlNudge(pt)
    BlRight(true)
    BlSleep(80)
    if IniRead(INI, "BossLock", "Method", "drag") = "drag" {
        ; v1.3.90.101：11/24 12:26 實測「蓋小方塊」沒卡住（遊戲看的是放開時游標在不在遊戲畫面裡）→ 預設改成照手動：
        ; 壓著右鍵一路拖到遊戲畫面外面（左 / 右 / 上 / 下找一個在螢幕上的點）放開，再拖回原位。放開的地方也蓋小方塊，免得送到別的視窗。
        out := BlOutsidePoint(r, pt)
        if !IsObject(out) {
            BlRight(false)
            return "遊戲畫面四邊外面都不在螢幕上，沒地方放開右鍵"
        }
        BlCover(out.x, out.y)
        BlSleep(30)
        Loop 8 {
            BlSetCursor(pt.x + (out.x - pt.x) * A_Index // 8, pt.y + (out.y - pt.y) * A_Index // 8)
            BlSleep(15)
        }
        BlSleep(60)
        BlRight(false)
        BlSleep(60)
        BlUncover()
        BlSleep(20)
        Loop 8 {
            BlSetCursor(out.x + (pt.x - out.x) * A_Index // 8, out.y + (pt.y - out.y) * A_Index // 8)
            BlSleep(15)
        }
    } else {
        BlCover(pt.x, pt.y)
        BlSleep(30)
        BlNudge(pt)
        BlRight(false)
        BlSleep(40)
        BlUncover()
        BlSleep(20)
    }
    BlNudge(pt)
    return ""
}
BossLockRun(list := 0, aimFn := 0) {   ; aimFn(p)：每隻角色自己的瞄準點（螢幕座標；自動進場打王用，視窗沒疊在一起時每隻的王在不同位置）
    global BL_STATE, blLocked, foregroundOwner, apLastOwn
    if foregroundOwner != "" && foregroundOwner != "bosslock" && foregroundOwner != "bossraid" {
        BlSetState("idle", "有其他自動操作正在用遊戲視窗（" foregroundOwner "），等它做完再按")
        return
    }
    why := ""
    try why := ApBlockerRaw()
    if why != "" && why != "多開打王卡右鍵中" {   ; 已經卡著的再卡一次不算
        BlSetState("idle", "現在不能卡右鍵：" why)
        return
    }
    chars := IsObject(list) ? list.Clone() : BlChars()   ; 自動進場打王：只卡有進場的
    orig := BlForeground(), aim := BlCursor()
    ; 原本最前面的那隻最後做（做完它就在最前面）
    origP := 0
    for i, p in chars
        if p.hwnd = orig {
            origP := chars.RemoveAt(i)
            break
        }
    if IsObject(origP)
        chars.Push(origP)
    BlSetState("running", "卡右鍵中…（不要動滑鼠）")
    ownBefore := foregroundOwner
    foregroundOwner := "bosslock", apLastOwn := A_TickCount
    ok := [], bad := []
    try {
        for p in chars {
            err := ""
            a := aim
            if IsObject(aimFn) {
                try {
                    q := aimFn(p)
                    if IsObject(q)
                        a := q
                }
            }
            try err := BlLockOne(p, a)
            catch as e
                err := e.Message
            if err = "" {
                blLocked[p.name] := A_TickCount
                c := BlCfg(p.name)
                ok.Push(p.name)
                EventLog(p.name, "BL_LOCK", "卡右鍵｜F" c.bar " 第 " BcKey(c.slot) " 格")
            } else {
                bad.Push(p.name "：" err)
                EventLog(p.name, "BL_FAIL", "卡右鍵失敗｜" err)
            }
        }
    } finally {
        BlUncover()
        try {
            if orig && orig != BlForeground()
                BlActivateHwnd(orig)
        }
        BlSetCursor(aim.x, aim.y)
        foregroundOwner := ownBefore = "bossraid" ? "bossraid" : ""
    }
    msg := (ok.Length ? "卡住了：" BcJoin(ok) : "一隻都沒有卡住") (bad.Length ? "｜失敗：" BcJoin(bad) : "")
    BlSetState(blLocked.Count ? "locked" : "idle", msg)
    BlTip("🎯 " msg)
}
; 只重卡一隻（命運箱子開完那隻）：叫到前面 → 卡右鍵 → 叫回原本最前面的視窗、游標放回原位
BlRelockOne(p, aim) {
    global foregroundOwner, apLastOwn, blLocked
    if foregroundOwner != "" && foregroundOwner != "bossraid"
        return "其他功能正在操作遊戲視窗（" foregroundOwner "）"
    orig := BlForeground(), cur := BlCursor(), ownBefore := foregroundOwner
    foregroundOwner := "bosslock", apLastOwn := A_TickCount
    err := ""
    try {
        try err := BlLockOne(p, aim)
        catch as e
            err := e.Message
        if err = "" {
            blLocked[p.name] := A_TickCount
            c := BlCfg(p.name)
            EventLog(p.name, "BL_LOCK", "卡右鍵｜F" c.bar " 第 " BcKey(c.slot) " 格｜游標 (" aim.x "," aim.y ")")
        }
    } finally {
        BlUncover()
        try {
            if orig && orig != BlForeground()
                BlActivateHwnd(orig)
        }
        BlSetCursor(cur.x, cur.y)
        foregroundOwner := ownBefore
    }
    return err
}
BlActivateHwnd(hw) {
    global blTestDriver, apLastOwn
    if IsObject(blTestDriver)
        return blTestDriver.Activate({hwnd: hw})
    if WinExist("ahk_id " hw) {
        WinActivate "ahk_id " hw
        apLastOwn := A_TickCount
    }
}
; 全部放開：每隻叫到前面、游標拉到遊戲視窗外面按一下左鍵（手動解除卡右鍵的方式）
BossLockStop() {
    global BL_STATE, blLocked, profiles, foregroundOwner, apLastOwn, blTestDriver
    if BL_STATE = "waiting" {
        if !IsObject(blTestDriver)
            SetTimer BlWaitTick, 0
        BlSetState(blLocked.Count ? "locked" : "idle", "取消開始")
        return
    }
    if BL_STATE = "running"
        return
    if !blLocked.Count {
        BlSetState("idle", "")
        return
    }
    orig := BlForeground(), aim := BlCursor()
    foregroundOwner := "bosslock", apLastOwn := A_TickCount
    done := []
    try {
        for p in profiles {
            if !blLocked.Has(p.name)
                continue
            try {
                if p.hwnd && BlActivate(p) {
                    r := BlClientRect(p)
                    ; v1.3.90.102：11/24 12:31 實測按頁面的「全部放開」沒放開：游標停在管理程式上，右鍵按到管理程式而不是遊戲。
                    ; 改找遊戲畫面裡「游標底下真的是這個遊戲視窗」的點（游標原位 → 畫面中間 → 四個角附近）
                    pt := IsObject(r) ? BlPointOnGame(p, r, aim) : 0
                    if !IsObject(pt) {   ; v1.3.90.125：11/24 17:02 欸等等一次「被蓋住」：再叫到前面一次、等 0.3 秒再找
                        BlActivate(p)
                        BlSleep(300)
                        r := BlClientRect(p)
                        pt := IsObject(r) ? BlPointOnGame(p, r, aim) : 0
                    }
                    if !IsObject(pt) {
                        EventLog(p.name, "BL_FAIL", "放開失敗｜遊戲畫面都被別的視窗蓋住，找不到地方按右鍵")
                        continue
                    }
                    BlSetCursor(pt.x, pt.y)
                    BlNudge(pt)
                    ; v1.3.90.104：手動解除卡右鍵 = 游標拉到遊戲視窗外面按一下左鍵（11/24 12:36 在畫面裡按右鍵放不開）。
                    ; 外面那個點先蓋管理程式的小方塊，左鍵不會按到桌面 / 別的視窗
                    out := BlOutsidePoint(r, pt)
                    if !IsObject(out) {
                        EventLog(p.name, "BL_FAIL", "放開失敗｜遊戲畫面四邊外面都不在螢幕上，沒地方按左鍵")
                        continue
                    }
                    BlCover(out.x, out.y)
                    BlSleep(30)
                    Loop 8 {
                        BlSetCursor(pt.x + (out.x - pt.x) * A_Index // 8, pt.y + (out.y - pt.y) * A_Index // 8)
                        BlSleep(15)
                    }
                    BlSleep(40)
                    BlLeft(true)
                    BlSleep(60)
                    BlLeft(false)
                    BlSleep(40)
                    BlUncover()
                }
            }
            done.Push(p.name)
            EventLog(p.name, "BL_RELEASE", "放開卡住的右鍵（拉到視窗外按一下左鍵）")
        }
    } finally {
        blLocked := Map()
        try {
            if orig && orig != BlForeground()
                BlActivateHwnd(orig)
        }
        BlSetCursor(aim.x, aim.y)
        foregroundOwner := ""
    }
    BlSetState("idle", "已放開：" BcJoin(done))
    BlTip("🎯 已放開右鍵：" BcJoin(done))
}
; 放開一隻（不管程式記不記得它卡著；重開管理程式後用）：叫到前面 → 游標拉到視窗外按一下左鍵。回傳空字串 = 做了
BlReleaseOne(p) {
    if !p.hwnd || !BlActivate(p)
        return "叫不到前面"
    r := BlClientRect(p)
    if !IsObject(r)
        return "讀不到遊戲畫面位置"
    c := BlCursor()
    pt := BlPointOnGame(p, r, c)
    if !IsObject(pt)
        return "遊戲畫面被蓋住"
    out := BlOutsidePoint(r, pt)
    if !IsObject(out)
        return "畫面外沒有地方按左鍵"
    BlSetCursor(pt.x, pt.y)
    BlNudge(pt)
    BlCover(out.x, out.y)
    BlSleep(30)
    Loop 8 {
        BlSetCursor(pt.x + (out.x - pt.x) * A_Index // 8, pt.y + (out.y - pt.y) * A_Index // 8)
        BlSleep(15)
    }
    BlSleep(40)
    BlLeft(true)
    BlSleep(60)
    BlLeft(false)
    BlSleep(40)
    BlUncover()
    BlSetCursor(c.x, c.y)
    return ""
}
; 頁面 / 小窗的一個按鈕：沒卡 → 開始；卡著 → 全部放開
BossLockToggle() {
    global BL_STATE
    if BL_STATE = "locked" || BL_STATE = "waiting"
        BossLockStop()
    else
        BossLockStart()
}

; ---- 視窗堆疊順序（v1.3.90.111）----
; 遊戲視窗由上到下的順序：Map(hwnd → 第幾層，1 = 最前面)。最小化的不算
BlZOrder() {
    global blTestDriver
    out := Map()
    if IsObject(blTestDriver)
        return blTestDriver.HasOwnProp("ZOrder") ? blTestDriver.ZOrder() : out
    k := 0
    try {
        for hw in WinGetList("ahk_exe Game.exe") {   ; WinGetList 由上到下
            if WinGetMinMax("ahk_id " hw) = -1
                continue
            k += 1
            out[hw] := k
        }
    }
    return out
}
global blZSig := ""
; 堆疊順序變了就更新頁面（多開打王頁開著時每秒看一次）
BlZWatch() {
    global blZSig, profiles, webReady
    if !webReady
        return
    z := BlZOrder(), sig := ""
    for p in profiles
        if p.enabled
            sig .= p.name ":" (p.hwnd && z.Has(p.hwnd) ? z[p.hwnd] : 0) ";"
    if sig != blZSig {
        blZSig := sig
        BossLockPushWeb()
    }
}
BossLockWatchZ(on) {
    SetTimer BlZWatch, on ? 1000 : 0
}
; ---- 頁面資料 ----
; 每個角色：參加 / 欄 / 格 / 卡住了沒、F1～F4 每一格的技能名稱
BossLockPushWeb() {
    global webReady, WVCore, profiles, BL_STATE, BL_TEXT, blLocked, INI
    if !webReady || !WVCore
        return
    rows := "", zo := BlZOrder()
    for p in profiles {
        if !p.enabled
            continue
        alive := false
        try alive := p.pid && ProfileGameAlive(p)
        z := p.hwnd && zo.Has(p.hwnd) ? zo[p.hwnd] : 0
        rc := ""   ; 視窗位置（檢查參加的角色有沒有完全重疊）
        if p.hwnd {
            try {
                WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " p.hwnd)
                rc := ',"rect":[' wx ',' wy ',' ww ',' wh ']'
            }
        }
        bars := ""
        if alive {
            names := Map()
            try {
                for s in MiningSkillSlots(p.pid)
                    if s.bar <= 4
                        names[s.bar "-" s.key] := s.name != "" ? s.name : s.id
            }
            Loop 4 {
                b := A_Index, row := ""
                Loop 10
                    row .= (row = "" ? "" : ",") '"' JsonEscapeWeb(names.Get(b "-" A_Index, "")) '"'
                bars .= (bars = "" ? "" : ",") "[" row "]"
            }
        }
        c := BlCfg(p.name)
        rows .= (rows = "" ? "" : ",") '{"name":"' JsonEscapeWeb(p.name) '","alive":' (alive ? "true" : "false") ',"on":' (c.on ? "true" : "false")
            . ',"bar":' c.bar ',"slot":' c.slot ',"locked":' (blLocked.Has(p.name) ? "true" : "false") ',"z":' z rc ',"names":[' bars ']}'
    }
    br := "", brNm := "BrWebJson"   ; 自動進場打王的資料（BossRaid.ahk；測試只載入這個檔時沒有）
    try {
        brf := %brNm%
        br := brf()
    }
    try WVCore.PostWebMessageAsJson('{"type":"bosslock","data":{"state":"' BL_STATE '","text":"' JsonEscapeWeb(BL_TEXT) '","chars":[' rows ']' br '}}')
}
