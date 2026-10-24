; H-006 夜間安靜模式：安靜時段內的一般 Discord 通知先存檔累積，時段結束後合併成一則送出。
; 純邏輯，不碰 GUI / Discord / INI；設定值與送出函式由呼叫端傳入，方便單元測試。
; 緊急通知（需要人工、斷線、伺服器、網路中斷…）一律不攔，照常立即送。
; 佇列檔：每行一則「HH:mm|內容」，內容中的換行存成 \n、反斜線存成 \\；程式重開不遺失。

; "HH:mm" → 當天第幾分鐘（0..1439）；格式不合回傳 def。
Quiet_ParseTime(s, def) {
    if !RegExMatch(Trim(s), "^(\d{1,2}):(\d{2})$", &m)
        return def
    h := Integer(m[1]), n := Integer(m[2])
    if (h > 23 || n > 59)
        return def
    return h * 60 + n
}

Quiet_FormatTime(mins) => Format("{:02}:{:02}", mins // 60, Mod(mins, 60))

; nowMin 是否落在 [start, end)；支援跨午夜；start = end 視為沒有時段。
Quiet_InWindow(nowMin, startMin, endMin) {
    if (startMin = endMin)
        return false
    if (startMin < endMin)
        return nowMin >= startMin && nowMin < endMin
    return nowMin >= startMin || nowMin < endMin
}

; 緊急關鍵字（寧可多判為緊急＝照送）。
Quiet_IsUrgent(msg) {
    static keys := ["🔴", "⚠️", "需要人工", "人工", "斷線", "伺服器", "網路中斷", "假在線", "已停止此帳號自動恢復", "自動恢復失敗", "失敗", "逾時", "載入過久", "保留遊戲視窗", "停止"]
    for k in keys {
        if InStr(msg, k)
            return true
    }
    return false
}

; Webhook 網址是否可用（空白或格式不符時不攔截，讓原流程照常丟錯誤）。
Quiet_UrlOk(url) => RegExMatch(Trim(url), "i)^https://(canary\.|ptb\.)?discord(app)?\.com/api/webhooks/") > 0

; 這則訊息現在要不要先收起來（force=使用者主動 / 測試，一律不攔）。
Quiet_ShouldHold(enabled, nowMin, startMin, endMin, msg, force := false, urlOk := true) {
    if (!enabled || force || !urlOk)
        return false
    if !Quiet_InWindow(nowMin, startMin, endMin)
        return false
    return !Quiet_IsUrgent(msg)
}

; 主程式呼叫：判斷並存檔。回傳 true = 已收進佇列（呼叫端直接當作送出成功）。
; 時間字串壞掉時回到預設 01:00 / 08:00。
Quiet_TryHold(file, enabled, startStr, endStr, msg, force, url, nowMin) {
    if !Quiet_ShouldHold(enabled, nowMin, Quiet_ParseTime(startStr, 60), Quiet_ParseTime(endStr, 480), msg, force, Quiet_UrlOk(url))
        return false
    return Quiet_Enqueue(file, msg)
}

Quiet_Escape(s) {
    s := StrReplace(s, "\", "\\")
    s := StrReplace(s, "`r", "")
    return StrReplace(s, "`n", "\n")
}

Quiet_Unescape(s) {
    out := "", i := 1, n := StrLen(s)
    while (i <= n) {
        c := SubStr(s, i, 1)
        if (c = "\" && i < n) {
            d := SubStr(s, i + 1, 1)
            if (d = "n")
                out .= "`n", i += 2
            else if (d = "\")
                out .= "\", i += 2
            else
                out .= c, i += 1
        } else
            out .= c, i += 1
    }
    return out
}

; 加入佇列（附加到檔尾）。成功回傳 true。
Quiet_Enqueue(file, msg, stamp := "") {
    if (stamp = "")
        stamp := FormatTime(, "MM-dd HH:mm")
    try {
        SplitPath(file, , &dir)
        if (dir != "" && !DirExist(dir))
            DirCreate(dir)
        FileAppend(stamp "|" Quiet_Escape(msg) "`n", file, "UTF-8")
        return true
    } catch
        return false
}

; 讀回佇列；檔案不存在 / 壞行一律略過，不丟例外。
Quiet_Load(file) {
    items := []
    if !FileExist(file)
        return items
    try text := FileRead(file, "UTF-8")
    catch
        return items
    for line in StrSplit(text, "`n", "`r") {
        if !RegExMatch(line, "^(\d{2}-\d{2} \d{2}:\d{2})\|(.+)$", &m)
            continue
        items.Push({t: m[1], msg: Quiet_Unescape(m[2])})
    }
    return items
}

Quiet_Count(file) => Quiet_Load(file).Length

Quiet_Clear(file) {
    try FileDelete(file)
}

; 重寫佇列檔（剩下的項目）；空了就刪檔。
Quiet_Save(file, items) {
    if (items.Length = 0) {
        Quiet_Clear(file)
        return
    }
    text := ""
    for it in items
        text .= it.t "|" Quiet_Escape(it.msg) "`n"
    try FileDelete(file)
    try FileAppend(text, file, "UTF-8")
}

; 把累積的通知切成數段 [{text, count}]（每段不超過 limit 字）。
; count = 這一段消耗掉的佇列項目數（最後一段也包含沒列出的「另有 N 則」）。
; 每則都帶「MM-dd HH:mm」，超過一天的舊通知也看得出日期。
Quiet_BuildParts(items, maxItems := 20, limit := 1900) {
    parts := []
    if (items.Length = 0)
        return parts
    shown := Min(items.Length, maxItems)
    cur := "🌙 HIHIYONG 安靜時段累積通知（共 " items.Length " 則）"
    cnt := 0
    Loop shown {
        it := items[A_Index]
        body := it.msg
        if (StrLen(body) > limit - 120)
            body := SubStr(body, 1, limit - 120) "…"
        block := "`n──────────`n[" it.t "] " body
        if (StrLen(cur) + StrLen(block) > limit) {
            parts.Push({text: cur, count: cnt})
            cur := "🌙 （續）", cnt := 0
        }
        cur .= block, cnt += 1
    }
    if (items.Length > shown) {
        cur .= "`n──────────`n另有 " (items.Length - shown) " 則未列出，詳見執行紀錄。"
        cnt += items.Length - shown
    }
    parts.Push({text: cur, count: cnt})
    return parts
}

; 只要文字的版本（給測試 / 簡單用途）。
Quiet_BuildMerged(items, maxItems := 20, limit := 1900) {
    out := []
    for p in Quiet_BuildParts(items, maxItems, limit)
        out.Push(p.text)
    return out
}

; 時段已結束（或安靜模式已關閉，enabled=0）且佇列非空 → 合併後用 sendFn(part) 送出。
; 每段送成功就把對應項目從佇列檔移除，中途失敗不會重複送已送出的部分。
; 回傳成功送出的段數（0 = 沒送）。時段內、佇列空、或第一段就失敗都回傳 0。
Quiet_Flush(file, sendFn, nowMin, startMin, endMin, enabled := true) {
    if (enabled && Quiet_InWindow(nowMin, startMin, endMin))
        return 0
    items := Quiet_Load(file)
    if (items.Length = 0) {
        if FileExist(file)
            Quiet_Clear(file)
        return 0
    }
    sentParts := 0
    for part in Quiet_BuildParts(items) {
        ok := false
        try ok := sendFn(part.text)
        if !ok
            return sentParts
        sentParts += 1
        items.RemoveAt(1, part.count)
        Quiet_Save(file, items)
    }
    return sentParts
}
