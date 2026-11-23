; 縮小小窗：主視窗縮小時，在螢幕角落顯示一個永遠在最上面的小窗（不搶遊戲的焦點）。
; 分三頁，滑鼠滾輪或 ◀ ▶ 切換：① 概況（監控狀態、啟用中的功能）② 角色清單 ③ 功能開關（忘記勾的功能直接在這裡開）。
; 開關直接呼叫各功能原本的設定函式，結果和在主視窗按一樣；每日討伐要選角色和地圖，只顯示狀態，請回主視窗設定。
global MINI_ENABLED := Integer(IniRead(INI, "MiniWindow", "Enabled", "0"))
global MINI_PAGES := 3, MINI_ROWS := 7
global miniGui := 0, miniPage := 1, miniPageCtl := Map(), miniToggleCtl := Map(), miniText := Map(), miniLastSave := 0
; 自動化操作遊戲視窗時小窗暫時讓開（11/18 只剩一台螢幕，小窗蓋在欸等 / 豆奶的遊戲畫面上，
; 每日討伐點護士、換每日道具找視窗連續失敗快 2 小時）：miniShown = 應該顯示，miniYielded = 暫時藏起來
global miniShown := false, miniYielded := false, miniIdleSince := 0
; 監控開關（第 1 頁）：開著是黑底白字，點一下要再點一次才停止（3 秒內），避免誤觸
global miniStopArmed := 0, miniMonLook := ""

; 可在小窗開關的功能：{key, label, on}
MiniFeatures() {
    global MBOX_ENABLED, AP_ENABLED, CW_ENABLED, LF_ENABLED, autoSwitchRunning, BC_ON
    return [{key: "mbox", label: "命運箱子", on: MBOX_ENABLED ? 1 : 0}
        , {key: "party", label: "自動組隊", on: AP_ENABLED ? 1 : 0}
        , {key: "companion", label: "寵物 / 雇傭兵監測", on: CW_ENABLED ? 1 : 0}
        , {key: "lagfix", label: "變慢自動過圖", on: LF_ENABLED ? 1 : 0}
        , {key: "switcher", label: "視窗按鍵精靈", on: autoSwitchRunning ? 1 : 0}
        , {key: "buffcast", label: "一鍵施法（打字前先關）", on: BC_ON ? 1 : 0}]
}

; 開 / 關一個功能；成功與否以重新讀到的狀態為準（呼叫端會馬上刷新）
MiniToggle(key) {
    global MBOX_ENABLED, MBOX_INTERVAL_SEC, AP_ENABLED, AP_SETTLE_SEC, CW_ENABLED, CW_PET, CW_MERC, CW_DOLL
    global LF_ENABLED, LF_PING_MS, autoSwitchRunning, BC_ON
    if key = "mbox" {
        MBoxSetGlobal((MBOX_ENABLED ? 0 : 1) "~" MBOX_INTERVAL_SEC), MBoxPushWeb()
    } else if key = "party" {
        ApSetGlobal((AP_ENABLED ? 0 : 1) "~" AP_SETTLE_SEC), ApPushWeb()
    } else if key = "companion" {
        CompanionSet((CW_ENABLED ? 0 : 1) "~" CW_PET "~" CW_MERC "~" CW_DOLL), CompanionPushWeb()
    } else if key = "lagfix" {
        LagFixSet((LF_ENABLED ? 0 : 1) "~" LF_PING_MS), LagFixPushWeb()
    } else if key = "buffcast" {
        BuffCastSetGlobal(BC_ON ? "0" : "1")
    } else if key = "switcher" {
        if autoSwitchRunning
            StopAutoWindowSwitch()
        else
            StartAutoWindowSwitch()
    }
}

; 小窗角色清單的類型欄（首頁「角色類型」）：沒選就留空
MiniRoleTypeShort(p) {
    t := p.HasOwnProp("roleType") ? p.roleType : ""
    return t = "" ? "" : RoleTypeText(t)
}

MiniProfileCounts() {
    global profiles
    total := 0, alive := 0, watching := 0
    for p in profiles {
        if !p.enabled
            continue
        total++
        if ProfileGameAlive(p)
            alive++
        if p.state = "監控中"
            watching++
    }
    return {total: total, alive: alive, watching: watching}
}

