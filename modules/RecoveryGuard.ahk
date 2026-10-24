; ============================================================================
; v1.3.21.0 RecoveryGuard：重新登入的完成度。
;
; 2026-10-23 03:39 假在線，7 個角色重新登入只有 2 個完全恢復（有的停在學院、有的沒按到 F6），
; 凌晨沒有人在電腦前，通知幫助不大，所以這裡以「自動補做到完成」為主，只寫紀錄：
; 1. 重新登入成功（RECOVERY_OK）後每 PostCheckSeconds 秒用記憶體檢查一次，最多 RG_POST_CHECK_ROUNDS 輪：
;    - 還在城裡（學院 / 安全區）→ 按前點卡回怪區；
;    - 自動攻擊（F6）沒開 → 開啟；
;    - 這段時間擊殺數沒有增加（只看平常有擊殺紀錄的角色）→ 補送登入後按鍵。
;    全部正常就結束；補做幾輪仍不正常，才發一次 Discord。
; 2. 一直死亡（RG_DEATH_WINDOW_MIN 分鐘內 RG_DEATH_COUNT 次）時檢查 F6，沒開就開啟（只寫紀錄）。
; 需要前景時與復活輔助相同：等其他自動化結束、鍵盤滑鼠閒置後才動作。
; ============================================================================

global RG_POST_CHECK_SEC := Integer(IniRead(INI,"Recovery","PostCheckSeconds","180"))
global RG_POST_CHECK_ROUNDS := 3
global RG_DEATH_WINDOW_MIN := Integer(IniRead(INI,"Recovery","DeathLoopWindowMinutes","10"))
global RG_DEATH_COUNT := Integer(IniRead(INI,"Recovery","DeathLoopCount","3"))
global RG_IDLE_SEC := 10
global RG_TICK_MS := 5000

; ---- 給登入流程用的記憶體判斷（讀不到資料時一律回傳空字串，維持原本的畫面判斷） ----

RecoveryHwndPid(hwnd) {
    pid:=0
    try pid:=WinGetPID("ahk_id " hwnd)
    return pid && GameOffsetsReady(pid) ? pid : 0
}

; 角色在遊戲世界裡：回傳 "alive" / "dead"；不在（選角畫面、Loading）或讀不到：""。
RecoveryMemoryGate(hwnd) {
    if !(pid:=RecoveryHwndPid(hwnd)) || !GameInWorld(pid)
        return ""
    hpNow:=0,hpMax:=0
    ReadGameHP(pid,&hpNow,&hpMax)
    return hpNow>0 ? "alive" : "dead"
}

; 角色在城裡（學院 / 安全區）時回傳地圖名稱。
RecoveryTownName(hwnd) {
    if !(pid:=RecoveryHwndPid(hwnd)) || !GameInWorld(pid)
        return ""
    return DailyTownName(pid)
}

; 角色在遊戲中、而且不在城裡時回傳地圖名稱（前點卡後確認已離開城裡）。
RecoveryLeftTown(hwnd) {
    if !(pid:=RecoveryHwndPid(hwnd)) || !GameInWorld(pid) || DailyTownName(pid)!=""
        return ""
    info:=GameMapInfo(pid,ReadGameMapId(pid))
    return IsObject(info) ? info.name : ReadGameMapId(pid)
}

RecoveryAutoAttackOn(hwnd) {
    return (pid:=RecoveryHwndPid(hwnd)) && ReadGameAutoAttack(pid)=1
}

; ---- 重新登入後檢查 ----

RecoveryGuardArm(p) {
    global RG_POST_CHECK_SEC
    p.rgDue:=A_TickCount+RG_POST_CHECK_SEC*1000
    p.rgRound:=1
    p.rgPid:=p.pid
    p.rgKills:=RecoveryGuardKills(p)
    ; 平常就沒有擊殺紀錄的角色（例如組隊的隊員）不用擊殺數判斷。
    p.rgUseKills:=p.rgKills>0 || KillStatsTotal(p.name,FormatTime(DateAdd(A_Now,-1,"Days"),"yyyy-MM-dd"))>0
}

RecoveryGuardKills(p) {
    return KillStatsTotal(p.name,FormatTime(,"yyyy-MM-dd"))
}

RecoveryGuardNoteDeath(p) {
    if !p.HasOwnProp("rgDeaths")
        p.rgDeaths:=[]
    p.rgDeaths.Push(A_TickCount)
    RecoveryGuardPruneDeaths(p)
}

