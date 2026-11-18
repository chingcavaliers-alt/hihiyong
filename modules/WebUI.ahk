; 網頁介面（WebView2）：建立視窗、hihiyong:// 指令分派（WebRunAction）、推送畫面狀態（PushWebState）與帳號 / 設定的網頁儲存。
; 從主程式搬出來（v1.3.90.52），內容沒有改；只有函式，#Include 的位置就是原本的位置。

InitWebUI(*) {
    global APP_TITLE,WebGui,WVController,WVCore,WebNavStartingSub,WebNavCompletedSub
    if WebGui
        return
    if A_PtrSize!=8 {
        MsgBox "v0.9.3 固定使用 AutoHotkey v2 64-bit。",APP_TITLE
        ExitApp
    }
    loader:=A_ScriptDir "\Lib\WebView2\64bit\WebView2Loader.dll"
    uiFile:=A_ScriptDir "\ui\index.html"
    if !FileExist(loader) {
        MsgBox "找不到 WebView2Loader.dll。`n請先執行「下載_WebView2相依元件.ps1」。",APP_TITLE
        ExitApp
    }
    if !FileExist(uiFile) {
        MsgBox "找不到 ui\index.html。`n請完整解壓縮 ZIP。",APP_TITLE
        ExitApp
    }

    ; v1.3.22.0：介面會隨視窗大小調整（窄的時候側邊欄只剩圖示），最小尺寸放寬
    WebGui:=Gui("+Resize +MinSize760x540",APP_TITLE)
    WebGui.BackColor:="F4F5F7"
    WebGui.OnEvent("Close",(*)=>ExitApp())
    WebGui.OnEvent("Size",WebResize)
    WebGui.Show("w1360 h820")
    AppApplyIcon()

    try {
        WVController:=WebView2.create(WebGui.Hwnd,,0,A_ScriptDir "\WebView2UserData","",0,loader)
        WVController.Fill()
        WVCore:=WVController.CoreWebView2
        WVCore.Settings.IsWebMessageEnabled:=true

        ; Store subscription objects globally so the callbacks stay alive.
        WebNavStartingSub:=WVCore.NavigationStarting(WebNavigationStarting)
        WebNavCompletedSub:=WVCore.NavigationCompleted(WebNavigationCompleted)
        WVCore.Navigate(WebFileUri(uiFile))
    } catch as err {
        MsgBox "WebView2 初始化失敗：`n`n" err.Message,APP_TITLE
        ExitApp
    }
}

WebResize(guiObj,minMax,w,h) {
    global WVController
    try MiniSync(minMax)
    if !WVController
        return
    try {
        WVController.IsVisible:=(minMax!=-1)
        if minMax!=-1
            WVController.Fill()
    }
}

WebNavigationCompleted(sender,args) {
    global webReady
    if !args.IsSuccess
        return
    webReady:=true
    RefreshGames()
    PushWebState()
    ; UI 先出現，再啟動背景監控，降低啟動時與 WebView 初始化搶資源。
    SetTimer MonitorTick, 2000
    SetTimer HPAndSoftMonitorTick, 1000
    SetTimer MemoryHPMonitorTick, MEMORY_HP_SAMPLE_MS
    SetTimer NetGuardTick, 5000   ; H-031：整體斷網守門（不開任何外部程式）
    SetTimer InventoryStatsTick, INV_STATS_INTERVAL_MS
    SetTimer SignalsTick, SIGNAL_TICK_MS
    SetTimer LagProbeTick, LAG_TICK_MS
    SetTimer DailyItemsTick, DAILY_TICK_MS
    ; 同一個函式重設 SetTimer 會改掉原本的週期，所以第一次（啟動 1 分鐘後）用另一個函式物件
    SetTimer DropRatesCheck.Bind(false), -60000
    SetTimer DropRatesCheckTick, DROP_CHECK_MS
    SetTimer UpdateCheck.Bind(false), -90000
    SetTimer UpdateCheckTick, UPDATE_CHECK_MS
    SetTimer UpdateCleanupOld, -30000
    SetTimer MBoxTick, 1000
    SetTimer ApTick, 2000
    SetTimer ApAcceptTick, 1000   ; 隊長在另一台電腦時，邀請視窗有時效：比 ApTick 看得勤一點
    SetTimer CompanionTick, CW_CHECK_MS   ; 寵物 / 雇傭兵監測（預設關閉）
    SetTimer DailyHuntTick, DH_TICK_MS    ; 每日討伐自動跑圖（預設關閉）
    SetTimer DailyHuntSchedTick, 10000    ; 每日討伐：各角色的定時啟動
    SetTimer MnTick, MN_TICK_MS           ; 水晶礦場自動採礦（預設關閉）
    SetTimer LagFixTick, 5000   ; 變慢自動過圖（預設關閉；待救援的角色即使關閉也會送回去）
    SetTimer AutoAttackTick, AUTOATTACK_TICK_MS
    SetTimer ReportsTick, 30000
    SetTimer KillStatsTick, KILL_TICK_MS
    SetTimer KillHitTick, KILL_HIT_TICK_MS
    SetTimer RecoveryGuardTick, RG_TICK_MS
    WebPushEvent("",APP_VERSION " 已連線；背景監控於 UI 完成後啟動。")
    ; UI 500ms 更新一次；Memory HP 底層仍維持 50ms。
    SetTimer PushWebState,500
}

WebNavigationStarting(sender,args) {
    uri:=args.Uri
    if !InStr(uri,"hihiyong://")
        return
    args.Cancel:=true
    cmd:=SubStr(uri,StrLen("hihiyong://")+1)
    cmd:=StrReplace(cmd,"%20"," ")
    parts:=StrSplit(cmd,"/")
    action:=parts.Length>=1 ? parts[1] : ""
    rawValue:=parts.Length>=2 ? parts[2] : ""
    ; rawValue may be URL-encoded account/profile text. Never force arbitrary
    ; command payloads through numeric conversion here.
    value:=0
    if rawValue!="" {
        try value:=rawValue+0
        catch
            value:=0
    }
    SetTimer WebRunAction.Bind(action,value,rawValue),-1
}

