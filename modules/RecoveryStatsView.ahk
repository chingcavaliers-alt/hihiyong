; ============================================================
; RecoveryStatsView — 重新登入統計的「顯示」部分（H-003）：報表文字與網頁 JSON。
; 純字串處理，依賴 RecoveryStats.ahk（RecStats_*）；不碰遊戲 / 不依賴主程式全域變數。
;
; 規則：成功率 rate = -1（沒有已結案的）一律顯示「—」，JSON 內維持 -1 讓網頁自己顯示「—」。
; ============================================================

; 0~1 → "85%"；-1（沒有資料）→ "—"
RecView_Pct(rate) => rate < 0 ? "—" : Round(rate * 100) "%"

; 步驟事件名 → 白話。沒對到的原樣顯示事件名。
RecView_StepLabel(step) {
    exact := Map("LOADING_CHARSELECT_STUCK", "卡在選角畫面", "ENTER_RETRY_GIVEUP", "進入遊戲重試放棄"
        , "ENTER_RETRY", "進入遊戲重試", "FOCUS_RETRY", "視窗焦點重試", "INGAME_GATE", "進遊戲確認", "CHAR_READY", "選角完成確認")
    if exact.Has(step)
        return exact[step]
    for pre, label in Map("LOADING_", "讀取畫面", "SERVER_", "選伺服器", "SCREEN_", "等待畫面", "LOGIN_", "登入畫面", "STARTGAME_", "開始遊戲") {
        if SubStr(step, 1, StrLen(pre)) = pre
            return label "（" step "）"
    }
    return step
}

; 一行：最近 days 天成功率與最常卡住的步驟。S = RecStats_Compute 的結果。
RecView_ReportLine(S, days := 7) {
    head := "📈 最近 " days " 天重新登入："
    t := S.total
    if S.files = 0
        return head "找不到日誌，無法統計"
    if t.total = 0
        return head "這段期間沒有重新登入紀錄"
    if t.rate < 0
        return head "共 " t.total " 次，成功率 —（還沒有結案的紀錄）"
    out := head "成功率 " RecView_Pct(t.rate) "（" t.ok " / " (t.ok + t.fail) " 次成功）"
    top := RecStats_TopSteps(t, 3)
    if !top.Length
        return out "｜🎉 沒有卡住的紀錄"
    parts := ""
    for x in top
        parts .= (parts = "" ? "" : "、") RecView_StepLabel(x.step) " ×" x.count
    return out "｜🚧 最常卡住：" parts
}

; 給每日報表：讀日誌並回傳那一行。任何錯誤回傳 ""（不影響報表其他內容）。
RecView_WeekLine(logDir, endDay, days := 7) {
    try {
        S := RecStats_Compute(logDir, endDay, days)
        return RecView_ReportLine(S, days)
    } catch
        return ""
}

RecView_Str(s) {
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, '"', '\"')
    s := StrReplace(s, "`r", "\r")
    s := StrReplace(s, "`n", "\n")
    s := StrReplace(s, "`t", "\t")
    return s
}

RecView_Rate(rate) => rate < 0 ? "-1" : RegExReplace(Format("{:.4f}", rate), "\.?0+$")

RecView_StatFields(st) {
    return '"total":' st.total ',"ok":' st.ok ',"fail":' st.fail ',"aborted":' st.aborted ',"running":' st.running
        . ',"rate":' RecView_Rate(st.rate) ',"avgSec":' st.avgSec ',"maxSec":' st.maxSec
}

RecView_TopStepsJson(st, n := 3) {
    out := ""
    for x in RecStats_TopSteps(st, n)
        out .= (out = "" ? "" : ",") '{"step":"' RecView_Str(x.step) '","label":"' RecView_Str(RecView_StepLabel(x.step)) '","count":' x.count '}'
    return "[" out "]"
}

; 網頁用 JSON 物件（放在 invstats 訊息的 "recovery" 欄位）：
; {"days":N,"files":N,"corrupt":N,
;  "total":{total,ok,fail,aborted,running,rate,avgSec,maxSec,"topSteps":[{step,label,count}]},
;  "byDay":[{"day","total","ok","fail","rate"} …連續 days 天，沒有紀錄的日子 total=0、rate=-1],
;  "roles":[{"name",total,ok,fail,aborted,running,rate,avgSec,maxSec,"topSteps":[…]} …]}
; rate：0~1，-1 = 沒有已結案的（網頁顯示「—」）。
RecView_Json(S, endDay, days := 7) {
    byDay := ""
    endTs := RecStats_ParseTime(endDay " 00:00:00")
    if endTs != "" {
        Loop days {
            d := FormatTime(DateAdd(endTs, -(days - A_Index), "Days"), "yyyy-MM-dd")
            if S.byDay.Has(d) {
                st := S.byDay[d]
                byDay .= (byDay = "" ? "" : ",") '{"day":"' d '","total":' st.total ',"ok":' st.ok ',"fail":' st.fail ',"rate":' RecView_Rate(st.rate) '}'
            } else
                byDay .= (byDay = "" ? "" : ",") '{"day":"' d '","total":0,"ok":0,"fail":0,"rate":-1}'
        }
    }
    roles := ""
    for name in S.roles {
        st := S.byRole[name]
        roles .= (roles = "" ? "" : ",") '{"name":"' RecView_Str(name) '",' RecView_StatFields(st) ',"topSteps":' RecView_TopStepsJson(st, 1) '}'
    }
    return '{"days":' days ',"files":' S.files ',"corrupt":' S.corrupt
        . ',"total":{' RecView_StatFields(S.total) ',"topSteps":' RecView_TopStepsJson(S.total, 3) '}'
        . ',"byDay":[' byDay '],"roles":[' roles ']}'
}

; 一次呼叫：讀日誌＋產生 JSON。錯誤時回傳 files=0 的空物件。
RecView_JsonFor(logDir, endDay, days := 7) {
    try {
        S := RecStats_Compute(logDir, endDay, days)
        return RecView_Json(S, endDay, days)
    } catch
        return '{"days":' days ',"files":0,"corrupt":0,"total":{"total":0,"ok":0,"fail":0,"aborted":0,"running":0,"rate":-1,"avgSec":0,"maxSec":0,"topSteps":[]},"byDay":[],"roles":[]}'
}

; 同上，但同樣的 logDir / endDay / days 在 ttlMs（預設 60 秒）內重用上次結果，
; 避免網頁 10~30 秒輪詢時每次都重讀多天日誌。now 預設 A_TickCount（測試可傳入）。
RecView_JsonCached(logDir, endDay, days := 7, now := "", ttlMs := 60000) {
    static key := "", json := "", at := 0
    if now = ""
        now := A_TickCount
    k := logDir "|" endDay "|" days
    if key = k && json != "" && now - at >= 0 && now - at < ttlMs
        return json
    json := RecView_JsonFor(logDir, endDay, days)
    key := k
    at := now
    return json
}
