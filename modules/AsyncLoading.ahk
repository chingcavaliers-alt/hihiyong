; ============================================================================
; v1.3.14.0 AsyncLoading：按下「開始遊戲」後，改由背景依遊戲記憶體判斷角色是否載入完成。
;
; 舊流程在開始遊戲後用畫面等 HUD 最多 90 秒，超過就判定失敗、需要人工處理；
; 多視窗同時運作或網路慢時，Loading 常超過 90 秒（但最後仍會進入遊戲），
; 而且佇列要等這個帳號結束才會處理下一個。
;
; 新流程（需要 Game.pdb 位置，否則自動沿用舊流程）：
; 1. 開始遊戲後登記到 asyncLoadingEntries，每 0.5 秒讀記憶體：最大 HP > 0 = 角色已載入。
; 2. 載入很快（ASYNC_LOADING_GRACE_SEC 內）時佇列先等它，行為與舊流程相同；
;    超過這個時間仍未載入，佇列才先處理下一個帳號。
; 3. 載入完成且沒有其他帳號在前景操作時，切回視窗執行 RecoverProfileEnterGame
;    （HUD 確認、登入後按鍵、位置辨識、恢復視窗位置），完成後回到監控。
; 4. 超過 ASYNC_LOADING_WARN_SEC 只發提醒、繼續等待；超過 ASYNC_LOADING_MAX_SEC
;    才標示需要人工確認（保留 game.exe）。載入期間視窗消失則自動重啟。
;
; v1.3.21.0 重新登入完成度（2026-10-23 03:39 假在線重啟 7 個角色只有 2 個完全恢復）：
; - 「已載入」改成 GameInWorld（有角色資料而且有地圖）；選角畫面就有角色資料，不能只看 HP。
; - 有角色資料但沒有地圖 = 停在選角畫面（開始遊戲沒按到）：每 ASYNC_STARTGAME_RETRY_SEC 秒補按一次，
;   最多 ASYNC_STARTGAME_RETRY_MAX 次；還是進不去就關掉這個 game.exe 完整重新登入（還沒進遊戲，關掉沒有損失）。
; - 進入遊戲後的步驟失敗（視窗被擋住等）：角色仍在遊戲裡就 ASYNC_ENTER_RETRY_SEC 秒後重做，
;   最多 ASYNC_ENTER_RETRY_MAX 次；都失敗仍綁回監控，交給 RecoveryGuard 補做前點卡 / F6。
;
; foregroundOwner 是前景操作的鎖：登入（ProcessNextRecovery）與進入遊戲後操作
; 不會同時進行，避免按鍵送到錯誤的視窗。
; ============================================================================

global ASYNC_LOADING_ENABLED := Integer(IniRead(INI,"Recovery","AsyncLoading","1"))
global ASYNC_LOADING_GRACE_SEC := Integer(IniRead(INI,"Recovery","AsyncLoadingGraceSeconds","60"))
global ASYNC_LOADING_WARN_SEC := Integer(IniRead(INI,"Recovery","AsyncLoadingWarnSeconds","600"))
global ASYNC_LOADING_MAX_SEC := Integer(IniRead(INI,"Recovery","AsyncLoadingMaxSeconds","1800"))
global ASYNC_LOADING_STABLE_MS := 2000      ; 角色資料要穩定存在這麼久才進行後續操作
global ASYNC_LOADING_HUD_TIMEOUT_SEC := 60  ; 記憶體已確認載入後，畫面 HUD 確認的上限
global ASYNC_LOADING_TICK_MS := 500
global ASYNC_STARTGAME_RETRY_SEC := 20
global ASYNC_STARTGAME_RETRY_MAX := 3
global ASYNC_ENTER_RETRY_SEC := 60
global ASYNC_ENTER_RETRY_MAX := 2
; v1.3.22.0 同時載入上限：很多視窗一起載入時電腦 / 網路變慢，反而每個都卡住。
; 只算開始載入不到 ASYNC_CONCURRENT_STUCK_SEC 秒的視窗；載入更久的多半已經卡住，不再擋其他帳號。
global ASYNC_LOADING_MAX_CONCURRENT := Integer(IniRead(INI,"Recovery","MaxConcurrentLoading","2"))
global ASYNC_CONCURRENT_STUCK_SEC := 180
global asyncConcurrentWaitLogged := false
global foregroundOwner := ""
global asyncLoadingEntries := Map()        ; idx → {hwnd,pid,oldPid,start,loadedSince,lastLog,warned}