MiniBuild() {
    global miniGui, miniPageCtl, miniToggleCtl, miniText, MINI_PAGES, MINI_ROWS
    g := Gui("+AlwaysOnTop +ToolWindow -Caption +Border +E0x08000000", "HIHIYONG 小窗")   ; E0x08000000：點它不會搶走遊戲視窗的焦點
    g.BackColor := "FFFFFF"
    g.SetFont("s9 c1F2937", "Microsoft JhengHei UI")
    g.MarginX := 0, g.MarginY := 0
    miniText["title"] := g.AddText("x10 y6 w168 h20 +0x200", "HIHIYONG")
    miniText["title"].SetFont("s9 Bold c2B6CB0")
    prev := g.AddButton("x180 y3 w26 h22", "◀"), nxt := g.AddButton("x208 y3 w26 h22", "▶")
    prev.OnEvent("Click", (*) => MiniGo(-1)), nxt.OnEvent("Click", (*) => MiniGo(1))
    miniText["page"] := g.AddText("x238 y6 w40 h20 +0x200 Center", "1/" MINI_PAGES)
    g.AddText("x0 y28 w282 h1 +0x10")   ; 分隔線
    for n in [1, 2, 3]
        miniPageCtl[n] := []
    ; 第 1 頁：概況。最上面是監控開關（點一下開 / 關），右邊是說明
    miniText["mon"] := g.AddText("x12 y34 w112 h26 +0x200 Center +Border", "")
    miniText["mon"].OnEvent("Click", (*) => MiniMonitorClick())
    miniText["monHint"] := g.AddText("x132 y34 w140 h26 +0x200 c6B7280", "")
    miniText["chars"] := g.AddText("x12 y68 w258 h20 +0x200", "")
    miniText["act"] := g.AddText("x12 y92 w258 h60", "")
    miniText["dh"] := g.AddText("x12 y156 w258 h20 +0x200", "")
    for c in [miniText["mon"], miniText["monHint"], miniText["chars"], miniText["act"], miniText["dh"]]
        miniPageCtl[1].Push(c)
    ; 第 2 頁：角色清單。三欄對齊（角色｜類型｜狀態），每列 22 px，不再擠成一行字
    miniText["rows"] := []
    Loop MINI_ROWS {
        y := 36 + (A_Index - 1) * 22
        r := {name: g.AddText("x12 y" y " w92 h22 +0x200", "")
            , type: g.AddText("x106 y" y " w72 h22 +0x200 c6B7280", "")
            , state: g.AddText("x180 y" y " w92 h22 +0x200", "")}
        miniText["rows"].Push(r)
        miniPageCtl[2].Push(r.name, r.type, r.state)
    }
    miniText["more"] := g.AddText("x12 y" (36 + (MINI_ROWS - 1) * 22) " w258 h22 +0x200 c6B7280", "")
    miniPageCtl[2].Push(miniText["more"])
    ; 第 3 頁：功能開關
    for i, f in MiniFeatures() {
        key := f.key
        cb := g.AddCheckbox("x12 y" (36 + (i - 1) * 24) " w258 h22", f.label)
        cb.OnEvent("Click", MiniOnToggle.Bind(key))
        miniToggleCtl[key] := cb, miniPageCtl[3].Push(cb)
    }
    openBtn := g.AddButton("x12 y206 w120 h26", "↗ 開啟主視窗")
    openBtn.OnEvent("Click", (*) => MiniOpenMain())
    miniText["note"] := g.AddText("x138 y210 w140 h20 +0x200 c6B7280", "滾輪可切頁")
    miniGui := g
    OnMessage(0x201, MiniDrag)     ; 按住標題 / 空白處拖曳
    OnMessage(0x20A, MiniWheel)    ; 滾輪切頁
}

MiniOnToggle(key, *) {
    MiniToggle(key)
    MiniRefresh()
}

; 監控開關：沒在監控 → 馬上開始；監控中 → 第一下只提示，3 秒內再點一次才停止
MiniMonitorClick() {
    global running, miniStopArmed
    if !running {
        miniStopArmed := 0
        StartMonitoring()
    } else if miniStopArmed && A_TickCount - miniStopArmed < 3000 {
        miniStopArmed := 0
        StopMonitoring()
        AddRecentEvent("小窗 → 停止監控")
    } else {
        miniStopArmed := A_TickCount
    }
    MiniRefresh()
}

MiniOpenMain() {
    global WebGui
    MiniHide()
    try {
        WinRestore "ahk_id " WebGui.Hwnd
        WinActivate "ahk_id " WebGui.Hwnd
    }
}