RecoveryGuardPruneDeaths(p) {
    global RG_DEATH_WINDOW_MIN
    cutoff:=A_TickCount-RG_DEATH_WINDOW_MIN*60000
    while p.rgDeaths.Length && p.rgDeaths[1]<cutoff
        p.rgDeaths.RemoveAt(1)
}

; 其他自動化正在用前景、或有人在操作電腦：這一輪先不動。
RecoveryGuardBusy() {
    global foregroundOwner,processingQueue,fastLoginCritical,dailyRunning,recorder,abortRequested,asyncLoadingEntries,RG_IDLE_SEC
    return abortRequested || foregroundOwner!="" || processingQueue || fastLoginCritical || dailyRunning!=""
        || IsObject(recorder) || asyncLoadingEntries.Count || A_TimeIdlePhysical<RG_IDLE_SEC*1000
}

RecoveryGuardTick() {
    global profiles
    for p in profiles {
        if !p.enabled || !p.pid || p.state!="監控中" || !ProfileGameAlive(p) || !GameOffsetsReady(p.pid)
            continue
        if p.HasOwnProp("rgDue") && p.rgDue && A_TickCount>=p.rgDue
            RecoveryGuardPostCheck(p)
        RecoveryGuardDeathLoop(p)
    }
}

RecoveryGuardPostCheck(p) {
    global RG_POST_CHECK_SEC,RG_POST_CHECK_ROUNDS
    if p.rgPid!=p.pid {
        p.rgDue:=0
        return
    }
    ; 死亡中 / 換地圖中：交給死亡監控與復活輔助，下一輪再看。
    if p.hpEventOpen || !GameInWorld(p.pid) || RecoveryGuardBusy()
        return
    town:=DailyTownName(p.pid)
    auto:=ReadGameAutoAttack(p.pid)
    kills:=RecoveryGuardKills(p)
    gained:=kills>=p.rgKills ? kills-p.rgKills : kills   ; 跨日時今天從 0 開始
    mins:=Round(RG_POST_CHECK_SEC/60,1)
    problems:=[]
    if town!=""
        problems.Push("還在 " town)
    if auto=0
        problems.Push("自動攻擊（F6）沒開")
    if p.rgUseKills && gained<=0
        problems.Push(mins " 分鐘內沒有擊殺")
    if !problems.Length {
        EventLog(p.name,"RECOVERY_CHECK_OK","重新登入後檢查正常（第 " p.rgRound " 輪）｜擊殺 +" gained "｜" NotificationLocationText(p))
        p.rgDue:=0
        return
    }
    text:=RecoveryGuardJoin(problems)
    if p.rgRound>RG_POST_CHECK_ROUNDS {
        p.rgDue:=0
        EventLog(p.name,"RECOVERY_CHECK_FAIL","補做 " RG_POST_CHECK_ROUNDS " 輪仍不正常｜" text)
        AddRecentEvent("⚠ " p.name " 重新登入後補做 " RG_POST_CHECK_ROUNDS " 輪仍沒有在打怪：" text)
        ReportEventShot(p,"⚠️ HIHIYONG 重新登入後角色沒有在打怪`n角色：" p.name "`n所在地圖：" NotificationLocationText(p)
            . "`n狀況：" text "`n已自動補做 " RG_POST_CHECK_ROUNDS " 輪仍不正常，請有空時確認。（附上當下畫面）")
        return
    }
    done:=RecoveryGuardFix(p,town)
    EventLog(p.name,"RECOVERY_CHECK_FIX","重新登入後檢查（第 " p.rgRound " 輪）：" text "｜已補做：" done)
    AddRecentEvent("🔧 " p.name " 重新登入後" text "，已補做：" done)
    p.rgRound+=1
    p.rgKills:=RecoveryGuardKills(p)
    p.rgDue:=A_TickCount+RG_POST_CHECK_SEC*1000
}