AsyncLoadingAvailable(hwnd) {
    global ASYNC_LOADING_ENABLED
    if !ASYNC_LOADING_ENABLED
        return false
    pid:=0
    try pid:=WinGetPID("ahk_id " hwnd)
    return pid && GameOffsetsReady(pid)
}

AsyncLoadingRegister(idx, hwnd, oldBoundPid) {
    global profiles,asyncLoadingEntries,activeRecoveryHwnd,activeRecoveryPid,activeRecoveryCommitted,ASYNC_LOADING_GRACE_SEC,ASYNC_LOADING_TICK_MS
    p:=profiles[idx]
    pid:=WinGetPID("ahk_id " hwnd)
    asyncLoadingEntries[idx]:={hwnd:hwnd,pid:pid,oldPid:oldBoundPid,start:A_TickCount,loadedSince:0,lastLog:A_TickCount,warned:false
        ,startClicks:0,lastStartClick:A_TickCount,enterTries:0,retryAt:0}
    ; 載入完成前不綁定到 Profile：視窗切換 / 背包清理 / 監控都不會碰這個視窗。
    p.state:="載入中"
    activeRecoveryHwnd:=0,activeRecoveryPid:=0,activeRecoveryCommitted:=false
    EventLog(p.name,"LOADING_ASYNC","Start Game 已送出｜背景依記憶體等待角色載入（PID " pid "）｜"
        . ASYNC_LOADING_GRACE_SEC " 秒內未載入就先處理下一個帳號")
    SetTimer AsyncLoadingTick,ASYNC_LOADING_TICK_MS
}

; 佇列是否要先等：有帳號已載入完成（優先做它的後續操作），或剛開始載入還在寬限時間內。
AsyncLoadingBlocksQueue() {
    global asyncLoadingEntries,ASYNC_LOADING_GRACE_SEC,ASYNC_LOADING_MAX_CONCURRENT,ASYNC_CONCURRENT_STUCK_SEC,asyncConcurrentWaitLogged
    active:=0
    for idx,entry in asyncLoadingEntries {
        if entry.loadedSince
            return true
        if A_TickCount-entry.start<ASYNC_LOADING_GRACE_SEC*1000
            return true
        if A_TickCount-entry.start<ASYNC_CONCURRENT_STUCK_SEC*1000
            active+=1
    }
    if ASYNC_LOADING_MAX_CONCURRENT>0 && active>=ASYNC_LOADING_MAX_CONCURRENT {
        if !asyncConcurrentWaitLogged
            EventLog("GLOBAL","QUEUE_WAIT_CONCURRENT","已有 " active " 個視窗在載入（上限 " ASYNC_LOADING_MAX_CONCURRENT "），等其中一個進入遊戲再登入下一個")
        asyncConcurrentWaitLogged:=true
        return true
    }
    asyncConcurrentWaitLogged:=false
    return false
}

