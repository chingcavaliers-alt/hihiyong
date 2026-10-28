#Requires AutoHotkey v2.0
#SingleInstance Force
; ============================================================================
; 登入測試工具（H-033）：驗證「登入畫面直接讀遊戲記憶體」的整段流程。
; 只操作你選的那一個遊戲視窗，不啟動遊戲、不碰管理程式與它的設定；帳號密碼只由你在視窗裡輸入，不會寫進任何檔案或記錄。
; 用法：先自己開一個遊戲視窗，停在「伺服器選擇」（或登入 / 選角）畫面，再按「開始測試」。F10 隨時中止。
; ============================================================================
if !A_IsAdmin {
    MsgBox "請用「登入測試.bat」開啟（需要系統管理員權限才能讀遊戲記憶體）。"
    ExitApp 2
}
OnError((e, mode) => (Log("發生錯誤：" e.Message " （行 " e.Line "）"), 1))
global offsetsIni := A_Args.Length ? A_Args[1] : A_Temp "\hihiyong_login_test_offsets.ini"
global profiles := [], webReady := false, WVCore := 0
global abortRequested := false, emergencyStop := false, processingQueue := false, activeRecoveryHwnd := 0
global foregroundOwner := "", dailyRunning := "", recorder := 0, autoSwitchRunning := false, setupMode := false
global invRunning := false, fastLoginCritical := false, asyncLoadingEntries := Map(), recoveryQueue := []
global memoryHpHandles := Map(), memoryHpModuleBases := Map(), memoryHpModuleSizes := Map()
global INI := A_Temp "\hihiyong_login_test_none.ini"
global Status := {Text: ""}, points := Map(), logBox := 0, running := false
EventLog(a, b, c := "") => Log(b (c != "" ? "｜" c : ""))
AddRecentEvent(t) => 0
SendDiscordMessage(m, f := false) => 0
JsonEscapeWeb(v) => v
SaveProfiles() => 0
WebUrlDecode(v) => v
ProfileGameAlive(p) => true
GetGameBuildStamp(pid) => gameOffsets.Get("Build", "")
GetGameModuleSize(pid) => 0
GetGameModuleBase(pid, hProc := 0) {
    if b := memoryHpModuleBases.Get(pid, 0)
        return b
    snap := DllCall("CreateToolhelp32Snapshot", "UInt", 0x18, "UInt", pid, "Ptr")
    if snap = -1 || !snap
        return 0
    me := Buffer(1080, 0), NumPut("UInt", me.Size, me, 0), base := 0
    try {
        if DllCall("Module32FirstW", "Ptr", snap, "Ptr", me.Ptr, "Int")
            base := NumGet(me, 24, "Ptr")
    } finally DllCall("CloseHandle", "Ptr", snap)
    return memoryHpModuleBases[pid] := base
}
#Include %A_ScriptDir%\..\modules\GameData.ahk
#Include %A_ScriptDir%\..\modules\AutoParty.ahk
#Include %A_ScriptDir%\..\modules\LoginUi.ahk
GAME_OFFSETS_INI := offsetsIni
STATS_DIR := A_Temp "\hihiyong_login_test_stats"
ITEM_NAMES_INI := STATS_DIR "\ItemNames.ini"
CoordMode "Mouse", "Screen"
SetKeyDelay 60, 60

Log(t) {
    global logBox
    line := FormatTime(, "HH:mm:ss") "  " t "`r`n"
    if logBox
        try {
            logBox.Value .= line
            SendMessage 0x115, 7, 0, logBox.Hwnd   ; 捲到最底
        }
}

; 這個程序現在在登入流程的哪一個畫面："server" / "login" / "char" / ""（不是登入畫面，例如已經在遊戲裡）
StageOf(pid) {
    snap := LoginUiSnap(pid)
    if !IsObject(snap)
        return ""
    for name, st in Map("Server", "server", "Login", "login", "CharLeft", "char")
        if snap.pages.Has(name) && snap.pages[name].shown
            return st
    return ""
}
StageText(st) => st = "server" ? "伺服器選擇" : st = "login" ? "輸入帳號密碼" : st = "char" ? "選擇角色" : "不在登入畫面"

Candidates() {
    out := []
    for hw in WinGetList("HIHIYong2.0") {
        pid := WinGetPID("ahk_id " hw)
        WinGetClientPos , , &cw, &ch, "ahk_id " hw
        if cw < 640
            continue
        st := ""
        try st := StageOf(pid)
        if st != ""
            out.Push({hwnd: hw, pid: pid, stage: st})
    }
    return out
}

ToolClick(hwnd, key, ov := "") {
    global abortRequested
    if abortRequested
        throw Error("已中止（F10）。")
    pt := IsObject(ov) ? ov : LoginUiClickPoint(hwnd, key)
    if !IsObject(pt)
        throw Error("從遊戲畫面找不到「" key "」的位置。")
    WinActivate "ahk_id " hwnd
    if !WinWaitActive("ahk_id " hwnd, , 3)
        throw Error("無法把遊戲視窗切到最上層。")
    WinGetClientPos &cx, &cy, &cw, &ch, "ahk_id " hwnd
    px := Round(cx + pt.x * cw / 1024), py := Round(cy + pt.y * ch / 768)
    Log("點「" key "」→ 遊戲畫面 (" pt.x "," pt.y ")")
    DllCall("SetCursorPos", "Int", px, "Int", py)
    Sleep 120
    DllCall("mouse_event", "UInt", 0x0002, "UInt", 0, "UInt", 0, "UInt", 0, "UPtr", 0)
    Sleep 80
    DllCall("mouse_event", "UInt", 0x0004, "UInt", 0, "UInt", 0, "UInt", 0, "UPtr", 0)
}
; LoginPickChar 用的點擊（位置由呼叫端指定）
ClickPoint(hwnd, key, ov := "") => ToolClick(hwnd, key, ov)

