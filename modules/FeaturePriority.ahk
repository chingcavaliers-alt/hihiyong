; ============================================================================
; FeaturePriority：功能優先順序（多個自動功能搶同一個角色 / 前景視窗時，誰先、誰等）。
;
; 設定在「自動化 → ⚖️ 功能優先順序」：排越前面越優先。預設把「每日更換道具」放最前面。
; 規則：功能 F 要對角色 P 動手之前，先問 FpBlocked(F, P)——排在 F 前面的功能只要有一個「忙著」（正在對 P 動手、或排隊等著動手），
; F 就等（不開始新的動作）；已經在進行中的動作不會被打斷（採一顆礦 60 秒、打王 10 分鐘都會做完這一段才讓）。
; 例外：每日更換道具遇到「自動採礦在礦場裡」且採礦排比較前面時，會等到角色離開礦場（被踢出 / 跑完趟數）才換。
; 設定存在 INI [Priority] Order（功能代碼，逗號分隔）。
; ============================================================================

global FP_KEYS := ["daily", "switcher", "mining", "boss", "dailyhunt", "party", "companion", "mbox", "lagfix"]
global FP_NAMES := Map("daily", "每日更換道具", "switcher", "視窗按鍵精靈（輪流切換視窗 + 按鍵）", "mining", "自動採礦", "boss", "打王（自動採礦的一部分）", "dailyhunt", "每日討伐"
    , "party", "自動組隊", "companion", "寵物 / 雇傭兵 / 娃娃監測", "mbox", "命運箱子", "lagfix", "變慢自動過圖")
global FP_DEFAULT := "daily,switcher,mining,boss,dailyhunt,party,companion,mbox,lagfix"

; 只保留認得的功能、去重、缺的補在最後（照預設順序）
FpParse(text) {
    global FP_KEYS
    out := []
    for part in StrSplit(text, ",") {
        k := Trim(part)
        known := false, dup := false
        for x in FP_KEYS
            if x = k
                known := true
        for o in out
            if o = k
                dup := true
        if known && !dup
            out.Push(k)
    }
    for idx, x in FP_KEYS {
        have := false
        for o in out
            if o = x
                have := true
        if have
            continue
        pos := 0   ; 預設順序裡排在它前面的那個功能，在目前順序裡的位置；插在它後面
        if idx > 1 {
            for j, o in out
                if o = FP_KEYS[idx - 1]
                    pos := j
        }
        out.InsertAt(pos + 1, x)
    }
    return out
}
FpIniGet() {
    global INI, FP_DEFAULT
    try return IniRead(INI, "Priority", "Order", FP_DEFAULT)
    return FP_DEFAULT
}
global FP_ORDER := FpParse(FpIniGet())

FpRank(key) {
    global FP_ORDER
    for i, k in FP_ORDER
        if k = key
            return i
    return 99
}

; 設定新的順序並存檔（text = 逗號分隔的功能代碼）
FpSet(text) {
    global INI, FP_ORDER
    FP_ORDER := FpParse(text)
    s := ""
    for k in FP_ORDER
        s .= (s = "" ? "" : ",") k
    try IniWrite s, INI, "Priority", "Order"
    AddRecentEvent("⚖ 功能優先順序：" FpOrderText())
}
FpOrderText() {
    global FP_ORDER, FP_NAMES
    s := ""
    for k in FP_ORDER
        s .= (s = "" ? "" : " > ") FP_NAMES[k]
    return s
}

; 功能 key 現在是不是「忙著」（對角色 p 動手中或排隊中；p = 0 表示不分角色）。回傳原因文字，不忙回傳 ""。
; asker：問的人是誰（每日更換道具問採礦時看「整趟都在礦場」，其他功能看「正在採集 / 走路」）。
FpBusy(key, p := 0, asker := "") {
    global dailyRunning, dailyRunQueue, profiles, mnBusy, mnBossFight, dhBusy, cwBusy, mboxBusy, lfBusy, apBusy, foregroundOwner, autoSwitchRunning
    if key = "daily" {
        ; 遊戲視窗一次只能有一個在前景：更換每日道具進行中，不分角色，其他功能都要等
        if dailyRunning != ""
            return "更換每日道具中（" dailyRunning "）"
        ; 排隊中的也不分角色：只要它「真的輪得到」（不是自己在等前面的功能，例如把採礦排前面、角色還在礦場裡），
        ; 就先擋住別的角色的低優先功能，讓它拿得到前景；它自己在等的時候不擋（否則會把別人白白擋兩小時）。
        for q in dailyRunQueue
            if FpBlocked("daily", profiles[q]) = ""
                return "排隊更換每日道具（" profiles[q].name "）"
        return ""
    }
    if key = "mining" {
        if p {
            if p.HasOwnProp("mnActive") && p.mnActive {
                if asker = "daily" && p.HasOwnProp("mn") && IsObject(p.mn) && p.mn.inMine
                    return "自動採礦中（在礦場裡）"
                if p.HasOwnProp("mn") && IsObject(p.mn) && p.mn.gathering
                    return "自動採礦中（正在採集）"
            }
        }
        if foregroundOwner = "mining" || mnBusy
            return "自動採礦中（走路 / 右鍵）"
        return ""
    }
    if key = "switcher"
        return autoSwitchRunning ? "視窗按鍵精靈執行中" : ""
    if key = "boss"
        return mnBossFight ? "打王中" : ""
    if key = "dailyhunt"
        return dhBusy ? "每日討伐進行中" : ""
    if key = "party"
        return apBusy && foregroundOwner = "party" ? "自動組隊進行中" : ""
    if key = "companion"
        return cwBusy ? "寵物 / 雇傭兵監測進行中" : ""
    if key = "mbox"
        return mboxBusy ? "命運箱子進行中" : ""
    if key = "lagfix"
        return lfBusy ? "變慢自動過圖進行中" : ""
    return ""
}

; 功能 key 要對角色 p 動手之前問：排在它前面的功能有沒有誰忙著？有就回傳「原因（優先）」，沒有回傳 ""。
FpBlocked(key, p := 0) {
    global FP_ORDER
    mine := FpRank(key)
    for i, k in FP_ORDER {
        if k = key
            break
        why := FpBusy(k, p, key)
        if why != ""
            return why "（優先順序較高）"
    }
    return ""
}

; 視窗按鍵精靈是不是「獨佔」：它排在其他所有要用前景的功能（採礦、每日討伐、組隊、寵物監測、命運箱子）前面 = 獨佔
; （它執行中那些功能一律不啟動，和以前一樣）；只要它排在其中任何一個後面，就交給各功能動手前的 FpBlocked 判斷
; （排在它前面的功能可以照常動作，它會暫停讓路；排在它後面的功能等它）。
FpSwitcherExclusive() {
    r := FpRank("switcher")
    for k in ["mining", "dailyhunt", "party", "companion", "mbox"]
        if FpRank(k) < r
            return false
    return true
}

; ---------------------------------------------------------------- 頁面
FpPushWeb() {
    global webReady, WVCore, FP_ORDER, FP_NAMES
    if !webReady || !WVCore
        return
    rows := ""
    for k in FP_ORDER
        rows .= (rows = "" ? "" : ",") '{"key":"' k '","name":"' JsonEscapeWeb(FP_NAMES[k]) '"}'
    try WVCore.PostWebMessageAsJson('{"type":"priority","data":{"order":[' rows ']}}')
}
