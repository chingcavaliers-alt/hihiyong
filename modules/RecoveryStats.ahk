; ============================================================
; RecoveryStats — 重新登入統計（純計算，不碰遊戲 / 不寫檔 / 不依賴主程式全域變數）
; 從 Logs\HIHIYONG_yyyy-MM-dd.log 把 RECOVERY_START 到最終結果配成一次「重新登入」。
;
; 日誌格式：yyyy-MM-dd HH:mm:ss | 角色 | 事件 | 訊息
;
; 一次重新登入（session）= {name, day, start, end, sec, result, ok, step}
;   result：
;     RECOVERY_OK / RECOVERY_CHECK_OK / RECOVERY_CHECK_FIX → 成功
;     RECOVERY_CHECK_FAIL / RECOVERY_FAIL / MANUAL_REQUIRED → 失敗
;     RECOVERY_ABORTED → 手動停止（不計入成功率）
;     ABANDONED → 還沒出結果就又開始新的一次（算失敗；耗時算到下一次開始）
;     RUNNING   → 只有 START 沒有結果＝進行中（不計入成功率，沒有耗時）
;   同一次裡第一個最終結果就結案；之後同角色的 RECOVERY_CHECK_OK 等沒有 START 的事件忽略。
;   step = START 之後、結果之前，最後一個「步驟類」事件名（例如 LOADING_CHARSELECT_STUCK），沒有則 ""。
; 跨午夜：依日期順序讀檔並保留未結案的 session，所以前一天的 START 能接到今天的結果。
; 壞行（格式不對、時間不合法）略過並計入 corrupt；檔案不存在 → missing；讀不到 → corrupt。
; ============================================================

RecStats_OkTypes() => Map("RECOVERY_OK",1,"RECOVERY_CHECK_OK",1,"RECOVERY_CHECK_FIX",1)
RecStats_FailTypes() => Map("RECOVERY_CHECK_FAIL",1,"RECOVERY_FAIL",1,"MANUAL_REQUIRED",1)

RecStats_IsFinal(type) {
    return RecStats_OkTypes().Has(type) || RecStats_FailTypes().Has(type) || type = "RECOVERY_ABORTED"
}

; 登入流程的步驟事件（白名單，對照主程式 / AsyncLoading 的 EventLog 事件名）。
; 只有這些會被記成「卡住的步驟」；其餘（SOFT_*、DISCORD_FAIL、QUEUE_*、NETWORK_*、HP_*…）一律當雜訊。
RecStats_IsStep(type) {
    for pre in ["LOADING_","STAGE_","SERVER_","SCREEN_","LOGIN_","STARTGAME_","FAST_","BOOT_","ENTER_RETRY","FOCUS_RETRY","CHAR_READY","INGAME_GATE","IME_SAFE","POST_KEYS","LOCATION_UNKNOWN","STEP"] {
        if SubStr(type, 1, StrLen(pre)) = pre
            return true
    }
    return false
}

; "2026-10-24 01:50:10" → 14 碼時間戳，格式不對或不是合法時間回傳 ""
RecStats_ParseTime(s) {
    if !RegExMatch(s, "^(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)$", &m)
        return ""
    ts := m[1] m[2] m[3] m[4] m[5] m[6]
    try {
        if FormatTime(ts, "yyyy-MM-dd HH:mm:ss") != s  ; 2026-13-45 之類會被改寫
            return ""
    } catch
        return ""
    return ts
}

RecStats_Secs(a, b) {
    try d := DateDiff(b, a, "Seconds")
    catch
        return 0
    return d < 0 ? 0 : d
}

