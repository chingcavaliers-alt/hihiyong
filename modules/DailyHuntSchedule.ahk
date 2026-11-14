; ============================================================================
; 每日討伐：每個監控視窗（角色）各自設定「每天幾點自動開始」，以及每次跑完的時間統計。
;
; 定時啟動：
;   - 設定檔 [DailyHuntSchedule] 角色名稱=05:10,13:00（可多個時間）。
;   - 時間一到，角色是「監控中」而且遊戲視窗還在 → 把這個角色加進要跑的角色並啟動，跑完所有勾選的地圖就自己停止
;     （只有「定時加進去的」角色會被自動拿掉，原本手動勾選的不動）。
;   - 防呆：時間到了 GRACE 分鐘（[DailyHunt] SchedGraceMin，預設 5）還抓不到視窗 / 帳號不在監控中，
;     或程式開晚了超過 60 分鐘 → 這個時間點當天作廢，頁面跳出紅色提醒 + 通知 Discord，請重新設定或手動啟動。
;   - 每個時間點一天只處理一次（已處理的記在 [DailyHuntSchedFired]，重開程式不會重跑）。
; 統計：每個地圖實際花的時間（不含被其他功能卡住的等待）與全部總時長，跑完通知 Discord、存 Stats\DailyHunt_Stats.csv。
; ============================================================================
global DH_SCHED_SEC := "DailyHuntSchedule"
global DH_SCHED_GRACE_MS := Max(1, Integer(DhIniGet("SchedGraceMin", "5"))) * 60000
global DH_SCHED_LATE_MAX_MS := 3600000
global DH_SCHED_ALERTS := []        ; [{id, text, at}] 頁面上的紅色提醒，按「知道了」才會消失
global DH_SCHED_ALERT_SEQ := 0
global DH_STATS_HISTORY := []       ; 最近幾次跑完的統計（新的在前）
global DH_SCHED := Map(), DH_SCHED_LOADED := false   ; Map(角色名稱 → ["05:10", "13:00"])；角色列表載入後才讀（第一次用到時）
global DH_SCHED_RAW := ""                            ; 上次讀進來的 [DailyHuntSchedule] 區段原文；設定檔被改了（手動改 INI / 別的工具）就重新讀
; 讀設定檔 [DailyHuntSchedule] 區段原文到 raw；讀不到（檔案被占住等）回傳 false，這次不判斷有沒有變動，避免把定時誤清掉。
; 區段整個不存在：檔案本身讀得到才算「沒有定時」（raw = ""）。
DhSchedRaw(&raw) {
    global INI, DH_SCHED_SEC
    raw := ""
    try {
        raw := IniRead(INI, DH_SCHED_SEC)
        return true
    }
    try {
        IniRead(INI, "General", "Launcher", "")   ; 檔案讀得到 → 區段不存在 = 沒有設定任何定時
        return true
    }
    return false
}
DhSchedEnsure() {
    global DH_SCHED, DH_SCHED_LOADED, DH_SCHED_RAW
    ok := DhSchedRaw(&raw)
    if !DH_SCHED_LOADED {
        DH_SCHED_LOADED := true
        DH_SCHED_RAW := ok ? raw : ""
        DH_SCHED := DhSchedLoad()
    } else if ok && raw != DH_SCHED_RAW {   ; 2026-11-13：設定檔清掉 06:30 後，記憶體還是舊的，隔天照樣啟動
        DH_SCHED_RAW := raw
        DH_SCHED := DhSchedLoad()
        EventLog("GLOBAL", "DH_SCHED_RELOAD", "設定檔的每日討伐定時有變動，已重新讀取")
    }
}

