; ============================================================================
; DailyItems：每日道具（一日道具）。
;
; v1.3.15.0 匯出診斷資料。v1.3.16.0 依實際資料確認：
; - 一日造型（頭/衣/褲/手套/鞋/武器貼、暗夜項鍊、勳章貼紙）的 tDISGUISE 就是到期時間。
; - 一日道具本身（例如 4倍歸魂修煉念珠[1D]）的到期時間 = 取得時間 + 時間限制。
; 角色的「每日道具到期時間」取所有一日項目中最早的一個；到期 DAILY_DELAY_MIN 分鐘後提醒更換。
; 這一版只提醒、不操作遊戲；自動更換等示範錄製完成後再加入。
; ============================================================================

global DAILY_ENABLED := Integer(IniRead(INI,"DailyItems","Enabled","1"))
global DAILY_DELAY_MIN := Integer(IniRead(INI,"DailyItems","DelayMinutes","5"))
global DAILY_SNOOZE_MIN := 10
global DAILY_TICK_MS := 30000
global DAILY_ITEM_MAX_LIMIT := 86400     ; 時間限制 ≤ 1 天的造型 / 道具視為每日道具
global DAILY_PACK_NAME := "每日分享禮包"
global dailyPopup := 0
global dailyPopupDue := []
global dailyPopupIdleText := 0

UnixNow() => DateDiff(A_NowUTC,"19700101000000","Seconds")

; 角色身上每日道具最早的到期時間（time_t）；沒有穿戴每日道具回傳 0；讀取失敗回傳 ""。
; v1.3.24.0：傳入角色時只看這個程式會更換、且這個角色有勾選的欄位（沒勾的、程式不換的一日道具
; 過期不會一直提醒；原地換時它們不會因過圖消失）。
DailyItemsExpiry(pid, p:=0) {
    global DAILY_ITEM_MAX_LIMIT,DAILY_SLOT_OPTION
    equip:=ReadGameEquipment(pid)
    if !IsObject(equip)
        return ""
    earliest:=0
    for i,s in equip {
        if !s || IsObject(p) && !(DAILY_SLOT_OPTION.Has(i-1) && DailyWants(p,DAILY_SLOT_OPTION[i-1]))
            continue
        if s.disguiseKey!="" && s.disguiseTime>0 {
            limit:=GameItemTimeLimit(pid,s.disguiseKey)
            if limit>0 && limit<=DAILY_ITEM_MAX_LIMIT && (!earliest || s.disguiseTime<earliest)
                earliest:=s.disguiseTime
        }
        limit:=GameItemTimeLimit(pid,s.key)
        if limit>0 && limit<=DAILY_ITEM_MAX_LIMIT && s.born>0 && (!earliest || s.born+limit<earliest)
            earliest:=s.born+limit
    }
    return earliest
}

DailyPackCount(pid) {
    global DAILY_PACK_NAME
    slots:=ReadGameInventorySlots(pid,"BankOffset")
    if !IsObject(slots)
        return ""
    ; 銀行內容要打開一次銀行分頁才會載入（重新登入後是空的）：完全沒有東西視為「尚未載入」。
    if !slots.Length
        return -2
    n:=0
    for s in slots
        if InStr(GameItemName(s.key,pid),DAILY_PACK_NAME)
            n+=s.count
    return n
}