WebRunAction(action,value:=0,rawValue:="") {
    global profiles,gameRows,webSelectedProfile,webSelectedGame,LV,GameList,selectedProfileRow

    if action="start" {
        StartMonitoring()
    } else if action="batchstart" {
        BatchStartChecked()
    } else if action="launchcheck" {
        WebSetLaunchCheck(rawValue)
    } else if action="monitorcheck" {
        WebSetMonitorCheck(rawValue)
    } else if action="emergencystop" {
        EmergencyStopAll()
    } else if action="restartchecked" {
        RestartCheckedAccounts()
    } else if action="oneclick" {
        BatchStartChecked()
        AddRecentEvent("🚀 一鍵啟動：已啟動勾選帳號並進入監控 / Recovery Queue")
    } else if action="switchnext" {
        SwitchNextBoundGame()
    } else if action="resetallstats" {
        ResetAllDeathStats()
    } else if action="switchautostart" {
        StartAutoWindowSwitch()
    } else if action="switchautostop" {
        StopAutoWindowSwitch()
    } else if action="switchsave" {
        SaveWindowSwitchSetting(rawValue)
    } else if action="switchstophotkey" {
        SaveSwitchStopHotkey(rawValue)
    } else if action="layoutrestore" {
        RestoreAllProfileWindows("手動")
    } else if action="layoutsave" {
        SaveAllCurrentWindowPositions()
    } else if action="layoutauto" {
        SetLayoutAutoRestore(rawValue)
    } else if action="minicfg" {
        MiniSetEnabled(rawValue)
    } else if action="uitheme" {
        ; v1.3.22.0 介面風格（只影響畫面）
        if RegExMatch(rawValue,"^[a-z]{0,20}$")
            IniWrite rawValue,INI,"UI","Theme"
    } else if action="invbindscan" {
        ScanInventoryWindows()
    } else if action="invshowwindow" {
        ShowInventoryCandidateWindow(rawValue)
    } else if action="invbindaddprofile" {
        AddInventoryBindingFromProfile(rawValue)
    } else if action="invbindadd" {
        AddInventoryBinding(rawValue)
    } else if action="invbindremove" {
        RemoveInventoryBinding(rawValue)
    } else if action="invbindcheck" {
        SetInventoryBindingChecked(rawValue)
    } else if action="invpause" {
        ToggleInventoryPause()
    } else if action="invstarthotkey" {
        SaveInventoryStartHotkey(rawValue)
    } else if action="invpausehotkey" {
        SaveInventoryPauseHotkey(rawValue)
    } else if action="invstophotkey" {
        SaveInventoryStopHotkey(rawValue)
    } else if action="inventorysetup" {
        StartInventoryCleanerSetup(value)
    } else if action="inventorysave" {
        SaveInventoryCleanerSettings(rawValue)
    } else if action="inventorystart" {
        StartMultiInventoryCleaner()
    } else if action="inventorystop" {
        StopMultiInventoryCleaner()
    } else if action="inventorycheck" {
        SetInventoryProfileChecked(rawValue)
    } else if action="autobind" {
        AutoBindGames()
    } else if action="stop" {
        StopMonitoring()
    } else if action="refresh" {
        RefreshGames()
    } else if action="checkhp" {
        CheckAllHpReadability()
    } else if action="calibratehp" {
        StartDynamicHPCalibration()
    } else if action="reportsave" {
        ReportsSaveSettings(rawValue)
    } else if action="reportnow" {
        ReportSendDaily(FormatTime(,"yyyy-MM-dd"))
        AddRecentEvent("📊 已發送今天到目前為止的報表到 Discord")
    } else if action="snapshotnow" {
        AddRecentEvent(ReportSendSnapshot("📸 手動截圖") ? "📸 已發送遊戲畫面截圖到 Discord" : "⚠ 截圖發送失敗（沒有開著的遊戲視窗，或 Discord 通知未啟用）")
    } else if action="equipdump" {
        DailyItemsDump()
    } else if action="shortcutcreate" {
        DesktopShortcutCreate()
    } else if action="shortcuticon" {
        DesktopShortcutChooseIcon()
    } else if action="shortcuticonreset" {
        DesktopShortcutResetIcon()
    } else if action="loginchars" {
        LoginCharsPushWeb()
    } else if action="logincharsave" {
        LoginCharSet(rawValue)
        LoginCharsPushWeb()
    } else if action="dailystate" {
        DailyItemsPushWeb()
    } else if action="dailyrun" {
        if value>=1 && value<=profiles.Length
            DailyRunEnqueue([value],"手動按下「立即更換」")
        DailyItemsPushWeb()
    } else if action="recstart" {
        RecorderStart(value)
        DailyItemsPushWeb()
    } else if action="recstop" {
        RecorderStop()
        DailyItemsPushWeb()

    } else if action="invstats" {
        ; 網頁端會把「|」編成 %7C（encodeURIComponent），一定要先解碼，否則時段完全沒有套用（H-033 修正）
        rq:=InvParseRequest(WebUrlDecode(rawValue))   ; 「日期」或「日期|起|迄」（H-023 自訂統計時段）
        InventoryStatsPushWeb(rq.day,rq.from,rq.to)
    } else if action="mboxstate" {
        MBoxPushWeb()
    } else if action="mboxcfg" {
        MBoxSetGlobal(WebUrlDecode(rawValue))
        MBoxPushWeb()
    } else if action="mboxrole" {
        MBoxSetRole(WebUrlDecode(rawValue))
        MBoxPushWeb()
    } else if action="skillcombostate" {
        SkillComboPushWeb()
    } else if action="skillcombocfg" {
        SkillComboSetGlobal(WebUrlDecode(rawValue))
        SkillComboPushWeb()
    } else if action="skillcombolist" {
        SkillComboSetList(WebUrlDecode(rawValue))
        SkillComboPushWeb()
    } else if action="dailyhuntstate" {
        DailyHuntPushWeb()
    } else if action="dailyhuntafter" {
        DailyHuntAfter(WebUrlDecode(rawValue))
        DailyHuntPushWeb()
    } else if action="dailyhuntspot" {
        DailyHuntSpot(WebUrlDecode(rawValue))
        DailyHuntPushWeb()
    } else if action="autominingbosstimer" {
        AutoMiningBossTimerNow()
        AutoMiningPushWeb()
    } else if action="dhschedset" {
        DailyHuntSchedSet(WebUrlDecode(rawValue))
        DailyHuntPushWeb()
    } else if action="dhschedack" {
        DailyHuntSchedAck(WebUrlDecode(rawValue))
        DailyHuntPushWeb()
    } else if action="dailyhuntset" {
        DailyHuntSet(WebUrlDecode(rawValue))
        DailyHuntPushWeb()
    } else if action="autominingstate" {
        AutoMiningPushWeb()
    } else if action="prioritystate" {
        FpPushWeb()
    } else if action="priorityset" {
        FpSet(WebUrlDecode(rawValue))
        FpPushWeb()
    } else if action="autominingresethard" {
        AutoMiningHardReset()
        AutoMiningPushWeb()
    } else if action="autominingreset" {
        AutoMiningReset()
        AutoMiningPushWeb()
    } else if action="autominingset" {
        AutoMiningSet(WebUrlDecode(rawValue))
        AutoMiningPushWeb()
    } else if action="companionstate" {
        CompanionPushWeb()
    } else if action="companionset" {
        CompanionSet(WebUrlDecode(rawValue))
        CompanionPushWeb()
    } else if action="quickkeyset" {
        CwQuickKeySet(WebUrlDecode(rawValue))
        CompanionPushWeb()
    } else if action="partystate" {
        ApPushWeb()
    } else if action="partycfg" {
        ApSetGlobal(WebUrlDecode(rawValue))
        ApPushWeb()
    } else if action="partyrole" {
        ApSetRole(WebUrlDecode(rawValue))
        ApPushWeb()
    } else if action="partyremote" {
        ApSetRemote(WebUrlDecode(rawValue))
        ApPushWeb()
    } else if action="partyaccept" {
        ApSetAccept(WebUrlDecode(rawValue))
        ApPushWeb()
    } else if action="partynow" {
        if IsInteger(WebUrlDecode(rawValue))
            ApRequestNow(Integer(WebUrlDecode(rawValue)))
        ApPushWeb()
    } else if action="licensestate" {
        Lic_PushWeb()
    } else if action="licenseinstall" {
        Lic_PickAndInstall()
    } else if action="licensecopy" {
        A_Clipboard := Lic_ShareNow()
    } else if action="updatestate" {
        UpdatePushWeb()
    } else if action="updatecheck" {
        UpdateCheck(true)
    } else if action="updateapply" {
        UpdateApply()
    } else if action="dropindex" {
        DropRatesPushIndex()
    } else if action="dropver" {
        DropRatesPushVersion(rawValue)
    } else if action="dropcheck" {
        DropRatesCheck(false)
    } else if action="recstats" {
        RecoveryStatsPushWeb()
    } else if action="hoursummary" {
        HourlySummaryPushWeb(WebUrlDecode(rawValue))
    } else if action="invstatsexport" {
        ; 「日期|起|迄|模式」：模式 detail（選的那天＋時段）/ all（全部日期明細）/ summary（每日摘要）
        xp:=StrSplit(WebUrlDecode(rawValue),"|")
        rq:=InvParseRequest(xp.Length>=3 ? xp[1] "|" xp[2] "|" xp[3] : (xp.Length ? xp[1] : ""))
        InventoryStatsExportCsv(rq.day,rq.from,rq.to,xp.Length>=4 && RegExMatch(xp[4],"^(detail|all|summary)$") ? xp[4] : "detail")
    } else if action="profile" {
        WebSelectProfile(value)
    } else if action="game" {
        WebSelectGame(value)
    } else if action="bind" {
        WebPrepareSelections()
        BindSelected()
    } else if action="unbind" {
        WebPrepareSelections()
        UnbindSelected()
    } else if action="show" {
        WebPrepareSelections()
        ShowSelectedGame()
    } else if action="position" {
        WebPrepareSelections()
        RecordWindowPosition()
    } else if action="recover" {
        WebPrepareSelections()
        ManualRecover()
    } else if action="recoverone" {   ; 首頁角色卡上的「重新登入」：直接指定是哪一個角色
        if IsInteger(value) && value>=1 && value<=profiles.Length {
            WebSelectProfile(Integer(value))
            ManualRecover()
        }
    } else if action="resetstats" {
        WebPrepareSelections()
        ResetDeathStats()
    } else if action="evidence" {
        StartSoftEvidenceCapture("手動測試20秒雙螢幕記錄")
    } else if action="log" {
        ShowLogViewer()
    } else if action="launcherbrowse" {
        BrowseLauncher()
        SaveGeneral()
    } else if action="postkeys" {
        global PostKeysEdit,profiles
        PostKeysEdit.Value:=WebDecodeSimple(rawValue)
        SaveGeneral()
        AddRecentEvent("登入後按鍵已更新：" PostKeysEdit.Value)
    } else if action="coordstart" {
        StartSetup()
    } else if action="coordrecord" {
        RecordSetupPoint()
    } else if action="coordcancel" {
        global setupMode
        if setupMode
            CancelSetup("8 點登入座標設定已取消，舊座標保持不變。")
    } else if action="coordclear" {
        ClearPoints()
    } else if action="coordtest" {
        TestLoginCoordinates()
    } else if action="mapprofile" {
        global LocationProfileDDL
        ; value 來自 Web UI 的 Profile index；Profiles 本身就是此 DDL 的資料來源。
        ; 不呼叫 Gui.DDL 不存在的 GetCount/GetItems method。
        if value>=1 && value<=profiles.Length
            LocationProfileDDL.Choose(value)
    } else if action="maptest" {
        TestSelectedLocation()
    } else if action="mapconf" {
        global ConfEdit
        ConfEdit.Value:=Max(1,Min(99,value))
        SaveGeneral()
    } else if action="mapzoom" {
        global ZoomCountEdit
        ZoomCountEdit.Value:=Max(1,Min(30,value))
        SaveGeneral()
    } else if action="mapreturn" {
        global ReturnKeyEdit
        keyValue:=WebDecodeSimple(rawValue)
        if keyValue!="" {
            ReturnKeyEdit.Value:=keyValue
            SaveGeneral()
        }
    } else if action="accountadd" {
        AddProfile()
        WebSelectProfile(profiles.Length)
        AddRecentEvent("已新增帳號 Profile；請輸入名稱 / 帳號 / 密碼後儲存。")
    } else if action="accountsave" {
        WebSaveAccount(rawValue)
    } else if action="accountdelete" {
        WebDeleteSelectedAccount()
    } else if action="accounttoggle" {
        WebToggleAccount(value,rawValue)
    } else if action="notifysave" {
        WebSaveNotifications(rawValue)
    } else if action="recoverytest" {
        TestDiscordWebhook()
    } else if action="deathtest" {
        TestDeathDiscordWebhook()
    } else if action="softdetect" {
        WebSetSoftDetect(rawValue)
    } else if action="softautorecover" {
        WebSetSoftAutoRecover(rawValue)
    } else if action="recoveryfirst" {
        WebSetRecoveryFirst(rawValue)
    } else if action="deathalarm" {
        WebSetDeathAlarm(rawValue)
    } else if action="alarmglobal" {
        WebSetAlarmGlobal(rawValue)
    } else if action="alarmtest" {
        TestDeathAlarm()
    } else if action="alarmstop" {
        StopDeathAlarm()
    } else if action="dailycardkeys" {
        if !DailySetCardKeys(WebUrlDecode(rawValue))
            AddRecentEvent("⚠ 傳送卡按鍵沒有儲存：只能填單一字母 / 數字 / F1～F12（快捷欄各格用逗號分隔）")
        DailyItemsPushWeb()
    } else if action="dailycfg" {
        WebSetDailyConfig(rawValue)
        DailyItemsPushWeb()
    } else if action="monitorsave" {
        WebSaveMonitorSettings(rawValue)
    } else if action="evidencetest" {
        StartSoftEvidenceCapture("手動測試20秒雙螢幕記錄")
        AddRecentEvent("已開始 20 秒雙螢幕蒐證測試")
    } else if action="showlog" {
        ShowLogViewer()
    } else if action="saveall" {
        SaveGeneral()
        AddRecentEvent("已儲存全部設定")
    } else if action="selfcheck" {
        WebRunSelfCheck()
    } else if action="diagexport" {
        DiagExport()
    } else if action="effectsdump" {
        EffectsDump()
    } else if action="diagopen" {
        DiagOpenFolder()
    } else if action="diagstate" {
        DiagPushWeb()
    } else if action="lagstate" {
        LagPushWeb()
        LagFixPushWeb()
    } else if action="lfset" {
        LagFixSet(WebUrlDecode(rawValue))
        LagFixPushWeb()
    } else if action="lfnow" {
        if IsInteger(rawValue)
            SetTimer(LagFixManual.Bind(Integer(rawValue)), -50)   ; 不要卡住網頁訊息處理
    } else if action="lagmark" {
        LagMark(IsInteger(rawValue) ? Integer(rawValue) : 0)
        LagPushWeb()
    } else if action="lagset" {
        LagSetEnabled(rawValue = "1")
        LagPushWeb()
    } else if action="settings" {
        global g
        g.Show("w1080 h748")
    } else if action="launcherpage" {
        WebOpenStablePage("遊戲程式啟動")
    } else if action="coordpage" {
        WebOpenStablePage("登入座標設定")
    } else if action="mappage" {
        WebOpenStablePage("地圖判定設定")
    } else if action="monitorpage" {
        WebOpenStablePage("監控設定")
    } else if action="notifypage" {
        WebOpenStablePage("通報設定")
    } else if action="toolspage" {
        WebOpenStablePage("記錄與工具")
    }
    PushWebState()
}

