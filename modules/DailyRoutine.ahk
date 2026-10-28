; ============================================================================
; v1.3.17.0 DailyRoutine：自動更換每日道具。
;
; 流程依 2026-10-21 豆奶的示範錄製建立：
;   Q 回城（過圖讓到期的一日道具消失）→ F6 → 開啟角色 / 道具視窗 → 銀行取出每日分享禮包 → 打開
;   → 打開飾品禮盒、暗夜項鍊禮盒、命運箱子 → 勳章貼紙 → 打開紀念造型服飾禮包 → 項鍊（念珠＋暗夜項鍊）
;   → 武器選擇盒選雙槍 → 頭 / 衣 / 褲 / 手套 / 鞋 / 武器：脫下 → 左鍵拿起造型 → 右鍵裝備（套上並穿回）
;   → 關閉視窗 → W 前點 → F6
;
; 安全設計：
; - 每一步都用遊戲記憶體確認結果（例如頭部欄確實套上造型），不符合就停止並通知，不會繼續亂點。
; - 每一步先檢查目前狀態，已完成就略過；中途失敗後再執行一次會從中斷處接續。
; - 點擊位置以視窗標題圖（DailyTemplates）為錨點換算，不依賴視窗固定位置。
; - 執行期間持有前景鎖（foregroundOwner）並設定 activeRecoveryHwnd：自動登入、視窗切換、背包清理都會等待。
; - F10 隨時中止；中止或失敗時先放下滑鼠上拿著的道具。
; ============================================================================

global DAILY_TPL_DIR := A_ScriptDir "\DailyTemplates"
global DAILY_AUTORUN := Integer(IniRead(INI,"DailyItems","AutoRun","0"))
global DAILY_IDLE_SEC := Integer(IniRead(INI,"DailyItems","IdleSeconds","60"))
; v1.3.20.3：提醒視窗出現後這麼多秒都沒有人點選任何選項（人不在電腦前）就自動更換；0 = 不自動
global DAILY_POPUP_TIMEOUT_SEC := Integer(IniRead(INI,"DailyItems","PopupTimeoutSec","60"))
global DAILY_POPUP_QUIET_SEC := 3
global dailyPopupStart := 0
; 實體鍵鼠閒置毫秒數；測試可換成固定值，避免結果受「有人正在用電腦」影響
global dailyIdleMs := () => A_TimeIdlePhysical
global DAILY_WEAPON_KEYWORD := IniRead(INI,"DailyItems","WeaponKeyword","雙槍")
; 武器造型貼選擇盒的道具編號（有人領到過就記住）：之後不用背包裡有盒子，也讀得到盒子裡有哪些武器可選
global DAILY_WEAPON_BOX_KEY := IniRead(INI,"DailyItems","WeaponBoxKey","1-242")
; H-028 / H-030 傳送卡按鍵：平常從道具快捷欄讀出卡在第幾格、改按那一格的鍵；讀不到快捷欄資料時才用這裡手動設定的鍵。
; QuickKeys = 快捷欄每一格對應的鍵（由左到右，預設只知道前 3 格是 Q W E，後面的格子要自己填才會用）。
global DAILY_START_KEY := Trim(IniRead(INI,"DailyItems","StartCardKey","q")), DAILY_PREV_KEY := Trim(IniRead(INI,"DailyItems","PrevCardKey","w"))
global DAILY_QUICK_KEYS := Trim(IniRead(INI,"DailyItems","QuickKeys","q,w,e,a,s,d"))
; 讀不到選擇盒清單時改用的位置（10/21 示範錄製：GT 武器造型貼選擇盒的雙槍在第 5 個）
global DAILY_WEAPON_CHOICE_INDEX := Integer(IniRead(INI,"DailyItems","WeaponChoiceIndex","5"))
global DAILY_STEP_TIMEOUT_MS := 6000
global DAILY_TELEPORT_TIMEOUT_MS := 45000
global DAILY_FRESH_SEC := 12*3600          ; 剩餘時間超過這個值的一日道具視為「今天已更換」
global DAILY_CLIENT_W := 1024, DAILY_CLIENT_H := 768
global dailyRunQueue := []
global dailyRunning := ""
; 測試用：設定為模擬器物件時，按鍵 / 點擊 / 辨識圖都交給模擬器，不會動到真正的滑鼠鍵盤。
global dailyTestDriver := 0

; 點擊位置：相對於模板左上角的位移（取自示範錄製，遊戲畫面 1024x768）
global DAILY_INV_TAB_BAG := [-33,30], DAILY_INV_TAB_BANK := [49,29], DAILY_INV_CELL0 := [-41,80], DAILY_INV_STEP := 37
global DAILY_INV_COLS := 6, DAILY_INV_VISIBLE_ROWS := 9
; H-024 背包分頁：6 欄 × 50 列，視窗每次顯示 10 列 = 一頁（共 5 頁）。道具位置的列 y 對應第 y÷10+1 頁；
; 同一頁內的第 (y mod 10) 列顯示在同樣的畫面位置。
global DAILY_INV_ROWS_PER_PAGE := 10, DAILY_PAGE_WAIT_MS := 3000, DAILY_PAGE_CONFIRM_MS := 150
; 角色視窗的裝備欄（EMSLOT → 位移）；褲子 / 手套若位置互換，脫裝備時會依記憶體自動辨識
global DAILY_CHAR_SLOTS := Map(0,[-163,127], 1,[-164,165], 2,[-163,239], 3,[-162,270], 4,[-159,312], 5,[-163,399], 19,[-48,393])
global DAILY_CHOICE_ICON0 := [-63,65], DAILY_CHOICE_STEP := 36, DAILY_CHOICE_SELECT := [36,205], DAILY_CHOICE_VISIBLE := 6
global DAILY_CONFIRM_YES := [181,74]
; 要套上一日造型的裝備欄與造型名稱關鍵字
global DAILY_COSTUME_SLOTS := [[0,"頭飾造型"],[1,"上衣造型"],[2,"褲子造型"],[3,"手套造型"],[4,"鞋子造型"],[5,"造型貼"]]
global DAILY_SLOT_NECK := 7, DAILY_SLOT_MEDAL := 19, DAILY_SLOT_HOLD := 21
; v1.3.24.0：每個角色可以選要換哪些每日道具、在哪裡換（角色設定 DailyItems / DailyMode / DailyWeapon）。
; 沒勾的項目：相關禮盒不打開、裝備欄不動；到期提醒也只看有勾的項目。
global DAILY_OPTIONS := [["medal","千手勳章"],["neck","念珠＋暗夜項鍊"],["weapon","武器造型貼"],["head","頭飾造型"]
    ,["top","上衣造型"],["pants","褲子造型"],["gloves","手套造型"],["shoes","鞋子造型"],["mbox","打開命運箱子"]]
global DAILY_ALL_ITEMS := "medal,neck,weapon,head,top,pants,gloves,shoes,mbox"
global DAILY_SLOT_OPTION := Map(0,"head",1,"top",2,"pants",3,"gloves",4,"shoes",5,"weapon",7,"neck",19,"medal")
global dailyCurWeaponKw := ""             ; 執行中角色的武器造型關鍵字（空白 = 共用設定 WeaponKeyword）

DailyItemsOf(p) => p.HasOwnProp("dailyItems") ? p.dailyItems : DAILY_ALL_ITEMS
DailyWants(p, opt) => InStr("," DailyItemsOf(p) ",","," opt ",")>0
; 裝備欄 slot 屬於哪個選項；不在清單內的欄位（其他一日道具）照舊計算 → true
DailyWantsSlot(p, slot) => !DAILY_SLOT_OPTION.Has(slot) || DailyWants(p,DAILY_SLOT_OPTION[slot])
; "town" = 回城換（Q 回城、換完 W 回怪區）；"here" = 原地換（不過圖，換完留在原地）
DailyModeOf(p) => p.HasOwnProp("dailyMode") && (p.dailyMode="here" || p.dailyMode="auto") ? p.dailyMode : "town"