; 前點卡（在城裡時）→ 登入後按鍵（F6 依實際狀態）。回傳做了哪些事。
RecoveryGuardFix(p, town) {
    global foregroundOwner,activeRecoveryHwnd,activeRecoveryPid,ReturnKeyEdit,PostKeysEdit
    ctx:={name:p.name,hwnd:p.hwnd,pid:p.pid}
    foregroundOwner:="guard"
    activeRecoveryHwnd:=p.hwnd,activeRecoveryPid:=p.pid
    done:=[]
    try {
        DailyEnsureOnScreen(ctx)
        EnsureRecoveryFocus(p.hwnd,p.name)
        Sleep 300
        if town!="" && (key:=Trim(ReturnKeyEdit.Value))!="" {
            before:=ReadGameMapId(p.pid)
            SendOneKey(key)
            moved:=RecoveryGuardWaitMap(p.pid,before,20000)
            done.Push("按前點卡 " key (moved ? "" : "（地圖沒有改變）"))
            Sleep 2500
        }
        hasF6:=false
        for key in StrSplit(Trim(PostKeysEdit.Value),",") {
            key:=Trim(key)
            if key=""
                continue
            if StrUpper(key)="F6" {
                hasF6:=true
                done.Push(RecoveryGuardAutoOn(p))
                continue
            }
            SendOneKey(key)
            Sleep 300
            done.Push("按 " key)
        }
        if !hasF6
            done.Push(RecoveryGuardAutoOn(p))
    } catch as e {
        done.Push("失敗：" e.Message)
    }
    DailyRestorePosition(ctx)
    activeRecoveryHwnd:=0,activeRecoveryPid:=0
    foregroundOwner:=""
    return RecoveryGuardJoin(done)
}

; 已取得前景時呼叫：自動攻擊沒開才按 F6，按完確認。
RecoveryGuardAutoOn(p) {
    if ReadGameAutoAttack(p.pid)!=0
        return "自動攻擊已開啟"
    SendOneKey("F6")
    Sleep 800
    return ReadGameAutoAttack(p.pid)=1 ? "開啟自動攻擊" : "按 F6 後自動攻擊仍未開啟"
}

RecoveryGuardWaitMap(pid, before, timeoutMs) {
    start:=A_TickCount
    while A_TickCount-start<timeoutMs {
        m:=ReadGameMapId(pid)
        if m!="" && m!=before && GameCharacterLoaded(pid)
            return true
        Sleep 300
    }
    return false
}

; ---- 一直死亡時檢查自動攻擊 ----

RecoveryGuardDeathLoop(p) {
    global RG_DEATH_COUNT,RG_DEATH_WINDOW_MIN,foregroundOwner,activeRecoveryHwnd,activeRecoveryPid
    if !p.HasOwnProp("rgDeaths") || p.hpEventOpen
        return
    RecoveryGuardPruneDeaths(p)
    n:=p.rgDeaths.Length
    if n<RG_DEATH_COUNT
        return
    last:=p.rgDeaths[n]
    if p.HasOwnProp("rgDeathChecked") && p.rgDeathChecked=last
        return
    auto:=ReadGameAutoAttack(p.pid)
    if auto=-1
        return
    if auto=1 {
        p.rgDeathChecked:=last,p.rgAutoOffSeen:=0
        return
    }
    ; 剛復活的瞬間可能讀到關閉：連續兩輪（約 5 秒以上）都是關閉才按。
    if !p.HasOwnProp("rgAutoOffSeen") || !p.rgAutoOffSeen {
        p.rgAutoOffSeen:=A_TickCount
        return
    }
    if A_TickCount-p.rgAutoOffSeen<4000 || RecoveryGuardBusy()
        return
    p.rgDeathChecked:=last,p.rgAutoOffSeen:=0
    ctx:={name:p.name,hwnd:p.hwnd,pid:p.pid}
    foregroundOwner:="guard"
    activeRecoveryHwnd:=p.hwnd,activeRecoveryPid:=p.pid
    try {
        DailyEnsureOnScreen(ctx)
        EnsureRecoveryFocus(p.hwnd,p.name)
        Sleep 300
        result:=RecoveryGuardAutoOn(p)
    } catch as e {
        result:="失敗：" e.Message
    }
    DailyRestorePosition(ctx)
    activeRecoveryHwnd:=0,activeRecoveryPid:=0
    foregroundOwner:=""
    EventLog(p.name,"DEATH_LOOP_AUTO",RG_DEATH_WINDOW_MIN " 分鐘內死亡 " n " 次，自動攻擊（F6）沒開｜" result)
    AddRecentEvent("🔧 " p.name " 一直死亡且 F6 沒開：" result)
}

RecoveryGuardJoin(arr) {
    out:=""
    for s in arr
        out.=(out="" ? "" : "、") s
    return out
}