WebOpenStablePage(pageName) {
    global g,MainTabs
    pageMap:=Map(
        "通報設定",3,
        "遊戲程式啟動",4,
        "登入座標設定",5,
        "地圖判定設定",6,
        "監控設定",7,
        "記錄與工具",8
    )
    if !pageMap.Has(pageName) {
        AddRecentEvent("設定頁不存在：" pageName)
        return
    }

    ; MainTabs is the real AddTab3 control in v0.7.5.9 Stable Core.
    ; Choose() changes the visible tab; no guessed NavDDL or synthetic callback.
    MainTabs.Choose(pageMap[pageName])
    g.Show("w1080 h748")
    try WinActivate("ahk_id " g.Hwnd)
    AddRecentEvent("開啟設定頁：" pageName)
}

WebDecodeSimple(value) {
    value:=StrReplace(value,"%2C",",")
    value:=StrReplace(value,"%2c",",")
    value:=StrReplace(value,"%20"," ")
    value:=StrReplace(value,"%2B","+")
    value:=StrReplace(value,"%2b","+")
    value:=StrReplace(value,"%2D","-")
    value:=StrReplace(value,"%2d","-")
    value:=StrReplace(value,"%5F","_")
    value:=StrReplace(value,"%5f","_")
    return value
}

WebSplitAccountPayload(rawValue) {
    ; payload fields use ~ delimiter and simple percent encoding from JS.
    parts:=StrSplit(rawValue,"~")
    while parts.Length<3
        parts.Push("")
    return [WebUrlDecode(parts[1]),WebUrlDecode(parts[2]),WebUrlDecode(parts[3])]
}

