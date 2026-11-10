; ============================================================================
; 水晶礦場王（虹光秘脈礦主）的重生倒數：打開遊戲的「BOSS 資訊」視窗，用 Windows 文字辨識（OCR）讀那一格的倒數時間，再關掉。
;
; 為什麼用畫面讀：王死了之後 2 小時重生，但王是不是別人打死的、角色在不在場都不一定，程式自己記的死亡時間不準；
; BOSS 資訊視窗的倒數是伺服器給的，不管誰打死的都準。遊戲畫面固定 1024x768、視窗版面固定，所以讀畫面比找記憶體位置穩，也不怕遊戲改版後位置位移。
;
; 流程：先看視窗是不是已經開著（畫面上有倒數時間）→ 沒開就點畫面右下角「寵物頭像左邊」的同心圓圖示 → 擷取遊戲畫面、裁出視窗 →
;   OCR（tools\ocr_text.ps1）→ 找「虹光秘脈礦主」那一格後面的「日 時 分 秒」→ 清單沒捲到就往下捲再讀 → 按 Esc 關閉。
; 觸發：頁面上的「現在讀王重生時間」按鈕（手動）；設定檔 [AutoMining] BossTimerAuto=1 時，礦都採完等重生的空檔自動讀
;   （沒讀過每 10 分鐘一次、讀過了王快重生前 15 分鐘每 5 分鐘一次）。預設只有手動。
; ============================================================================
global BT_BTN_X := 874, BT_BTN_Y := 688          ; BOSS 資訊按鈕（遊戲畫面 1024x768 座標）
global BT_CROP := [262, 98, 503, 570]            ; BOSS 資訊視窗的範圍 x, y, w, h
global BT_NAME := "虹光秘脈礦主"
global BT_AUTO := MnIniGet("BossTimerAuto", "0") = "1" ? 1 : 0
global BT_RECHECK_MS := 600000                   ; 沒有讀到過：每 10 分鐘讀一次
global BT_NEAR_MS := 900000                      ; 王快重生（15 分鐘內）才開始頻繁讀
global BT_NEAR_RECHECK_MS := 300000

; 一行文字裡的整數（OCR 常漏「時」之類的字，所以不看中文，只看數字）
BtNumbers(line) {
    nums := []
    pos := 1
    while RegExMatch(line, "\d+", &m, pos) {
        nums.Push(Integer(m[0]))
        pos := m.Pos + m.Len
    }
    return nums
}
; 「0 日 1 時 1 分 22 秒」→ 3682；不像倒數時間的行回傳 ""
BtTimeOf(line) {
    if !RegExMatch(line, "[日分秒時]")
        return ""
    n := BtNumbers(line)
    if n.Length != 4 || n[1] > 30 || n[2] > 23 || n[3] > 59 || n[4] > 59
        return ""
    return n[1] * 86400 + n[2] * 3600 + n[3] * 60 + n[4]
}
; 這一行有幾個字是王的名字裡的字（OCR 會漏字，也會多空白）
BtNameScore(line) {
    global BT_NAME
    s := StrReplace(line, " ", ""), n := 0
    Loop Parse BT_NAME
        if InStr(s, A_LoopField)
            n += 1
    return n
}
; OCR 出來的行 → 王那一格的剩餘秒數；找不到回傳 ""
BtFindSeconds(lines) {
    last := 0
    for i, l in lines {
        if BtNameScore(l) >= 3 {
            last := i
            continue
        }
        t := BtTimeOf(l)
        if t != "" && last && i - last <= 4
            return t
    }
    return ""
}
; 畫面上有幾行像倒數時間（視窗有沒有開著）
BtTimeLines(lines) {
    n := 0
    for l in lines
        if BtTimeOf(l) != ""
            n += 1
    return n
}

; 擷取遊戲畫面 → OCR → 行
BtOcrLines(p, scale := 3) {
    global BT_CROP
    png := A_Temp "\hihiyong_bt_" p.pid ".png", out := A_Temp "\hihiyong_bt_" p.pid ".txt"
    try FileDelete out
    cap := "CaptureWindowPng", ok := false
    try ok := %cap%(p.hwnd, png)
    if !ok
        return []
    w := 1024
    try {
        WinGetClientPos(, , &cw, , "ahk_id " p.hwnd)
        if cw > 0
            w := cw
    }
    f := w / 1024
    crop := Round(BT_CROP[1] * f) "," Round(BT_CROP[2] * f) "," Round(BT_CROP[3] * f) "," Round(BT_CROP[4] * f)
    try RunWait('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' A_ScriptDir '\tools\ocr_text.ps1" -Path "' png '" -Out "' out '" -Crop "' crop '" -Scale ' scale, , "Hide")
    txt := ""
    try txt := FileRead(out, "UTF-8")
    try FileDelete png
    return StrSplit(txt, "`n", "`r")
}