; 每 30 秒更新各角色的每日道具狀態；到期 DAILY_DELAY_MIN 分鐘後跳出提醒。
DailyItemsTick() {
    global profiles,DAILY_ENABLED,DAILY_DELAY_MIN,recorder,dailyRunning
    if !DAILY_ENABLED
        return
    now:=UnixNow()
    due:=[]
    for i,p in profiles {
        if !p.enabled || !p.pid || !ProfileGameAlive(p) || !GameOffsetsReady(p.pid) || !GameCharacterLoaded(p.pid)
            continue
        if DailyItemsOf(p)=""
            continue
        expiry:=DailyItemsExpiry(p.pid,p)
        if expiry=""
            continue
        packs:=DailyPackCount(p.pid)
        if packs=-2 {
            ; 尚未載入：保留這次程式執行期間最後讀到的數量，標示為未更新
            p.dailyPacksStale:=1
        } else if packs!="" {
            p.dailyPacks:=packs,p.dailyPacksStale:=0
        }
        ; 到期時間改變（換上新的每日道具）→ 新的一輪，清除提醒紀錄
        if !p.HasOwnProp("dailyExpiry") || p.dailyExpiry!=expiry {
            p.dailyExpiry:=expiry,p.dailyAcked:=0,p.dailySnoozeUntil:=0
            EventLog(p.name,"DAILY_EXPIRY",expiry ? "每日道具到期 " GameTimeText(expiry,"MM-dd HH:mm") "｜預定 " GameTimeText(expiry+DAILY_DELAY_MIN*60,"HH:mm") " 更換" : "未穿戴每日道具")
        }
        if p.dailyAcked || now<p.dailySnoozeUntil || p.state!="監控中" || dailyRunning=p.name
            continue
        if (!expiry || now>=expiry+DAILY_DELAY_MIN*60) && !DailyRecentlyDone(p)
            due.Push(i)
    }
    if due.Length && !IsObject(recorder)
        DailyItemsRemind(due)
}

DailyStatusText(p) {
    global DAILY_DELAY_MIN
    if DailyItemsOf(p)=""
        return "不更換（角色設定）"
    if !p.HasOwnProp("dailyExpiry")
        return "讀取中"
    if (!p.dailyExpiry || p.dailyExpiry<=UnixNow()) && DailyRecentlyDone(p)
        return "今天已更換（" GameTimeText(DailyDoneAt(p),"HH:mm") "）"
    if !p.dailyExpiry
        return "未穿戴每日道具"
    remain:=p.dailyExpiry-UnixNow()
    if remain>0
        return "有效（剩 " Floor(remain/3600) " 小時 " Floor(Mod(remain,3600)/60) " 分）"
    return remain>-DAILY_DELAY_MIN*60 ? "已到期，" DAILY_DELAY_MIN " 分鐘後提醒" : "已到期，等待更換"
}