WebUrlDecode(value) {
    out:="", i:=1, len:=StrLen(value)
    while i<=len {
        if SubStr(value,i,1)="%" && i+2<=len {
            vals:=[]
            while i+2<=len && SubStr(value,i,1)="%" {
                hx:=SubStr(value,i+1,2)
                if !RegExMatch(hx,"i)^[0-9A-F]{2}$")
                    break
                vals.Push("0x" hx), i+=3
            }
            if vals.Length {
                buf:=Buffer(vals.Length+1,0)
                for bi,bv in vals
                    NumPut("UChar",bv+0,buf,bi-1)
                out.=StrGet(buf,vals.Length,"UTF-8")
                continue
            }
        }
        out.=SubStr(value,i,1), i+=1
    }
    return out
}
RepairEncodedAccountProfiles() {
    global profiles
    changed:=false
    for p in profiles {
        if InStr(p.name,"~") {
            parts:=StrSplit(p.name,"~")
            if parts.Length>=2 {
                p.name:=WebUrlDecode(parts[1])
                p.account:=WebUrlDecode(parts[2])
                if parts.Length>=3 && parts[3]!=""
                    p.password:=WebUrlDecode(parts[3])
                changed:=true
            }
        } else if InStr(p.name,"%") {
            decoded:=WebUrlDecode(p.name)
            if decoded!=p.name
                p.name:=decoded, changed:=true
        }
    }
    if changed {
        SaveProfiles()
        RefreshProfileLV()
        AddRecentEvent("已修復舊版 Web 帳號編碼資料")
    }
}

WebSaveAccount(rawValue) {
    global webSelectedProfile,profiles,LV,NameEdit,AccountEdit,PasswordEdit
    global EnabledCB,LaunchCB,DeathDetectCB,DeathNotifyCB,SoftDetectCB
    if webSelectedProfile<1 || webSelectedProfile>profiles.Length {
        AddRecentEvent("請先選擇帳號，或按「新增帳號」。")
        return
    }
    data:=WebSplitAccountPayload(rawValue)
    NameEdit.Value:=data[1]
    AccountEdit.Value:=data[2]
    ; blank password means preserve current DPAPI-backed password.
    if data[3]!=""
        PasswordEdit.Value:=data[3]
    LV.Modify(0,"-Select")
    LV.Modify(webSelectedProfile,"Select Focus")
    SaveSelectedProfile()
    WebSelectProfile(webSelectedProfile)
    AddRecentEvent("帳號資料已儲存：" profiles[webSelectedProfile].name)
    miss:=ProfileMissingLogin(profiles[webSelectedProfile]), missText:=""
    for m in miss
        missText.=(missText="" ? "" : "、") m
    if missText!=""
        AddRecentEvent("⚠ " profiles[webSelectedProfile].name " 還沒填" missText "：自動登入 / 重新登入會失敗，請補上後再儲存")
}

WebDeleteSelectedAccount() {
    global webSelectedProfile,profiles,LV
    row:=webSelectedProfile
    if row<1 || row>profiles.Length {
        AddRecentEvent("請先選擇要刪除的帳號。")
        return
    }
    name:=profiles[row].name
    LV.Modify(0,"-Select")
    LV.Modify(row,"Select Focus")
    DeleteProfile()
    webSelectedProfile:=0
    AddRecentEvent("已刪除帳號 Profile：" name)
}

WebSetLaunchCheck(rawValue) {
    global profiles
    parts:=StrSplit(rawValue,"~")
    if parts.Length<2
        return
    idx:=parts[1]+0, on:=parts[2]+0
    if idx<1 || idx>profiles.Length
        return
    profiles[idx].launchEnabled:=on ? 1 : 0
    SaveProfiles()
    RefreshProfileLV()
    AddRecentEvent(profiles[idx].name " → 啟動 / 重啟勾選 " (on ? "ON" : "OFF"))
}

WebSetMonitorCheck(rawValue) {
    global profiles,running
    parts:=StrSplit(rawValue,"~")
    if parts.Length<2
        return
    idx:=parts[1]+0, on:=parts[2]+0
    if idx<1 || idx>profiles.Length
        return
    p:=profiles[idx]
    p.enabled:=on ? 1 : 0
    if !p.enabled {
        if p.state="監控中" || p.state="排隊恢復" || p.state="恢復中" || p.state="恢復失敗"
            p.state:="已登入（未監控）"
        RemoveProfileFromRecoveryQueue(idx)
    } else if running && ProfileGameAlive(p) {
        p.state:="監控中"
    }
    SaveProfiles()
    RefreshProfileLV()
    AddRecentEvent(p.name " → 單帳號監控 " (p.enabled ? "ON" : "OFF"))
}

RemoveProfileFromRecoveryQueue(idx) {
    global recoveryQueue,queued
    next:=[]
    for q in recoveryQueue
        if q!=idx
            next.Push(q)
    recoveryQueue:=next
    if queued.Has(idx)
        queued.Delete(idx)
}

WebToggleAccount(flag,rawValue) {
    global webSelectedProfile,profiles,LV,EnabledCB,LaunchCB,DeathDetectCB,DeathNotifyCB,SoftDetectCB
    row:=webSelectedProfile
    if row<1 || row>profiles.Length
        return
    p:=profiles[row]
    parts:=StrSplit(rawValue,"~")
    if parts.Length<2
        return
    key:=parts[1], on:=parts[2]+0
    if key="enabled"
        p.enabled:=on
    else if key="launch"
        p.launchEnabled:=on
    else if key="death"
        p.deathDetect:=on
    else if key="notify"
        p.deathNotify:=on
    else if key="soft"
        p.softDetect:=on
    SaveProfiles()
    RefreshProfileLV()
    WebSelectProfile(row)
}