; 開視窗 → 讀倒數 → 關視窗。回傳 {sec, lines}；讀不到 sec 是 ""
BtRead(p) {
    global BT_BTN_X, BT_BTN_Y
    lines := BtOcrLines(p)
    if BtTimeLines(lines) < 2 {   ; 視窗沒開（開著再點一次會被關掉）
        ApClick(p, BT_BTN_X, BT_BTN_Y)
        Sleep 1600   ; 要向伺服器要資料
        lines := BtOcrLines(p)
    }
    sec := BtFindSeconds(lines)
    tries := 0
    scroll := "ApScrollMany"
    while sec = "" && BtTimeLines(lines) >= 2 && tries < 6 {   ; 視窗開著但那一格不在畫面上：往下捲
        tries += 1
        try %scroll%(p, 500, 400, 1, 3, 40)
        Sleep 600
        lines := BtOcrLines(p)
        sec := BtFindSeconds(lines)
    }
    if sec = "" && BtTimeLines(lines) >= 2   ; 換不同放大倍數再試一次（偶爾 OCR 會漏字）
        for sc in [4, 2] {
            l2 := BtOcrLines(p, sc)
            sec := BtFindSeconds(l2)
            if sec != "" {
                lines := l2
                break
            }
        }
    ApKey(p, "Escape")
    return {sec: sec, lines: lines, opened: BtTimeLines(lines) >= 2}
}

MnBossTimer(p) {
    st := MnSt(p)
    st.btLast := A_TickCount, st.bossTimerNow := false
    st.text := "讀取王的重生時間（開 BOSS 資訊視窗）"
    r := BtRead(p)
    if r.sec != "" {
        st.bossEta := {sec: r.sec, tick: A_TickCount, at: A_Now}
        EventLog(p.name, "MN_BOSS_TIMER", "王的重生倒數 " MnFmtSec(r.sec) "｜預計 " FormatTime(DateAdd(A_Now, r.sec, "Seconds"), "MM-dd HH:mm") " 重生")
        AddRecentEvent("⛏ " p.name "：王約 " FormatTime(DateAdd(A_Now, r.sec, "Seconds"), "HH:mm") " 重生（還有 " MnFmtSec(r.sec) "）")
    } else {
        txt := ""
        for l in r.lines
            txt .= (txt = "" ? "" : " / ") l
        EventLog(p.name, "MN_BOSS_TIMER_FAIL", (r.opened ? "視窗開了但找不到王那一格" : "BOSS 資訊視窗沒有打開（沒辨識到倒數時間）") "｜OCR：" SubStr(txt, 1, 400))
        AddRecentEvent("⚠ " p.name "：讀不到王的重生時間（" (r.opened ? "找不到王那一格" : "視窗沒打開") "）")
    }
}

MnFmtSec(sec) {
    sec := Max(0, Round(sec))
    h := sec // 3600, m := Mod(sec, 3600) // 60, s := Mod(sec, 60)
    return h ? h " 小時 " m " 分" : (m ? m " 分 " s " 秒" : s " 秒")
}
; 頁面上顯示的一行
MnBossEtaText(st) {
    if !st.HasOwnProp("bossEta") || !IsObject(st.bossEta)
        return ""
    e := st.bossEta
    remain := e.sec - Round((A_TickCount - e.tick) / 1000)
    at := FormatTime(DateAdd(e.at, e.sec, "Seconds"), "HH:mm")
    if remain <= 0
        return "王應該已經重生（預計 " at "）"
    return "王約 " at " 重生（還有 " MnFmtSec(remain) "）"
}
; 現在該不該去讀：手動按了按鈕，或（開了自動、而且是等重生的空檔）還沒讀過 / 王快重生了
MnBossTimerDue(p, st, idle) {
    global BT_AUTO, BT_RECHECK_MS, BT_NEAR_MS, BT_NEAR_RECHECK_MS
    if st.HasOwnProp("bossTimerNow") && st.bossTimerNow
        return true
    if !BT_AUTO || !idle
        return false
    last := st.HasOwnProp("btLast") ? st.btLast : 0
    if !st.HasOwnProp("bossEta") || !IsObject(st.bossEta)
        return !last || A_TickCount - last >= BT_RECHECK_MS
    remainMs := (st.bossEta.sec - Round((A_TickCount - st.bossEta.tick) / 1000)) * 1000
    return remainMs <= BT_NEAR_MS && A_TickCount - last >= BT_NEAR_RECHECK_MS
}
; 頁面按鈕：勾選的、在遊戲裡的角色下一個空檔就去讀
AutoMiningBossTimerNow() {
    for p in MnSelectedAlive()
        MnSt(p).bossTimerNow := true
}
