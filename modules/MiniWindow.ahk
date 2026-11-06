; 縮小小窗：主視窗縮小時，在螢幕角落顯示一個永遠在最上面的小窗（不搶遊戲的焦點）。
; 分三頁，滑鼠滾輪或 ◀ ▶ 切換：① 概況（監控狀態、啟用中的功能）② 角色清單 ③ 功能開關（忘記勾的功能直接在這裡開）。
; 開關直接呼叫各功能原本的設定函式，結果和在主視窗按一樣；每日討伐要選角色和地圖，只顯示狀態，請回主視窗設定。
global MINI_ENABLED := Integer(IniRead(INI, "MiniWindow", "Enabled", "0"))
global MINI_PAGES := 3, MINI_ROWS := 7
global miniGui := 0, miniPage := 1, miniPageCtl := Map(), miniToggleCtl := Map(), miniText := Map(), miniLastSave := 0

; 可在小窗開關的功能：{key, label, on}
MiniFeatures() {
    global MBOX_ENABLED, AP_ENABLED, CW_ENABLED, LF_ENABLED, SC_ENABLED, autoSwitchRunning
    return [{key: "mbox", label: "命運箱子", on: MBOX_ENABLED ? 1 : 0}
        , {key: "party", label: "自動組隊", on: AP_ENABLED ? 1 : 0}
        , {key: "companion", label: "寵物 / 雇傭兵監測", on: CW_ENABLED ? 1 : 0}
        , {key: "lagfix", label: "變慢自動過圖", on: LF_ENABLED ? 1 : 0}
        , {key: "skillcombo", label: "技能組合", on: SC_ENABLED ? 1 : 0}
        , {key: "switcher", label: "視窗按鍵精靈", on: autoSwitchRunning ? 1 : 0}]
}

; 開 / 關一個功能；成功與否以重新讀到的狀態為準（呼叫端會馬上刷新）
MiniToggle(key) {
    global MBOX_ENABLED, MBOX_INTERVAL_SEC, AP_ENABLED, AP_SETTLE_SEC, CW_ENABLED, CW_PET, CW_MERC, CW_DOLL
    global LF_ENABLED, LF_PING_MS, SC_ENABLED, SC_PAUSE_KEY, autoSwitchRunning
    if key = "mbox" {
        MBoxSetGlobal((MBOX_ENABLED ? 0 : 1) "~" MBOX_INTERVAL_SEC), MBoxPushWeb()
    } else if key = "party" {
        ApSetGlobal((AP_ENABLED ? 0 : 1) "~" AP_SETTLE_SEC), ApPushWeb()
    } else if key = "companion" {
        CompanionSet((CW_ENABLED ? 0 : 1) "~" CW_PET "~" CW_MERC "~" CW_DOLL), CompanionPushWeb()
    } else if key = "lagfix" {
        LagFixSet((LF_ENABLED ? 0 : 1) "~" LF_PING_MS), LagFixPushWeb()
    } else if key = "skillcombo" {
        SkillComboSetGlobal((SC_ENABLED ? 0 : 1) "~" SC_PAUSE_KEY), SkillComboPushWeb()
    } else if key = "switcher" {
        if autoSwitchRunning
            StopAutoWindowSwitch()
        else
            StartAutoWindowSwitch()
    }
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
    ; 第 1 頁：概況
    miniText["mon"] := g.AddText("x12 y36 w258 h20 +0x200", "")
    miniText["chars"] := g.AddText("x12 y58 w258 h20 +0x200", "")
    miniText["act"] := g.AddText("x12 y82 w258 h64", "")
    miniText["dh"] := g.AddText("x12 y150 w258 h20 +0x200", "")
    startBtn := g.AddButton("x12 y174 w120 h26", "▶ 開始監控")
    startBtn.OnEvent("Click", (*) => MiniStartMonitoring())
    miniText["startBtn"] := startBtn
    for c in [miniText["mon"], miniText["chars"], miniText["act"], miniText["dh"], startBtn]
        miniPageCtl[1].Push(c)
    ; 第 2 頁：角色清單
    miniText["rows"] := []
    Loop MINI_ROWS {
        t := g.AddText("x12 y" (36 + (A_Index - 1) * 20) " w258 h20 +0x200", "")
        miniText["rows"].Push(t), miniPageCtl[2].Push(t)
    }
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

MiniStartMonitoring() {
    StartMonitoring()
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
    global miniGui, miniPage, miniPageCtl, miniToggleCtl, miniText, MINI_PAGES, MINI_ROWS, running, DH_RUNNING, profiles
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
        miniText["mon"].Text := (running ? "● 監控中" : "○ 尚未監控")
        miniText["mon"].SetFont(running ? "Bold c15803D" : "Bold cB45309")
        miniText["chars"].Text := "角色：" cnt.alive " / " cnt.total " 在線｜" cnt.watching " 個監控中"
        act := ""
        for f in feats
            if f.on
                act .= (act = "" ? "" : "、") f.label
        miniText["act"].Text := "啟用中：" (act = "" ? "（沒有，滾輪到第 3 頁開啟）" : act)
        miniText["dh"].Text := "每日討伐：" (DH_RUNNING ? "執行中" : "停止（請在主視窗設定）")
        miniText["startBtn"].Visible := !running
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
            miniText["rows"][i].Text := (alive ? "● " : "○ ") p.name "　" (alive ? p.state : "未連線")
            miniText["rows"][i].SetFont(alive ? "c1F2937" : "c9CA3AF")
        }
        if extra
            miniText["rows"][MINI_ROWS].Text := "…還有 " extra " 個角色（在主視窗查看）"
        Loop MINI_ROWS - i
            miniText["rows"][i + A_Index].Text := (i = 0 && A_Index = 1) ? "沒有啟用的角色" : ""
    } else {
        for f in feats
            miniToggleCtl[f.key].Value := f.on
    }
}

MiniShow() {
    global miniGui, miniPage
    if !IsObject(miniGui)
        MiniBuild()
    pos := MiniSavedPos()
    miniGui.Show("NoActivate x" pos.x " y" pos.y " w282 h238")
    MiniRefresh()
    SetTimer MiniRefresh, 1000
}

MiniHide() {
    global miniGui
    SetTimer MiniRefresh, 0
    if !IsObject(miniGui)
        return
    MiniSavePos()
    miniGui.Hide()
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