; 提醒視窗：不搶焦點（自動登入或遊戲操作中不會被打斷）。
; AutoRun=1 時，視窗出現後鍵盤滑鼠（實體操作）連續 IdleSeconds 秒沒有動作就自動開始更換。
; v1.3.20.3：另外，視窗出現 PopupTimeoutSec 秒都沒有人點選任何選項，也自動開始更換
; （開始前鍵鼠需靜止 DAILY_POPUP_QUIET_SEC 秒，避免和正在操作的人搶滑鼠）。
DailyItemsRemind(due) {
    global profiles,dailyPopup,dailyPopupDue,dailyPopupIdleText,dailyRunning,dailyRunQueue,dailyPopupStart
    global DAILY_SNOOZE_MIN,DAILY_AUTORUN,DAILY_IDLE_SEC,DAILY_POPUP_TIMEOUT_SEC
    if IsObject(dailyPopup) || dailyRunning!="" || dailyRunQueue.Length
        return
    names:="",lines:=""
    for i in due {
        p:=profiles[i]
        names.=(names="" ? "" : "、") p.name
        lines.="・" p.name "：" (p.dailyExpiry ? GameTimeText(p.dailyExpiry,"MM-dd HH:mm") " 已到期" : "尚未穿戴每日道具") "`n"
    }
    EventLog("GLOBAL","DAILY_REMIND","提醒更換每日道具｜" names "｜AutoRun=" DAILY_AUTORUN)
    AddRecentEvent("🎁 每日道具需要更換：" names)
    auto:=DAILY_AUTORUN || DAILY_POPUP_TIMEOUT_SEC>0
    try SendDiscordMessage("🎁 HIHIYONG 每日道具需要更換`n" lines
        . (DAILY_POPUP_TIMEOUT_SEC>0 ? DAILY_POPUP_TIMEOUT_SEC " 秒內沒有人點選提醒視窗就會自動更換。"
        : DAILY_AUTORUN ? "無人操作 " DAILY_IDLE_SEC " 秒後將自動更換。" : ""))
    SoundBeep 880,200

    dailyPopupDue:=due
    dailyPopupStart:=A_TickCount
    dailyPopup:=Gui("+AlwaysOnTop +ToolWindow +E0x08000000","每日道具提醒")
    dailyPopup.SetFont("s10","Microsoft JhengHei")
    note:=DAILY_POPUP_TIMEOUT_SEC>0
        ? "`n" DAILY_POPUP_TIMEOUT_SEC " 秒內沒有點選任何按鈕，就會自動開始更換（F10 可隨時中止）。"
        . "`n自己要換的話，請按「我自己換」。"
        : DAILY_AUTORUN
        ? "`n即將自動更換，請不要操作鍵盤滑鼠。`n" DAILY_IDLE_SEC " 秒內沒有任何鍵鼠操作就會自動開始（F10 可隨時中止）。"
        : "`n可以按「立即更換」由程式自動完成，或自己手動更換。"
    dailyPopup.AddText("w380","以下角色的每日道具需要更換：`n`n" lines note)
    dailyPopupIdleText:=dailyPopup.AddText("w380 cRed",auto ? DailyPopupCountdownText(0,0) : "")
    dailyPopup.AddButton("w120 Default","立即更換").OnEvent("Click",(*)=>DailyItemsCloseRemind("run"))
    dailyPopup.AddButton("x+10 w120","我自己換").OnEvent("Click",(*)=>DailyItemsCloseRemind("self"))
    dailyPopup.AddButton("x+10 w120",DAILY_SNOOZE_MIN " 分鐘後再說").OnEvent("Click",(*)=>DailyItemsCloseRemind("snooze"))
    dailyPopup.OnEvent("Close",(*)=>DailyItemsCloseRemind("snooze"))
    dailyPopup.Show("NoActivate")
    if auto {
        ; 只計算實體鍵鼠操作；程式自己送出的按鍵（視窗切換等）不會重置閒置時間。
        InstallKeybdHook()
        InstallMouseHook()
        SetTimer DailyPopupTick,1000
    }
}

DailyPopupCountdownText(elapsed, idle) {
    global DAILY_AUTORUN,DAILY_IDLE_SEC,DAILY_POPUP_TIMEOUT_SEC,DAILY_POPUP_QUIET_SEC
    if DAILY_POPUP_TIMEOUT_SEC>0 {
        left:=DAILY_POPUP_TIMEOUT_SEC-elapsed
        if left>0
            return "⏳ " left " 秒後自動開始更換"
        return "⏳ 等鍵盤滑鼠停下 " DAILY_POPUP_QUIET_SEC " 秒後自動開始"
    }
    return "目前已閒置 " idle " 秒（達 " DAILY_IDLE_SEC " 秒自動開始）"
}

DailyPopupTick() {
    global dailyPopup,dailyPopupIdleText,dailyPopupStart,DAILY_AUTORUN,DAILY_IDLE_SEC,DAILY_POPUP_TIMEOUT_SEC,DAILY_POPUP_QUIET_SEC,dailyIdleMs
    if !IsObject(dailyPopup) {
        SetTimer DailyPopupTick,0
        return
    }
    idle:=dailyIdleMs()//1000
    elapsed:=(A_TickCount-dailyPopupStart)//1000
    try dailyPopupIdleText.Text:=DailyPopupCountdownText(elapsed,idle)
    if DAILY_AUTORUN && idle>=DAILY_IDLE_SEC
        return DailyItemsCloseRemind("run")
    ; 沒有人點選：時間到、而且鍵鼠剛好沒在動（不和正在操作的人搶滑鼠）就自動開始
    if DAILY_POPUP_TIMEOUT_SEC>0 && elapsed>=DAILY_POPUP_TIMEOUT_SEC && idle>=DAILY_POPUP_QUIET_SEC {
        EventLog("GLOBAL","DAILY_POPUP_TIMEOUT","提醒視窗 " elapsed " 秒沒有人點選，自動開始更換")
        DailyItemsCloseRemind("run")
    }
}

