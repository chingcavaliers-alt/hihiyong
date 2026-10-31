; ============================================================================
; H-015 怪物掉落率：遊戲改版後自動重算，介面「收益統計 → 🎯 掉落率」。
; 計算交給 tools\droprates\droprates.py（只讀遊戲檔，不修改）；結果存 Stats\DropRates：
;   index.json（版本清單、最新版、遊戲檔指紋）、<yyyyMMdd-HHmm>.json（每一版的掉落表＋和上一版的差異）。
; 這裡只負責：排程檢查（啟動 1 分鐘後、之後每小時）、背景執行、讀結果、通知、送到網頁。
; 遊戲沒改版時工具只比對指紋就結束（不到 1 秒）。
; ============================================================================

global DROP_DIR := A_ScriptDir "\Stats\DropRates"
global DROP_TOOL := A_ScriptDir "\tools\droprates\droprates.py"
global DROP_CHECK_MS := 3600000
global dropRunPid := 0, dropRunStart := 0, dropLatestBefore := "", dropStatus := ""
global DROP_RUN_TIMEOUT_MS := 300000

; 發佈包內建的 Python；開發資料夾沒有時用系統的 py 啟動器。
DropRatesPython() {
    p := A_ScriptDir "\runtime\python\python.exe"
    return FileExist(p) ? p : "py"
}

; 遊戲資料夾 = 「遊戲啟動程式」所在的資料夾（裡面要有 game.exe）。
DropRatesGameDir(launcher) {
    SplitPath Trim(launcher), , &dir
    if dir != "" && SubStr(dir, -1) = ":"   ; 遊戲在磁碟根目錄（F:）→ D:\
        dir .= "\"
    return dir != "" && FileExist(RTrim(dir, "\") "\game.exe") ? dir : ""
}

; 版本代碼：yyyyMMdd-HHmm，同一分鐘有第二次不同的更新時加 -2、-3…
DropRatesValidId(id) => RegExMatch(id, "^\d{8}-\d{4}(-\d+)?$")
DropRatesLatest(indexText) => RegExMatch(indexText, '"latest":"(\d{8}-\d{4}(?:-\d+)?)"', &m) ? m[1] : ""
; index.json 裡某一版的名稱與數量；找不到回傳 0。
DropRatesVersionInfo(indexText, id) {
    if !RegExMatch(indexText, '\{"id":"' id '","label":"([^"]*)","maps":(\d+),"changes":(\d+)[,}]', &m)
        return 0
    return {label: m[1], maps: m[2] + 0, changes: m[3] + 0}
}

DropRatesReadIndex() {
    try return FileRead(DROP_DIR "\index.json", "UTF-8")
    return ""
}

DropRatesCheckTick() => DropRatesCheck(false)

DropRatesCheck(force := false) {
    global dropRunPid, dropRunStart, dropLatestBefore, dropStatus, LauncherEdit
    if dropRunPid && ProcessExist(dropRunPid)
        return
    game := ""
    try game := DropRatesGameDir(LauncherEdit.Value)
    if game = "" {
        dropStatus := "找不到遊戲資料夾：請到「設定 → 啟動與登入」確認遊戲啟動程式的路徑"
        return
    }
    if !FileExist(DROP_TOOL) {
        dropStatus := "缺少 tools\droprates\droprates.py"
        return
    }
    try DirCreate DROP_DIR
    dropLatestBefore := DropRatesLatest(DropRatesReadIndex())
    ; 結尾的 \ 會把引號吃掉：根目錄寫成 "D:\."
    gameArg := SubStr(game, -1) = "\" ? game "." : game
    cmd := '"' DropRatesPython() '" -I -X utf8 "' DROP_TOOL '" --game "' gameArg '" --out "' DROP_DIR '"' (force ? " --force" : "")
    try {
        Run cmd, , "Hide", &pid
        dropRunPid := pid, dropRunStart := A_TickCount
        try ProcessSetPriority "BelowNormal", pid
        dropStatus := "檢查遊戲改版中…"
        SetTimer DropRatesPoll, 1000
    } catch as e {
        dropStatus := "無法執行掉落率工具：" e.Message
    }
    DropRatesPushIndex()
}

DropRatesPoll() {
    global dropRunPid, dropRunStart, dropLatestBefore, dropStatus
    if dropRunPid && ProcessExist(dropRunPid) {
        if A_TickCount - dropRunStart < DROP_RUN_TIMEOUT_MS
            return
        ; 卡住（例如遊戲檔被鎖住）：結束它，下次排程再試
        try ProcessClose dropRunPid
        SetTimer DropRatesPoll, 0
        dropRunPid := 0
        dropStatus := "掉落率工具超過 5 分鐘沒有完成，已停止；下次檢查會再試"
        EventLog("GLOBAL", "DROPRATES_FAIL", dropStatus)
        return DropRatesPushIndex()
    }
    SetTimer DropRatesPoll, 0
    dropRunPid := 0
    idx := DropRatesReadIndex()
    latest := DropRatesLatest(idx)
    err := ""
    if FileExist(DROP_DIR "\last_error.txt")
        try err := Trim(StrSplit(FileRead(DROP_DIR "\last_error.txt", "UTF-8"), "`n")[1])
    if err != "" {
        if !InStr(dropStatus, err) {
            EventLog("GLOBAL", "DROPRATES_FAIL", err)
            AddRecentEvent("⚠ 掉落率：新版遊戲資料解析失敗（" err "），目前顯示上一版")
        }
        dropStatus := "新版遊戲資料解析失敗：" err "（目前顯示上一版）"
    } else {
        dropStatus := ""
    }
    if latest != "" && latest != dropLatestBefore && (info := DropRatesVersionInfo(idx, latest)) {
        txt := "🎯 掉落率已更新為 " info.label "（" info.maps " 張地圖，和上一版相比 " info.changes " 項變動）"
        EventLog("GLOBAL", "DROPRATES_UPDATED", txt)
        AddRecentEvent(txt)
        ; 第一次建立（以前沒有任何版本）不發 Discord
        if dropLatestBefore != ""
            try SendDiscordMessage("HIHIYONG " txt)
    }
    DropRatesPushIndex()
}

; ---- 網頁 ----
DropRatesPushIndex() {
    global webReady, WVCore, dropRunPid, dropStatus
    if !webReady || !WVCore
        return
    idx := DropRatesReadIndex()
    running := dropRunPid && ProcessExist(dropRunPid)
    try WVCore.PostWebMessageAsJson('{"type":"dropindex","data":{"index":' (idx != "" ? idx : "null")
        . ',"status":"' JsonEscapeWeb(dropStatus) '","running":' (running ? "true" : "false") '}}')
}

DropRatesPushVersion(id) {
    global webReady, WVCore
    if !webReady || !WVCore || !DropRatesValidId(id)
        return
    doc := ""
    try doc := FileRead(DROP_DIR "\" id ".json", "UTF-8")
    try WVCore.PostWebMessageAsJson('{"type":"dropver","data":' (doc != "" ? doc : "null") '}')
}
