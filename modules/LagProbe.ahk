; ============================================================================
; LagProbe：久掛延遲量測（只讀，不送任何按鍵 / 滑鼠，不動遊戲）。
; 玩家反映：掛很久之後角色動作很慢、寵物撿東西很慢，過一次圖就好，而且多開時各視窗輪流發生。
; 伺服器時間的紀錄顯示這不是「伺服器沒送資料」，所以先量客戶端：
;   - 遊戲處理程序的記憶體（私有 / 工作集）、控制代碼數、CPU 使用、登入至今多久
;   - 遊戲視窗回應訊息要多久（SendMessageTimeout WM_NULL：視窗的訊息迴圈忙 / 被降速時會變長）
;   - 是不是前景視窗、是不是最小化，並附上伺服器時間停了幾秒、HP、金幣、地圖
; 每 LAG_TICK_MS 毫秒輪流量一個視窗，寫到 Logs\LagProbe_yyyy-MM-dd.csv。
; 看到延遲時按「標記 Lag」（記錄當下所有視窗，標記欄 = 1），之後拿過圖前後的數字比對。
; ============================================================================

global LAG_DIR := A_ScriptDir "\Logs"   ; 測試時可以改到別處
global LAG_TICK_MS := 5000, LAG_PING_TIMEOUT_MS := 300, LAG_KEEP_DAYS := 21
global lagEnabledRaw := IniRead(INI, "LagProbe", "Enabled", "1")
global LAG_ENABLED := IsInteger(lagEnabledRaw) && Integer(lagEnabledRaw) = 0 ? 0 : 1
global lagRR := 0, lagLast := Map(), lagMarkAt := "", lagMarkCount := 0, lagCleanDay := ""
global LAG_CSV_HEADER := "時間,角色,PID,登入至今(分),私有記憶體(MB),工作集(MB),控制代碼數,CPU(%),前景,最小化,視窗回應平均(ms),視窗回應最大(ms),伺服器時間未變(秒),HP,金幣,地圖,標記`r`n"

; 處理程序資訊：回傳 {priv, ws, handles, cpu100ns, created100ns}（單位：位元組 / FILETIME 100ns），讀不到回傳 0。
LagProcInfo(pid) {
    h := DllCall("OpenProcess", "UInt", 0x1000, "Int", 0, "UInt", pid, "Ptr")   ; PROCESS_QUERY_LIMITED_INFORMATION
    if !h
        return 0
    try {
        mem := Buffer(80, 0)
        NumPut("UInt", 80, mem, 0)
        if !DllCall("K32GetProcessMemoryInfo", "Ptr", h, "Ptr", mem, "UInt", 80, "Int")
            return 0
        tm := Buffer(32, 0)
        if !DllCall("GetProcessTimes", "Ptr", h, "Ptr", tm.Ptr, "Ptr", tm.Ptr + 8, "Ptr", tm.Ptr + 16, "Ptr", tm.Ptr + 24, "Int")
            return 0
        hc := 0
        DllCall("GetProcessHandleCount", "Ptr", h, "UIntP", &hc)
        return {priv: NumGet(mem, 72, "UInt64"), ws: NumGet(mem, 8, "UInt64"), handles: hc
            , cpu: NumGet(tm, 16, "Int64") + NumGet(tm, 24, "Int64"), created: NumGet(tm, 0, "Int64")}
    } finally {
        DllCall("CloseHandle", "Ptr", h)
    }
}

LagNow100ns() {
    ft := Buffer(8, 0)
    DllCall("GetSystemTimeAsFileTime", "Ptr", ft)
    return NumGet(ft, 0, "Int64")
}