; 讀取 endDay（"yyyy-MM-dd"）往前 days 天（含當天）內「開始」的重新登入。
; 回傳 {sessions:[...依開始時間], corrupt:N, missing:N, files:N}
RecStats_Load(logDir, endDay, days := 7) {
    res := {sessions: [], corrupt: 0, missing: 0, files: 0}
    endTs := RecStats_ParseTime(endDay " 00:00:00")
    if endTs = "" || days < 1
        return res
    open := Map()          ; 角色 → 未結案 session
    all := []
    ; 多讀一天（視窗前一天），讓跨午夜開始的也能接起來；那一天開始的不列入輸出
    winFirst := FormatTime(DateAdd(endTs, -(days - 1), "Days"), "yyyy-MM-dd")
    Loop days + 1 {
        day := FormatTime(DateAdd(endTs, -(days + 1 - A_Index), "Days"), "yyyy-MM-dd")
        path := logDir "\HIHIYONG_" day ".log"
        if !FileExist(path) {
            res.missing += 1
            continue
        }
        try text := FileRead(path, "UTF-8")
        catch {
            res.corrupt += 1
            continue
        }
        res.files += 1
        Loop Parse text, "`n", "`r" {
            line := A_LoopField
            if Trim(line) = ""
                continue
            parts := StrSplit(line, " | ", , 4)
            ts := parts.Length >= 3 ? RecStats_ParseTime(parts[1]) : ""
            if ts = "" || Trim(parts[2]) = "" || Trim(parts[3]) = "" {
                res.corrupt += 1
                continue
            }
            name := parts[2], type := Trim(parts[3])
            if type = "RECOVERY_START" {
                if open.Has(name) {
                    s := open[name]
                    s.end := ts, s.sec := RecStats_Secs(s.start, ts), s.result := "ABANDONED"
                }
                s := {name: name, day: SubStr(parts[1], 1, 10), start: ts, end: "", sec: 0, result: "RUNNING", ok: false, step: ""}
                open[name] := s
                all.Push(s)
            } else if open.Has(name) {
                s := open[name]
                if RecStats_IsFinal(type) {
                    s.end := ts, s.sec := RecStats_Secs(s.start, ts), s.result := type
                    s.ok := RecStats_OkTypes().Has(type)
                    open.Delete(name)
                } else if RecStats_IsStep(type)
                    s.step := type
            }
        }
    }
    for s in all {
        if StrCompare(s.day, winFirst) >= 0
            res.sessions.Push(s)
    }
    return res
}

RecStats_NewStat() => {total: 0, ok: 0, fail: 0, aborted: 0, running: 0, rate: -1, avgSec: 0, maxSec: 0, steps: Map(), _sum: 0, _n: 0}

RecStats_Add(st, s) {
    st.total += 1
    if s.result = "RUNNING" {
        st.running += 1
        return
    }
    if s.result = "RECOVERY_ABORTED" {
        st.aborted += 1
        return
    }
    if s.ok
        st.ok += 1
    else {
        st.fail += 1
        if s.step != ""
            st.steps[s.step] := (st.steps.Has(s.step) ? st.steps[s.step] : 0) + 1
    }
    st._sum += s.sec, st._n += 1
    if s.sec > st.maxSec
        st.maxSec := s.sec
}

RecStats_Finish(st) {
    if st.ok + st.fail > 0
        st.rate := st.ok / (st.ok + st.fail)
    if st._n > 0
        st.avgSec := Round(st._sum / st._n)
}

; 彙總：{total, byDay: Map(日期→stat), byRole: Map(角色→stat), days:[排序後日期], roles:[排序後角色]}
; stat = {total, ok, fail, aborted, running, rate(0~1，沒有已結案的為 -1), avgSec, maxSec, steps: Map(步驟→失敗次數)}
RecStats_Summarize(sessions) {
    sum := {total: RecStats_NewStat(), byDay: Map(), byRole: Map(), days: [], roles: []}
    for s in sessions {
        RecStats_Add(sum.total, s)
        if !sum.byDay.Has(s.day)
            sum.byDay[s.day] := RecStats_NewStat(), sum.days.Push(s.day)
        RecStats_Add(sum.byDay[s.day], s)
        if !sum.byRole.Has(s.name)
            sum.byRole[s.name] := RecStats_NewStat(), sum.roles.Push(s.name)
        RecStats_Add(sum.byRole[s.name], s)
    }
    RecStats_Finish(sum.total)
    for _, st in sum.byDay
        RecStats_Finish(st)
    for _, st in sum.byRole
        RecStats_Finish(st)
    sum.days := RecStats_SortStrings(sum.days)
    sum.roles := RecStats_SortStrings(sum.roles)
    return sum
}

RecStats_SortStrings(arr) {
    n := arr.Length
    Loop n - 1 {
        i := A_Index
        Loop n - i {
            j := A_Index
            if StrCompare(arr[j], arr[j + 1]) > 0
                t := arr[j], arr[j] := arr[j + 1], arr[j + 1] := t
        }
    }
    return arr
}

; 最常卡住的步驟：[{step, count}, ...]，次數多的在前，同次數依名稱排序；最多 n 個。
RecStats_TopSteps(st, n := 3) {
    keys := []
    for k, _ in st.steps
        keys.Push(k)
    keys := RecStats_SortStrings(keys)
    out := []
    Loop Min(n, keys.Length) {
        best := ""
        for k in keys {
            if (best = "" || st.steps[k] > st.steps[best])
                best := k
        }
        out.Push({step: best, count: st.steps[best]})
        for i, k in keys {
            if k = best {
                keys.RemoveAt(i)
                break
            }
        }
    }
    return out
}

; 一次呼叫：讀檔＋彙總。
RecStats_Compute(logDir, endDay, days := 7) {
    r := RecStats_Load(logDir, endDay, days)
    sum := RecStats_Summarize(r.sessions)
    sum.sessions := r.sessions
    sum.corrupt := r.corrupt
    sum.missing := r.missing
    sum.files := r.files
    return sum
}