WebRunSelfCheck() {
    global profiles,LauncherEdit,DiscordEnableCB,DiscordWebhookEdit
    global DeathDiscordEnableCB,DeathDiscordWebhookEdit,WVCore,webReady,gameRows
    items:=[]
    launcherOk:=FileExist(Trim(LauncherEdit.Value)) ? 1 : 0
    items.Push([launcherOk,"遊戲啟動程式",launcherOk ? "已設定" : "找不到啟動程式，請到「環境與通知」重新選擇"])
    coordsOk:=(PointsConfigured() || LoginMemoryAvailable()) ? 1 : 0
    items.Push([coordsOk,"登入座標",PointsConfigured() ? "8/8 已設定" : (coordsOk ? "直接讀遊戲畫面（這台不需要設 8 點）" : "尚未完成 8 點（這台讀不到遊戲的登入畫面位置，自動登入要靠 8 點）")])
    profileOk:=profiles.Length>0 ? 1 : 0
    items.Push([profileOk,"帳號",profiles.Length " 個"])
    bound:=0
    for p in profiles {
        if p.hwnd && p.pid && WinExist("ahk_id " p.hwnd)
            bound+=1
    }
    items.Push([profiles.Length>0 && bound=profiles.Length,"遊戲視窗連接",bound " / " profiles.Length " 個帳號已連接"])
    hpOk:=0
    hpNeed:=0
    for p in profiles {
        if p.enabled && ProfileGameAlive(p) {
            hpNeed+=1
            _mh:=0
            if ReadMemoryHP(p.pid,&_mh)
                hpOk+=1
        }
    }
    items.Push([hpNeed>0 && hpOk=hpNeed,"角色血量讀取",hpOk " / " hpNeed " 個正常"])
    discordConfigured:=(!DiscordEnableCB.Value || Trim(DiscordWebhookEdit.Value)!="")
        && (!DeathDiscordEnableCB.Value || Trim(DeathDiscordWebhookEdit.Value)!="")
    items.Push([discordConfigured,"Discord 通知",discordConfigured ? "設定完整" : "已啟用但還沒填通知網址"])
    logOk:=1
    try {
        path:=GetDailyLogPath()
        FileAppend "",path,"UTF-8"
    } catch {
        logOk:=0
    }
    items.Push([logOk,"執行紀錄",logOk ? "正常" : "無法寫入，請確認資料夾權限"])
    _softOn:=0, _softAuto:=0
    for p in profiles {
        if p.softDetect
            _softOn+=1
        if p.HasOwnProp("softAutoRecover") && p.softAutoRecover
            _softAuto+=1
    }
    items.Push([1,"假在線","偵測 " _softOn " 個｜自動恢復 " _softAuto " 個（每帳號獨立）"])
    ; v1.3.13.0: Game.pdb 資料位置
    pdbRoles:=0,aliveRoles:=0
    for p in profiles {
        if !p.pid || !ProfileGameAlive(p)
            continue
        aliveRoles+=1
        if GameOffsetsReady(p.pid)
            pdbRoles+=1
    }
    pdbOk:=GameOffsetsLoadedOk() && (aliveRoles=0 || pdbRoles=aliveRoles)
    pdbDetail:=GameOffsetsLoadedOk() ? (pdbRoles "/" aliveRoles " 個遊戲可讀取") : (GameOffsetsResolving() ? "準備中…（遊戲更新後第一次啟動需要幾十秒）" : "尚未就緒（血量改用備援方式讀取）")
    items.Push([pdbOk,"遊戲資料讀取",pdbDetail])

    okCount:=0
    json:="["
    for i,it in items {
        if it[1]
            okCount+=1
        if i>1
            json.=","
        json.='{"ok":' (it[1] ? "true":"false") ',"name":"' JsonEscapeWeb(it[2])
            . '","detail":"' JsonEscapeWeb(it[3]) '"}'
    }
    json.="]"
    if webReady && WVCore {
        payload:='{"type":"selfcheck","data":{"ok":' okCount ',"total":' items.Length ',"items":' json '}}'
        try WVCore.PostWebMessageAsJson(payload)
    }
    AddRecentEvent("系統自我檢查完成｜" okCount "/" items.Length)
}

WebPayloadParts(rawValue, minCount:=1) {
    parts:=StrSplit(rawValue,"~")
    while parts.Length<minCount
        parts.Push("")
    for i,v in parts
        parts[i]:=WebUrlDecode(v)
    return parts
}

WebSaveNotifications(rawValue) {
    global DiscordEnableCB,DiscordWebhookEdit,DiscordPcEdit
    global DeathDiscordEnableCB,DeathDiscordWebhookEdit
    p:=WebPayloadParts(rawValue,5)
    DiscordEnableCB.Value:=p[1]+0
    ; blank webhook means preserve existing encrypted secret.
    if p[2]!=""
        DiscordWebhookEdit.Value:=p[2]
    DiscordPcEdit.Value:=p[3]
    DeathDiscordEnableCB.Value:=p[4]+0
    if p[5]!=""
        DeathDiscordWebhookEdit.Value:=p[5]
    SaveGeneral()
    AddRecentEvent("Discord 通報設定已儲存")
}

WebSetSoftDetect(rawValue) {
    global profiles
    parts:=StrSplit(rawValue,"~")
    if parts.Length<2
        return
    idx:=parts[1]+0, on:=parts[2]+0
    if idx<1 || idx>profiles.Length
        return
    profiles[idx].softDetect:=on ? 1 : 0
    if !on
        profiles[idx].memSoftState:="正常", profiles[idx].memSoftAlerted:=0
    SaveProfiles()
    AddRecentEvent(profiles[idx].name " → 假在線偵測 " (on ? "ON" : "OFF"))
}

; v1.3.24.0 每日道具角色設定：「編號~勾選項目(逗號分隔)~town|here~武器關鍵字~角色名稱」
; 帶名稱比對：畫面畫好後角色被刪除 / 重排時不會改到別的角色。
WebSetDailyConfig(rawValue) {
    global profiles
    parts:=StrSplit(WebUrlDecode(rawValue),"~")
    if parts.Length<3
        return
    if !IsInteger(parts[1])
        return
    idx:=Integer(parts[1])
    if idx<1 || idx>profiles.Length
        return
    p:=profiles[idx]
    if parts.Length>=5 {
        name:=parts[5]
        Loop parts.Length-5
            name.="~" parts[5+A_Index]
        if name!=p.name {
            AddRecentEvent("⚠ 每日道具設定沒有儲存：角色清單已變動，請重新整理畫面再設定")
            return
        }
    }
    items:=DailyNormalizeItems(parts[2])
    p.dailyItems:=items
    p.dailyMode:=(parts[3]="here" || parts[3]="auto") ? parts[3] : "town"
    p.dailyWeapon:=parts.Length>=4 ? Trim(RegExReplace(parts[4],"[\r\n~|]")) : ""
    SaveProfiles()
    ; 勾選改變 → 到期時間要重新計算（只看有勾的項目）
    if p.HasOwnProp("dailyExpiry")
        p.DeleteProp("dailyExpiry")
    AddRecentEvent(p.name " → 每日道具：" (items="" ? "不更換" : (p.dailyMode="here" ? "原地換" : p.dailyMode="auto" ? "自動（依快捷欄）" : "回城換")))
    ; 11/17 小柯基「明明選回城卻原地換」：設定是 11/10～11/16 間被改成原地換，只在畫面事件裡有，日誌查不到，改設定也記進日誌
    EventLog(p.name,"DAILY_CFG","每日道具設定：" DailyModeText(p) "｜項目 " (items="" ? "（不更換）" : items) (p.dailyWeapon!="" ? "｜武器 " p.dailyWeapon : ""))
    if items="" && DailyInProgress(p.name)
        AddRecentEvent("⚠ " p.name " 上次每日道具更換沒有完成，裝備可能還在背包：請按「立即更換」穿回")
}