; "5:10, 1300 ,25:00,05:10" → ["05:10","13:00"]（排序、去重、無效的略過）
DhSchedParse(text) {
    out := []
    seen := Map()
    for part in StrSplit(RegExReplace(text, "[，、;；\s]+", ","), ",") {
        part := Trim(part)
        if part = ""
            continue
        h := "", m := ""
        if RegExMatch(part, "^(\d{1,2})[:：](\d{2})$", &mt)
            h := Integer(mt[1]), m := Integer(mt[2])
        else if RegExMatch(part, "^(\d{2})(\d{2})$", &mt)
            h := Integer(mt[1]), m := Integer(mt[2])
        else
            continue
        if h > 23 || m > 59
            continue
        key := Format("{:02d}:{:02d}", h, m)
        if seen.Has(key)
            continue
        seen[key] := 1
        out.Push(key)
    }
    ; 字串排序即時間排序（HH:MM 固定寬度）
    n := out.Length
    Loop n - 1 {
        i := A_Index
        Loop n - i {
            j := A_Index
            if StrCompare(out[j], out[j + 1]) > 0
                tmp := out[j], out[j] := out[j + 1], out[j + 1] := tmp
        }
    }
    return out
}
DhSchedJoin(arr) {
    s := ""
    for t in arr
        s .= (s = "" ? "" : ",") t
    return s
}
DhSchedLoad() {
    global INI, DH_SCHED_SEC, profiles
    out := Map()
    if !IsSet(profiles) || !IsObject(profiles)
        return out
    for p in profiles {
        txt := ""
        try txt := IniRead(INI, DH_SCHED_SEC, p.name, "")
        arr := DhSchedParse(txt)
        if arr.Length
            out[p.name] := arr
    }
    return out
}
; rawValue：角色名稱~時間,時間（時間空白 = 清除）；回傳給畫面的訊息
DailyHuntSchedSet(rawValue) {
    global INI, DH_SCHED, DH_SCHED_SEC, DH_SCHED_RAW
    DhSchedEnsure()
    cut := InStr(rawValue, "~", , -1)
    if !cut
        return "格式不對"
    name := Trim(SubStr(rawValue, 1, cut - 1)), text := SubStr(rawValue, cut + 1)
    if name = ""
        return "沒有指定角色"
    arr := DhSchedParse(text)
    if arr.Length {
        DH_SCHED[name] := arr
        IniWrite DhSchedJoin(arr), INI, DH_SCHED_SEC, name
        if DhSchedRaw(&raw)
            DH_SCHED_RAW := raw   ; 自己寫的，不算「設定檔被外部改過」
        EventLog(name, "DH_SCHED_SET", "每日討伐定時啟動：" DhSchedJoin(arr))
        AddRecentEvent("⏰ 每日討伐｜" name "｜每天 " DhSchedJoin(arr) " 自動開始")
        return name "：每天 " DhSchedJoin(arr) " 自動開始"
    }
    if DH_SCHED.Has(name)
        DH_SCHED.Delete(name)
    try IniDelete INI, DH_SCHED_SEC, name
    if DhSchedRaw(&raw)
        DH_SCHED_RAW := raw
    EventLog(name, "DH_SCHED_SET", "每日討伐定時啟動：已清除")
    return name "：已清除定時啟動"
}

; ---- 已處理的時間點（一天一次，重開程式不重跑）----
DhSchedFiredGet(name, t) {
    global INI
    v := ""
    try v := IniRead(INI, "DailyHuntSchedFired", name "|" t, "")
    return v
}
DhSchedFiredSet(name, t, status) {
    global INI
    try IniWrite SubStr(A_Now, 1, 8) ":" status, INI, "DailyHuntSchedFired", name "|" t
}
; 今天這個時間點的狀態："" = 還沒處理 / started / missed
DhSchedStatusToday(name, t) {
    v := DhSchedFiredGet(name, t)
    return SubStr(v, 1, 8) = SubStr(A_Now, 1, 8) ? SubStr(v, 10) : ""
}

DhSchedAlert(text) {
    global DH_SCHED_ALERTS, DH_SCHED_ALERT_SEQ
    DH_SCHED_ALERT_SEQ += 1
    DH_SCHED_ALERTS.Push({id: DH_SCHED_ALERT_SEQ, text: text, at: FormatTime(, "MM-dd HH:mm")})
    while DH_SCHED_ALERTS.Length > 20
        DH_SCHED_ALERTS.RemoveAt(1)
    AddRecentEvent("⚠ " text)
}
DailyHuntSchedAck(rawValue) {
    global DH_SCHED_ALERTS
    if rawValue = "all" || rawValue = ""
        DH_SCHED_ALERTS := []
    else
        for i, a in DH_SCHED_ALERTS
            if a.id = Integer(rawValue) {
                DH_SCHED_ALERTS.RemoveAt(i)
                break
            }
}