; H-032 "auto" = 依道具快捷欄決定：起點卡和前點卡都放在快捷欄 → 回城換；有一張不在 → 原地換（不用人工設定每個角色）。
; 讀不到快捷欄資料（舊位置檔）時當作回城換（維持原本行為與原本的安全停止）。
DailyCanReturn(pid) {
    s:=DailyQuickInfo(pid,"起點傳送卡"),p:=DailyQuickInfo(pid,"前點傳送卡")
    if s="" || p=""
        return true
    return IsObject(s) && s.key!="" && IsObject(p) && p.key!=""
}
DailyWeaponOf(p) => p.HasOwnProp("dailyWeapon") ? p.dailyWeapon : ""
DailyWeaponKw() => dailyCurWeaponKw!="" ? dailyCurWeaponKw : DAILY_WEAPON_KEYWORD
; 只留已知的項目、順序固定（INI 被手改過也不會壞掉）
DailyNormalizeItems(s) {
    global DAILY_OPTIONS
    picked:=",",out:=""
    for o in StrSplit(s,",")
        picked.=Trim(o," `t`"") ","
    for o in DAILY_OPTIONS
        if InStr(picked,"," o[1] ",")
            out.=(out="" ? "" : ",") o[1]
    return out
}
; 上次自動更換成功的時間（time_t，存在 INI，程式重開也記得）。
DailyDoneAt(p) {
    global INI
    if !p.HasOwnProp("dailyDoneAt")
        p.dailyDoneAt:=Integer(IniRead(INI,"DailyItemsProgress",p.name "|done","0"))
    return p.dailyDoneAt
}
; 換完後到期時間仍讀不到 / 已過（例如只勾命運箱子、或原地換時沒勾的舊道具還在）時，
; 靠這個避免一直重跑：成功後 DAILY_REDO_SEC 內不再判定為到期。
DailyRecentlyDone(p) => UnixNow()-DailyDoneAt(p)<DAILY_REDO_SEC
global DAILY_REDO_SEC := 20*3600
; 「未完成的更換」紀錄超過這麼久就不再接續（照原本設定重新開始，會回城）。2026-10-26 欸等等 / 小柯基留著幾小時前失敗的紀錄，
; 後來的更換被當成接續而略過 Q，在戰鬥區原地更換。
global DAILY_RESUME_SEC := 3*3600

; ---------------------------------------------------------------------------
; 排程：依序執行佇列中的角色
; ---------------------------------------------------------------------------

DailyRunEnqueue(indexes, reason) {
    global dailyRunQueue,profiles
    for i in indexes {
        already:=false
        for q in dailyRunQueue
            if q=i
                already:=true
        if !already {
            dailyRunQueue.Push(i)
            EventLog(profiles[i].name,"DAILY_QUEUE","排入每日道具更換｜" reason)
        }
    }
    SetTimer DailyRunNext,-200
}

DailyRunNext() {
    global dailyRunQueue,foregroundOwner,processingQueue,asyncLoadingEntries,abortRequested,fastLoginCritical
    if !dailyRunQueue.Length
        return
    if abortRequested {
        dailyRunQueue:=[]
        return
    }
    ; 自動登入 / 載入中的帳號正在使用前景時先等待
    if foregroundOwner!="" || processingQueue || fastLoginCritical || asyncLoadingEntries.Count {
        SetTimer DailyRunNext,-3000
        return
    }
    idx:=dailyRunQueue.RemoveAt(1)
    DailyRoutineRun(idx)
    if dailyRunQueue.Length
        SetTimer DailyRunNext,-2000
}

; 目前不能執行的原因；可以執行回傳 ""。
DailyRoutineBlocker(p) {
    global abortRequested,recorder,DAILY_TPL_DIR,DAILY_CLIENT_W,DAILY_CLIENT_H,dailyTestDriver
    if abortRequested
        return "自動化已停止（F10 / 停止監控），請先開始監控"
    if !p.pid || !ProfileGameAlive(p)
        return "沒有連接遊戲視窗"
    if !GameOffsetsReady(p.pid) || !GameCharacterLoaded(p.pid)
        return "角色資料尚未就緒"
    if IsObject(recorder)
        return "示範錄製中"
    if DailyItemsOf(p)="" && !DailyInProgress(p.name)
        return "這個角色設定為不更換任何每日道具"
    for name in ["inventory_title","character_title","choice_title","confirm_take"]
        if !FileExist(DAILY_TPL_DIR "\" name ".bmp")
            return "缺少辨識圖 DailyTemplates\" name ".bmp"
    if IsObject(dailyTestDriver)
        return ""
    WinGetClientPos(,,&cw,&ch,"ahk_id " p.hwnd)
    if cw!=DAILY_CLIENT_W || ch!=DAILY_CLIENT_H
        return "遊戲畫面大小為 " cw "x" ch "，目前只支援 " DAILY_CLIENT_W "x" DAILY_CLIENT_H
    return ""
}

DailyRoutineRun(idx) {
    global profiles,foregroundOwner,activeRecoveryHwnd,activeRecoveryPid,dailyRunning,Status,INI,dailyTestDriver
    p:=profiles[idx]
    reason:=DailyRoutineBlocker(p)
    if reason!="" {
        EventLog(p.name,"DAILY_SKIP",reason)
        AddRecentEvent("⚠ " p.name " 無法自動更換每日道具：" reason)
        return false
    }
    global dailyCurWeaponKw
    ctx:={idx:idx,name:p.name,hwnd:p.hwnd,pid:p.pid,start:A_TickCount,invAnchor:0,charAnchor:0,p:p}
    dailyCurWeaponKw:=DailyWeaponOf(p)
    foregroundOwner:="daily",dailyRunning:=p.name
    activeRecoveryHwnd:=p.hwnd,activeRecoveryPid:=p.pid
    EventLog(p.name,"DAILY_START","開始自動更換每日道具")
    AddRecentEvent("🎁 " p.name " 開始自動更換每日道具（請勿操作鍵盤滑鼠，F10 可中止）")
    ok:=true
    try {
        DailyEnsureOnScreen(ctx)
        DailyRoutineSteps(ctx)
        secs:=Round((A_TickCount-ctx.start)/1000)
        EventLog(p.name,"DAILY_DONE","每日道具更換完成｜" secs " 秒")
        p.dailyDoneAt:=UnixNow()
        if !IsObject(dailyTestDriver)
            try IniWrite p.dailyDoneAt,INI,"DailyItemsProgress",p.name "|done"
        AddRecentEvent("✓ " p.name " 每日道具更換完成（" secs " 秒）")
        try SendDiscordMessage("✅ HIHIYONG 每日道具已自動更換`n角色：" p.name "（" secs " 秒）")
    } catch as e {
        ok:=false
        shot:=DailySaveFailShot(ctx)
        DailyReleaseHeld(ctx)
        EventLog(p.name,"DAILY_FAIL",e.Message (shot!="" ? "｜畫面：" shot : ""))
        AddRecentEvent("⚠ " p.name " 每日道具自動更換停止：" e.Message)
        msg:="⚠️ HIHIYONG 每日道具自動更換停止`n角色：" p.name "`n原因：" e.Message "`n已停止操作，請人工確認。"
        try (shot!="" && REPORT_ERROR_SHOTS) ? SendDiscordImage(msg,shot) : SendDiscordMessage(msg)
        p.dailyAcked:=1   ; 失敗後不再自動重試，等人工處理
    }
    DailyRestorePosition(ctx)
    dailyCurWeaponKw:=""
    activeRecoveryHwnd:=0,activeRecoveryPid:=0
    foregroundOwner:="",dailyRunning:=""
    ; 讓下一次 DailyItemsTick 重新讀取到期時間
    if p.HasOwnProp("dailyExpiry")
        p.DeleteProp("dailyExpiry")
    return ok
}

; ---------------------------------------------------------------------------
; 流程
; ---------------------------------------------------------------------------

DailyRoutineSteps(ctx) {
    pid:=ctx.pid
    ; 上次中途停止時已回城：這次不再按 Q。
    ; v1.3.18.8：F6 依遊戲中的實際狀態按（開著才關）。v1.3.24.0：讀不到狀態就停止，不再盲按。
    ; v1.3.20.2：角色本來就在城裡（例如欸等）時按 Q 不會換地圖，舊版會一直等到逾時。
    ; 改成略過 Q、結束後不按 W 留在原地，自動攻擊恢復成原本的狀態。
    inProgress:=DailyInProgress(ctx.name)
    stay:=false,here:=false
    autoWas:=ReadGameAutoAttack(pid)
    ; 在按 Q / 動任何東西之前就確認讀得到自動攻擊狀態（否則回城後才發現，角色會整晚停在城裡）
    if autoWas=-1
        throw Error("讀不到自動攻擊（F6）狀態，無法確認能關閉，為安全起見停止更換（還沒動任何東西）")
    ; 讀不到目前地圖就不做（無法判斷該不該 Q / W，也無法確認結束時在怪區）
    if DailyWhere(pid)=""
        throw Error("讀不到目前所在地圖，為安全起見停止更換（還沒動任何東西）")
    resume:=inProgress && DailyProgressRecent(ctx.name)
    if inProgress && !resume
        DailyStep(ctx,"上次未完成的更換紀錄已經過期（超過 " Round(DAILY_RESUME_SEC/3600) " 小時），不接續，照設定從頭開始")
    if resume {
        stay:=DailyInProgressStay(ctx.name)
        here:=InStr(DailyProgressValue(ctx.name),"here")=1
        DailyStep(ctx,"接續上次未完成的更換（略過 Q）")
    } else if (town:=DailyTownName(pid))!="" {
        stay:=true
        DailyStep(ctx,"角色已在城裡（" town "），略過 Q 回城，換完 W 前點到怪區")
    } else if DailyModeOf(ctx.p)="here" || (DailyModeOf(ctx.p)="auto" && !DailyCanReturn(pid)) {
        stay:=true,here:=true
        DailyStep(ctx,DailyModeOf(ctx.p)="auto" ? "原地更換（道具快捷欄沒有起點卡 / 前點卡，自動改成不回城），換完留在原地" : "原地更換（角色設定：不回城），換完留在原地")
    } else {
        DailyStep(ctx,"Q 回城（過圖讓到期道具消失）")
        DailyTeleport(ctx,DailyCardKey(ctx,"起點傳送卡",DAILY_START_KEY))
    }
    ; v1.3.24.0：換裝前一定要確認自動攻擊（F6）已關閉；讀不到狀態就停止，不盲按（F6 是開關，可能反而打開）。
    if !DailySetAutoAttack(ctx,false)
        throw Error("讀不到自動攻擊（F6）狀態，無法確認已關閉，停止更換（還沒動任何道具；角色可能已在城裡）")
    ; 進行中紀錄："1" = 回城換；"town" = 原本在城裡；"here1" / "here0" = 原地換（原本自動攻擊開 / 關）
    if !resume
        DailySetInProgress(ctx.name,true,here ? "here" (autoWas=1 ? 1 : 0) : stay ? "town" : "1")
    DailyStep(ctx,"開啟角色與道具視窗")
    DailyEnsureWindows(ctx)
    if inProgress
        DailyRestoreUnwanted(ctx)

    want:=ctx.p
    if DailyItemsOf(want)="" {
        ; 全部不勾、但上次更換中斷：只把脫下的裝備穿回（上面 DailyRestoreUnwanted），再回怪區開 F6
        DailyStep(ctx,"全部項目已取消勾選：只穿回上次脫下的裝備")
    } else {
    DailyTakePackFromBank(ctx)
    DailyOpenItem(ctx,"每日分享禮包",["紀念造型服飾禮包","千手勳章"])
    if DailyWants(want,"neck") {
        DailyOpenItem(ctx,"飾品禮盒",["念珠"])
        DailyOpenItem(ctx,"暗夜項鍊(1D)禮盒",["暗夜項鍊(1D)["])
    }
    if DailyWants(want,"mbox")
        DailyOpenItem(ctx,"命運箱子[100P][禮盒]",[],false)
    if DailyWants(want,"medal")
        DailyMedal(ctx)
    ; v1.3.18.1：身上全是永久造型的角色（例如欸等）只換勳章與項鍊，服飾禮包留在背包不開。
    need:=DailyCostumeSlotsNeeded(pid,want)
    if need.Length {
        DailyOpenItem(ctx,"紀念造型服飾禮包",["頭飾造型","上衣造型","褲子造型","手套造型","鞋子造型"])
    } else {
        DailyStep(ctx,"沒有要換的造型（未勾選、已換好或是永久造型），略過造型更換")
    }
    if DailyWants(want,"neck")
        DailyNecklace(ctx)
    if DailyWants(want,"weapon")
        DailyWeaponSticker(ctx)
    DailyCostumes(ctx)
    }

    DailyCloseWindows(ctx)
    ; v1.3.24.0：結束時一律「在怪物地圖＋自動攻擊確認已開啟」（使用者要求：開始時就在城裡的角色也送去怪區）；
    ; 任何一項沒做到就停止並通知，下次接續會從這一步再做。
    try {
        ; 只有在城裡才按 W（接續時可能已在怪區：上次 W 成功、F6 失敗）
        ; 讀不到地圖時不能當成在怪區（否則可能在城裡開 F6 原地不動）
        DailyWaitUntil(ctx,"讀不到目前所在地圖",() => DailyWhere(pid)!="",5000)
        if DailyWhere(pid)="town" {
            DailyStep(ctx,"W 前點到怪物區")
            DailyTeleport(ctx,DailyCardKey(ctx,"前點傳送卡",DAILY_PREV_KEY))
        }
        DailyWaitUntil(ctx,"角色不在怪物地圖（目前在 " (DailyTownName(pid)!="" ? DailyTownName(pid) : "無法辨識的地圖") "）",() => DailyWhere(pid)="field",5000)
        DailyStep(ctx,"F6 開啟自動攻擊並確認")
        DailyAutoAttackOn(ctx)
    } catch as e {
        throw Error("道具已換好，但" e.Message "，請人工確認角色位置與自動攻擊")
    }
    DailySetInProgress(ctx.name,false)
}

; "town" = 城裡（安全區或「學院」），"field" = 怪物地圖，"" = 讀不到地圖資料。
DailyWhere(pid) {
    info:=0
    try info:=GameMapInfo(pid,ReadGameMapId(pid))
    if !IsObject(info)
        return ""
    return info.peace || InStr(info.name,"學院") ? "town" : "field"
}

; 目前在城裡（安全區，或地圖名稱含「學院」）就回傳地圖名稱，否則回傳 ""。
DailyTownName(pid) {
    info:=GameMapInfo(pid,ReadGameMapId(pid))
    if IsObject(info) && (info.peace || InStr(info.name,"學院"))
        return info.name
    return ""
}

; 開啟自動攻擊並用記憶體確認；讀不到狀態或按了沒開都丟錯誤（不盲按）。
DailyAutoAttackOn(ctx) {
    if !DailySetAutoAttack(ctx,true)
        throw Error("讀不到自動攻擊（F6）狀態，無法確認已開啟")
}

; 把自動攻擊切到指定狀態（已是該狀態就不按）；讀不到狀態回傳 false，由呼叫端決定怎麼處理。
DailySetAutoAttack(ctx, on) {
    state:=ReadGameAutoAttack(ctx.pid)
    if state=-1
        return false
    if state=(on ? 1 : 0)
        return true
    DailyKey(ctx,"F6")
    pid:=ctx.pid
    DailyWaitUntil(ctx,"按 F6 後自動攻擊沒有" (on ? "開啟" : "關閉"),() => ReadGameAutoAttack(pid)=(on ? 1 : 0),4000)
    return true
}

; 「已回城、但還沒換完」的紀錄；存在 INI，程式重開也能接續。
DailyProgressValue(name) {
    global INI,dailyTestDriver
    if IsObject(dailyTestDriver) && dailyTestDriver.HasOwnProp("inProgress")
        return String(dailyTestDriver.inProgress.Get(name,"0"))
    return IniRead(INI,"DailyItemsProgress",name,"0")
}

; 這筆「進行中」紀錄是不是剛才的（可以接續）。沒有時間的舊紀錄一律當作過期。
DailyProgressRecent(name) {
    global INI,dailyTestDriver,DAILY_RESUME_SEC
    if IsObject(dailyTestDriver) && dailyTestDriver.HasOwnProp("inProgress")
        return !(dailyTestDriver.HasOwnProp("staleProgress") && dailyTestDriver.staleProgress)
    t:=0
    try t:=Integer(IniRead(INI,"DailyItemsProgress",name "|t","0"))
    return t>0 && UnixNow()-t<DAILY_RESUME_SEC
}

DailyInProgress(name) {
    v:=DailyProgressValue(name)
    return v="1" || v="town" || v="here1" || v="here0"
}

; 進行中的這一輪是「原本就在城裡、換完留在原地」。
DailyInProgressStay(name) {
    v:=DailyProgressValue(name)
    return v="town" || v="here1" || v="here0"
}

; mark：開始時寫入的進行中紀錄（見 DailyRoutineSteps）。
DailySetInProgress(name, on, mark:="1") {
    global INI,dailyTestDriver,DAILY_COSTUME_SLOTS,DAILY_SLOT_MEDAL
    if IsObject(dailyTestDriver) && dailyTestDriver.HasOwnProp("inProgress") {
        if on
            dailyTestDriver.inProgress[name]:=mark
        else
            for key in dailyTestDriver.inProgress.Clone()
                if key=name || InStr(key,name "|")=1
                    dailyTestDriver.inProgress.Delete(key)
        return
    }
    try IniWrite on ? mark : "0",INI,"DailyItemsProgress",name
    if on
        try IniWrite UnixNow(),INI,"DailyItemsProgress",name "|t"
    if !on {
        try IniDelete INI,"DailyItemsProgress",name "|t"
        for pair in DAILY_COSTUME_SLOTS
            try IniDelete INI,"DailyItemsProgress",name "|" pair[1]
        try IniDelete INI,"DailyItemsProgress",name "|" DAILY_SLOT_MEDAL
    }
}

; 記錄某一欄原本的裝備（脫下前寫入；完成整個流程後清除）。
DailyRecordUnequipped(name, slot, key) {
    global INI,dailyTestDriver
    if IsObject(dailyTestDriver) && dailyTestDriver.HasOwnProp("inProgress")
        return dailyTestDriver.inProgress[name "|" slot]:=key
    try IniWrite key,INI,"DailyItemsProgress",name "|" slot
}

DailyRecordedUnequipped(name, slot) {
    global INI,dailyTestDriver
    if IsObject(dailyTestDriver) && dailyTestDriver.HasOwnProp("inProgress")
        return dailyTestDriver.inProgress.Has(name "|" slot) ? dailyTestDriver.inProgress[name "|" slot] : ""
    return IniRead(INI,"DailyItemsProgress",name "|" slot,"")
}

; 接續時：上次脫下的裝備，若這一欄現在已不勾選（不會再套造型），直接穿回原本的裝備，不留在背包。
DailyRestoreUnwanted(ctx) {
    global DAILY_COSTUME_SLOTS,DAILY_SLOT_MEDAL
    pid:=ctx.pid
    slots:=[DAILY_SLOT_MEDAL]
    for pair in DAILY_COSTUME_SLOTS
        slots.Push(pair[1])
    for slot in slots {
        if DailyWantsSlot(ctx.p,slot) || DailyEquip(pid)[slot+1]
            continue
        rec:=DailyRecordedUnequipped(ctx.name,slot)
        ; 沒有脫下紀錄就不猜（這一欄本來可能就是空的，背包裡的同部位裝備可能是備用的）
        if rec="" || !(it:=DailyFindItem(pid,rec))
            continue
        DailyStep(ctx,"接續：" GAME_EQUIP_SLOT_NAMES[slot+1] " 已不勾選，穿回原本的 " GameItemName(rec,pid))
        DailyClickCell(ctx,it,"Right")
        s:=slot
        DailyWaitUntil(ctx,GAME_EQUIP_SLOT_NAMES[slot+1] "沒有穿回",() => (e:=DailyEquip(pid)[s+1]) && e.key=rec)
    }
}

; 欄位是空的時，找出原本那件裝備：先用脫下時的紀錄；沒有紀錄時，背包中「同部位、非造型、非限時」
; 的裝備只有一件才採用，否則停止並列出候選，請人工穿回（避免誤穿備用裝備）。
DailyFindUnequipped(ctx, slot) {
    pid:=ctx.pid
    rec:=DailyRecordedUnequipped(ctx.name,slot)
    if rec!="" && DailyFindItem(pid,rec)
        return rec
    candidates:=Map()
    for s in DailyInventory(pid) {
        if GameItemSuit(pid,s.key)!=slot
            continue
        name:=GameItemName(s.key,pid)
        if InStr(name,"造型") || InStr(name,"禮") || GameItemTimeLimit(pid,s.key)>0
            continue
        candidates[s.key]:=name
    }
    if candidates.Count=1
        for key in candidates
            return key
    list:=""
    for key,name in candidates
        list.=(list="" ? "" : "、") name
    throw Error(GAME_EQUIP_SLOT_NAMES[slot+1] "欄是空的，"
        . (candidates.Count ? "背包裡有 " candidates.Count " 件可能是原本的裝備（" list "）" : "背包裡找不到原本的裝備")
        . "，請人工穿回後再執行")
}

; H-028 道具快捷欄（畫面下方 6 格）：每個角色起點卡 / 前點卡放的格子可能不同，所以從快捷欄讀出它實際在哪一格，
; 再換成那一格對應的鍵。H-032：每一格的鍵直接讀遊戲目前的「快捷鍵設定」（玩家可能改成 Z X C…）；
; 讀不到才用設定檔 [DailyItems] QuickKeys 的預設（q,w,e,a,s,d）。
; 回傳 {slot, key}；快捷欄裡找不到回傳 0；讀不到快捷欄資料回傳 ""。
DailyQuickInfo(pid, needle) {
    global dailyTestDriver,DAILY_QUICK_KEYS
    st:=""
    if IsObject(dailyTestDriver) && HasMethod(dailyTestDriver,"ActionQuick")
        st:=dailyTestDriver.ActionQuick()
    else
        try st:=ReadGameActionQuick(pid)
    if !IsObject(st)
        return ""
    keys:=""
    if IsObject(dailyTestDriver) && HasMethod(dailyTestDriver,"QuickKeys")
        keys:=dailyTestDriver.QuickKeys()
    else
        try keys:=ReadGameQuickKeys(pid)
    manual:=StrSplit(DAILY_QUICK_KEYS,",")
    for i,s in st {
        if s.key="" || !InStr(GameItemName(s.key,pid),needle)
            continue
        ; 遊戲設定的鍵優先；那一格認不得（例如數字鍵盤）才用設定檔填的備用鍵
        k:=IsObject(keys) && i<=keys.Length ? keys[i] : ""
        if k=""
            k:=i<=manual.Length ? Trim(manual[i]) : ""
        return {slot:i,key:k}
    }
    return 0
}

; 要按哪個鍵用卡：用快捷欄裡實際的位置。讀不到快捷欄資料（舊的位置檔）就照舊按 fallback（Q / W）並寫進日誌；
; 讀得到、但快捷欄裡找不到這張卡就停止（不亂按：Q / W 那一格可能是別的道具）。
DailyCardKey(ctx, needle, fallback) {
    info:=DailyQuickInfo(ctx.pid,needle)
    if info="" {
        EventLog(ctx.name,"DAILY_WARN","讀不到道具快捷欄，照舊按 " StrUpper(fallback))
        return fallback
    }
    if !IsObject(info)
        throw Error("道具快捷欄裡找不到「" needle "」，請把它放到道具快捷欄（畫面下方 6 格）再執行")
    if info.key=""
        throw Error("「" needle "」放在道具快捷欄第 " info.slot " 格，但不知道這一格對應哪個鍵；請在設定檔 [DailyItems] QuickKeys 填入每一格的鍵")
    if info.key!=fallback
        DailyStep(ctx,"「" needle "」在快捷欄第 " info.slot " 格，改按 " StrUpper(info.key) "（不是 " StrUpper(fallback) "）")
    return info.key
}

; 傳送卡按鍵設定（「起點卡鍵~前點卡鍵~快捷欄各格鍵」）。鍵只接受單一字母 / 數字 / F1～F12。
DailyKeyOk(k) => RegExMatch(Trim(k),"i)^([a-z0-9]|F([1-9]|1[0-2]))$") ? true : false
DailySetCardKeys(rawValue) {
    global INI,DAILY_START_KEY,DAILY_PREV_KEY,DAILY_QUICK_KEYS
    parts:=StrSplit(rawValue,"~")
    if parts.Length<3
        return false
    s:=Trim(parts[1]),p:=Trim(parts[2]),quick:=""
    if !DailyKeyOk(s) || !DailyKeyOk(p)
        return false
    for k in StrSplit(parts[3],",") {
        k:=Trim(k)
        if k="" || !DailyKeyOk(k)
            return false
        quick.=(quick="" ? "" : ",") StrLower(k)
    }
    DAILY_START_KEY:=StrLower(s),DAILY_PREV_KEY:=StrLower(p),DAILY_QUICK_KEYS:=quick
    try {
        IniWrite DAILY_START_KEY,INI,"DailyItems","StartCardKey"
        IniWrite DAILY_PREV_KEY,INI,"DailyItems","PrevCardKey"
        IniWrite DAILY_QUICK_KEYS,INI,"DailyItems","QuickKeys"
    }
    AddRecentEvent("每日道具傳送卡按鍵：起點卡 " StrUpper(DAILY_START_KEY) "、前點卡 " StrUpper(DAILY_PREV_KEY) "｜快捷欄各格 " StrUpper(DAILY_QUICK_KEYS))
    return true
}

DailyTeleport(ctx, key, required:=true) {
    global DAILY_TELEPORT_TIMEOUT_MS
    pid:=ctx.pid
    before:=ReadGameMapId(pid)
    DailyKey(ctx,key)
    try {
        DailyWaitUntil(ctx,"按 " StrUpper(key) " 後地圖沒有改變",() => (m:=ReadGameMapId(pid))!="" && m!=before && GameCharacterLoaded(pid),DAILY_TELEPORT_TIMEOUT_MS)
    } catch as e {
        if required
            throw e
        EventLog(ctx.name,"DAILY_WARN",e.Message "｜請確認角色位置")
        return
    }
    Sleep 2500
}

; 開啟角色視窗（預設 C）與道具視窗（預設 I）。按鍵是開 / 關切換，所以每按一次都觀察
; 「實際切換的是哪個視窗」，依此修正按鍵對應，不會把已開好的視窗一直關掉。
DailyEnsureWindows(ctx) {
    keyFor:=Map("character_title","c","inventory_title","i")
    other:=Map("character_title","inventory_title","inventory_title","character_title")
    Loop 6 {
        state:=DailyWindowState(ctx)
        missing:=!state["character_title"] ? "character_title" : (!state["inventory_title"] ? "inventory_title" : "")
        if missing=""
            break
        key:=keyFor[missing]
        DailyKey(ctx,key)
        after:=state
        start:=A_TickCount
        while A_TickCount-start<2500 {
            after:=DailyWindowState(ctx)
            if after["character_title"]!=state["character_title"] || after["inventory_title"]!=state["inventory_title"]
                break
            Sleep 200
        }
        if after[missing]!=state[missing]
            continue
        swapped:=key="c" ? "i" : "c"
        if after[other[missing]]!=state[other[missing]] {
            ; 這個鍵切換的是另一個視窗 → 兩個鍵的對應相反
            keyFor[other[missing]]:=key,keyFor[missing]:=swapped
            EventLog(ctx.name,"DAILY_STEP","快捷鍵與預設相反：角色視窗 " StrUpper(keyFor["character_title"]) "、道具視窗 " StrUpper(keyFor["inventory_title"]))
        } else {
            keyFor[missing]:=swapped
        }
    }
    state:=DailyWindowState(ctx)
    for tpl,title in Map("character_title","角色詳情","inventory_title","裝備道具")
        if !state[tpl]
            throw Error("打不開「" title "」視窗（按 C / I 後畫面上找不到）")
    ctx.invKey:=keyFor["inventory_title"]
    x:=0,y:=0
    DailyFindTemplate(ctx,"character_title",&x,&y), ctx.charAnchor:=[x,y]
    DailyFindTemplate(ctx,"inventory_title",&x,&y), ctx.invAnchor:=[x,y]
    DailyClickRel(ctx,ctx.invAnchor,DAILY_INV_TAB_BAG,"Left")
}

DailyWindowState(ctx) {
    x:=0,y:=0
    return Map("character_title",DailyFindTemplate(ctx,"character_title",&x,&y)
        ,"inventory_title",DailyFindTemplate(ctx,"inventory_title",&x,&y))
}

; 遊戲畫面有一部分在螢幕外時（點不到也截不到），先移到所在螢幕內；結束後移回原位。
DailyEnsureOnScreen(ctx) {
    global dailyTestDriver
    if IsObject(dailyTestDriver)
        return
    WinGetPos(&wx,&wy,&ww,&wh,"ahk_id " ctx.hwnd)
    WinGetClientPos(&cx,&cy,&cw,&ch,"ahk_id " ctx.hwnd)
    mon:=DailyMonitorOf(cx+cw//2,cy+ch//2)
    MonitorGetWorkArea(mon,&ml,&mt,&mr,&mb)
    if cx>=ml && cy>=mt && cx+cw<=mr && cy+ch<=mb
        return
    nx:=Min(Max(wx,ml),mr-ww),ny:=Min(Max(wy,mt),mb-wh)
    ctx.movedFrom:=[wx,wy]
    WinMove nx,ny,,,"ahk_id " ctx.hwnd
    Sleep 500
    EventLog(ctx.name,"DAILY_STEP","遊戲視窗部分在螢幕外，暫時移到 (" nx "," ny ")，完成後移回")
}

DailyRestorePosition(ctx) {
    if ctx.HasOwnProp("movedFrom")
        try WinMove ctx.movedFrom[1],ctx.movedFrom[2],,,"ahk_id " ctx.hwnd
}

DailyMonitorOf(x,y) {
    Loop MonitorGetCount() {
        MonitorGet(A_Index,&l,&t,&r,&b)
        if x>=l && x<r && y>=t && y<b
            return A_Index
    }
    return MonitorGetPrimary()
}

; 失敗時保存遊戲畫面，方便確認停在哪裡。
DailySaveFailShot(ctx) {
    global dailyTestDriver
    if IsObject(dailyTestDriver)
        return ""
    try {
        WinGetClientPos(&cx,&cy,&cw,&ch,"ahk_id " ctx.hwnd)
        path:=A_ScriptDir "\Logs\DailyFail_" FormatTime(,"yyyyMMdd_HHmmss") "_" ctx.name ".png"
        CaptureScreenPng(cx,cy,cw,ch,path)
        return path
    }
    return ""
}

DailyTakePackFromBank(ctx) {
    pid:=ctx.pid
    ; 今天的禮包已打開的判斷用千手勳章（背包裡或已套上）：永久造型角色會留著沒開的服飾禮包，不能拿來判斷。
    ; v1.3.24.0：原地換時不過圖，昨天剩下的道具不會消失；背包裡已快到期的不算「今天已打開」。
    if DailyFindItem(pid,"每日分享禮包") || DailyHasToday(pid,"千手勳章") || DailyHasToday(pid,"頭飾造型")
        return
    ; 銀行內容是第一次打開銀行分頁時才向伺服器取得（重新登入後記憶體裡是空的）：先切到銀行分頁再讀。
    DailyClickRel(ctx,ctx.invAnchor,DAILY_INV_TAB_BANK,"Left")
    bank:=0
    try DailyWaitUntil(ctx,"",() => (bank:=DailyFindItem(pid,"每日分享禮包","BankOffset")),8000)
    if !bank {
        DailyClickRel(ctx,ctx.invAnchor,DAILY_INV_TAB_BAG,"Left")
        throw Error("銀行裡沒有每日分享禮包" (DailyInventory(pid,"BankOffset").Length ? ""
            : "（讀到的銀行是空的；若銀行其實有禮包，可能是還沒載入，請手動打開一次銀行分頁後再執行）"))
    }
    DailyStep(ctx,"從銀行取出每日分享禮包（銀行格子 " bank.x "," bank.y "）")
    Sleep 300
    DailyClickCell(ctx,bank,"Left",true,true)
    Sleep 500
    DailyClickRel(ctx,ctx.invAnchor,DAILY_INV_TAB_BAG,"Left")
    ; 若禮包被拿在滑鼠上，放到背包空格
    if DailyHeldName(pid)!=""
        DailyReleaseHeld(ctx)
    DailyWaitUntil(ctx,"每日分享禮包沒有移到背包",() => DailyFindItem(pid,"每日分享禮包"))
}

; 右鍵打開背包中的禮包；required=false 時找不到就略過。
DailyOpenItem(ctx, needle, products, required:=true) {
    pid:=ctx.pid
    s:=DailyFindItem(pid,needle)
    if !s {
        for prod in products
            if DailyHasAnywhere(pid,prod)
                return
        if !required || !products.Length
            return
        throw Error("背包裡找不到「" needle "」")
    }
    DailyStep(ctx,"打開 " GameItemName(s.key,pid))
    DailyClickCell(ctx,s,"Right")
    DailyWaitUntil(ctx,"「" needle "」沒有打開",() => !DailySameSlot(pid,s))
    for prod in products {
        ; AHK v2 的匿名函式抓不到 for 迴圈變數，先複製成一般區域變數
        expected:=prod
        DailyWaitUntil(ctx,"打開後沒有出現「" expected "」",() => DailyHasAnywhere(pid,expected))
    }
}

DailyMedal(ctx) {
    global DAILY_SLOT_MEDAL
    pid:=ctx.pid
    equip:=DailyEquip(pid)
    medal:=equip[DAILY_SLOT_MEDAL+1]
    if medal && DailyFresh(pid,medal,"千手勳章")
        return
    sticker:=DailyFindItem(pid,"千手勳章")
    if !sticker
        throw Error("背包裡找不到千手勳章")
    ; 上次中途停止時勳章已脫到背包：照紀錄套上貼紙後穿回
    if !medal {
        rec:=DailyRecordedUnequipped(ctx.name,DAILY_SLOT_MEDAL)
        if rec!="" && DailyFindItem(pid,rec) {
            DailyStep(ctx,"接續：勳章 " GameItemName(rec,pid) " 套上千手勳章")
            DailyApplyCostume(ctx,DAILY_SLOT_MEDAL,rec,sticker)
            return
        }
    }
    ; 沒有勳章（或只有昨天的貼紙）：直接把貼紙裝到勳章欄
    if !medal || InStr(GameItemName(medal.key,pid),"千手勳章") {
        DailyStep(ctx,"千手勳章直接裝到勳章欄")
        DailyClickCell(ctx,sticker,"Right")
        DailyWaitUntil(ctx,"千手勳章沒有裝上",() => (m:=DailyEquip(pid)[DAILY_SLOT_MEDAL+1]) && m.key=sticker.key && DailyFresh(pid,m,"千手勳章"))
        return
    }
    ; 有勳章：脫到背包 → 拿起貼紙 → 右鍵勳章（套上並穿回）
    DailyStep(ctx,"勳章 " GameItemName(medal.key,pid) " 套上千手勳章")
    DailyRecordUnequipped(ctx.name,DAILY_SLOT_MEDAL,medal.key)
    DailyClickChar(ctx,DAILY_SLOT_MEDAL,"Right")
    DailyWaitUntil(ctx,"勳章沒有脫下",() => !DailyEquip(pid)[DAILY_SLOT_MEDAL+1] && DailyFindItem(pid,medal.key))
    DailyApplyCostume(ctx,DAILY_SLOT_MEDAL,medal.key,DailyFindItem(pid,"千手勳章"))
}

DailyNecklace(ctx) {
    global DAILY_SLOT_NECK
    pid:=ctx.pid
    neck:=DailyEquip(pid)[DAILY_SLOT_NECK+1]
    if neck && DailyFresh(pid,neck,"暗夜項鍊")
        return
    ; v1.3.20.2：以今天新開的念珠＋暗夜項鍊為主，項鍊欄原本是什麼（昨天殘留的暗夜項鍊、舊念珠等）都直接換掉；
    ; 背包裡有好幾個時拿最新的那個（舊的殘留品不會被誤用）。
    beads:=DailyFindNewest(pid,"念珠")
    necklace:=DailyFindNewest(pid,"暗夜項鍊(1D)[")
    if !beads || !necklace
        throw Error("找不到念珠或暗夜項鍊")
    if neck
        DailyStep(ctx,"項鍊欄的 " GameItemName(neck.key,pid) " 換成今天的念珠＋暗夜項鍊")
    else
        DailyStep(ctx,"念珠裝到項鍊欄並套上暗夜項鍊")
    DailyApplyCostume(ctx,DAILY_SLOT_NECK,beads.key,necklace,beads)
}

DailyWeaponSticker(ctx) {
    global DAILY_WEAPON_CHOICE_INDEX,DAILY_CHOICE_ICON0,DAILY_CHOICE_STEP,DAILY_CHOICE_SELECT,DAILY_CHOICE_VISIBLE,DAILY_CONFIRM_YES
    pid:=ctx.pid
    kw:=DailyWeaponKw()
    weapon:=DailyEquip(pid)[6]
    if weapon && (DailyFresh(pid,weapon,"造型貼") || DailyPermanentCostume(pid,weapon))
        return
    if DailyFindCostume(pid,"造型貼")
        return
    ; 打開紀念造型服飾禮包後出現的「GT武器造型貼(1D)選擇盒」
    box:=DailyFindItem(pid,"選擇盒",,"武器")
    if !box
        throw Error("背包裡找不到 GT 武器造型貼選擇盒")
    DailyLearnWeaponBox(box.key)
    list:=GameBoxItems(pid,box.key)
    pick:=0
    for i,key in list
        if InStr(GameItemName(key,pid),kw) {
            pick:=i
            break
        }
    if pick {
        how:="第 " pick " 個（" GameItemName(list[pick],pid) "）"
    } else {
        ; 遊戲記憶體讀不到清單：改用示範錄製時的位置；領到後會確認名稱是不是雙槍
        pick:=DAILY_WEAPON_CHOICE_INDEX
        how:="第 " pick " 個（讀不到清單 " list.Length " 項，依錄製位置）"
    }
    if pick>DAILY_CHOICE_VISIBLE
        throw Error("「" kw "」在選擇清單第 " pick " 個，需要捲動，目前不支援")
    DailyStep(ctx,"武器選擇盒：選" how)
    DailyClickCell(ctx,box,"Right")
    anchor:=DailyWaitTemplate(ctx,"choice_title","右鍵選擇盒後沒有出現選擇箱視窗")
    DailyClickRel(ctx,anchor,[DAILY_CHOICE_ICON0[1]+(pick-1)*DAILY_CHOICE_STEP,DAILY_CHOICE_ICON0[2]],"Left")
    Sleep 300
    DailyClickRel(ctx,anchor,DAILY_CHOICE_SELECT,"Left")
    confirm:=DailyWaitTemplate(ctx,"confirm_take","沒有出現「領取物品？」確認視窗")
    DailyClickRel(ctx,confirm,DAILY_CONFIRM_YES,"Left")
    DailyWaitUntil(ctx,"選擇盒領取後背包沒有出現造型貼",() => !DailySameSlot(pid,box))
    ; 確認領到的是對應職業的武器造型貼（名稱含 WeaponKeyword）
    DailyWaitUntil(ctx,"領到的造型貼不是「" kw "」，請人工確認",() => DailyFindCostume(pid,"造型貼"))
}

DailyLearnWeaponBox(key) {
    global INI,DAILY_WEAPON_BOX_KEY
    if key=DAILY_WEAPON_BOX_KEY
        return
    DAILY_WEAPON_BOX_KEY:=key
    try IniWrite key,INI,"DailyItems","WeaponBoxKey"
}

; 武器選擇盒裡的選項（遊戲資料，依盒內順序）：[{name,index,ok}]；沒有任何一個遊戲開著 / 還不知道盒子的編號時回傳空陣列。
; ok = 在選擇視窗一次看得到的前幾個（後面的要捲動，目前不支援）。
DailyWeaponChoices() {
    global profiles,DAILY_WEAPON_BOX_KEY,DAILY_CHOICE_VISIBLE
    if DAILY_WEAPON_BOX_KEY=""
        return []
    for p in profiles {
        if !p.pid || !ProfileGameAlive(p) || !GameOffsetsReady(p.pid)
            continue
        out:=[]
        try {
            for i,key in GameBoxItems(p.pid,DAILY_WEAPON_BOX_KEY)
                out.Push({name:GameItemName(key,p.pid),index:i,ok:i<=DAILY_CHOICE_VISIBLE})
        }
        if out.Length
            return out
    }
    return []
}

DailyCostumes(ctx) {
    global DAILY_COSTUME_SLOTS,DAILY_CHAR_SLOTS
    pid:=ctx.pid
    equip:=DailyEquip(pid)
    todo:=[]
    for pair in DAILY_COSTUME_SLOTS {
        slot:=pair[1],needle:=pair[2]
        if !DailyWantsSlot(ctx.p,slot)
            continue
        e:=equip[slot+1]
        if e && (DailyFresh(pid,e,needle) || DailyPermanentCostume(pid,e))
            continue
        if !DailyFindCostume(pid,needle)
            throw Error("背包裡找不到「" needle "」")
        ; 欄位是空的 = 上次中途停止時已脫到背包，找回原本的裝備
        todo.Push({slot:slot,needle:needle,itemKey:e ? e.key : DailyFindUnequipped(ctx,slot)})
    }
    if !todo.Length
        return
    ; 先記下每一欄原本的裝備，中途停止時下次可以正確穿回（不會誤拿背包裡的備用裝備）
    for t in todo
        DailyRecordUnequipped(ctx.name,t.slot,t.itemKey)
    ; 1) 脫下：依錄製的位置右鍵，用記憶體確認「有一件脫下」即可（不假設位置與欄位一一對應，
    ;    例如褲子 / 手套的位置若對調也能完成）。第二輪改點尚未用過的位置。
    DailyStep(ctx,"脫下 " todo.Length " 件裝備")
    ; 先快速把每一欄各右鍵一次（不逐件等待），再一次確認；沒脫下的交給下面原本逐件確認的流程補做。
    for t in todo {
        if DailyEquip(pid)[t.slot+1]
            DailyClickChar(ctx,t.slot,"Right",90)
    }
    try DailyWaitUntil(ctx,"",() => DailyCountEmpty(pid,todo)>=todo.Length,2500)
    used:=Map()
    Loop 2 {
        secondPass:=A_Index=2
        for t in todo {
            if !DailyEquip(pid)[t.slot+1]
                continue
            candidates:=[]
            if !secondPass
                candidates.Push(t.slot)
            else
                for c in todo
                    if !used.Has(c.slot)
                        candidates.Push(c.slot)
            for pos in candidates {
                emptyBefore:=DailyCountEmpty(pid,todo)
                DailyClickChar(ctx,pos,"Right")
                try {
                    DailyWaitUntil(ctx,"",() => DailyCountEmpty(pid,todo)>emptyBefore,secondPass ? 1500 : 0)
                    used[pos]:=true
                    break
                }
            }
        }
    }
    for t in todo
        if DailyEquip(pid)[t.slot+1]
            throw Error(GAME_EQUIP_SLOT_NAMES[t.slot+1] "沒有脫下")
    ; 2) 每件：左鍵拿起造型 → 右鍵背包中的裝備（套上並穿回）
    for t in todo {
        DailyStep(ctx,GAME_EQUIP_SLOT_NAMES[t.slot+1] " 套上 " t.needle)
        DailyApplyCostume(ctx,t.slot,t.itemKey,DailyFindCostume(pid,t.needle))
    }
}

; 左鍵拿起造型 → 右鍵背包中的裝備；確認裝備回到 slot 且套上造型。
DailyApplyCostume(ctx, slot, itemKey, costume, item:=0) {
    pid:=ctx.pid
    if !costume
        throw Error(GAME_EQUIP_SLOT_NAMES[slot+1] "：找不到要套的造型")
    if !item
        item:=DailyFindItem(pid,itemKey)
    if !item
        throw Error(GAME_EQUIP_SLOT_NAMES[slot+1] "：背包裡找不到 " GameItemName(itemKey,pid))
    DailyClickCell(ctx,costume,"Left",true,false,120)
    DailyWaitUntil(ctx,"沒有拿起 " GameItemName(costume.key,pid),() => DailyHeldKey(pid)=costume.key)
    DailyClickCell(ctx,item,"Right",true,false,120)
    DailyWaitUntil(ctx,GAME_EQUIP_SLOT_NAMES[slot+1] "沒有套上 " GameItemName(costume.key,pid)
        ,() => (e:=DailyEquip(pid)[slot+1]) && e.key=itemKey && e.disguiseKey=costume.key)
}

DailyCloseWindows(ctx) {
    x:=0,y:=0
    try DailyBackToFirstPage(ctx)
    Loop 4 {
        if !DailyFindTemplate(ctx,"inventory_title",&x,&y) && !DailyFindTemplate(ctx,"character_title",&x,&y)
            return
        DailyKey(ctx,"Escape")
        Sleep 400
    }
}

; 失敗 / 中止時：滑鼠上拿著道具就放到背包空格。
DailyReleaseHeld(ctx) {
    pid:=ctx.pid
    try {
        if DailyHeldName(pid)="" || !IsObject(ctx.invAnchor)
            return
        st:=DailyInvUi(pid)
        cell:=DailyFreeCell(pid,IsObject(st) && st.page>0 ? st.page : 0)   ; 優先放在目前這一頁（F10 中止時不一定換得了頁）
        if IsObject(cell)
            DailyClickCell(ctx,cell,"Left",false)
    }
}

; ---------------------------------------------------------------------------
; 記憶體查詢
; ---------------------------------------------------------------------------

DailyEquip(pid) {
    Loop 5 {
        e:=ReadGameEquipment(pid)
        if IsObject(e)
            return e
        Sleep 100
    }
    throw Error("無法讀取裝備欄")
}

DailyInventory(pid, invenKey:="InvenOffset") {
    Loop 5 {
        s:=ReadGameInventorySlots(pid,invenKey)
        if IsObject(s)
            return s
        Sleep 100
    }
    throw Error("無法讀取背包")
}

; needle 為 "主ID-子ID" 時比對 ID，否則比對名稱；also 為額外必須包含的字。
DailyFindItem(pid, needle, invenKey:="InvenOffset", also:="") {
    byKey:=RegExMatch(needle,"^\d+-\d+$")
    for s in DailyInventory(pid,invenKey) {
        if byKey ? s.key=needle : InStr(GameItemName(s.key,pid),needle) {
            if also="" || InStr(GameItemName(s.key,pid),also)
                return s
        }
    }
    return 0
}

; 名稱包含 needle 的道具中最新取得的一個（排除禮盒）；找不到回傳 0。
DailyFindNewest(pid, needle) {
    best:=0
    for s in DailyInventory(pid) {
        name:=GameItemName(s.key,pid)
        if InStr(name,needle) && !InStr(name,"禮") && (!best || s.born>best.born)
            best:=s
    }
    return best
}

; 背包中的一日造型（排除禮盒 / 選擇盒；武器貼紙只找符合職業武器的）。
DailyFindCostume(pid, needle) {
    kw:=DailyWeaponKw()
    for s in DailyInventory(pid) {
        name:=GameItemName(s.key,pid)
        if !InStr(name,needle) || InStr(name,"禮") || InStr(name,"選擇盒")
            continue
        if needle="造型貼" && !InStr(name,kw)
            continue
        return s
    }
    return 0
}

; 今天的道具已經存在：在背包裡，或已穿在身上且剩餘時間足夠（昨天快到期的不算）。
DailyHasAnywhere(pid, needle) {
    if DailyFindItem(pid,needle)
        return true
    for e in DailyEquip(pid)
        if e && DailyFresh(pid,e,needle)
            return true
    return false
}

; 同 DailyHasAnywhere，但背包裡的道具也要是今天的：有時間限制且快到期（昨天剩下的）不算。
; 讀不到時間限制的道具照舊視為今天的（和舊版相同）。
DailyHasToday(pid, needle) {
    global DAILY_FRESH_SEC
    now:=UnixNow()
    for s in DailyInventory(pid) {
        if !InStr(GameItemName(s.key,pid),needle)
            continue
        limit:=GameItemTimeLimit(pid,s.key)
        if limit<=0 || !s.born || s.born+limit-now>DAILY_FRESH_SEC
            return true
    }
    for e in DailyEquip(pid)
        if e && DailyFresh(pid,e,needle)
            return true
    return false
}

; 裝備欄的一日項目（裝備本身或造型名稱包含 needle）仍有足夠剩餘時間 = 今天已更換。
DailyFresh(pid, e, needle) {
    global DAILY_FRESH_SEC
    now:=UnixNow()
    if e.disguiseKey!="" && InStr(GameItemName(e.disguiseKey,pid),needle) && e.disguiseTime-now>DAILY_FRESH_SEC
        return true
    if InStr(GameItemName(e.key,pid),needle) {
        limit:=GameItemTimeLimit(pid,e.key)
        if limit>0 && e.born+limit-now>DAILY_FRESH_SEC
            return true
    }
    return false
}

; 裝備已套上永久（或超過一天）的造型：這一欄不換一日造型，避免蓋掉永久造型。
; 已到期的一日造型回城後會消失，不會被當成永久。
DailyPermanentCostume(pid, e) {
    global DAILY_ITEM_MAX_LIMIT
    if !e || e.disguiseKey=""
        return false
    limit:=GameItemTimeLimit(pid,e.disguiseKey)
    return e.disguiseTime=0 || limit=0 || limit>DAILY_ITEM_MAX_LIMIT
}

; 有哪些欄位需要換一日造型（排除已換好、套著永久造型的欄位）。
DailyCostumeSlotsNeeded(pid, p:=0) {
    global DAILY_COSTUME_SLOTS
    equip:=DailyEquip(pid),need:=[]
    for pair in DAILY_COSTUME_SLOTS {
        if IsObject(p) && !DailyWantsSlot(p,pair[1])
            continue
        e:=equip[pair[1]+1]
        if !(e && (DailyFresh(pid,e,pair[2]) || DailyPermanentCostume(pid,e)))
            need.Push(pair)
    }
    return need
}

DailySameSlot(pid, s) {
    for t in DailyInventory(pid)
        if t.x=s.x && t.y=s.y && t.key=s.key && t.count=s.count
            return true
    return false
}

DailyCountEmpty(pid, todo) {
    equip:=DailyEquip(pid),n:=0
    for t in todo
        if !equip[t.slot+1]
            n+=1
    return n
}

DailyHeldKey(pid) {
    global DAILY_SLOT_HOLD
    held:=DailyEquip(pid)[DAILY_SLOT_HOLD+1]
    return held ? held.key : ""
}

DailyHeldName(pid) {
    key:=DailyHeldKey(pid)
    return key="" ? "" : GameItemName(key,pid)
}

; 找第一個空格。prefPage > 0 時先找那一頁（目前停在哪一頁就放那頁，免得為了放東西還要換頁）；
; 沒有再從第 1 頁找起（點的時候會自動換頁）。最下面打叉的列不算。
DailyFreeCell(pid, prefPage:=0) {
    global DAILY_INV_COLS,DAILY_INV_ROWS_PER_PAGE
    used:=Map()
    for s in DailyInventory(pid)
        used[s.x "," s.y]:=true
    rows:=DailyUsableRows(pid)
    order:=[]
    if prefPage>0
        Loop DAILY_INV_ROWS_PER_PAGE
            order.Push((prefPage-1)*DAILY_INV_ROWS_PER_PAGE+A_Index-1)
    Loop rows
        order.Push(A_Index-1)
    for y in order {
        if y>=rows
            continue
        Loop DAILY_INV_COLS {
            x:=A_Index-1
            if !used.Has(x "," y)
                return {x:x,y:y}
        }
    }
    return 0
}
; ---------------------------------------------------------------------------
; 操作
; ---------------------------------------------------------------------------

DailyStep(ctx, text) {
    global Status
    EventLog(ctx.name,"DAILY_STEP",text)
    try Status.Text:="狀態：" ctx.name "｜每日道具｜" text
}

DailyCheckAbort() {
    global abortRequested
    if abortRequested
        throw Error("F10 / 停止監控：已中止")
}

DailyKey(ctx, key, checkAbort:=true) {
    global dailyTestDriver
    if checkAbort
        DailyCheckAbort()
    if IsObject(dailyTestDriver)
        return dailyTestDriver.Key(key)
    ctx.pageOkAt:=0   ; 按鍵可能開關視窗 / 重設頁數：之前的分頁確認作廢
    EnsureRecoveryFocus(ctx.hwnd,ctx.name)
    SendOneKey(key)
    Sleep 300
}
DailyClickClient(ctx, x, y, button, checkAbort:=true, post:=350) {
    global dailyTestDriver
    if checkAbort
        DailyCheckAbort()
    if IsObject(dailyTestDriver)
        return dailyTestDriver.Click(x,y,button)
    EnsureRecoveryFocus(ctx.hwnd,ctx.name)
    WinGetClientPos(&cx,&cy,,,"ahk_id " ctx.hwnd)
    MouseMove cx+x,cy+y,2
    Sleep 90
    Click button
    Sleep post
}

DailyClickRel(ctx, anchor, offset, button) {
    DailyClickClient(ctx,anchor[1]+offset[1],anchor[2]+offset[2],button)
}

; bank = true：銀行的格子（銀行分頁沒有背包的分頁，維持只能點第一頁的可見列）。
DailyClickCell(ctx, slot, button, checkAbort:=true, bank:=false, post:=350) {
    global DAILY_INV_CELL0,DAILY_INV_STEP,DAILY_INV_VISIBLE_ROWS,DAILY_INV_ROWS_PER_PAGE
    if bank {
        if slot.y>=DAILY_INV_VISIBLE_ROWS
            throw Error("道具在銀行第 " slot.y+1 " 列，超出可見範圍")
        DailyEnsureInventoryVisible(ctx,checkAbort)
        row:=slot.y
    } else {
        st:=DailyInvUi(ctx.pid)
        if !IsObject(st) {
            ; 讀不到分頁資料：只能操作第 1 頁的可見列（跟以前一樣），其他一律停止並說明
            if slot.y<0 || slot.y>=DAILY_INV_VISIBLE_ROWS
                throw Error("道具在背包第 " slot.y+1 " 列，但讀不到背包分頁資料（遊戲位置檔需要更新），無法換頁")
        } else if slot.y<0 || slot.y>=DailyUsableRows(ctx.pid)
            throw Error("道具在背包第 " slot.y+1 " 列，超出可用範圍（最下面打叉的列不能放東西）")
        DailyEnsureInventoryVisible(ctx,checkAbort)
        DailyEnsurePage(ctx,DailyInvPageOf(slot.y),checkAbort,true)   ; 先叫回最上層、再換頁（重新開啟會重設頁數）
        row:=Mod(slot.y,DAILY_INV_ROWS_PER_PAGE)
    }
    DailyClickClient(ctx,ctx.invAnchor[1]+DAILY_INV_CELL0[1]+slot.x*DAILY_INV_STEP
        ,ctx.invAnchor[2]+DAILY_INV_CELL0[2]+row*DAILY_INV_STEP,button,checkAbort,post)
}

; 背包可以放東西的列數：讀得到就用遊戲說的（46：最後一頁最下面 4 列是打叉的）；
; 讀得到分頁但沒有列數 = 保守算前 4 頁（40 列）；讀不到分頁資料 = 只有第 1 頁（跟以前一樣）。
DailyUsableRows(pid) {
    global DAILY_INV_ROWS_PER_PAGE,DAILY_INV_VISIBLE_ROWS
    st:=DailyInvUi(pid)
    if !IsObject(st)
        return DAILY_INV_VISIBLE_ROWS
    return st.rows>0 ? st.rows : 4*DAILY_INV_ROWS_PER_PAGE
}

DailyInvPageOf(y) {
    global DAILY_INV_ROWS_PER_PAGE
    return y//DAILY_INV_ROWS_PER_PAGE+1
}

; 背包分頁狀態（記憶體）：{open, page, count, rows, btns}；沒有這組位置資料 / 讀不到回傳 ""。
DailyInvUi(pid) {
    global dailyTestDriver
    if IsObject(dailyTestDriver) && HasMethod(dailyTestDriver,"InvUi")
        return dailyTestDriver.InvUi()
    st:=""
    try st:=ReadGameInvUi(pid)
    return st
}

; 目前頁「連續兩次讀到一樣」才採信（遊戲換頁 / 重新開啟後記憶體要一下子才更新，只讀一次可能讀到舊的）。
; 讀不到、兩次不一樣、沒有被選取的頁都回傳 0。
DailyStablePage(pid) {
    global DAILY_PAGE_CONFIRM_MS
    a:=DailyInvUi(pid)
    if !IsObject(a)
        return 0
    if DAILY_PAGE_CONFIRM_MS>0
        Sleep DAILY_PAGE_CONFIRM_MS
    b:=DailyInvUi(pid)
    return IsObject(b) && a.page=b.page ? a.page : 0
}

; 背包切到第 page 頁：先確認道具視窗在最上層（visibleChecked 表示呼叫端剛確認過）、點頁籤（座標從記憶體讀，
; 不靠畫面辨識），再讀記憶體確認真的換過去了（連續兩次一樣）。點了沒換就重試，最多 3 次。
; checkAbort = false：失敗 / 中止後要把滑鼠上的道具放回去時用，不被 F10 打斷。
; 第 1 頁讀不到分頁資料時照舊（以前就只能操作第 1 頁）；其他頁讀不到就停止，不亂點。
DailyEnsurePage(ctx, page, checkAbort:=true, visibleChecked:=false) {
    global DAILY_PAGE_WAIT_MS
    st:=DailyInvUi(ctx.pid)
    if !IsObject(st) {
        if page=1
            return
        throw Error("道具在背包第 " page " 頁，但讀不到背包分頁資料（遊戲位置檔需要更新），無法換頁")
    }
    if page<1 || page>st.count
        throw Error("背包沒有第 " page " 頁")
    if !visibleChecked
        DailyEnsureInventoryVisible(ctx,checkAbort)
    ; 剛確認過就是這一頁、中間沒有按過鍵 / 換過頁：只再讀一次確認，不用每次都等 150ms 做「連續兩次一樣」
    if ctx.HasOwnProp("pageOkAt") && ctx.pageOkAt && A_TickCount-ctx.pageOkAt<4000 && st.page=page
        return
    tries:=0
    Loop {
        if DailyStablePage(ctx.pid)=page {
            ctx.pageOkAt:=A_TickCount
            return
        }
        ctx.pageOkAt:=0
        if tries>=3
            throw Error("背包切不到第 " page " 頁（點了頁籤但沒有換過去）")
        tries+=1
        cur:=DailyInvUi(ctx.pid)
        btn:=IsObject(cur) ? cur.btns[page] : 0
        if !IsObject(btn)
            throw Error("讀不到背包第 " page " 頁的頁籤位置")
        DailyStep(ctx,"背包換到第 " page " 頁")
        DailyClickClient(ctx,Round((btn.l+btn.r)/2),Round((btn.t+btn.b)/2),"Left",checkAbort)
        start:=A_TickCount
        while A_TickCount-start<DAILY_PAGE_WAIT_MS {
            if DailyStablePage(ctx.pid)=page
                return
            Sleep 100
        }
    }
}

; 結束前回到第 1 頁（下次打開背包才不會停在別頁）；背包沒開、已在第 1 頁或讀不到都不動。失敗不影響結果。
DailyBackToFirstPage(ctx) {
    st:=DailyInvUi(ctx.pid)
    if IsObject(st) && st.open && st.page>1
        DailyEnsurePage(ctx,1)
}
; 道具視窗與角色視窗重疊時，點了角色視窗後道具視窗會被蓋住（仍是開啟狀態）。
; 點背包格子前先確認看得到；看不到就按 I（關掉再打開會回到最上層），並重新定位。
DailyEnsureInventoryVisible(ctx, checkAbort:=true) {
    global DAILY_INV_TAB_BAG
    x:=0,y:=0
    ; 道具視窗上次在哪就先只找那附近（小範圍比整個畫面快很多）；附近沒有才找整個畫面
    near:=""
    if ctx.HasOwnProp("invAnchor") && IsObject(ctx.invAnchor)
        near:=[ctx.invAnchor[1]-12,ctx.invAnchor[2]-12,ctx.invAnchor[1]+300,ctx.invAnchor[2]+70]
    if (IsObject(near) && DailyFindTemplate(ctx,"inventory_title",&x,&y,near)) || DailyFindTemplate(ctx,"inventory_title",&x,&y) {
        ctx.invAnchor:=[x,y]
        return
    }
    key:=ctx.HasOwnProp("invKey") ? ctx.invKey : "i"
    Loop 3 {
        DailyKey(ctx,key,checkAbort)
        Sleep 400
        if DailyFindTemplate(ctx,"inventory_title",&x,&y) {
            ctx.invAnchor:=[x,y]
            EventLog(ctx.name,"DAILY_STEP","道具視窗被角色視窗蓋住，已重新叫到最上層")
            ; 重新開啟後可能停在銀行分頁，切回背包
            DailyClickClient(ctx,x+DAILY_INV_TAB_BAG[1],y+DAILY_INV_TAB_BAG[2],"Left",checkAbort)
            return
        }
    }
    throw Error("道具視窗被蓋住，無法叫回最上層")
}

DailyClickChar(ctx, slot, button, post:=350) {
    global DAILY_CHAR_SLOTS
    DailyClickClient(ctx,ctx.charAnchor[1]+DAILY_CHAR_SLOTS[slot][1],ctx.charAnchor[2]+DAILY_CHAR_SLOTS[slot][2],button,true,post)
}

; 在遊戲畫面中尋找辨識圖（遊戲視窗需在最上層）；找到時回傳 true 並寫入左上角座標。
DailyFindTemplate(ctx, name, &x, &y, region:="") {
    global DAILY_TPL_DIR,DAILY_CLIENT_W,DAILY_CLIENT_H,dailyTestDriver
    if IsObject(dailyTestDriver)
        return dailyTestDriver.Find(name,&x,&y)
    EnsureRecoveryFocus(ctx.hwnd,ctx.name)
    CoordMode "Pixel","Client"
    try {
        if IsObject(region)
            return ImageSearch(&x,&y,Max(0,region[1]),Max(0,region[2]),Min(DAILY_CLIENT_W,region[3]),Min(DAILY_CLIENT_H,region[4]),"*60 " DAILY_TPL_DIR "\" name ".bmp")
        return ImageSearch(&x,&y,0,0,DAILY_CLIENT_W,DAILY_CLIENT_H,"*60 " DAILY_TPL_DIR "\" name ".bmp")
    }
    catch
        return false
}

DailyWaitTemplate(ctx, name, failText, timeoutMs:=6000) {
    x:=0,y:=0
    start:=A_TickCount
    while A_TickCount-start<timeoutMs {
        DailyCheckAbort()
        if DailyFindTemplate(ctx,name,&x,&y)
            return [x,y]
        Sleep 200
    }
    throw Error(failText)
}

DailyWaitUntil(ctx, failText, check, timeoutMs:=0) {
    global DAILY_STEP_TIMEOUT_MS
    timeoutMs:=timeoutMs ? timeoutMs : DAILY_STEP_TIMEOUT_MS
    start:=A_TickCount
    loop {
        DailyCheckAbort()
        try {
            if check()
                return
        }
        if A_TickCount-start>timeoutMs
            throw Error(failText)
        Sleep 60
    }
}
