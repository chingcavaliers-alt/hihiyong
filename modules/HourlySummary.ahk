; 每小時摘要（首頁「每小時收益」下面那張表）：從當天日誌算每個角色每小時的死亡、採礦（顆數、採集 / 走路 / 循環秒數中位數、
; 循環超過 HS_SLOW_SEC 的次數）和異常事件數。金幣 / 拾取網頁直接用 invstats 的 hourMoney / hourItems。
; 只讀日誌，不碰遊戲；同一天 60 秒內重複要求就用上次算好的。
global HS_SLOW_SEC := 110
global HS_ISSUE_KINDS := Map("MN_ERROR", 1, "MN_HANG", 1, "KICKED", 1, "RECOVERY_FAIL", 1, "MANUAL_REQUIRED", 1, "QUICKKEYS", 1, "CW_FAIL", 1
    , "DH_ERROR", 1, "DH_STOP_STUCK", 1, "DH_CROWDED", 1, "DAILY_FAIL", 1, "REVIVE_CLICK_FAIL", 1, "MBOX_STUCK", 1)

; text：日誌全文。回傳 Map(角色, Map(小時 0-23, {deaths, gathers, gather:[], walk:[], cycle:[], slow, issues: Map(種類, 次數)}))
HsParse(text) {
    global HS_SLOW_SEC, HS_ISSUE_KINDS
    out := Map(), last := Map()
    Loop Parse text, "`n", "`r" {
        line := A_LoopField
        if !RegExMatch(line, "^\d{4}-\d\d-\d\d (\d\d):(\d\d):(\d\d) \| ([^|]+?) \| ([A-Z_0-9]+)", &m)
            continue
        name := m[4], kind := m[5]
        if name = "GLOBAL"
            continue
        sec := m[1] * 3600 + m[2] * 60 + m[3], h := Integer(m[1])
        if !out.Has(name)
            out[name] := Map()
        if !out[name].Has(h)
            out[name][h] := {deaths: 0, gathers: 0, gather: [], walk: [], cycle: [], slow: 0, issues: Map()}
        b := out[name][h]
        if kind = "DEATH"
            b.deaths += 1
        else if kind = "MN_GOTO"
            last[name "|goto"] := sec
        else if kind = "MN_GATHER_START" {
            if last.Has(name "|goto") && (d := sec - last[name "|goto"]) > 0 && d < 300
                b.walk.Push(d)
            last[name "|start"] := sec
        } else if kind = "MN_GATHER_DONE" {
            b.gathers += 1
            if last.Has(name "|start") && (d := sec - last[name "|start"]) >= 0 && d < 600
                b.gather.Push(d)
            if last.Has(name "|done") && (d := sec - last[name "|done"]) > 0 && d < 900 {
                b.cycle.Push(d)
                if d > HS_SLOW_SEC
                    b.slow += 1
            }
            last[name "|done"] := sec
        }
        if HS_ISSUE_KINDS.Has(kind)
            b.issues[kind] := b.issues.Get(kind, 0) + 1
    }
    return out
}
HsMedian(a) {
    if !a.Length
        return -1
    s := []
    for v in a
        s.Push(v)
    ; 插入排序：一小時最多幾十筆
    Loop s.Length - 1 {
        i := A_Index + 1, v := s[i], j := i - 1
        while j >= 1 && s[j] > v
            s[j + 1] := s[j], j -= 1
        s[j + 1] := v
    }
    n := s.Length
    if Mod(n, 2)
        return s[(n + 1) // 2]
    v := (s[n // 2] + s[n // 2 + 1]) / 2
    return v = Floor(v) ? Integer(v) : Round(v, 1)
}
HsJson(parsed) {
    roles := ""
    for name, hours in parsed {
        hs := ""
        for h, b in hours {
            iss := ""
            for k, n in b.issues
                iss .= (iss = "" ? "" : ",") '"' k '":' n
            hs .= (hs = "" ? "" : ",") '{"h":' h ',"deaths":' b.deaths ',"gathers":' b.gathers ',"gatherMed":' HsMedian(b.gather) ',"walkMed":' HsMedian(b.walk)
                . ',"cycleMed":' HsMedian(b.cycle) ',"slow":' b.slow ',"issues":{' iss '}}'
        }
        roles .= (roles = "" ? "" : ",") '{"name":"' JsonEscapeWeb(name) '","hours":[' hs ']}'
    }
    return '{"roles":[' roles ']}'
}
; 日誌用共用讀取（程式自己還在寫）
HsReadLog(path) {
    try {
        f := FileOpen(path, "r", "UTF-8")
        t := f.Read()
        f.Close()
        return t
    }
    return ""
}
HourlySummaryJson(day := "") {
    static key := "", json := "", at := 0
    if day = ""
        day := FormatTime(, "yyyy-MM-dd")
    if !RegExMatch(day, "^\d{4}-\d\d-\d\d$")
        return '{"roles":[]}'
    if key = day && json != "" && A_TickCount - at < 60000
        return json
    json := HsJson(HsParse(HsReadLog(A_ScriptDir "\Logs\HIHIYONG_" day ".log")))
    key := day, at := A_TickCount
    return json
}
HourlySummaryPushWeb(day := "") {
    global webReady, WVCore, HS_SLOW_SEC
    if !webReady || !WVCore
        return
    d := RegExMatch(day, "^\d{4}-\d\d-\d\d$") ? day : FormatTime(, "yyyy-MM-dd")
    try WVCore.PostWebMessageAsJson('{"type":"hoursum","data":{"day":"' d '","today":"' FormatTime(, "yyyy-MM-dd") '","base":{"gather":63,"walk":"10～15","cycle":74,"slow":' HS_SLOW_SEC '},"sum":' HourlySummaryJson(d) '}}')
}