DailyItemsCloseRemind(mode) {
    global profiles,dailyPopup,dailyPopupDue,DAILY_SNOOZE_MIN
    SetTimer DailyPopupTick,0
    due:=dailyPopupDue
    for i in due {
        if mode="snooze"
            profiles[i].dailySnoozeUntil:=UnixNow()+DAILY_SNOOZE_MIN*60
        else if mode="self"
            profiles[i].dailyAcked:=1
    }
    try dailyPopup.Destroy()
    dailyPopup:=0,dailyPopupDue:=[]
    if mode="run"
        DailyRunEnqueue(due,"提醒視窗")
}

DailyItemsPushWeb() {
    global webReady,WVCore,profiles,recorder,DAILY_DELAY_MIN
    if !webReady || !WVCore
        return
    roles:=""
    for i,p in profiles {
        if !p.enabled
            continue
        expiry:=p.HasOwnProp("dailyExpiry") ? p.dailyExpiry : 0
        roles.=(roles="" ? "" : ",") '{"index":' i ',"name":"' JsonEscapeWeb(p.name) '"'
            . ',"alive":' (p.pid && ProfileGameAlive(p) ? "true" : "false")
            . ',"expiry":"' (expiry ? GameTimeText(expiry,"MM-dd HH:mm") : "") '"'
            . ',"due":"' (expiry ? GameTimeText(expiry+DAILY_DELAY_MIN*60,"MM-dd HH:mm") : "") '"'
            . ',"status":"' JsonEscapeWeb(DailyStatusText(p)) '"'
            . ',"packs":' (p.HasOwnProp("dailyPacks") ? p.dailyPacks : -1)
            . ',"packsStale":' (p.HasOwnProp("dailyPacksStale") && p.dailyPacksStale ? "true" : "false")
            . ',"items":"' JsonEscapeWeb(DailyItemsOf(p)) '","mode":"' DailyModeOf(p) '","weapon":"' JsonEscapeWeb(DailyWeaponOf(p)) '"}'
    }
    rec:=IsObject(recorder)
        ? '{"active":true,"name":"' JsonEscapeWeb(recorder.name) '","count":' recorder.count ',"seconds":' Floor((A_TickCount-recorder.start)/1000) ',"dir":"' JsonEscapeWeb(recorder.dir) '"}'
        : '{"active":false}'
    global dailyRunning,dailyRunQueue,DAILY_AUTORUN,DAILY_IDLE_SEC,DAILY_OPTIONS,DAILY_WEAPON_KEYWORD
    opts:=""
    for o in DAILY_OPTIONS
        opts.=(opts="" ? "" : ",") '["' o[1] '","' JsonEscapeWeb(o[2]) '"]'
    queue:=""
    for i in dailyRunQueue
        queue.=(queue="" ? "" : "、") profiles[i].name
    try WVCore.PostWebMessageAsJson('{"type":"daily","data":{"delay":' DAILY_DELAY_MIN ',"autorun":' (DAILY_AUTORUN ? "true" : "false")
        . ',"idle":' DAILY_IDLE_SEC ',"running":"' JsonEscapeWeb(dailyRunning) '","queue":"' JsonEscapeWeb(queue) '"'
        . ',"roles":[' roles '],"options":[' opts '],"weaponDefault":"' JsonEscapeWeb(DAILY_WEAPON_KEYWORD) '","recorder":' rec '}}')
}

