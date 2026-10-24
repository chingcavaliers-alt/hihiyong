; ============================================================================
; v1.3.18.0 ReviveAssist：卡復活時自動點遊戲畫面上的復活鍵。
;
; 死亡事件（Memory HP = 0）持續超過 StuckSeconds 秒仍沒復活 → 視為卡復活：
; - 等鍵盤滑鼠閒置 IdleSeconds 秒（避免搶走正在操作的畫面），並等其他自動化（登入 / 每日道具）結束。
; - 取得前景鎖，把遊戲視窗叫到最上層，先存一張畫面到 Logs\Revive\（方便確認卡在哪）。
; - 只點「使用歸魂珠」（原地復活），不點「復活」（回城）；背包沒有歸魂珠就只通知、不點。
; - 用 DailyTemplates\revive_button.bmp（「使用歸魂珠」按鈕）找位置並點擊中心；沒有辨識圖時，若 INI 有設定
;   [Revive] ClickX / ClickY（遊戲畫面座標）就點那裡；兩者都沒有則只截圖、通知，不亂點。
; - 點擊後以記憶體 HP > 0 確認復活；沒成功每 RetrySeconds 秒再試，最多 MaxAttempts 次。
; ============================================================================

global REVIVE_AUTOCLICK := Integer(IniRead(INI,"Revive","AutoClick","1"))
global REVIVE_STUCK_SEC := Integer(IniRead(INI,"Revive","StuckSeconds","60"))
global REVIVE_IDLE_SEC := Integer(IniRead(INI,"Revive","IdleSeconds","20"))
global REVIVE_RETRY_SEC := Integer(IniRead(INI,"Revive","RetrySeconds","20"))
global REVIVE_MAX_ATTEMPTS := Integer(IniRead(INI,"Revive","MaxAttempts","3"))
global REVIVE_CLICK_X := Integer(IniRead(INI,"Revive","ClickX","0"))
global REVIVE_CLICK_Y := Integer(IniRead(INI,"Revive","ClickY","0"))
global REVIVE_TEMPLATE := "revive_button"
global REVIVE_CONFIRM_MS := 8000

; 由 Memory HP 監控在死亡事件進行中呼叫（每次取樣一次）。
ReviveStuckCheck(p) {
    global REVIVE_AUTOCLICK,REVIVE_STUCK_SEC,REVIVE_IDLE_SEC,REVIVE_RETRY_SEC,REVIVE_MAX_ATTEMPTS
    global foregroundOwner,processingQueue,fastLoginCritical,asyncLoadingEntries,abortRequested,dailyRunning,recorder
    if !REVIVE_AUTOCLICK || !p.hpEventOpen || abortRequested
        return
    if p.HasOwnProp("reviveEventNo") && p.reviveEventNo!=p.hpEventNo
        p.reviveAttempts:=0,p.reviveLastTick:=0
    p.reviveEventNo:=p.hpEventNo
    if !p.HasOwnProp("reviveAttempts")
        p.reviveAttempts:=0,p.reviveLastTick:=0
    if A_TickCount-p.hpEventTick<REVIVE_STUCK_SEC*1000 || p.reviveAttempts>=REVIVE_MAX_ATTEMPTS
        return
    if p.reviveLastTick && A_TickCount-p.reviveLastTick<REVIVE_RETRY_SEC*1000
        return
    ; 使用者正在操作 / 其他自動化正在用前景：下一輪再看。
    if A_TimeIdlePhysical<REVIVE_IDLE_SEC*1000 || foregroundOwner!="" || processingQueue || fastLoginCritical
        || asyncLoadingEntries.Count || dailyRunning!="" || IsObject(recorder)
        return
    p.reviveAttempts+=1
    p.reviveLastTick:=A_TickCount
    ReviveAttempt(p)
}