; H-020：死亡警報音 — 每個角色的開關（「編號~0/1」）
WebSetDeathAlarm(rawValue) {
    global profiles
    parts:=StrSplit(rawValue,"~")
    if parts.Length<2 || !IsInteger(parts[1]) || !IsInteger(parts[2])
        return
    idx:=Integer(parts[1]), on:=Integer(parts[2])
    if idx<1 || idx>profiles.Length
        return
    profiles[idx].deathAlarm:=on ? 1 : 0
    SaveProfiles()
    AddRecentEvent(profiles[idx].name " → 死亡警報音 " (on ? "ON" : "OFF"))
}

; H-020：死亡警報音 — 總開關與響的秒數（「0/1~秒數」）；總開關關掉時所有角色都不響
WebSetAlarmGlobal(rawValue) {
    global DeathAlarmEnableCB,DeathAlarmSecondsEdit,INI
    parts:=StrSplit(rawValue,"~")
    if parts.Length<2 || !IsInteger(parts[1]) || !IsInteger(parts[2])
        return
    DeathAlarmEnableCB.Value:=Integer(parts[1]) ? 1 : 0
    DeathAlarmSecondsEdit.Value:=Max(5,Min(300,Integer(parts[2])))
    IniWrite DeathAlarmEnableCB.Value,INI,"DeathAlert","SoundEnabled"
    IniWrite DeathAlarmSecondsEdit.Value,INI,"DeathAlert","SoundSeconds"
    if !DeathAlarmEnableCB.Value
        StopDeathAlarm()
    AddRecentEvent("死亡警報音：" (DeathAlarmEnableCB.Value ? "開啟，響 " DeathAlarmSecondsEdit.Value " 秒" : "關閉"))
}

WebSetRecoveryFirst(rawValue) {
    global profiles
    parts:=StrSplit(rawValue,"~")
    if parts.Length<2
        return
    idx:=parts[1]+0, on:=parts[2]+0
    if idx<1 || idx>profiles.Length
        return
    profiles[idx].recoveryFirst:=on ? 1 : 0
    SaveProfiles()
    AddRecentEvent(profiles[idx].name " → 優先重新登入（隊長） " (on ? "ON" : "OFF"))
}

WebSetSoftAutoRecover(rawValue) {
    global profiles
    parts:=StrSplit(rawValue,"~")
    if parts.Length<2
        return
    idx:=parts[1]+0, on:=parts[2]+0
    if idx<1 || idx>profiles.Length
        return
    profiles[idx].softAutoRecover:=on ? 1 : 0
    SaveProfiles()
    AddRecentEvent(profiles[idx].name " → 假在線自動恢復 " (on ? "ON" : "OFF"))
}

WebSaveMonitorSettings(rawValue) {
    global SoftEnableCB,SoftIdleEdit,SoftConfirmEdit,SoftMinVotesEdit,SoftAutoRecoverCB,SoftMultiAssistCB
    p:=WebPayloadParts(rawValue,6)
    SoftEnableCB.Value:=p[1]+0
    SoftIdleEdit.Value:=Max(30,p[2]+0)
    SoftConfirmEdit.Value:=Max(5,p[3]+0)
    SoftMinVotesEdit.Value:=Max(1,p[4]+0)
    SoftAutoRecoverCB.Value:=p[5]+0
    SoftMultiAssistCB.Value:=p[6]+0
    SaveGeneral()
    AddRecentEvent("監控 / 假在線設定已儲存")
}

WebSelectProfile(row) {
    global profiles,LV,selectedProfileRow,webSelectedProfile,gameRows,webSelectedGame
    if row<1 || row>profiles.Length
        return
    webSelectedProfile:=row
    selectedProfileRow:=row
    LV.Modify(0,"-Select")
    LV.Modify(row,"Select Focus")
    OnProfileSelect(LV,row,true)

    p:=profiles[row]
    webSelectedGame:=0
    for gi,grow in gameRows {
        if (p.hwnd && grow.hwnd=p.hwnd) || (p.pid && grow.pid=p.pid) {
            webSelectedGame:=gi
            break
        }
    }
}

WebSelectGame(gi) {
    global gameRows,profiles,webSelectedGame,webSelectedProfile,LV,selectedProfileRow
    if gi<1 || gi>gameRows.Length
        return
    webSelectedGame:=gi
    grow:=gameRows[gi]
    for i,p in profiles {
        if (p.hwnd && p.hwnd=grow.hwnd) || (p.pid && p.pid=grow.pid) {
            webSelectedProfile:=i
            selectedProfileRow:=i
            LV.Modify(0,"-Select")
            LV.Modify(i,"Select Focus")
            OnProfileSelect(LV,i,true)
            break
        }
    }
}

WebPrepareSelections() {
    global webSelectedProfile,webSelectedGame,LV,GameList,profiles,gameRows,selectedProfileRow
    if webSelectedProfile>=1 && webSelectedProfile<=profiles.Length {
        selectedProfileRow:=webSelectedProfile
        LV.Modify(0,"-Select")
        LV.Modify(webSelectedProfile,"Select Focus")
        OnProfileSelect(LV,webSelectedProfile,true)
    }
    if webSelectedGame>=1 && webSelectedGame<=gameRows.Length
        GameList.Choose(webSelectedGame)
}