; time_t（UTC 秒）→ 本機時間文字；0 或負數顯示「—」。
GameTimeText(t, fmt:="MM-dd HH:mm:ss") {
    if t<=0
        return "—"
    static tzOffset:=DateDiff(A_Now,A_NowUTC,"Seconds")
    return FormatTime(DateAdd(DateAdd("19700101000000",t,"Seconds"),tzOffset,"Seconds"),fmt)
}

DurationText(sec) {
    if sec<=0
        return "無"
    if Mod(sec,86400)=0
        return Floor(sec/86400) " 天"
    if Mod(sec,3600)=0
        return Floor(sec/3600) " 小時"
    return sec " 秒"
}

DailyItemLine(pid, label, s) {
    limit:=GameItemTimeLimit(pid,s.key)
    line:="  " label "｜" s.key " " GameItemName(s.key,pid)
    if s.HasOwnProp("x")
        line.="｜格子 (" s.x "," s.y ")"
    line.="｜數量 " s.count "｜取得 " GameTimeText(s.born) " [" s.born "]｜時限 " DurationText(limit)
    if limit
        line.="｜取得+時限 " GameTimeText(s.born+limit)
    if s.disguiseKey!="" {
        dl:=GameItemTimeLimit(pid,s.disguiseKey)
        line.="｜造型 " s.disguiseKey " " GameItemName(s.disguiseKey,pid)
            . "｜造型時間 " GameTimeText(s.disguiseTime) " [" s.disguiseTime "]｜造型時限 " DurationText(dl)
        if dl
            line.="｜造型時間+時限 " GameTimeText(s.disguiseTime+dl)
    }
    return line "`r`n"
}

; 單一角色的裝備欄 / 背包 / 銀行完整清單（匯出與示範錄製共用）。
DailyRoleDumpText(p) {
    global GAME_EQUIP_SLOT_NAMES
    serverTime:=0
    ReadGameServerTime(p.pid,&serverTime)
    out:="==================== " p.name "｜PID " p.pid "｜職業代碼 " ReadGameCharClass(p.pid)
        . "｜伺服器時間 " GameTimeText(serverTime) " [" serverTime "]`r`n"
    out.="[裝備欄]`r`n"
    equip:=ReadGameEquipment(p.pid)
    if IsObject(equip) {
        for i,s in equip
            if s
                out.=DailyItemLine(p.pid,Format("{:02}",i-1) " " GAME_EQUIP_SLOT_NAMES[i],s)
    } else {
        out.="  讀取失敗`r`n"
    }
    for part in [["背包","InvenOffset"],["銀行","BankOffset"]] {
        out.="[" part[1] "]`r`n"
        slots:=ReadGameInventorySlots(p.pid,part[2])
        if !IsObject(slots) {
            out.="  讀取失敗（可能正在變動，請再匯出一次）`r`n"
            continue
        }
        for s in slots
            out.=DailyItemLine(p.pid,part[1],s)
    }
    return out
}

; 匯出所有已連接角色的裝備欄 / 背包 / 銀行（診斷用，只讀）。
DailyItemsDump() {
    global profiles
    path:=A_ScriptDir "\Logs\EquipDump_" FormatTime(,"yyyyMMdd_HHmmss") ".txt"
    out:="匯出時間 " FormatTime(,"yyyy-MM-dd HH:mm:ss") "（本機）`r`n"
    count:=0
    for p in profiles {
        if !p.pid || !ProfileGameAlive(p)
            continue
        if !GameOffsetsReady(p.pid) {
            out.="==================== " p.name "｜Game.pdb 位置尚未就緒`r`n"
            continue
        }
        count+=1
        out.=DailyRoleDumpText(p)
    }
    if !DirExist(A_ScriptDir "\Logs")
        DirCreate A_ScriptDir "\Logs"
    FileAppend out,path,"UTF-8"
    EventLog("GLOBAL","EQUIP_DUMP","已匯出 " count " 隻角色的裝備 / 背包 / 銀行｜" path)
    AddRecentEvent("📄 已匯出 " count " 隻角色的裝備 / 背包 / 銀行資料")
    try Run('explorer.exe /select,"' path '"')
}