; 視窗回應時間（毫秒）：送一個什麼都不做的 WM_NULL，量對方的訊息迴圈多久回。連量兩次，回傳 [平均, 最大]；
; 第一次就逾時就不再量第二次（避免讓卡住的視窗拖慢整個程式）。逾時記成 LAG_PING_TIMEOUT_MS。
LagPing(hwnd) {
    global LAG_PING_TIMEOUT_MS
    freq := 0, a := 0, b := 0
    DllCall("QueryPerformanceFrequency", "Int64P", &freq)
    if freq <= 0
        return [-1, -1]
    vals := []
    Loop 2 {
        DllCall("QueryPerformanceCounter", "Int64P", &a)
        res := 0
        ok := DllCall("SendMessageTimeoutW", "Ptr", hwnd, "UInt", 0, "Ptr", 0, "Ptr", 0, "UInt", 0x2, "UInt", LAG_PING_TIMEOUT_MS, "UPtrP", &res, "Ptr")   ; SMTO_ABORTIFHUNG
        DllCall("QueryPerformanceCounter", "Int64P", &b)
        ms := ok ? (b - a) * 1000 / freq : LAG_PING_TIMEOUT_MS
        vals.Push(ms)
        if !ok
            break
        Sleep 20
    }
    sum := 0, mx := 0
    for v in vals {
        sum += v
        mx := Max(mx, v)
    }
    return [sum / vals.Length, mx]
}

; 取樣一個角色。回傳樣本物件；不能量（不在監控、沒有視窗）回傳 0。
LagSample(p, mark := 0) {
    global lagLast, LAG_DIR, LAG_CSV_HEADER
    if !p.enabled || !p.pid || !ProfileGameAlive(p)
        return 0
    info := LagProcInfo(p.pid)
    if !IsObject(info)
        return 0
    nowTick := A_TickCount
    cpuPct := ""
    if p.HasOwnProp("lagPrevPid") && p.lagPrevPid = p.pid && nowTick > p.lagPrevTick
        cpuPct := Round(((info.cpu - p.lagPrevCpu) / 10000) / (nowTick - p.lagPrevTick) * 100, 1)
    if !p.HasOwnProp("lagPrevPid") || p.lagPrevPid != p.pid
        p.lagHist := []   ; 重新登入換了遊戲處理程序：舊的回應紀錄不算
    p.lagPrevPid := p.pid, p.lagPrevCpu := info.cpu, p.lagPrevTick := nowTick
    upMin := Round((LagNow100ns() - info.created) / 600000000, 1)
    mn := 0, fg := 0
    try mn := WinGetMinMax("ahk_id " p.hwnd) = -1 ? 1 : 0
    try fg := WinActive("ahk_id " p.hwnd) ? 1 : 0
    ping := mn ? [-1, -1] : LagPing(p.hwnd)   ; 最小化的視窗不量（回應時間沒有意義）
    srv := ""
    try srv := SignalServerStaticSec(p)
    mapId := ""
    try mapId := ReadGameMapId(p.pid)
    s := {t: FormatTime(, "HH:mm:ss"), name: p.name, pid: p.pid, upMin: upMin, priv: Round(info.priv / 1048576, 1), ws: Round(info.ws / 1048576, 1)
        , handles: info.handles, cpu: cpuPct, fg: fg, min: mn, pingAvg: ping[1] < 0 ? "" : Round(ping[1], 1), pingMax: ping[2] < 0 ? "" : Round(ping[2], 1)
        , srv: srv, hp: p.HasOwnProp("memHp") ? p.memHp : "", money: p.HasOwnProp("invSnapMoney") ? p.invSnapMoney : "", map: mapId, mark: mark ? 1 : 0}
    lagLast[p.name] := s
    ; 最近幾次視窗回應（LagFix 判斷「變慢」用）；剛過完圖的一小段時間不算
    if s.pingAvg != "" && !(p.HasOwnProp("lagQuietUntil") && A_TickCount < p.lagQuietUntil) {
        if !p.HasOwnProp("lagHist")
            p.lagHist := []
        p.lagHist.Push({tick: A_TickCount, v: s.pingAvg})
        while p.lagHist.Length > 12
            p.lagHist.RemoveAt(1)
    }
    try {
        path := LAG_DIR "\LagProbe_" FormatTime(, "yyyy-MM-dd") ".csv"
        if !FileExist(path) {
            if !DirExist(LAG_DIR)
                DirCreate LAG_DIR
            FileAppend LAG_CSV_HEADER, path, "UTF-8"
        }
        FileAppend FormatTime(, "yyyy-MM-dd ") s.t "," CsvField(s.name) "," s.pid "," s.upMin "," s.priv "," s.ws "," s.handles "," s.cpu "," s.fg "," s.min
            . "," s.pingAvg "," s.pingMax "," s.srv "," s.hp "," s.money "," s.map "," s.mark "`r`n", path, "UTF-8"
    }
    return s
}