; 這個角色現在能不能開始跑：有遊戲視窗、狀態是「監控中」
DhSchedReady(p) {
    if !p.enabled || p.state != "監控中" || !p.pid
        return false
    alive := false
    try alive := ProfileGameAlive(p)
    return alive
}
DhSchedWhyNot(p) {
    if !p.enabled
        return "這個帳號沒有勾選"
    if p.state != "監控中"
        return "帳號狀態是「" p.state "」，不是監控中"
    if !p.pid
        return "沒有綁定遊戲視窗"
    return "找不到遊戲視窗"
}

DhSchedPersistChars() {
    global INI, DH_CHARS, DH_RUNNING, DH_RESUME
    names := ""
    for n, _ in DH_CHARS
        names .= (names = "" ? "" : "|") n
    IniWrite names, INI, "DailyHunt", "Chars"
    if DH_RESUME
        IniWrite DH_RUNNING, INI, "DailyHunt", "Running"
}

DhSchedStart(p, t, lateSec) {
    global DH_CHARS, DH_RUNNING, DH_TEST
    st0 := p.HasOwnProp("dh") ? p.dh : 0
    already := DH_RUNNING && DH_CHARS.Has(p.name) && IsObject(st0) && !st0.done
    if already {
        EventLog(p.name, "DH_SCHED_START", t " 到了，但每日討伐已經在跑，不重複啟動")
        return
    }
    added := !DH_CHARS.Has(p.name)
    DH_CHARS[p.name] := 1
    if p.HasOwnProp("dh")
        p.DeleteProp("dh")
    st := DhSt(p)
    st.schedAdded := added, st.sched := t
    DH_RUNNING := 1
    DhSchedPersistChars()
    EventLog(p.name, "DH_SCHED_START", "定時啟動 " t (lateSec > 90 ? "（晚了 " lateSec " 秒）" : "") "｜" (added ? "自動加入要跑的角色，跑完自動停止" : "原本就勾選，跑完不取消勾選"))
    DhNotify("⏰ 每日討伐｜" p.name "｜" t " 定時啟動" (lateSec > 90 ? "（晚了 " Round(lateSec / 60) " 分鐘）" : ""))
    AddRecentEvent("⏰ " p.name " 每日討伐定時啟動（" t "）")
}

; 每 10 秒看一次：今天到點、還沒處理的時間點
DailyHuntSchedTick() {
    global profiles, DH_SCHED, DH_SCHED_GRACE_MS, DH_SCHED_LATE_MAX_MS, DH_TEST
    DhSchedEnsure()
    if !DH_SCHED.Count
        return
    for p in profiles {
        if !DH_SCHED.Has(p.name)
            continue
        for t in DH_SCHED[p.name] {
            if DhSchedStatusToday(p.name, t) != ""
                continue
            due := SubStr(A_Now, 1, 8) StrReplace(t, ":") "00"
            if A_Now < due
                continue
            lateSec := DateDiff(A_Now, due, "Seconds"), lateMs := lateSec * 1000
            if lateMs > DH_SCHED_LATE_MAX_MS {   ; 程式開得太晚才看到：不補跑，請人確認
                DhSchedFiredSet(p.name, t, "missed")
                msg := "每日討伐定時啟動錯過｜" p.name "｜" t " 到點時管理程式沒有在跑（現在已晚 " Round(lateSec / 60) " 分鐘），這次沒有啟動；需要的話請手動按「啟動」，或重新設定時間"
                EventLog(p.name, "DH_SCHED_MISSED", msg)
                DhSchedAlert(msg), DhNotify("⚠️ " msg)
                continue
            }
            if DhSchedReady(p) {
                if DH_TEST {
                    DhSchedFiredSet(p.name, t, "missed")
                    msg := "每日討伐定時啟動沒有執行｜" p.name "｜" t "｜目前開著「測試流程」，為了避免誤跑沒有啟動，請關掉測試流程後手動啟動"
                    EventLog(p.name, "DH_SCHED_MISSED", msg)
                    DhSchedAlert(msg), DhNotify("⚠️ " msg)
                    continue
                }
                DhSchedFiredSet(p.name, t, "started")
                DhSchedStart(p, t, lateSec)
            } else if lateMs >= DH_SCHED_GRACE_MS {
                DhSchedFiredSet(p.name, t, "missed")
                msg := "每日討伐定時啟動失敗｜" p.name "｜" t " 到了 " Round(lateMs / 60000) " 分鐘還是無法啟動：" DhSchedWhyNot(p) "。請確認帳號和遊戲視窗，重新設定時間或手動啟動"
                EventLog(p.name, "DH_SCHED_MISSED", msg)
                DhSchedAlert(msg), DhNotify("⚠️ " msg)
            }
        }
    }
}