AsyncLoadingTick() {
    global asyncLoadingEntries,profiles,abortRequested,foregroundOwner,fastLoginCritical
    global ASYNC_LOADING_WARN_SEC,ASYNC_LOADING_MAX_SEC,ASYNC_LOADING_STABLE_MS,ASYNC_LOADING_GRACE_SEC
    if !asyncLoadingEntries.Count {
        SetTimer AsyncLoadingTick,0
        return
    }
    if abortRequested {
        for idx,entry in asyncLoadingEntries {
            profiles[idx].state:="人工操作"
            EventLog(profiles[idx].name,"LOADING_ASYNC_ABORTED","F10 / 停止監控｜保留載入中的 game.exe 供人工操作")
        }
        asyncLoadingEntries:=Map()
        RefreshProfileLV()
        return
    }

    ready:=0
    for idx,entry in asyncLoadingEntries.Clone() {
        p:=profiles[idx]
        elapsedSec:=Floor((A_TickCount-entry.start)/1000)
        if !WinExist("ahk_id " entry.hwnd) || !ProcessExist(entry.pid) {
            asyncLoadingEntries.Delete(idx)
            AsyncLoadingFailed(idx,"LOADING_WINDOW_LOST｜載入期間遊戲視窗已消失（" elapsedSec " 秒）",false)
            continue
        }
        if GameInWorld(entry.pid) {
            if !entry.loadedSince {
                entry.loadedSince:=A_TickCount
                EventLog(p.name,"LOADING_ASYNC_LOADED","角色已進入地圖｜載入花費 " elapsedSec " 秒")
            }
            if !ready && A_TickCount-entry.loadedSince>=ASYNC_LOADING_STABLE_MS && A_TickCount>=entry.retryAt
                ready:=idx
            continue
        }
        entry.loadedSince:=0
        if GameCharacterLoaded(entry.pid) && AsyncLoadingCharSelect(idx,entry)
            continue
        if elapsedSec>=ASYNC_LOADING_MAX_SEC {
            asyncLoadingEntries.Delete(idx)
            AsyncLoadingFailed(idx,"LOADING_TIMEOUT｜等待 " elapsedSec " 秒仍未載入角色；已保留 game.exe",true)
            continue
        }
        if !entry.warned && elapsedSec>=ASYNC_LOADING_WARN_SEC {
            entry.warned:=true
            msg:="遊戲載入已超過 " Floor(elapsedSec/60) " 分鐘，仍持續等待（上限 " Floor(ASYNC_LOADING_MAX_SEC/60) " 分鐘）"
            EventLog(p.name,"LOADING_ASYNC_SLOW",msg)
            AddRecentEvent("⚠ " p.name " " msg)
            RecoveryWebhook(p,"遊戲載入過久",msg)
        }
        if A_TickCount-entry.lastLog>=15000 {
            entry.lastLog:=A_TickCount
            EventLog(p.name,"LOADING_ASYNC_WAIT","角色尚未載入｜已等待 " elapsedSec " 秒"
                . (elapsedSec>=ASYNC_LOADING_GRACE_SEC ? "｜佇列已先處理其他帳號" : ""))
        }
    }
    if !ready || foregroundOwner!="" || fastLoginCritical
        return
    entry:=asyncLoadingEntries[ready]
    asyncLoadingEntries.Delete(ready)
    AsyncLoadingEnterGame(ready,entry)
}

; 角色已載入：取得前景鎖，執行開始遊戲之後的原流程，再回到監控。
AsyncLoadingEnterGame(idx, entry) {
    global profiles,foregroundOwner,activeRecoveryHwnd,activeRecoveryPid,activeRecoveryCommitted,ASYNC_LOADING_HUD_TIMEOUT_SEC
    p:=profiles[idx]
    foregroundOwner:="enter"
    ; activeRecoveryHwnd 讓視窗切換 / 背包清理 / 視窗配置暫停；Committed 確保失敗時不關閉 game.exe。
    activeRecoveryHwnd:=entry.hwnd,activeRecoveryPid:=entry.pid,activeRecoveryCommitted:=true
    p.state:="恢復中"
    RefreshProfileLV()
    EventLog(p.name,"LOADING_ASYNC_ENTER","角色已進入遊戲（共 " Floor((A_TickCount-entry.start)/1000) " 秒）｜切回視窗執行登入後按鍵與位置辨識")
    try {
        hwnd:=RecoverProfileEnterGame(idx,entry.hwnd,ASYNC_LOADING_HUD_TIMEOUT_SEC)
        FinalizeRecovery(idx,hwnd,entry.oldPid)
    } catch as e {
        if !AsyncLoadingRetryEnter(idx,entry,e)
            HandleRecoveryException(idx,e)
    }
    activeRecoveryHwnd:=0,activeRecoveryPid:=0,activeRecoveryCommitted:=false
    foregroundOwner:=""
    RefreshProfileLV()
    ScheduleNextRecovery(1000)
}