ReviveAttempt(p) {
    global foregroundOwner,activeRecoveryHwnd,activeRecoveryPid,REVIVE_MAX_ATTEMPTS
    ctx:={name:p.name,hwnd:p.hwnd,pid:p.pid}
    foregroundOwner:="revive"
    activeRecoveryHwnd:=p.hwnd,activeRecoveryPid:=p.pid
    secs:=Round((A_TickCount-p.hpEventTick)/1000)
    result:=""
    try {
        if !ReviveHasSoulBead(p.pid) {
            result:="背包裡沒有歸魂珠，未點擊（不使用回城復活）"
            p.reviveAttempts:=REVIVE_MAX_ATTEMPTS
            EventLog(p.name,"REVIVE_CLICK_FAIL",result)
            AddRecentEvent("⚠ " p.name " 卡復活，但" result)
            if p.deathNotify
                try SendDiscordMessage("⚠️ HIHIYONG 卡復活`n角色：" p.name "`n" result "，請人工處理。")
            activeRecoveryHwnd:=0,activeRecoveryPid:=0,foregroundOwner:=""
            return
        }
        DailyEnsureOnScreen(ctx)
        EnsureRecoveryFocus(p.hwnd,p.name)
        Sleep 300
        shot:=ReviveSaveShot(ctx)
        how:=ReviveClick(ctx)
        if how="" {
            result:="找不到「使用歸魂珠」按鈕（缺少 DailyTemplates\revive_button.bmp 或畫面上沒有），未點擊"
        } else if ReviveWaitAlive(p.pid) {
            result:="OK"
            EventLog(p.name,"REVIVE_CLICK_OK","死亡 " secs " 秒後自動點復活鍵成功｜" how)
            AddRecentEvent("♥ " p.name " 卡復活，已自動點復活鍵（" how "）")
        } else {
            result:="已點復活鍵（" how "），但 HP 仍為 0"
        }
        if result!="OK" {
            EventLog(p.name,"REVIVE_CLICK_FAIL","第 " p.reviveAttempts "/" REVIVE_MAX_ATTEMPTS " 次｜" result (shot!="" ? "｜畫面：" shot : ""))
            AddRecentEvent("⚠ " p.name " 自動復活失敗（第 " p.reviveAttempts " 次）：" result)
            if p.reviveAttempts>=REVIVE_MAX_ATTEMPTS && p.deathNotify {
                msg:="⚠️ HIHIYONG 卡復活，自動點復活鍵 " REVIVE_MAX_ATTEMPTS " 次仍未成功`n角色：" p.name "`n原因：" result "`n請人工處理。"
                try (shot!="" && REPORT_ERROR_SHOTS) ? SendDiscordImage(msg,shot) : SendDiscordMessage(msg)
            }
        }
    } catch as e {
        EventLog(p.name,"REVIVE_CLICK_FAIL",e.Message)
    }
    DailyRestorePosition(ctx)
    activeRecoveryHwnd:=0,activeRecoveryPid:=0
    foregroundOwner:=""
}

; 有沒有歸魂珠效果：背包裡的歸魂珠，或身上的「歸魂」道具（例如項鍊欄的 4倍歸魂修煉念珠，
; 2026-10-22 椰奶示範：背包沒有歸魂珠，靠念珠也能使用歸魂珠）。讀不到資料時當作有（交給畫面辨識決定）。
ReviveHasSoulBead(pid) {
    slots:=ReadGameInventorySlots(pid,"InvenOffset")
    equip:=ReadGameEquipment(pid)
    if !IsObject(slots) || !IsObject(equip)
        return true
    for s in slots
        if InStr(GameItemName(s.key,pid),"歸魂")
            return true
    for e in equip
        if e && InStr(GameItemName(e.key,pid),"歸魂")
            return true
    return false
}

; 點「使用歸魂珠」；回傳點擊方式，沒點回傳 ""。
ReviveClick(ctx) {
    global DAILY_TPL_DIR,REVIVE_TEMPLATE,REVIVE_CLICK_X,REVIVE_CLICK_Y
    x:=0,y:=0
    path:=DAILY_TPL_DIR "\" REVIVE_TEMPLATE ".bmp"
    if FileExist(path) && DailyFindTemplate(ctx,REVIVE_TEMPLATE,&x,&y) {
        w:=0,h:=0
        ReviveImageSize(path,&w,&h)
        DailyClickClient(ctx,x+w//2,y+h//2,"Left",false)
        return "辨識圖 (" x+w//2 "," y+h//2 ")"
    }
    if REVIVE_CLICK_X && REVIVE_CLICK_Y {
        DailyClickClient(ctx,REVIVE_CLICK_X,REVIVE_CLICK_Y,"Left",false)
        return "INI 座標 (" REVIVE_CLICK_X "," REVIVE_CLICK_Y ")"
    }
    return ""
}

ReviveWaitAlive(pid) {
    global REVIVE_CONFIRM_MS
    start:=A_TickCount
    while A_TickCount-start<REVIVE_CONFIRM_MS {
        hpNow:=0,hpMax:=0
        if ReadGameHP(pid,&hpNow,&hpMax) && hpNow>0
            return true
        Sleep 250
    }
    return false
}

; BMP 檔頭的寬高（BITMAPINFOHEADER：+18 寬、+22 高，高度可能為負值）。
ReviveImageSize(path, &w, &h) {
    w:=0,h:=0
    try {
        f:=FileOpen(path,"r")
        f.Pos:=18
        w:=f.ReadInt(),h:=Abs(f.ReadInt())
        f.Close()
    }
}

ReviveSaveShot(ctx) {
    try {
        dir:=A_ScriptDir "\Logs\Revive"
        if !DirExist(dir)
            DirCreate dir
        WinGetClientPos(&cx,&cy,&cw,&ch,"ahk_id " ctx.hwnd)
        path:=dir "\Stuck_" FormatTime(,"yyyyMMdd_HHmmss") "_" ctx.name ".png"
        CaptureScreenPng(cx,cy,cw,ch,path)
        return path
    }
    return ""
}
