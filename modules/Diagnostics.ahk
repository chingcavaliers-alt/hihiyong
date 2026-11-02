; ============================================================================
; Diagnostics：一鍵匯出診斷包。
; 別台電腦出問題（登入、每日道具、組隊……）時，把版本、環境、最近日誌和失敗截圖打成一個 zip，交給開發者看。
; 只讀：不碰遊戲、不送按鍵。不會包含帳號密碼、Discord 通知網址、授權檔（設定檔 .ini 一律不收，日誌裡的網址也會遮掉）。
; ============================================================================

global DIAG_APP_DIR := A_ScriptDir   ; 程式資料夾（測試時可以改到別處）
global DIAG_DIR := DIAG_APP_DIR "\Diagnostics"
global DIAG_LOG_DAYS := 3, DIAG_SHOT_MAX := 5, DIAG_KEEP_ZIPS := 5
global diagLast := {path: "", size: 0, at: "", err: "", busy: false}

; 日誌文字裡不能留下的東西：Discord 通知網址、疑似金鑰
DiagScrub(text) {
    text := RegExReplace(text, "i)https?://(?:\w+\.)?discord(?:app)?\.com/api/(?:v\d+/)?webhooks/\S+", "[通知網址已移除]")
    text := RegExReplace(text, "i)(password|passwd|pwd|token|secret|密碼)[`"']?\s*[=:：]\s*[`"']?[^\s`"',;]+", "$1=[已移除]")
    text := RegExReplace(text, "i)(Bearer)\s+[\w\-\.=]+", "$1 [已移除]")
    return text
}

; 環境與狀態說明（info.txt）。每一項都包 try：讀不到的寫「讀不到」，不讓匯出失敗。
DiagInfoText() {
    global DIAG_APP_DIR, APP_VERSION, GAME_TITLE, profiles, setupMode, AP_ENABLED, DAILY_ENABLED, LOGIN_MEM_UI
    out := "HIHIYONG 診斷資料`r`n"
    out .= "匯出時間：" FormatTime(, "yyyy-MM-dd HH:mm:ss") "`r`n"
    out .= "程式版本：" APP_VERSION "`r`n"
    out .= "AutoHotkey：" A_AhkVersion "｜" (A_Is64bitOS ? "64 位元" : "32 位元") " Windows " A_OSVersion "`r`n"
    out .= "顯示縮放：" Round(A_ScreenDPI / 96 * 100) "%（A_ScreenDPI=" A_ScreenDPI "）`r`n"
    try {
        Loop MonitorGetCount() {
            MonitorGet(A_Index, &l, &t, &r, &b)
            out .= "螢幕 " A_Index "：" (r - l) "x" (b - t) (A_Index = MonitorGetPrimary() ? "（主螢幕）" : "") "`r`n"
        }
    } catch
        out .= "螢幕：讀不到`r`n"
    out .= "`r`n[功能開關]`r`n"
    try out .= "自動組隊：" (AP_ENABLED ? "開" : "關") "｜每日道具：" (DAILY_ENABLED ? "開" : "關") "｜記憶體登入：" (LOGIN_MEM_UI ? "開" : "關") "`r`n"
    try out .= "8 點登入座標：" (PointsConfigured() ? "8/8 已設定" : "沒有設定完整") "｜設定模式：" (setupMode ? "進行中（沒做完）" : "沒有") "`r`n"
    try out .= "登入走記憶體：" (LoginMemoryAvailable() ? "是（不需要 8 點）" : "否（要靠 8 點）") "`r`n"
    try out .= "遊戲資料位置：" (GameOffsetsLoadedOk() ? "已就緒" : (GameOffsetsResolving() ? "解析中" : "尚未就緒")) "`r`n"
    out .= "`r`n[偏移資料庫]`r`n"
    try {
        n := 0
        Loop Files, DIAG_APP_DIR "\offsets_db\*.ini" {
            out .= "  " A_LoopFileName "（" A_LoopFileSize " 位元組）`r`n"
            n += 1
        }
        if !n
            out .= "  （沒有檔案）`r`n"
    } catch
        out .= "  讀不到`r`n"
    out .= "`r`n[遊戲視窗]（視窗標題 " GAME_TITLE "）`r`n"
    for p in profiles {
        line := "  " p.name "｜" (p.enabled ? "監控中勾選" : "未勾選") "｜狀態 " p.state
        try {
            if p.pid && ProfileGameAlive(p) {
                WinGetClientPos(, , &cw, &ch, "ahk_id " p.hwnd)
                line .= "｜PID " p.pid "｜遊戲畫面 " cw "x" ch "｜遊戲資料 " (GameOffsetsReady(p.pid) ? "可讀" : "不可讀") "｜角色 " (GameCharacterLoaded(p.pid) ? "已載入" : "未載入")
                exe := ProcessGetPath(p.pid)
                shown := RegExReplace(exe, "i)^([A-Z]:\\Users\\)[^\\]+", "$1<使用者>")   ; 不留 Windows 使用者名稱
                line .= "｜" shown "｜" FileGetSize(exe) " 位元組｜" FormatTime(FileGetTime(exe), "yyyy-MM-dd HH:mm")
                try line .= "｜檔案版本 " FileGetVersion(exe)
            } else
                line .= "｜沒有遊戲視窗"
        } catch
            line .= "｜（部分資料讀不到）"
        out .= line "`r`n"
    }
    return out
}

; 每隻已連接角色現在的「效果清單」（右下角狀態圖示的資料）、寵物是否在外面、道具快捷欄每一格是什麼。
; 只讀。用途：找「雇傭兵」之類召喚出來才會多一格的東西，在遊戲裡「沒叫出」和「叫出後」各匯出一次，比對多出來的那一格。
EffectsDumpText() {
    global profiles
    out := "匯出時間 " FormatTime(, "yyyy-MM-dd HH:mm:ss") "（本機）`r`n"
    out .= "用法：同一個角色，先在狀態 A（例如雇傭兵沒叫出）匯出一次，再到狀態 B（叫出後）匯出一次，比對兩份的『效果清單』。`r`n"
    count := 0
    for p in profiles {
        if !p.pid || !ProfileGameAlive(p)
            continue
        out .= "`r`n==================== " p.name "｜PID " p.pid "`r`n"
        if !GameOffsetsReady(p.pid) {
            out .= "遊戲資料位置尚未就緒`r`n"
            continue
        }
        count += 1
        pet := -1
        try pet := ReadGamePetOut(p.pid)
        out .= "寵物：" (pet = 1 ? "在外面" : pet = 0 ? "不在外面" : "讀不到") "`r`n"
        sm := -1, sg := ""
        try sm := ReadGameSummonOut(p.pid)
        try sg := ReadGameSummonGuid(p.pid)
        out .= "召喚獸（雇傭兵）：" (sm = 1 ? "在外面" : sm = 0 ? "不在外面" : "讀不到") "｜角色記的召喚獸 ID " (sg = "" ? "讀不到" : Format("0x{:X}", sg)) "`r`n"
        ; 道具快捷欄（畫面下方）每一格
        out .= "[道具快捷欄]`r`n"
        try {
            st := ReadGameActionQuick(p.pid)
            keys := ReadGameQuickKeys(p.pid)
            if IsObject(st) {
                for i, s in st
                    out .= "  第 " i " 格｜鍵 " (IsObject(keys) && i <= keys.Length ? keys[i] : "?") "｜" (s.key = "" ? "（空）" : s.key " " GameItemName(s.key, p.pid)) "`r`n"
            } else
                out .= "  讀不到`r`n"
        } catch
            out .= "  讀不到`r`n"
        ; 隊伍視窗（隊長交還功能的位置資料驗證用）
        out .= "[隊伍視窗 / 確認視窗]`r`n"
        try out .= ApPartyWinText(p.pid)
        catch
            out .= "  讀不到`r`n"
        ; 效果清單
        out .= "[效果清單]（編號 = 主ID-子ID；Q 開頭是命運箱子效果；age = 遊戲裡的 fAGE）`r`n"
        list := ""
        try list := ReadGameSkillFacts(p.pid)
        if !IsObject(list)
            out .= "  讀不到（這個遊戲版本沒有效果清單的位置資料）`r`n"
        else if !list.Length
            out .= "  （沒有任何效果）`r`n"
        else
            for f in list {
                nm := ""
                try nm := SubStr(f.id, 1, 1) = "Q" ? "命運箱子（問號道具）效果" : MiningSkillName(p.pid, f.id)
                out .= "  " f.id "｜" nm "｜age " Round(f.age, 2) "`r`n"
            }
    }
    if !count
        out .= "`r`n沒有已連接、而且遊戲資料就緒的角色。`r`n"
    return out
}

EffectsDump() {
    global DIAG_APP_DIR
    path := DIAG_APP_DIR "\Logs\EffectsDump_" FormatTime(, "yyyyMMdd_HHmmss") ".txt"
    try {
        if !DirExist(DIAG_APP_DIR "\Logs")
            DirCreate DIAG_APP_DIR "\Logs"
        FileAppend EffectsDumpText(), path, "UTF-8"
        EventLog("GLOBAL", "EFFECTS_DUMP", "已匯出效果清單｜" path)
        AddRecentEvent("📄 已匯出效果清單：" path)
        try Run('explorer.exe /select,"' path '"')
    } catch as e {
        EventLog("GLOBAL", "EFFECTS_DUMP_FAIL", e.Message)
        AddRecentEvent("⚠ 匯出效果清單失敗：" e.Message)
    }
}

; 匯出。成功回傳 zip 路徑；失敗回傳空字串（原因在 diagLast.err）。
DiagExport() {
    global DIAG_APP_DIR, DIAG_DIR, DIAG_LOG_DAYS, DIAG_SHOT_MAX, DIAG_KEEP_ZIPS, diagLast, APP_VERSION
    if diagLast.busy
        return ""
    diagLast.busy := true, diagLast.err := ""
    DiagPushWeb()
    tmp := DIAG_DIR "\_tmp_" FormatTime(, "yyyyMMdd_HHmmss")
    zip := DIAG_DIR "\診斷包_" APP_VERSION "_" FormatTime(, "yyyyMMdd_HHmmss") ".zip"
    try {
        ; 上次中途結束留下的暫存資料夾（裡面是日誌）一併清掉
        Loop Files, DIAG_DIR "\_tmp_*", "D"
            try DirDelete A_LoopFileFullPath, true
        DirCreate tmp
        FileAppend DiagInfoText(), tmp "\info.txt", "UTF-8"
        try FileAppend EffectsDumpText(), tmp "\effects.txt", "UTF-8"
        ; 最近幾天的日誌（遮掉通知網址）
        n := 0
        Loop Files, DIAG_APP_DIR "\Logs\HIHIYONG_*.log" {
            if DateDiff(A_Now, A_LoopFileTimeModified, "Days") > DIAG_LOG_DAYS
                continue
            FileAppend DiagScrub(FileRead(A_LoopFileFullPath, "UTF-8")), tmp "\" A_LoopFileName, "UTF-8"
            n += 1
        }
        ; 久掛延遲量測（最近 2 天；只有數字）
        Loop Files, DIAG_APP_DIR "\Logs\LagProbe_*.csv" {
            if DateDiff(A_Now, A_LoopFileTimeModified, "Days") <= 2
                try FileCopy A_LoopFileFullPath, tmp "\" A_LoopFileName
        }
        ; 最近幾張每日道具失敗截圖
        shots := []
        Loop Files, DIAG_APP_DIR "\Logs\DailyFail_*.png"
            shots.Push([A_LoopFileTimeModified, A_LoopFileFullPath, A_LoopFileName])
        Loop shots.Length - 1 {   ; 新的排前面
            i := A_Index
            Loop shots.Length - i {
                j := A_Index
                if shots[j][1] < shots[j + 1][1]
                    t := shots[j], shots[j] := shots[j + 1], shots[j + 1] := t
            }
        }
        Loop Min(DIAG_SHOT_MAX, shots.Length)
            FileCopy shots[A_Index][2], tmp "\" shots[A_Index][3]
        ; 這台解析出來的遊戲資料位置（只有位置數字，不含個人資料）
        if FileExist(DIAG_APP_DIR "\HIHIYONG_GameOffsets.ini")
            FileCopy DIAG_APP_DIR "\HIHIYONG_GameOffsets.ini", tmp "\HIHIYONG_GameOffsets.ini"
        ; 路徑用環境變數交給 PowerShell（資料夾名稱有引號 / 方括號也不會壞）；最多等 90 秒，卡住就放棄
        EnvSet "HIHIYONG_DIAG_SRC", tmp
        EnvSet "HIHIYONG_DIAG_ZIP", zip
        Run('powershell -NoProfile -ExecutionPolicy Bypass -Command "Compress-Archive -LiteralPath (Get-ChildItem -LiteralPath $env:HIHIYONG_DIAG_SRC | ForEach-Object FullName) -DestinationPath $env:HIHIYONG_DIAG_ZIP -Force"', , "Hide", &zpid)
        if ProcessWaitClose(zpid, 90) {   ; 逾時時回傳還活著的 PID，正常結束回傳 0
            try ProcessClose zpid
            try FileDelete zip
            throw Error("壓縮超過 90 秒沒有完成（防毒軟體或系統政策擋住 PowerShell？）")
        }
        if !FileExist(zip) || FileGetSize(zip) <= 0
            throw Error("壓縮失敗（沒有產生 zip）")
        diagLast.path := zip, diagLast.size := FileGetSize(zip), diagLast.at := FormatTime(, "yyyy-MM-dd HH:mm:ss")
        EventLog("GLOBAL", "DIAG_EXPORT", "已匯出診斷包｜" zip "｜" diagLast.size " 位元組｜日誌 " n " 個")
        AddRecentEvent("📦 已匯出診斷包：" zip)
        DiagCleanOld()
    } catch as e {
        diagLast.err := e.Message
        zip := ""
        EventLog("GLOBAL", "DIAG_FAIL", e.Message)
        AddRecentEvent("⚠ 匯出診斷包失敗：" e.Message)
    }
    try DirDelete tmp, true
    diagLast.busy := false
    DiagPushWeb()
    return zip
}

; 只留最近幾個診斷包，不讓資料夾一直變大。
DiagCleanOld() {
    global DIAG_DIR, DIAG_KEEP_ZIPS
    zips := []
    Loop Files, DIAG_DIR "\診斷包_*.zip"
        zips.Push([A_LoopFileTimeModified, A_LoopFileFullPath])
    Loop zips.Length - 1 {
        i := A_Index
        Loop zips.Length - i {
            j := A_Index
            if zips[j][1] < zips[j + 1][1]
                t := zips[j], zips[j] := zips[j + 1], zips[j + 1] := t
        }
    }
    Loop zips.Length {
        if A_Index > DIAG_KEEP_ZIPS
            try FileDelete zips[A_Index][2]
    }
}

DiagOpenFolder() {
    global diagLast, DIAG_DIR
    try {
        if diagLast.path != "" && FileExist(diagLast.path)
            Run 'explorer.exe /select,"' diagLast.path '"'
        else if DirExist(DIAG_DIR)
            Run 'explorer.exe "' DIAG_DIR '"'
    }
}

DiagPushWeb() {
    global webReady, WVCore, diagLast
    if !webReady || !WVCore
        return
    try WVCore.PostWebMessageAsJson('{"type":"diag","data":{"path":"' JsonEscapeWeb(diagLast.path) '","size":' diagLast.size
        . ',"at":"' JsonEscapeWeb(diagLast.at) '","err":"' JsonEscapeWeb(diagLast.err) '","busy":' (diagLast.busy ? "true" : "false") '}}')
}