PushWebState(*) {
    global fastLoginCritical
    if fastLoginCritical
        return
    static repairedEncodedProfiles:=false
    if !repairedEncodedProfiles {
        repairedEncodedProfiles:=true
        RepairEncodedAccountProfiles()
    }
    global webReady,WVCore,profiles,recoveryQueue,running,hpReadableStatus,gameRows,appStartTick
    global webSelectedProfile,webSelectedGame,PROFILE_INI,INI
    global LauncherEdit,PostKeysEdit,ConfEdit,ZoomCountEdit,ReturnKeyEdit,LocationProfileDDL
    global DiscordEnableCB,DiscordWebhookEdit,DiscordPcEdit,DeathDiscordEnableCB,DeathDiscordWebhookEdit
    global SoftEnableCB,SoftIdleEdit,SoftConfirmEdit,SoftMinVotesEdit,SoftAutoRecoverCB,SoftMultiAssistCB,softEvidenceBusy
    global points,pointKeys,pointNames,setupMode,setupIndex,setupHwnd,profiles
    global coordDiagnosticText,serverDisconnectLast
    global invConfigured,invSetupMode,invSetupStep,invRunning,invCurrentProfile,invProcessed,invTotal,invStatus,invStartPage,invStartRow,invEndPage,invEndRow,invSpeed,invSetupHotkey
    global invPaused,invStartHotkey,invPauseHotkey,invStopHotkey
    global layoutAutoRestore,layoutStatus,layoutRestored,layoutSkipped
    global autoSwitchRunning,autoSwitchCurrentIdx,autoSwitchNextAt,switchStopHotkey,autoSwitchRecoveryPaused,autoSwitchPausedRemainMs

    if !webReady || !WVCore
        return

    mon:=0
    abnormal:=0
    for p in profiles {
        if p.state="監控中"
            mon+=1
        if p.state="需要人工處理" || p.state="恢復失敗"
            abnormal+=1
    }

    accounts:="["
    for i,p in profiles {
        if i>1
            accounts.=","
        hp:=MemoryHPDisplayStatus(p)
        accounts.="{"
            . '"index":' i
            . ',"name":"' JsonEscapeWeb(p.name) '"'
            . ',"account":"' JsonEscapeWeb(p.account) '"'
            . ',"state":"' JsonEscapeWeb(p.state) '"'
            . ',"pid":' (p.pid+0)
            . ',"hwnd":' (p.hwnd+0)
            . ',"hasPos":' (p.hasPos ? "true":"false")
            . ',"winX":' (p.winX+0)
            . ',"winY":' (p.winY+0)
            . ',"winW":' (p.winW+0)
            . ',"winH":' (p.winH+0)
            . ',"hp":"' JsonEscapeWeb(hp) '"'
            . ',"hpOk":' (p.memHpReadOk ? "true":"false")
            . ',"location":"' JsonEscapeWeb(NotificationLocationText(p)) '"'
            . ',"deaths":' (p.hpEventNo+0)
            . ',"revives":' (p.hpReviveNo+0)
            . ',"soft":' (p.softDetect ? "true":"false")
            . ',"softAutoRecover":' ((p.HasOwnProp("softAutoRecover") && p.softAutoRecover) ? "true":"false")
            . ',"recoveryFirst":' (ProfileRecoveryFirst(p) ? "true":"false")
          . ',"deathAlarm":' ((p.HasOwnProp("deathAlarm") ? p.deathAlarm : 1) ? "true":"false")
            . ',"memHp":' (p.memHp+0)
            . ',"memHpMin":' (p.memHpMin+0)
            . ',"memHpMax":' (p.memHpMax+0)
            . ',"memHpLearnedMax":' ProfileMaxHP(p)
            . ',"hpSource":"' (GameOffsetsReady(p.pid) ? "PDB" : "校正") '"'
            . ',"srvStaticSec":' SignalServerStaticSec(p)
            . ',"memHpChanges":' (p.memHpChanges+0)
            . ',"memHpStaticSec":' Floor(Max(0,A_TickCount-p.memHpLastChangeTick)/1000)
            . ',"memHpMaxStaticSec":' Floor((p.HasOwnProp("memHpMaxStaticMs") ? p.memHpMaxStaticMs : 0)/1000)
            . ',"memHpStaticCount":' (p.HasOwnProp("memHpStaticCount") ? p.memHpStaticCount : 0)
            . DeathStatsJson(p)
            . AutoAttackJson(p)
            . ActivityJson(p)
            . ',"memHpGraceSec":' (p.HasOwnProp("memHpGraceUntil") ? Ceil(Max(0,p.memHpGraceUntil-A_TickCount)/1000) : 0)
            . ',"memHpReadOk":' (p.memHpReadOk ? "true":"false")
            . ',"memHpState":"' JsonEscapeWeb(p.memHpState) '"'
            . ',"memSoftState":"' JsonEscapeWeb(p.memSoftState) '"'
            . ',"switchEnabled":' (p.switchEnabled ? "true":"false")
            . ',"switchSeconds":' (p.switchSeconds+0)
            . ',"switchKeys":"' JsonEscapeWeb(p.switchKeys) '"'
            . ',"enabled":' (p.enabled ? "true":"false")
            . ',"launch":' (p.launchEnabled ? "true":"false")
            . ',"deathDetect":' (p.deathDetect ? "true":"false")
            . ',"deathNotify":' (p.deathNotify ? "true":"false")
            . ',"hasPassword":' (p.password!="" ? "true":"false")
            . ',"loginNote":"' JsonEscapeWeb(p.HasOwnProp("loginNote") ? p.loginNote : "") '"'
            . ',"recoveryStage":"' JsonEscapeWeb(WebRecoveryStage(p)) '"'
            . "}"
    }
    accounts.="]"

    games:="["
    for i,grow in gameRows {
        if i>1
            games.=","
        owner:=grow.owner!="" ? grow.owner : "未綁定"
        ; v1.3.18.5：網頁只顯示使用者看得懂的資訊（遊戲中的角色名稱 / 已連接的帳號）
        charName:=ReadGameCharName(grow.pid)
        label:="遊戲視窗 " i "｜" (charName!="" ? "角色 " charName : "尚未進入遊戲") "｜" (grow.owner!="" ? "已連接：" grow.owner : "未連接")
        games.='{"index":' i ',"label":"' JsonEscapeWeb(label) '","owner":"' JsonEscapeWeb(owner) '"}'
    }
    games.="]"

    pointState:="["
    for i,k in pointKeys {
        if i>1
            pointState.=","
        configured:=points.Has(k)
        nx:=configured ? Round(points[k].nx,4) : 0
        ny:=configured ? Round(points[k].ny,4) : 0
        pointState.='{"index":' i ',"key":"' k '","name":"' JsonEscapeWeb(pointNames[i])
            . '","configured":' (configured ? "true":"false")
            . ',"nx":' nx ',"ny":' ny '}'
    }
    pointState.="]"

    mapProfiles:="["
    for i,p in profiles {
        if i>1
            mapProfiles.=","
        mapProfiles.='{"index":' i ',"name":"' JsonEscapeWeb(p.name) '"}'
    }
    mapProfiles.="]"

    mapRow:=LocationProfileDDL.Value
    mapResult:="不確定"
    if mapRow>=1 && mapRow<=profiles.Length
        mapResult:=NotificationLocationText(profiles[mapRow])

    iniInfo:="Profiles=" profiles.Length " | " PROFILE_INI
    coordInfo:=GetCoordTargetInfo(setupHwnd)
    coordClientText:=coordInfo.valid ? (coordInfo.w " × " coordInfo.h) : "未偵測"
    coordDpiText:=coordInfo.valid ? (coordInfo.dpi " / " Round(coordInfo.dpi/96*100) "%") : "—"
    swInfo:=GetAutoSwitchRuntimeInfo()
    payload:='{"type":"state","data":{'
        . '"running":' (running ? "true":"false")
        . ',"monitoring":' mon
        . ',"total":' profiles.Length
        . ',"abnormal":' abnormal
        . ',"queue":' recoveryQueue.Length
        . ',"selectedProfile":' webSelectedProfile
        . ',"selectedGame":' webSelectedGame
        . ',"gameCount":' gameRows.Length
        . ',"uptimeSec":' Floor((A_TickCount-appStartTick)/1000)
        . ',"launcher":"' JsonEscapeWeb(LauncherEdit.Value) '"'
        . ',"postKeys":"' JsonEscapeWeb(PostKeysEdit.Value) '"'
        . ',"coordConfigured":' ((PointsConfigured() || LoginMemoryAvailable()) ? "true":"false") ',"loginMemory":' (LoginMemoryAvailable() ? "true":"false")
        . ',"coordSetup":' (setupMode ? "true":"false")
        . ',"coordIndex":' setupIndex
        . ',"coordTargetValid":' (setupMode && setupHwnd && WinExist("ahk_id " setupHwnd) ? "true":"false")
        . ',"coordClient":"' JsonEscapeWeb(coordClientText) '"'
        . ',"coordDpi":"' JsonEscapeWeb(coordDpiText) '"'
        . ',"coordDiagnostic":"' JsonEscapeWeb(coordDiagnosticText) '"'
        . ',"serverDisconnectLast":"' JsonEscapeWeb(serverDisconnectLast) '"'
        . ',"points":' pointState
        . ',"mapConfidence":' (ConfEdit.Value+0)
        . ',"mapZoom":' (ZoomCountEdit.Value+0)
        . ',"mapReturn":"' JsonEscapeWeb(ReturnKeyEdit.Value) '"'
        . ',"mapSelected":' mapRow
        . ',"mapResult":"' JsonEscapeWeb(mapResult) '"'
        . ',"mapProfiles":' mapProfiles
        . ',"discordEnabled":' (DiscordEnableCB.Value ? "true":"false")
        . ',"discordPc":"' JsonEscapeWeb(DiscordPcEdit.Value) '"'
        . ReportsJson()
        . ',"discordHasWebhook":' (Trim(DiscordWebhookEdit.Value)!="" ? "true":"false")
        . ',"deathDiscordEnabled":' (DeathDiscordEnableCB.Value ? "true":"false")
        . ',"alarmEnabled":' (DeathAlarmEnableCB.Value ? "true":"false")
        . ',"alarmSeconds":' Max(5,Min(300,DeathAlarmSecondsEdit.Value+0))
        . ',"deathDiscordHasWebhook":' (Trim(DeathDiscordWebhookEdit.Value)!="" ? "true":"false")
        . ',"softEnabled":' (SoftEnableCB.Value ? "true":"false")
        . ',"softIdle":' (SoftIdleEdit.Value+0)
        . ',"softConfirm":' (SoftConfirmEdit.Value+0)
        . ',"softMinVotes":' (SoftMinVotesEdit.Value+0)
        . ',"softMultiAssist":' (SoftMultiAssistCB.Value ? "true":"false")
        . ',"softAutoRecover":' (SoftAutoRecoverCB.Value ? "true":"false")
        . ',"evidenceBusy":' (softEvidenceBusy ? "true":"false")
        . ',"iniInfo":"' JsonEscapeWeb(iniInfo) '"'
        . ',"autoSwitchRunning":' (autoSwitchRunning ? "true":"false")
        . ',"autoSwitchCurrentIdx":' autoSwitchCurrentIdx
        . ',"autoSwitchRemain":' swInfo.remain
        . ',"autoSwitchCurrentName":"' JsonEscapeWeb(swInfo.currentName) '"'
        . ',"autoSwitchCurrentHwnd":' swInfo.currentHwnd
        . ',"autoSwitchNextName":"' JsonEscapeWeb(swInfo.nextName) '"'
        . ',"autoSwitchNextHwnd":' swInfo.nextHwnd
        . ',"autoSwitchTotalSeconds":' swInfo.total
        . ',"switchStopHotkey":"' JsonEscapeWeb(switchStopHotkey) '"'
        . ',"layoutAutoRestore":' (layoutAutoRestore ? "true":"false")
        . ',"miniWindow":' (MINI_ENABLED ? "true":"false")
        . ',"uiTheme":"' JsonEscapeWeb(IniRead(INI,"UI","Theme","")) '"'
        . ',"layoutStatus":"' JsonEscapeWeb(layoutStatus) '"'
        . ',"layoutRestored":' layoutRestored
        . ',"layoutSkipped":' layoutSkipped
        . ',"inventoryConfigured":' (invConfigured ? "true":"false")
        . ',"inventorySetupMode":' (invSetupMode ? "true":"false")
        . ',"inventorySetupStep":' invSetupStep
        . ',"inventoryRunning":' (invRunning ? "true":"false")
        . ',"inventoryCurrentProfile":' invCurrentProfile
        . ',"inventoryProcessed":' invProcessed
        . ',"inventoryTotal":' invTotal
        . ',"inventoryStatus":"' JsonEscapeWeb(invStatus) '"'
        . ',"inventoryStartPage":' invStartPage
        . ',"inventoryStartRow":' invStartRow
        . ',"inventoryEndPage":' invEndPage
        . ',"inventoryEndRow":' invEndRow
        . ',"inventorySpeed":"' JsonEscapeWeb(invSpeed) '"'
        . ',"inventorySetupHotkey":"' JsonEscapeWeb(invSetupHotkey) '"'
        . ',"inventoryBindings":' BuildInventoryBindingsJson()
        . ',"inventoryWindows":' BuildInventoryWindowsJson()
        . ',"inventoryProfileCandidates":' BuildInventoryProfileCandidatesJson()
        . ',"accounts":' accounts
        . ',"games":' games
        . '}}'
    try WVCore.PostWebMessageAsJson(payload)
}


