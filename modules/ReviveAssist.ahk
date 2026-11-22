; ============================================================================
; v1.3.18.0 ReviveAssist：卡復活時自動點遊戲畫面上的復活鍵。
;
; 死亡事件（Memory HP = 0）持續超過 StuckSeconds 秒仍沒復活 → 視為卡復活：
; - 等鍵盤滑鼠閒置 IdleSeconds 秒（避免搶走正在操作的畫面），並等其他自動化（登入 / 每日道具）結束。
; - 取得前景鎖，把遊戲視窗叫到最上層，先存一張畫面到 Logs\Revive\（方便確認卡在哪）。
; - 有歸魂珠只點「使用歸魂珠」（原地復活）。沒有歸魂珠（v1.3.90.57）：點「復活」回城
;   （DailyTemplates\revive_town_button.bmp；[Revive] TownWhenNoBead=0 可關掉，改回只通知），
;   每日道具已到期就接著排入更換（城裡換、換完 W 前點卡回怪區，念珠也一起換上）。
;   每日討伐跑圖途中的死亡不回城（照舊只用歸魂珠）。
;   每日道具沒到期（v1.3.90.63）：列入「待救援」，等空檔用前點卡回到死亡的野外地圖，回去後補開 F6、叫出寵物 / 雇傭兵
;   （沿用 LagFix 的救援流程；[Revive] ReturnAfterTown=0 可關掉）。死在城裡 / 副本、自動採礦中、或 30 分鐘內已回城復活
;   3 次（怪太強，回去還是會死）→ 不送回去，只通知。
; - 每個角色各自設定（v1.3.90.63，角色設定 ReviveMode / ReviveReturn / ReviveF6，空白 = 用 [Revive] 的共用設定）：
;   ReviveMode auto = 有歸魂珠用歸魂珠、沒有就回城；bead = 只用歸魂珠（沒有就通知）；off = 不自動復活，只通知。
;   ReviveReturn = 回城復活後用前點卡回怪區；ReviveF6 = 回怪區後開啟自動攻擊。
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
global REVIVE_TOWN_NO_BEAD := Integer(IniRead(INI,"Revive","TownWhenNoBead","1"))
global REVIVE_TOWN_TEMPLATE := "revive_town_button"
global REVIVE_TOWN_RETURN := Integer(IniRead(INI,"Revive","ReturnAfterTown","1"))
global REVIVE_TOWN_LOOP_COUNT := 3, REVIVE_TOWN_LOOP_MS := 1800000

ReviveModeOf(p) {
    global REVIVE_TOWN_NO_BEAD
    m:=p.HasOwnProp("reviveMode") ? p.reviveMode : ""
    return (m="auto" || m="bead" || m="off") ? m : (REVIVE_TOWN_NO_BEAD ? "auto" : "bead")
}
ReviveModeText(p) => ReviveModeOf(p)="off" ? "不自動復活，只通知" : ReviveModeOf(p)="bead" ? "只用歸魂珠" : "有歸魂珠用歸魂珠，沒有就回城"
ReviveReturnOf(p) {
    global REVIVE_TOWN_RETURN
    v:=p.HasOwnProp("reviveReturn") ? p.reviveReturn : ""
    return v="" ? (REVIVE_TOWN_RETURN ? 1 : 0) : (v ? 1 : 0)
}
ReviveF6Of(p) => (p.HasOwnProp("reviveF6") && p.reviveF6!="" ? (p.reviveF6 ? 1 : 0) : 1)

; 由 Memory HP 監控在死亡事件進行中呼叫（每次取樣一次）。
; stuckSec / idleSec：預設用設定值（死亡超過 60 秒、鍵鼠閒置 20 秒）。每日討伐跑圖途中死亡傳 0 / 3：馬上用歸魂珠原地復活，不等 60 秒。
ReviveStuckCheck(p, stuckSec := -1, idleSec := -1) {
    global REVIVE_AUTOCLICK,REVIVE_STUCK_SEC,REVIVE_IDLE_SEC,REVIVE_RETRY_SEC,REVIVE_MAX_ATTEMPTS
    global foregroundOwner,processingQueue,fastLoginCritical,asyncLoadingEntries,abortRequested,dailyRunning,recorder
    if !REVIVE_AUTOCLICK || !p.hpEventOpen || abortRequested
        return
    allowTown:=stuckSec<0   ; 一般掛機的死亡才可以回城；每日討伐跑圖途中（傳 0 / 3）不回城
    if p.HasOwnProp("reviveEventNo") && p.reviveEventNo!=p.hpEventNo
        p.reviveAttempts:=0,p.reviveLastTick:=0
    p.reviveEventNo:=p.hpEventNo
    if !p.HasOwnProp("reviveAttempts")
        p.reviveAttempts:=0,p.reviveLastTick:=0
    if stuckSec<0
        stuckSec:=REVIVE_STUCK_SEC
    if ReviveModeOf(p)="off" {   ; 這個角色設定不自動復活：到時間記一次就好（死亡通報照舊）
        if p.reviveAttempts<REVIVE_MAX_ATTEMPTS && A_TickCount-p.hpEventTick>=stuckSec*1000 {
            p.reviveAttempts:=REVIVE_MAX_ATTEMPTS
            EventLog(p.name,"REVIVE_SKIP","死亡事件 #" p.hpEventNo "｜這個角色設定「不自動復活，只通知」，不點復活鍵")
        }
        return
    }
    if idleSec<0
        idleSec:=REVIVE_IDLE_SEC
    if A_TickCount-p.hpEventTick<stuckSec*1000 || p.reviveAttempts>=REVIVE_MAX_ATTEMPTS
        return
    if p.reviveLastTick && A_TickCount-p.reviveLastTick<REVIVE_RETRY_SEC*1000
        return
    ; 使用者正在操作 / 其他自動化正在用前景：下一輪再看。
    if A_TimeIdlePhysical<idleSec*1000 || foregroundOwner!="" || processingQueue || fastLoginCritical
        || asyncLoadingEntries.Count || dailyRunning!="" || IsObject(recorder)
        return
    p.reviveAttempts+=1
    p.reviveLastTick:=A_TickCount
    ReviveAttempt(p, allowTown)
}