FillField(hwnd, key, value, label) {
    ToolClick(hwnd, key)
    Sleep 300
    SendEvent "{Ctrl down}a{Ctrl up}"
    Sleep 120
    SendEvent "{Backspace}"
    Sleep 120
    SendText value
    Sleep 350
    Log(label "已輸入（" StrLen(value) " 個字元）")
}

RunTest(hwnd, pid, account, password, charName, pressStart) {
    global abortRequested
    abortRequested := false
    st := StageOf(pid)
    Log("目前畫面：" StageText(st))
    p := {name: "測試", loginChar: charName}
    if st = "server" {
        LoginMemoryGate(hwnd, "server", "測試", 20), ToolClick(hwnd, "server")
        LoginMemoryGate(hwnd, "channel", "測試", 20), ToolClick(hwnd, "channel")
        LoginMemoryGate(hwnd, "connect", "測試", 20), ToolClick(hwnd, "connect")
        st := "login"
    }
    if st = "login" {
        if !LoginMemoryGate(hwnd, "account", "測試", 40)
            throw Error("讀不到登入畫面。")
        FillField(hwnd, "account", account, "帳號")
        FillField(hwnd, "password", password, "密碼")
        Sleep 500
        ToolClick(hwnd, "login")
        st := "char"
    }
    if st = "char" {
        if !LoginMemoryGate(hwnd, "char", "測試", 90)
            throw Error("讀不到選角畫面。")
        lc := ReadGameLobyChars(pid)
        names := ""
        if IsObject(lc)
            for c in lc.chars
                names .= (names = "" ? "" : "、") c.name " (Lv" c.level ")"
        Log("選角畫面的角色：" names)
        if !LoginPickChar(hwnd, p)
            throw Error("讀不到角色清單，無法選角。")
        lc := ReadGameLobyChars(pid)
        Log("目前選到：" lc.chars[lc.selected + 1].name)
        LoginMemoryGate(hwnd, "startgame", "測試", 30)
        if pressStart {
            ToolClick(hwnd, "startgame")
            Log("已按「開始遊戲」。")
        } else
            Log("已停在「開始遊戲」按鈕前（沒有勾「最後按開始遊戲」）。")
    }
    Log("完成。")
}

; ---------------------------------------------------------------- 視窗
g := Gui("+AlwaysOnTop", "登入測試（H-033）")
g.SetFont("s10", "Microsoft JhengHei UI")
g.AddText("w520", "先開一個遊戲視窗，停在「伺服器選擇」（或登入 / 選角）畫面。帳號密碼只在這裡輸入，不會被儲存或寫進記錄。")
g.AddText("xm y+10", "遊戲視窗")
ddl := g.AddDropDownList("x+8 w360 Choose1", ["（按重新整理）"])
btnRef := g.AddButton("x+8 w90", "重新整理")
g.AddText("xm y+10 w70", "帳號")
edAcc := g.AddEdit("x+8 w180")
g.AddText("x+14 w50", "密碼")
edPw := g.AddEdit("x+8 w180 Password")
g.AddText("xm y+10 w70", "選角色")
edChar := g.AddEdit("x+8 w180")
g.AddText("x+8 w300 cGray", "（角色名稱，空白 = 第 1 隻）")
chkStart := g.AddCheckbox("xm y+10", "最後按「開始遊戲」（不勾 = 停在開始遊戲按鈕前）")
btnRun := g.AddButton("xm y+10 w120 Default", "開始測試")
g.AddText("x+12 yp+5 cGray", "F10 = 中止")
logBox := g.AddEdit("xm y+10 w600 r14 ReadOnly -Wrap +VScroll")
btnRef.OnEvent("Click", (*) => Refresh())
btnRun.OnEvent("Click", (*) => Go())
g.OnEvent("Close", (*) => ExitApp())
cands := []
Refresh() {
    global cands, ddl
    cands := Candidates()
    ddl.Delete()
    if !cands.Length {
        ddl.Add(["（沒有停在登入畫面的遊戲視窗）"]), ddl.Choose(1)
        Log("沒找到停在登入畫面的遊戲視窗。")
        return
    }
    items := []
    for c in cands
        items.Push("視窗 " c.pid "｜" StageText(c.stage))
    ddl.Add(items), ddl.Choose(1)
    Log("找到 " cands.Length " 個登入畫面的視窗。")
}
Go() {
    global cands, ddl, edAcc, edPw, edChar, chkStart, running, btnRun
    if running
        return
    if !cands.Length || ddl.Value < 1 {
        Log("請先按「重新整理」選一個遊戲視窗。")
        return
    }
    c := cands[ddl.Value]
    if StageOf(c.pid) = "login" && (edAcc.Value = "" || edPw.Value = "") {
        Log("這個視窗在輸入帳號密碼的畫面，請先填帳號和密碼。")
        return
    }
    if StageOf(c.pid) = "server" && (edAcc.Value = "" || edPw.Value = "") {
        Log("請先填帳號和密碼（測試會一路登入到選角畫面）。")
        return
    }
    running := true, btnRun.Enabled := false
    try {
        RunTest(c.hwnd, c.pid, edAcc.Value, edPw.Value, Trim(edChar.Value), chkStart.Value)
    } catch as e {
        Log("停止：" e.Message)
    }
    running := false, btnRun.Enabled := true
}
F10:: {
    global abortRequested
    abortRequested := true
    Log("收到 F10，中止。")
}
Log("讀取位置資料：" (LoadGameOffsets() ? "成功（v" gameOffsets.Get("ToolVersion", "?") "）" : "失敗，請確認遊戲視窗已開啟後重開本工具"))
g.Show()
Refresh()