MiniGo(delta) {
    global miniPage, MINI_PAGES
    miniPage := Mod(miniPage - 1 + delta + MINI_PAGES, MINI_PAGES) + 1
    MiniRefresh()
}

MiniDrag(wParam, lParam, msg, hwnd) {
    global miniGui, miniText
    if !IsObject(miniGui)
        return
    if hwnd = miniGui.Hwnd || hwnd = miniText["title"].Hwnd {
        PostMessage 0xA1, 2, , , "ahk_id " miniGui.Hwnd   ; WM_NCLBUTTONDOWN + HTCAPTION：拖曳視窗
        return 0
    }
}

MiniWheel(wParam, lParam, msg, hwnd) {
    global miniGui
    if !IsObject(miniGui) || !WinExist("ahk_id " miniGui.Hwnd)
        return
    ; 滑鼠在小窗上才切頁
    MouseGetPos , , &under
    if under != miniGui.Hwnd
        return
    delta := (wParam >> 16) & 0xFFFF
    if delta > 0x7FFF
        delta -= 0x10000
    MiniGo(delta > 0 ? -1 : 1)
    return 0
}

MiniRefresh() {
    global miniGui, miniPage, miniPageCtl, miniToggleCtl, miniText, MINI_PAGES, MINI_ROWS, running, DH_RUNNING, profiles, miniStopArmed, miniMonLook
    if !IsObject(miniGui)
        return
    for n, ctls in miniPageCtl
        for c in ctls
            c.Visible := (n = miniPage)
    miniText["page"].Text := miniPage "/" MINI_PAGES
    miniText["note"].Visible := true
    cnt := MiniProfileCounts()
    feats := MiniFeatures()
    if miniPage = 1 {
        armed := running && miniStopArmed && A_TickCount - miniStopArmed < 3000
        if !armed
            miniStopArmed := 0
        ; 開著：黑底白字；要停止的確認：紅底；關著：白底灰字（點了開始）
        ; 每秒刷新：樣子有變才重畫，避免閃
        look := armed ? "armed" : running ? "on" : "off"
        if look != miniMonLook {
            miniMonLook := look
            miniText["mon"].Opt(armed ? "+BackgroundB91C1C" : running ? "+Background1F2937" : "+BackgroundF3F4F6")
            miniText["mon"].SetFont(running ? "Bold cFFFFFF" : "Bold c6B7280")
            miniText["mon"].Text := armed ? "再點一次停止" : running ? "● 監控中" : "○ 監控已關"
        }
        miniText["monHint"].Text := armed ? "3 秒內沒點就取消" : running ? "點一下可停止監控" : "點一下開始監控"
        miniText["chars"].Text := "角色：" cnt.alive " / " cnt.total " 在線｜" cnt.watching " 個監控中"
        act := ""
        for f in feats
            if f.on
                act .= (act = "" ? "" : "、") f.label
        miniText["act"].Text := "啟用中：" (act = "" ? "（沒有，滾輪到第 3 頁開啟）" : act)
        miniText["dh"].Text := "每日討伐：" (DH_RUNNING ? "執行中" : "停止（請在主視窗設定）")
    } else if miniPage = 2 {
        i := 0, extra := 0
        for p in profiles {
            if !p.enabled
                continue
            if i >= MINI_ROWS {
                extra++
                continue
            }
            i++
            alive := ProfileGameAlive(p)
            r := miniText["rows"][i]
            r.name.Text := (alive ? "● " : "○ ") p.name
            r.name.SetFont(alive ? "c1F2937" : "c9CA3AF")
            r.type.Text := MiniRoleTypeShort(p)
            r.state.Text := alive ? p.state : "未連線"
            r.state.SetFont(alive ? "c1F2937" : "c9CA3AF")
        }
        Loop MINI_ROWS - i {
            r := miniText["rows"][i + A_Index]
            r.name.Text := (i = 0 && A_Index = 1) ? "沒有啟用的角色" : "", r.type.Text := "", r.state.Text := ""
        }
        ; 超過列數：最後一列改成一行提示（三欄先清空，避免字疊在一起）
        miniText["more"].Visible := extra > 0
        if extra {
            r := miniText["rows"][MINI_ROWS]
            r.name.Text := "", r.type.Text := "", r.state.Text := ""
            miniText["more"].Text := "…還有 " (extra + 1) " 個角色（在主視窗查看）"
        }
    } else {
        for f in feats
            miniToggleCtl[f.key].Value := f.on
    }
}