ReviveAttempt(p, allowTown := false) {
    global foregroundOwner,activeRecoveryHwnd,activeRecoveryPid,REVIVE_MAX_ATTEMPTS
    ctx:={name:p.name,hwnd:p.hwnd,pid:p.pid}
    foregroundOwner:="revive"
    activeRecoveryHwnd:=p.hwnd,activeRecoveryPid:=p.pid
    secs:=Round((A_TickCount-p.hpEventTick)/1000)
    result:=""
    allowTown:=allowTown && ReviveModeOf(p)="auto"
    try {
        if !ReviveHasSoulBead(p.pid) && allowTown {
            ReviveTown(p, ctx, secs)
            DailyRestorePosition(ctx)
            activeRecoveryHwnd:=0,activeRecoveryPid:=0,foregroundOwner:=""
            return
        }
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
            if p.deathNotify {
                msg:="✅ HIHIYONG 卡復活已自動處理`n角色：" p.name "`n死亡 " secs " 秒後自動使用歸魂珠，已復活"
                    . "`n位置：" NotificationLocationText(p)
                    . (p.reviveAttempts>1 ? "`n（第 " p.reviveAttempts " 次嘗試才成功）" : "")
                try (shot!="" && REPORT_ERROR_SHOTS) ? SendDiscordImage(msg "`n（附上死亡當時畫面）",shot) : SendDiscordMessage(msg)
            }
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

; 沒有歸魂珠：點「復活」回城；復活後每日道具已到期就排入更換（換上念珠，換完 W 前點卡回怪區）
ReviveTown(p, ctx, secs) {
    global REVIVE_MAX_ATTEMPTS,REPORT_ERROR_SHOTS,profiles
    mapB:=""
    try mapB:=LfFieldMap(p.pid)   ; 死亡當下的野外地圖：回城復活後用前點卡回這裡
    DailyEnsureOnScreen(ctx)
    EnsureRecoveryFocus(p.hwnd,p.name)
    Sleep 300
    shot:=ReviveSaveShot(ctx)
    how:=ReviveClickTown(ctx)
    if how="" || !ReviveWaitAlive(p.pid) {
        result:=how="" ? "找不到「復活」按鈕（缺少 DailyTemplates\revive_town_button.bmp 或畫面上沒有），未點擊" : "已點「復活」（" how "），但 HP 仍為 0"
        EventLog(p.name,"REVIVE_CLICK_FAIL","第 " p.reviveAttempts "/" REVIVE_MAX_ATTEMPTS " 次｜沒有歸魂珠，回城復活：" result (shot!="" ? "｜畫面：" shot : ""))
        AddRecentEvent("⚠ " p.name " 沒有歸魂珠，回城復活失敗（第 " p.reviveAttempts " 次）：" result)
        if p.reviveAttempts>=REVIVE_MAX_ATTEMPTS && p.deathNotify {
            msg:="⚠️ HIHIYONG 卡復活（沒有歸魂珠），回城復活 " REVIVE_MAX_ATTEMPTS " 次仍未成功`n角色：" p.name "`n原因：" result "`n請人工處理。"
            try (shot!="" && REPORT_ERROR_SHOTS) ? SendDiscordImage(msg,shot) : SendDiscordMessage(msg)
        }
        return false
    }
    idx:=0
    for i,q in profiles
        if q=p
            idx:=i
    queued:=idx && ReviveDailyDue(p)
    back:=queued ? {ok:false,text:""} : ReviveTownReturn(p, mapB)
    EventLog(p.name,"REVIVE_TOWN_OK","死亡 " secs " 秒後沒有歸魂珠，已點「復活」回城｜" how (queued ? "｜每日道具已到期，排入更換" : "｜每日道具沒有到期，不更換｜" back.text))
    AddRecentEvent("♥ " p.name " 沒有歸魂珠，已回城復活" (queued ? "，接著更換每日道具" : back.ok ? "，接著用前點卡回怪區" : ""))
    if p.deathNotify {
        msg:="✅ HIHIYONG 卡復活已自動處理`n角色：" p.name "`n死亡 " secs " 秒後背包沒有歸魂珠，已點「復活」回城"
            . (queued ? "`n每日道具已到期：接著自動更換（含念珠），換完用前點卡回怪區"
            : back.ok ? "`n每日道具沒有到期：" back.text "，回去後補開自動攻擊（F6）"
            : "`n每日道具沒有到期，角色留在城裡（" back.text "），請人工帶回怪區")
        try (shot!="" && REPORT_ERROR_SHOTS) ? SendDiscordImage(msg "`n（附上死亡當時畫面）",shot) : SendDiscordMessage(msg)
    }
    if queued
        DailyRunEnqueue([idx],"沒有歸魂珠，回城復活後更換")
    return true
}

; 每日道具沒到期：要不要用前點卡送回死亡的野外地圖。回傳 {ok, text}。
ReviveTownReturn(p, mapB) {
    global REVIVE_TOWN_RETURN,REVIVE_TOWN_LOOP_COUNT,REVIVE_TOWN_LOOP_MS
    if !p.HasOwnProp("reviveTownTimes")
        p.reviveTownTimes:=[]
    times:=p.reviveTownTimes
    times.Push(A_TickCount)
    while times.Length && A_TickCount-times[1]>REVIVE_TOWN_LOOP_MS
        times.RemoveAt(1)
    if !ReviveReturnOf(p)
        return {ok:false,text:"這個角色設定回城復活後不回怪區"}
    if p.HasOwnProp("mnActive") && p.mnActive
        return {ok:false,text:"自動採礦中，交給自動採礦處理"}
    if mapB=""
        return {ok:false,text:"死亡地點不是野外地圖（或讀不到），不用前點卡"}
    if times.Length>=REVIVE_TOWN_LOOP_COUNT
        return {ok:false,text:Round(REVIVE_TOWN_LOOP_MS/60000) " 分鐘內已回城復活 " times.Length " 次，回去可能還會死，先不送回去"}
    if !LagFixReviveReturn(p, mapB, ReviveF6Of(p))
        return {ok:false,text:"已經有一筆待救援在處理"}
    return {ok:true,text:"等空檔用前點卡回 " mapB}
}

; 角色設定畫面的說明：目前從遊戲讀到的前點卡按鍵 / 有沒有歸魂珠（30 秒讀一次）
ReviveQuickHint(p) {
    if p.HasOwnProp("reviveHintAt") && A_TickCount-p.reviveHintAt<30000
        return p.reviveHint
    t:=""
    try {
        if !p.pid || !GameOffsetsReady(p.pid) || !GameInWorld(p.pid)
            t:="遊戲沒開或還沒進遊戲，讀不到快捷欄"
        else {
            info:=DailyQuickInfo(p.pid,"前點傳送卡")
            card:=info="" ? "讀不到道具快捷欄" : IsObject(info) && info.key!="" ? "前點卡目前在 " StrUpper(info.key) : "道具快捷欄沒有前點卡（回城後沒辦法自動回去）"
            t:=card "｜" ReviveBeadText(p.pid)
        }
    } catch
        t:="讀不到快捷欄"
    p.reviveHint:=t, p.reviveHintAt:=A_TickCount
    return t
}
ReviveBeadText(pid) {
    slots:=ReadGameInventorySlots(pid,"InvenOffset")
    equip:=ReadGameEquipment(pid)
    if !IsObject(slots) || !IsObject(equip)
        return "讀不到有沒有歸魂珠"
    for s in slots
        if InStr(GameItemName(s.key,pid),"歸魂")
            return "背包有歸魂珠（會原地復活）"
    for e in equip
        if e && InStr(GameItemName(e.key,pid),"歸魂")
            return "身上有歸魂道具（會原地復活）"
    return "沒有歸魂珠（死亡會回城復活）"
}

; 每日道具要不要換：這個角色有設定要換、已到期（或身上沒有）、今天還沒換過
ReviveDailyDue(p) {
    if DailyItemsOf(p)="" || DailyRecentlyDone(p)
        return false
    expiry:=p.HasOwnProp("dailyExpiry") ? p.dailyExpiry : 0
    return !expiry || expiry<=UnixNow()
}

; 點「復活」（回城）；回傳點擊方式，沒點回傳 ""。
ReviveClickTown(ctx) {
    global DAILY_TPL_DIR,REVIVE_TOWN_TEMPLATE
    x:=0,y:=0
    path:=DAILY_TPL_DIR "\" REVIVE_TOWN_TEMPLATE ".bmp"
    if FileExist(path) && DailyFindTemplate(ctx,REVIVE_TOWN_TEMPLATE,&x,&y) {
        w:=0,h:=0
        ReviveImageSize(path,&w,&h)
        DailyClickClient(ctx,x+w//2,y+h//2,"Left",false)
        return "辨識圖 (" x+w//2 "," y+h//2 ")"
    }
    return ""
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