WebRecoveryStage(p) {
    if p.state="排隊中"
        return "等待自動重新登入"
    if p.state="恢復中"
        return "自動重新登入中"
    if p.state="恢復失敗"
        return "等待重試"
    if p.state="需要人工處理"
        return "需要人工處理"
    if p.state="人工操作"
        return "人工操作"
    return ""
}

; H-003: 「角色 → 🔁 重新登入」分頁的成功率卡片資料（最近 7 天，只讀日誌，不影響任何自動操作）。
RecoveryStatsPushWeb() {
    global webReady,WVCore
    if !webReady || !WVCore
        return
    payload:='{"type":"recstats","data":' RecView_JsonCached(A_ScriptDir "\Logs",FormatTime(,"yyyy-MM-dd"),7) '}'
    try WVCore.PostWebMessageAsJson(payload)
}

WebPushEvent(level,messageText,stamp:="") {
    global webReady,WVCore
    if !webReady || !WVCore
        return
    if stamp=""
        stamp:=FormatTime(,"HH:mm:ss")
    payload:='{"type":"event","data":{"time":"' JsonEscapeWeb(stamp)
        . '","level":"' JsonEscapeWeb(level)
        . '","text":"' JsonEscapeWeb(messageText) '"}}'
    try WVCore.PostWebMessageAsJson(payload)
}

WebFileUri(path) {
    path:=StrReplace(path,"\","/")
    path:=StrReplace(path," ","%20")
    path:=StrReplace(path,"#","%23")
    return "file:///" path
}

JsonEscapeWeb(value) {
    value:=StrReplace(value,"\","\\")
    value:=StrReplace(value,'"','\"')
    value:=StrReplace(value,"`r","\r")
    value:=StrReplace(value,"`n","\n")
    if RegExMatch(value, "[\x00-\x1f]")   ; 其他控制字元（Tab、遊戲文字裡的色碼…）在 JSON 裡不合法，會讓整則訊息被丟掉
        Loop 31   ; Chr(0) 不能當搜尋字串（會被當成空字串），字串裡本來也不會有
            value:=StrReplace(value,Chr(A_Index),Format("\u{:04x}",A_Index))
    return value
}