; 輪流量測：每次一個視窗。
LagProbeTick() {
    global profiles, fastLoginCritical, lagRR, LAG_ENABLED
    if !LAG_ENABLED || fastLoginCritical
        return
    LagCleanOld()
    list := []
    for p in profiles
        if p.enabled && p.pid && p.state = "監控中" && ProfileGameAlive(p)
            list.Push(p)
    if !list.Length
        return
    lagRR += 1
    try LagSample(list[Mod(lagRR - 1, list.Length) + 1])
}

; 每天第一次執行時刪掉太舊的量測檔
LagCleanOld() {
    global LAG_DIR, LAG_KEEP_DAYS, lagCleanDay
    day := FormatTime(, "yyyyMMdd")
    if lagCleanDay = day
        return
    lagCleanDay := day
    try Loop Files, LAG_DIR "\LagProbe_*.csv" {
        if DateDiff(A_Now, A_LoopFileTimeModified, "Days") > LAG_KEEP_DAYS
            try FileDelete A_LoopFileFullPath
    }
}

; 標記 Lag：馬上量目前所有（或指定一個）視窗，標記欄 = 1。idx = 0 → 全部。
LagMark(idx := 0) {
    global profiles, lagMarkAt, lagMarkCount
    n := 0, names := ""
    for i, p in profiles {
        if idx && i != idx
            continue
        s := 0
        try s := LagSample(p, 1)
        if IsObject(s) {
            n += 1
            names .= (names = "" ? "" : "、") p.name
        }
    }
    lagMarkAt := FormatTime(, "HH:mm:ss"), lagMarkCount += n
    EventLog("GLOBAL", "LAG_MARK", "玩家標記 Lag｜" n " 個視窗｜" names)
    AddRecentEvent("📌 已標記 Lag（" n " 個視窗）")
    return n
}

LagSetEnabled(on) {
    global INI, LAG_ENABLED
    LAG_ENABLED := on ? 1 : 0
    IniWrite LAG_ENABLED, INI, "LagProbe", "Enabled"
}

LagPushWeb() {
    global webReady, WVCore, profiles, lagLast, LAG_ENABLED, lagMarkAt, lagMarkCount
    if !webReady || !WVCore
        return
    rows := ""
    for i, p in profiles {
        if !p.enabled || !p.pid || !ProfileGameAlive(p)
            continue
        s := lagLast.Has(p.name) ? lagLast[p.name] : 0
        rows .= (rows = "" ? "" : ",") '{"index":' i ',"name":"' JsonEscapeWeb(p.name) '"'
        if IsObject(s)
            rows .= ',"t":"' s.t '","up":' s.upMin ',"priv":' s.priv ',"cpu":' (s.cpu = "" ? "null" : s.cpu) ',"ping":' (s.pingAvg = "" ? "null" : s.pingAvg)
                . ',"pingMax":' (s.pingMax = "" ? "null" : s.pingMax) ',"fg":' (s.fg ? "true" : "false") ',"min":' (s.min ? "true" : "false")
        rows .= '}'
    }
    try WVCore.PostWebMessageAsJson('{"type":"lag","data":{"enabled":' (LAG_ENABLED ? "true" : "false") ',"markAt":"' lagMarkAt '","marks":' lagMarkCount ',"rows":[' rows ']}}')
}