MiniShow() {
    global miniGui, miniPage, miniShown, miniYielded
    if !IsObject(miniGui)
        MiniBuild()
    pos := MiniSavedPos()
    miniGui.Show("NoActivate x" pos.x " y" pos.y " w282 h238")
    miniShown := true, miniYielded := false
    MiniRefresh()
    SetTimer MiniRefresh, 1000
    SetTimer MiniGuardTick, 200
}

MiniHide() {
    global miniGui, miniShown, miniYielded
    SetTimer MiniRefresh, 0
    SetTimer MiniGuardTick, 0
    if !IsObject(miniGui)
        return
    if !miniYielded
        MiniSavePos()
    miniShown := false, miniYielded := false
    miniGui.Hide()
}

; 有自動化在操作遊戲視窗（前景鎖、重新登入）
MiniAutomationBusy() {
    global foregroundOwner, activeRecoveryHwnd
    return foregroundOwner != "" || activeRecoveryHwnd
}

; 小窗蓋住任何一個遊戲視窗
MiniOverlapsGame() {
    global miniGui, profiles
    try WinGetPos &mx, &my, &mw, &mh, "ahk_id " miniGui.Hwnd
    catch
        return false
    for p in profiles {
        if !p.hwnd
            continue
        try {
            WinGetPos &gx, &gy, &gw, &gh, "ahk_id " p.hwnd
            if mx < gx + gw && gx < mx + mw && my < gy + gh && gy < my + mh
                return true
        }
    }
    return false
}

; 暫時藏起來（不記位置、不停計時器）；自動化做完 2 秒後 MiniGuardTick 會放回來
MiniYield() {
    global miniGui, miniShown, miniYielded, miniIdleSince
    if !miniShown || miniYielded || !IsObject(miniGui)
        return false
    MiniSavePos()
    miniGui.Hide()
    miniYielded := true, miniIdleSince := 0
    return true
}

MiniGuardTick() {
    global miniGui, miniShown, miniYielded, miniIdleSince
    if !miniShown || !IsObject(miniGui)
        return
    if MiniAutomationBusy() {
        miniIdleSince := 0
        if !miniYielded && MiniOverlapsGame()
            MiniYield()
        return
    }
    if !miniYielded
        return
    if !miniIdleSince {
        miniIdleSince := A_TickCount
        return
    }
    if A_TickCount - miniIdleSince >= 2000 {
        pos := MiniSavedPos()
        miniGui.Show("NoActivate x" pos.x " y" pos.y " w282 h238")
        miniYielded := false
    }
}

MiniSavedPos() {
    global INI
    x := IniRead(INI, "MiniWindow", "X", ""), y := IniRead(INI, "MiniWindow", "Y", "")
    if IsInteger(x) && IsInteger(y) {
        ; 存的位置在目前的螢幕範圍內才用（換過螢幕設定就不用）
        Loop MonitorGetCount() {
            MonitorGetWorkArea(A_Index, &l, &t, &r, &b)
            if x >= l - 10 && x <= r - 60 && y >= t - 10 && y <= b - 40
                return {x: Integer(x), y: Integer(y)}
        }
    }
    MonitorGetWorkArea(MonitorGetPrimary(), &l, &t, &r, &b)
    return {x: r - 300, y: b - 260}   ; 預設：主螢幕右下角
}

MiniSavePos() {
    global INI, miniGui
    try {
        WinGetPos &x, &y, , , "ahk_id " miniGui.Hwnd
        IniWrite x, INI, "MiniWindow", "X"
        IniWrite y, INI, "MiniWindow", "Y"
    }
}

; 主視窗大小改變時呼叫：縮小 → 顯示小窗（有勾選才顯示）；還原 → 收起
MiniSync(minMax) {
    global MINI_ENABLED
    if MINI_ENABLED && minMax = -1
        MiniShow()
    else
        MiniHide()
}

; 設定頁的勾選：1 / 0
MiniSetEnabled(raw) {
    global INI, MINI_ENABLED, WebGui
    MINI_ENABLED := (raw + 0) = 1 ? 1 : 0
    IniWrite MINI_ENABLED, INI, "MiniWindow", "Enabled"
    minMax := 0
    try minMax := WinGetMinMax("ahk_id " WebGui.Hwnd)
    MiniSync(minMax)
}