; 這個角色跑完：定時加進來的角色自動拿掉；沒有角色要跑了就停止
DhSchedFinish(p) {
    global DH_CHARS, DH_RUNNING
    st := DhSt(p)
    if !(st.HasOwnProp("schedAdded") && st.schedAdded)
        return
    st.schedAdded := false
    if DH_CHARS.Has(p.name)
        DH_CHARS.Delete(p.name)
    if DH_CHARS.Count = 0
        DH_RUNNING := 0
    DhSchedPersistChars()
    EventLog(p.name, "DH_SCHED_STOP", "定時啟動的每日討伐跑完，已自動停止" (DH_RUNNING ? "（其他角色還在跑）" : ""))
}

; ---- 統計：每張圖實際花的時間 ----
DhStatFmt(ms) {
    s := Round(ms / 1000)
    h := s // 3600, m := Mod(s, 3600) // 60, sec := Mod(s, 60)
    return h ? h " 小時 " m " 分 " sec " 秒" : (m ? m " 分 " sec " 秒" : sec " 秒")
}
DhStatReset(p) {
    st := DhSt(p)
    st.stat := {on: true, start: A_TickCount, startNow: A_Now, last: A_TickCount, cur: 0, maps: Map(), order: []}
}
; 每次 DhPlan 之後呼叫：上次到現在的這一小段（只算正常的 3 秒輪詢；被其他功能卡住的長空檔不算）加到「目前在做的圖」
DhStatTrack(p, st, d) {
    if !st.HasOwnProp("stat") || !IsObject(st.stat) || !st.stat.on
        DhStatReset(p)
    s := st.stat, now := A_TickCount
    dt := now - s.last
    if s.cur != 0 && dt > 0 && dt <= 15000
        DhStatAdd(s, s.cur, dt)
    s.last := now
    if IsObject(d.goal)
        s.cur := d.goal.map, DhStatName(s, d.goal.map, d.goal.name)
    else if d.action = "finish"
        s.cur := -1, DhStatName(s, -1, "回起點")
}
DhStatName(s, key, name) {
    if !s.maps.Has(key) {
        s.maps[key] := {name: name, ms: 0}
        s.order.Push(key)
    }
}
DhStatAdd(s, key, ms) {
    if s.maps.Has(key)
        s.maps[key].ms += ms
}
; DhRun 結束時呼叫：這一回合（搭車 / 走路 / 開始打怪…）花的時間加到目前的圖
DhStatRunEnd(p, ms) {
    st := DhSt(p)
    if !st.HasOwnProp("stat") || !IsObject(st.stat) || !st.stat.on
        return
    s := st.stat
    if s.cur != 0
        DhStatAdd(s, s.cur, ms)
    s.last := A_TickCount
}
; 全部做完（DhActFinish 最後）：產生統計、通知、存檔
DhStatFinish(p, runMs) {
    global DH_STATS_HISTORY, DH_TEST
    st := DhSt(p)
    if DH_TEST || !st.HasOwnProp("stat") || !IsObject(st.stat) || !st.stat.on
        return
    s := st.stat
    if s.cur != 0
        DhStatAdd(s, s.cur, runMs)
    s.on := false
    wall := A_TickCount - s.start, active := 0
    maps := []
    lines := ""
    for key in s.order {
        m := s.maps[key]
        active += m.ms
        maps.Push({name: m.name, sec: Round(m.ms / 1000)})
        lines .= "`n・" m.name "：" DhStatFmt(m.ms)
    }
    trig := st.HasOwnProp("sched") && st.sched != "" ? "定時 " st.sched : "手動"
    rec := {char: p.name, date: FormatTime(s.startNow, "MM-dd HH:mm"), trigger: trig, wall: Round(wall / 1000), active: Round(active / 1000), maps: maps}
    DH_STATS_HISTORY.InsertAt(1, rec)
    while DH_STATS_HISTORY.Length > 10
        DH_STATS_HISTORY.Pop()
    text := "📊 每日討伐統計｜" p.name "｜" trig lines "`n總時長（從開始到結束）：" DhStatFmt(wall) "｜實際作業：" DhStatFmt(active)
    EventLog(p.name, "DH_STATS", StrReplace(StrReplace(text, "`n", "｜"), "📊 ", ""))
    DhNotify(text)
    DhStatSave(p.name, trig, s, wall)
}
DhStatSave(name, trig, s, wall) {
    global STATS_DIR
    try {
        if !IsSet(STATS_DIR) || STATS_DIR = ""
            return
        if !DirExist(STATS_DIR)
            DirCreate STATS_DIR
        f := STATS_DIR "\DailyHunt_Stats.csv"
        out := FileExist(f) ? "" : "日期,角色,觸發,地圖,秒數`r`n"
        day := FormatTime(s.startNow, "yyyy-MM-dd HH:mm")
        for key in s.order
            out .= day "," name "," trig "," s.maps[key].name "," Round(s.maps[key].ms / 1000) "`r`n"
        out .= day "," name "," trig ",總時長（開始到結束）," Round(wall / 1000) "`r`n"
        FileAppend out, f, "UTF-8"
    }
}