; 有角色資料但沒有地圖：停在選角畫面。補按開始遊戲；次數用完就關掉重新登入。
; 回傳 true 表示這一輪已處理（補按或已移出等待清單）。
AsyncLoadingCharSelect(idx, entry) {
    global profiles,asyncLoadingEntries,foregroundOwner,fastLoginCritical,activeRecoveryHwnd,activeRecoveryPid
    global ASYNC_STARTGAME_RETRY_SEC,ASYNC_STARTGAME_RETRY_MAX
    if A_TickCount-entry.lastStartClick<ASYNC_STARTGAME_RETRY_SEC*1000
        return false
    p:=profiles[idx]
    if entry.startClicks>=ASYNC_STARTGAME_RETRY_MAX {
        asyncLoadingEntries.Delete(idx)
        EventLog(p.name,"LOADING_CHARSELECT_STUCK","補按開始遊戲 " entry.startClicks " 次仍停在選角畫面｜關閉這個 game.exe 重新登入")
        try ProcessClose entry.pid
        AsyncLoadingFailed(idx,"LOADING_CHARSELECT｜停在選角畫面，已關閉重新登入",false)
        return true
    }
    if foregroundOwner!="" || fastLoginCritical
        return false
    entry.startClicks+=1
    entry.lastStartClick:=A_TickCount
    foregroundOwner:="startgame"
    activeRecoveryHwnd:=entry.hwnd,activeRecoveryPid:=entry.pid
    EventLog(p.name,"LOADING_CHARSELECT","有角色資料但還沒有地圖（停在選角畫面）｜補按開始遊戲 第 " entry.startClicks "/" ASYNC_STARTGAME_RETRY_MAX " 次")
    try {
        ClickPoint(entry.hwnd,"startgame")
    } catch as e {
        EventLog(p.name,"LOADING_CHARSELECT_FAIL",e.Message)
    }
    activeRecoveryHwnd:=0,activeRecoveryPid:=0
    foregroundOwner:=""
    return true
}

; 進入遊戲後的步驟失敗，但角色仍在遊戲裡：放回等待清單，稍後重做（不需要人工）。
; 重試次數用完時，角色仍在遊戲裡就照樣綁回監控，交給 RecoveryGuard 補做。
AsyncLoadingRetryEnter(idx, entry, e) {
    global profiles,asyncLoadingEntries,abortRequested,ASYNC_ENTER_RETRY_SEC,ASYNC_ENTER_RETRY_MAX,ASYNC_LOADING_TICK_MS
    if abortRequested || InStr(e.Message,"使用者停止") || InStr(e.Message,"F10")
        return false
    if !WinExist("ahk_id " entry.hwnd) || !ProcessExist(entry.pid) || !GameInWorld(entry.pid)
        return false
    p:=profiles[idx]
    if entry.enterTries<ASYNC_ENTER_RETRY_MAX {
        entry.enterTries+=1
        entry.retryAt:=A_TickCount+ASYNC_ENTER_RETRY_SEC*1000
        entry.loadedSince:=0
        asyncLoadingEntries[idx]:=entry
        p.state:="載入中"
        EventLog(p.name,"ENTER_RETRY","進入遊戲後的步驟失敗：" e.Message "｜角色仍在遊戲中，" ASYNC_ENTER_RETRY_SEC " 秒後重做（第 " entry.enterTries "/" ASYNC_ENTER_RETRY_MAX " 次）")
        SetTimer AsyncLoadingTick,ASYNC_LOADING_TICK_MS
        return true
    }
    EventLog(p.name,"ENTER_RETRY_GIVEUP","重做 " entry.enterTries " 次仍失敗：" e.Message "｜角色在遊戲中，先綁回監控，由登入後檢查補做")
    try {
        p.locType:="不確定"
        FinalizeRecovery(idx,entry.hwnd,entry.oldPid)
        return true
    } catch as e2 {
        EventLog(p.name,"ENTER_RETRY_GIVEUP_FAIL",e2.Message)
    }
    return false
}

AsyncLoadingFailed(idx, message, keepGame) {
    global profiles,MAX_AUTO_FAILURES,Status
    p:=profiles[idx]
    p.failures+=1
    EventLog(p.name,"RECOVERY_FAIL",message)
    if keepGame {
        p.state:="需要人工確認"
        EventLog(p.name,"LOGIN_COMMITTED_SAFE",message)
        RecoveryWebhook(p,"載入逾時－保留遊戲視窗",message)
        Status.Text:="狀態：" p.name " 載入逾時；已保留遊戲視窗，請人工確認"
    } else if p.failures>=MAX_AUTO_FAILURES {
        p.state:="需要人工處理"
        reason:="連續自動恢復失敗 " p.failures " 次｜最後原因：" message
        EventLog(p.name,"MANUAL_REQUIRED",reason)
        RecoveryWebhook(p,"需要人工處理",reason)
        Status.Text:="狀態：" p.name " 需要人工處理：" reason
    } else {
        ; 視窗已消失，沒有東西需要保留：照原本的失敗流程 5 秒後完整重啟。
        p.state:="恢復失敗"
        Status.Text:="狀態：" p.name " 載入期間遊戲關閉｜5 秒後完整重啟再試"
        SetTimer (() => RetryProfile(idx)), -5000
    }
    RefreshProfileLV()
    ScheduleNextRecovery(1000)
}