; 畫面資料：{"sched":[{name,times,status}], "alerts":[…], "stats":[…]}
DhSchedJson() {
    global profiles, DH_SCHED, DH_SCHED_ALERTS, DH_STATS_HISTORY
    DhSchedEnsure()
    sc := ""
    for p in profiles {
        if !p.enabled
            continue
        times := DH_SCHED.Has(p.name) ? DhSchedJoin(DH_SCHED[p.name]) : ""
        status := ""
        if DH_SCHED.Has(p.name)
            for t in DH_SCHED[p.name] {
                s := DhSchedStatusToday(p.name, t)
                status .= (status = "" ? "" : "　") t (s = "started" ? " ✅已啟動" : (s = "missed" ? " ⚠錯過" : (A_Now < SubStr(A_Now, 1, 8) StrReplace(t, ":") "00" ? " ⏳等待" : " …")))
            }
        sc .= (sc = "" ? "" : ",") '{"name":"' JsonEscapeWeb(p.name) '","times":"' JsonEscapeWeb(times) '","status":"' JsonEscapeWeb(status) '"}'
    }
    al := ""
    for a in DH_SCHED_ALERTS
        al .= (al = "" ? "" : ",") '{"id":' a.id ',"text":"' JsonEscapeWeb(a.text) '","at":"' a.at '"}'
    stt := ""
    for r in DH_STATS_HISTORY {
        ms := ""
        for m in r.maps
            ms .= (ms = "" ? "" : ",") '{"n":"' JsonEscapeWeb(m.name) '","s":' m.sec '}'
        stt .= (stt = "" ? "" : ",") '{"char":"' JsonEscapeWeb(r.char) '","date":"' r.date '","trigger":"' JsonEscapeWeb(r.trigger) '","wall":' r.wall ',"active":' r.active ',"maps":[' ms ']}'
    }
    return '"sched":[' sc '],"alerts":[' al '],"stats":[' stt ']'
}
