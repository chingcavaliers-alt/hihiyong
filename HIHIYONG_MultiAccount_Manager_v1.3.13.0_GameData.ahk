#Requires AutoHotkey v2.0
#SingleInstance Force
#Include *i Lib\WebView2\WebView2.ahk
Persistent

SendMode "Event"
SetKeyDelay 60, 60
SetMouseDelay 60
CoordMode "Mouse", "Screen"

global APP_VERSION := "v1.3.41.0"
global APP_TITLE := "HIHIYONG 多帳號管理器 " APP_VERSION " Game Data"
global GAME_TITLE := "HIHIYong2.0"
global UPDATE_TITLE := "Update - HiHiYong"
global INI := A_ScriptDir "\HIHIYONG_AutoRecovery.ini"
global PROFILE_INI := A_ScriptDir "\HIHIYONG_Recovery_Profiles.ini"
global EVENT_LOG := A_ScriptDir "\HIHIYONG_Recovery_Events.log"
global MAX_AUTO_FAILURES := 3
global RECOVERY_FOCUS_RETRY_SEC := 60
global appStartTick := A_TickCount

global abortRequested := false
global running := false
global processingQueue := false
global profiles := []
global recoveryQueue := []
global queued := Map()
global manualRecovery := Map()
global refreshingLV := false
global gameRows := []
global pointKeys := ["server","channel","connect","account","password","login","char","startgame"]
global points := Map()
global setupMode := false
global setupIndex := 0
global setupHwnd := 0
global setupTemp := Map()
global SCREEN_TEMPLATE_DIR := A_ScriptDir "\LoginReadyTemplates"
global recoveryStage := Map()
global pointNames := ["伺服器","唯一分流","連線","帳號欄","密碼欄","確認登入","左側角色","開始遊戲"]
global setupKeyState := Map("F7", false, "F6", false)
global HP_ROI_X:=42, HP_ROI_Y:=0, HP_ROI_W:=180, HP_ROI_H:=28
global HP_ALIVE_RED:=0.30158730158730157
global HP_DEAD_RED:=0.0043650793650793652
global HP_DEATH_CONFIRM_MS:=250
global HP_REVIVE_CONFIRM_MS:=250
global MEMORY_HP_SAMPLE_MS:=50
global MEMORY_HP_ZERO_CONFIRM_SAMPLES:=5
global MEMORY_HP_ALIVE_CONFIRM_SAMPLES:=5
global MEMORY_HP_RECOVERY_GRACE_MS:=30000
; v1.3.11.1: read-only Memory HP is the primary HP/death source. Screen ROI remains fallback only.
global MEMORY_HP_OFFSET:=0xED4880 ; 2026-10-04 dynamic validation: 76 changes / single candidate
global HP_CALIBRATION_MS:=30000
global hpCalibration:=0 ; Array of concurrent calibration jobs in v1.3.12.5
; v1.3.12.6: 自動校正模式（維修後）不跳 MsgBox；失敗後隔一段時間再試。
global hpCalibrationAuto:=false
global hpAutoCalibNextTick:=0
global HP_AUTO_CALIB_RETRY_MS:=120000
; v1.3.12.6: 新 session 連續這麼久都讀不到合理 HP，就判定 offset 失效（多半是維修更新），改走自動校正。
global MEMORY_HP_SUSPECT_MS:=60000
; v1.3.18.8：伺服器時間停止更新的假在線門檻（秒）
global SOFT_SRV_SUSPECT_SEC:=Integer(IniRead(INI,"SoftDetect","ServerStallSuspectSec","40"))
global SOFT_SRV_CONFIRM_SEC:=Integer(IniRead(INI,"SoftDetect","ServerStallConfirmSec","60"))
global MEMORY_HP_RUNTIME_OFFSET:=Integer(IniRead(INI,"MemoryHP","LastDetectedOffset",MEMORY_HP_OFFSET))
; v1.3.12.6: offset 綁定 game.exe 版本（PE TimeDateStamp + 映像大小）；版本變了就不沿用舊 offset。
global MEMORY_HP_BUILD:=IniRead(INI,"MemoryHP","BuildStamp","")
; v1.3.13.0: Game.pdb 資料位置（HP / 金幣 / 經驗 / 背包）與每日背包統計。
#Include modules\GameData.ahk
#Include modules\InventoryStats.ahk
; v1.3.14.0: 背景等待遊戲載入（佇列不再被慢載入卡住）與假在線訊號紀錄。
#Include modules\AsyncLoading.ahk
#Include modules\Signals.ahk
; v1.3.15.0: 每日道具資料；v1.3.16.0: 到期提醒與示範錄製。
#Include modules\DailyItems.ahk
#Include modules\Recorder.ahk
; v1.3.17.0: 自動更換每日道具。
#Include modules\DailyRoutine.ahk
; v1.3.18.0: 卡復活自動點復活鍵。
#Include modules\ReviveAssist.ahk
; v1.3.18.7: 每日角色死亡次數。
#Include modules\DeathStats.ahk
; v1.3.18.8: 自動攻擊（F6）狀態；截圖存證、定時截圖、每日報表。
#Include modules\AutoAttack.ahk
#Include modules\Reports.ahk
; v1.3.18.9: 每日擊殺統計（依地圖、怪物種類）。
#Include modules\KillStats.ahk
; v1.3.18.11: 自動採礦用的遊戲資料讀取（示範錄製會記錄位置 / 坐騎 / 技能欄 / 附近礦石）。
#Include modules\Mining.ahk
; v1.3.21.0: 重新登入完成度（選角畫面補按、記憶體確認、登入後 3 分鐘檢查、一直死亡時檢查 F6）。
#Include modules\RecoveryGuard.ahk
; v1.3.22.0: 桌面捷徑與自訂圖示（設定 → 其他）。
#Include modules\DesktopShortcut.ahk
; H-004: 重新登入排程的排入邏輯（隊長優先、載入中 / 重複略過）。
#Include modules\RecoveryQueue.ahk
; H-039: 斷線重新登入一整批結束後，把所有遊戲畫面合成一張傳到 Discord。
#Include modules\RecoveryBatch.ahk
; H-003: 重新登入統計（日誌 → 成功率）與其顯示文字 / JSON。
#Include modules\RecoveryStats.ahk
#Include modules\RecoveryStatsView.ahk
; H-006: 夜間安靜模式（時段判斷、緊急判斷、通知累積與合併）。
#Include modules\QuietHours.ahk
; H-009: 前景視窗變化記錄（只寫日誌 FOCUS_CHANGE；INI [FocusWatch] Enabled=0 可關閉）。
#Include modules\FocusWatch.ahk
; H-015: 怪物掉落率（遊戲改版後自動重算；收益統計 → 🎯 掉落率）。
#Include modules\DropRates.ahk
; H-016: 從 GitHub 檢查新版，跳提醒、使用者按了才更新。
#Include modules\Updater.ahk
; H-017: 命運箱子自動開啟（每個角色自選；切到前面按鍵、確認數量減少、切回原本的視窗）。
#Include modules\MBox.ahk
; H-018: 自動組隊（全部登入完成後，隊長邀請設定好的隊員；預設關閉）。
#Include modules\AutoParty.ahk
#Include modules\LoginUi.ahk
#Include modules\SkillCombo.ahk
#Include modules\NetGuard.ahk
#Include modules\License.ahk
; v1.3.20.0：自動採礦已停用（效益不足），MiningRun.ahk 保留在 Git 紀錄中，不再載入。
; v1.3.12.2 migration: known stale offsets from the previous maintenance must not override the newly validated value.
if MEMORY_HP_RUNTIME_OFFSET=0xE7ADE0 || MEMORY_HP_RUNTIME_OFFSET=0x26B250 {
    MEMORY_HP_RUNTIME_OFFSET:=MEMORY_HP_OFFSET
    IniWrite MEMORY_HP_RUNTIME_OFFSET,INI,"MemoryHP","LastDetectedOffset"
}
global memoryHpModuleSizes:=Map()
global deathAlarmRunning:=false, deathAlarmUntil:=0, deathAlarmPhase:=0
global memoryHpHandles:=Map()
global memoryHpModuleBases:=Map()
global selectedProfileRow:=0
global recentEvents:=[]
global deathWebhook:=""
global deathDiscordEnabled:=0
global softEnabled:=Integer(IniRead(INI,"SoftDisconnect","Enabled","1"))
global softIdleSec:=Integer(IniRead(INI,"SoftDisconnect","IdleSeconds","90"))
global softConfirmSec:=Integer(IniRead(INI,"SoftDisconnect","ConfirmSeconds","30"))
; v1.3.11.1 migration: previous 60+15 defaults are raised to safer 90+30. Custom values are preserved.
if softIdleSec=60 && softConfirmSec=15 {
    softIdleSec:=90
    softConfirmSec:=30
    ; v1.3.11.2: persist the migration so a restart cannot fall back to 60+15.
    IniWrite softIdleSec, INI, "SoftDisconnect", "IdleSeconds"
    IniWrite softConfirmSec, INI, "SoftDisconnect", "ConfirmSeconds"
}
global softMinVotes:=Integer(IniRead(INI,"SoftDisconnect","MinVotes","2"))
global softMultiAssist:=Integer(IniRead(INI,"SoftDisconnect","MultiAssist","1"))
global softAutoRecover:=Integer(IniRead(INI,"SoftDisconnect","AutoRecover","1"))
global softCandidateSince:=0
global softAlerted:=false
global activeRecoveryHwnd:=0
global activeRecoveryPid:=0
global activeRecoveryCommitted:=false
global recoveryUserPauseLogged:=false
global softEvidenceBusy:=false
global softEvidenceDir:=""
global softEvidenceFrame:=0
global softEvidenceEndTick:=0
global pendingHttp:=[]
global emergencyStop:=false
global emergencyF10Down:=0
global emergencyF10Triggered:=false
global fastLoginCritical:=false   ; v1.3.10.13: SERVER_READY -> StartGame 期間略過非必要背景 Timer，F10 緊急停止仍保留
global hpReadableStatus:=Map()
global WebGui:=0
global WVController:=0
global WVCore:=0
global WebNavStartingSub:=0
global WebNavCompletedSub:=0
global webReady:=false
global webSelectedProfile:=0
global webSelectedGame:=0
global coordDiagnosticText := "尚未執行座標診斷"
global serverDisconnectSeen := Map()
global serverDisconnectHandled := Map()
global serverDisconnectLast := "尚未偵測"
global serverDisconnectConfirmMs := 900
global autoSwitchRunning := false
global autoSwitchLastTick := 0
global autoSwitchCurrentIdx := 0
global autoSwitchNextAt := 0
global autoSwitchRecoveryPaused := false
global autoSwitchPausedRemainMs := 0
global switchStopHotkey := ""
global switchStopHotkeyApplied := ""
; v1.3.0 背包清理（多視窗）
global invConfigured := false
global invSetupMode := false
global invSetupStep := 0
global invSetupProfile := 0
global invSetupPts := []
global invGridNX := 0.0, invGridNY := 0.0, invStepNX := 0.0, invStepNY := 0.0
global invDropNX := 0.0, invDropNY := 0.0
global invPageNX := [], invPageNY := []
global invStartPage := 1, invStartRow := 1, invEndPage := 5, invEndRow := 6
global invSpeed := "STABLE"
global invRunning := false
global invStopRequested := false
global invCurrentProfile := 0
global invProcessed := 0, invTotal := 0
global invStatus := "待命"
global invSetupHotkey := "F6"
; v1.3.1 視窗配置還原
global layoutAutoRestore := true
global layoutStatus := "待命"
global layoutRestored := 0
global layoutSkipped := 0
; v1.3.2 背包清理獨立綁定：不再使用 Recovery Profile 的 pid/hwnd 作為清理目標
global invBindings := []   ; [{name,pid,hwnd,enabled}]
global invBindSelected := 0
global invPaused := false
global invStartHotkey := "F3"
global invPauseHotkey := "F8"
global invStopHotkey := "F9"
global invPauseHotkeyApplied := ""
global invStopHotkeyApplied := ""
global invControlKeyState := Map()
global netOutageActive:=false, netDownStreak:=0, netUpStreak:=0






; Compatibility globals used by the proven v0.5.3 recognition functions.
global ZoomCountEdit := 0
global Status := 0

EnsureWebViewDependency() {
    dep:=A_ScriptDir "\Lib\WebView2\WebView2.ahk"
    loader:=A_ScriptDir "\Lib\WebView2\64bit\WebView2Loader.dll"
    if FileExist(dep) && FileExist(loader)
        return true

    ps:=A_ScriptDir "\下載_WebView2相依元件.ps1"
    if !FileExist(ps) {
        MsgBox "缺少 WebView2 相依元件與下載腳本。", "HIHIYONG"
        return false
    }

    answer:=MsgBox("此新版資料夾尚未安裝 WebView2 AHK 相依元件。`n`n按「是」自動安裝，完成後程式會重新啟動。","HIHIYONG v0.9.4","YesNo Iconi")
    if answer!="Yes"
        return false

    try {
        RunWait('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' ps '"',A_ScriptDir,"Hide")
    } catch as err {
        MsgBox "WebView2 相依元件安裝失敗：`n" err.Message,"HIHIYONG"
        return false
    }

    if !FileExist(dep) || !FileExist(loader) {
        MsgBox "下載未完成。`n可手動執行「下載_WebView2相依元件.ps1」，或複製上一版可用的 Lib 資料夾。","HIHIYONG"
        return false
    }

    Run('"' A_AhkPath '" "' A_ScriptFullPath '"')
    ExitApp
}

if !EnsureWebViewDependency()
    ExitApp

; H-042：沒有授權就跳出授權視窗，直到成功或離開
Lic_Gate()
LoadPoints()
LoadProfiles()
Lic_ApplyToProfiles(profiles, licState)
SetTimer(Lic_Tick, 5000)

; v1.3.11.13 one-time targeted max-HP relearn.
; Game update changed the HP reader. Only clear the known stale value for 欸等欸.
ResetKnownStaleMaxHP() {
    global profiles,PROFILE_INI
    for i,p in profiles {
        if p.name="欸等欸" && p.HasOwnProp("memHpLearnedMax") && p.memHpLearnedMax=133163 {
            oldMax:=p.memHpLearnedMax
            p.memHpLearnedMax:=0
            if p.HasOwnProp("memHpLearnedMaxDirty")
                p.memHpLearnedMaxDirty:=0
            if p.HasOwnProp("memHpLearnedMaxSaveTick")
                p.memHpLearnedMaxSaveTick:=A_TickCount
            try IniWrite 0, PROFILE_INI, "Profile_" i, "MemoryHPLearnedMax"
            EventLog(p.name,"HP_MAX_RESET","已清除舊版錯誤最大血量 " oldMax "，等待新版角色血量重新學習")
            return true
        }
    }
    return false
}
ResetKnownStaleMaxHP()
LoadGameOffsets()
LoadItemNameCache()
InventoryStatsInit()
KillStatsInit()
LoadInventoryCleanerConfig()
LoadWindowLayoutConfig()
LoadInventoryBindings()
LoadInventoryControlHotkeys()

; H-009：每秒看一次前景視窗，變成非遊戲、非管理程式時只寫日誌（預設開）。
global focusSeen := Map(), focusRecent := [], focusLastHwnd := 0
if Integer(IniRead(INI,"FocusWatch","Enabled","1"))
    SetTimer(FocusWatchTick, 1000)
FocusWatchTick() {
    global focusSeen, focusRecent, focusLastHwnd
    try {
        w := Focus_Query()
        if (w = "" || w.hwnd = focusLastHwnd)
            return
        focusLastHwnd := w.hwnd
        if !Focus_ShouldLog(w.hwnd, w.proc, w.pid, DllCall("GetCurrentProcessId"), ["game.exe"])
            return
        if !Focus_ShouldEmit(focusSeen, w.hwnd "|" w.pid, A_TickCount)
            return
        EventLog("GLOBAL", "FOCUS_CHANGE", Focus_FormatMessage(w.proc, w.pid, w.title, w.parent))
        Focus_Remember(focusRecent, A_Now, w.proc, w.title)
    }
}

; v1.3.22.0：系統匣 / 視窗圖示用桌面捷徑同一個圖示（app\HiHiyong.ico，沒有就用預設的雙劍）
AppApplyIcon()
g := Gui("+Resize +MinSize1180x760", APP_TITLE)
g.SetFont("s9","Microsoft JhengHei")
g.BackColor := "EAF0F6"
g.SetFont("s11 Bold","Microsoft JhengHei")
g.AddText("x16 y10 w1140 h24","HIHIYONG Multi-Account Manager  " APP_VERSION "  |  Game.pdb Memory / Daily Inventory Stats / 50ms Death Core")
g.SetFont("s9 Norm","Microsoft JhengHei")

; Compact dashboard — no dynamic game preview
g.AddGroupBox("x16 y42 w1148 h126","即時監控 Dashboard")
global SummaryTxt := g.AddText("x34 y70 w1110 h28","● 監控中：0　　⚠ 異常：0　　↻ Recovery Queue：0")
global EventLV := g.AddListView("x34 y101 w1110 h54 Grid -Hdr",["時間","最近事件"])
EventLV.ModifyCol(1,85), EventLV.ModifyCol(2,1000)

global MainTabs := g.AddTab3("x16 y180 w1148 h560",["帳號總覽","帳號設定","通報設定","遊戲設定","畫面辨識 / 座標","地圖判定","監控設定","記錄與工具"])

; --- Tab 1 Home ---
MainTabs.UseTab(1)
global LV := g.AddListView("x30 y221 w1120 h355 Grid -Multi Checked",["#","帳號名稱","狀態","登入流程 / Screen Ready","PID","HWND","HP / 監控","死亡偵測","死亡","復活","假在線","位置","恢復","失敗"])
for i,w in [30,105,85,190,60,90,75,65,45,45,55,125,45,40]
    LV.ModifyCol(i,w)
global StartMonitorBtn := g.AddButton("x30 y592 w145 h36","▶ 開始監控")
global StopMonitorBtn := g.AddButton("x185 y592 w135 h36","■ 停止監控")
global ManualRecoverBtn := g.AddButton("x330 y592 w175 h36","↻ 重啟 / Recovery")
global ShowSelectedBtn := g.AddButton("x515 y592 w150 h36","顯示遊戲視窗")
global ResetDeathStatsBtn := g.AddButton("x675 y592 w165 h36","重置死亡 / 復活")
global CheckHpBtn := g.AddButton("x850 y592 w140 h36","檢查全部 HP")
global CalibrateHpBtn := g.AddButton("x30 y638 w300 h36","重新校正角色血量（30 秒）")

; --- Tab 2 Accounts ---
MainTabs.UseTab(2)
global LaunchLV := g.AddListView("x30 y273 w430 h360 Grid -Multi Checked",["#","名稱","帳號","自動登入"])
LaunchLV.ModifyCol(1,35),LaunchLV.ModifyCol(2,110),LaunchLV.ModifyCol(3,175),LaunchLV.ModifyCol(4,85)

g.AddGroupBox("x480 y268 w560 h190","帳號設定")
g.AddText("x500 y300 w55","名稱")
global NameEdit := g.AddEdit("x560 y296 w150")
g.AddText("x730 y300 w45","帳號")
global AccountEdit := g.AddEdit("x775 y296 w235")
g.AddText("x500 y338 w55","密碼")
global PasswordEdit := g.AddEdit("x560 y334 w200 Password")
global PasswordShowBtn := g.AddButton("x765 y334 w72 h24","顯示密碼")
global EnabledCB := g.AddCheckBox("x845 y336 w85","啟用監控")
global LaunchCB := g.AddCheckBox("x935 y336 w75","自動登入")
global DeathDetectCB := g.AddCheckBox("x500 y376 w100","死亡偵測")
global DeathNotifyCB := g.AddCheckBox("x610 y376 w115","死亡通報")
global SoftDetectCB := g.AddCheckBox("x735 y376 w120","假在線偵測")
global SaveProfileBtn := g.AddButton("x500 y413 w110 h30","儲存帳號")
global AddProfileBtn := g.AddButton("x620 y413 w110 h30","新增帳號")
global DeleteProfileBtn := g.AddButton("x740 y413 w110 h30","刪除帳號")
global BatchStartBtn := g.AddButton("x860 y413 w150 h30","批次自動登入")

g.AddGroupBox("x480 y472 w560 h161","遊戲視窗綁定")
g.AddText("x500 y500 w75","遊戲視窗")
global GameList := g.AddDropDownList("x580 y496 w430")
global RefreshGamesBtn := g.AddButton("x500 y536 w95 h30","重新掃描")
global BindBtn := g.AddButton("x605 y536 w105 h30","綁定此帳號")
global UnbindBtn := g.AddButton("x720 y536 w95 h30","解除綁定")
global CenterBtn := g.AddButton("x825 y536 w85 h30","顯示視窗")
global RecordPosBtn := g.AddButton("x920 y536 w90 h30","記錄位置")
global BindingInfoTxt := g.AddText("x500 y580 w510 h42","PID：-　HWND：-　- x -　（未綁定）")

; --- Tab 3 Notifications ---
MainTabs.UseTab(3)
g.AddGroupBox("x30 y273 w1010 h100","Recovery / 斷線 Discord")
global DiscordEnableCB := g.AddCheckBox("x50 y305 w90","啟用")
DiscordEnableCB.Value := Integer(IniRead(INI,"Discord","Enabled","0"))
g.AddText("x150 y308 w80","Webhook")
global DiscordWebhookEdit := g.AddEdit("x230 y302 w600 Password")
_encWebhook := IniRead(INI,"Discord","Webhook","")
if _encWebhook != "" {
    try DiscordWebhookEdit.Value := DPAPIUnprotect(_encWebhook)
}
global DiscordPcEdit := g.AddEdit("x840 y302 w100",IniRead(INI,"Discord","PCName",A_ComputerName))
global DiscordTestBtn := g.AddButton("x950 y300 w70 h30","測試")
g.AddGroupBox("x30 y398 w1010 h110","死亡事件 Discord（與 Recovery 分開）")
global DeathDiscordEnableCB := g.AddCheckBox("x50 y430 w90","啟用")
DeathDiscordEnableCB.Value := Integer(IniRead(INI,"DeathDiscord","Enabled","0"))
g.AddText("x150 y423 w80","Webhook")
global DeathDiscordWebhookEdit := g.AddEdit("x230 y427 w600 Password")
_encDeath := IniRead(INI,"DeathDiscord","Webhook","")
if _encDeath != "" {
    try DeathDiscordWebhookEdit.Value := DPAPIUnprotect(_encDeath)
}
global DeathDiscordTestBtn := g.AddButton("x950 y425 w70 h30","測試")
g.AddText("x50 y470 w900","正常死亡不立即通知；確認復活結案後一次通報。死亡超過 30 秒未復活仍會立即警報。")

g.AddGroupBox("x30 y520 w1010 h105","死亡統計 / 本機長時間警報")
global DeathResetOnMonitorCB := g.AddCheckBox("x50 y550 w245","開始監控時清除死亡 / 復活累積")
DeathResetOnMonitorCB.Value := Integer(IniRead(INI,"DeathAlert","ResetOnMonitorStart","0"))
global DeathAlarmEnableCB := g.AddCheckBox("x330 y550 w165","30 秒未復活播放警報音")
DeathAlarmEnableCB.Value := Integer(IniRead(INI,"DeathAlert","SoundEnabled","1"))
g.AddText("x520 y554 w65","持續秒數")
global DeathAlarmSecondsEdit := g.AddEdit("x590 y548 w55 Number",IniRead(INI,"DeathAlert","SoundSeconds","30"))
global DeathAlarmTestBtn := g.AddButton("x675 y546 w120 h30","測試警報音")
global DeathAlarmStopBtn := g.AddButton("x805 y546 w120 h30","停止警報音")
g.AddText("x50 y588 w900","警報音使用 Windows 系統蜂鳴音循環播放；Discord 訊息照常發送。")

; H-006 夜間安靜模式（預設關閉）
g.AddGroupBox("x30 y635 w1010 h85","夜間安靜模式")
global QuietEnableCB := g.AddCheckBox("x50 y662 w170","🌙 夜間安靜模式")
QuietEnableCB.Value := Integer(IniRead(INI,"QuietHours","Enabled","0"))
g.AddText("x240 y665 w45","開始")
global QuietStartEdit := g.AddEdit("x285 y660 w60",IniRead(INI,"QuietHours","Start","01:00"))
g.AddText("x360 y665 w45","結束")
global QuietEndEdit := g.AddEdit("x405 y660 w60",IniRead(INI,"QuietHours","End","08:00"))
g.AddText("x480 y665 w530","格式 HH:mm（例如 01:00 ～ 08:00，可跨午夜）")
g.AddText("x50 y692 w980","安靜時段內的一般通知先收起來，早上一次送出；需要人工處理或斷線的緊急通知照常立即送。")

; --- Tab 4 Launcher ---
MainTabs.UseTab(4)
g.AddGroupBox("x30 y273 w1010 h250","遊戲程式啟動設定")
g.AddText("x50 y308 w80","Launcher")
global LauncherEdit := g.AddEdit("x135 y303 w650",IniRead(INI,"General","Launcher","D:\HiHiYong\Launcher.exe"))
global BrowseLauncherBtn := g.AddButton("x800 y302 w100 h30","選擇檔案")
g.AddText("x50 y358 w80","登入後按鍵")
global PostKeysEdit := g.AddEdit("x135 y353 w220",IniRead(INI,"General","PostKeys","F5,F6,A"))
g.AddText("x50 y408 w900","此頁只管理遊戲啟動流程；帳號與 game.exe 視窗綁定已移至「帳號管理」。")
; --- Tab 5 Coordinates ---
MainTabs.UseTab(5)
g.AddGroupBox("x30 y273 w1010 h225","登入座標設定")
global CoordStatus := g.AddText("x50 y308 w940 h28","座標：" (PointsConfigured() ? "已設定 8/8" : "尚未設定"))
global SetupBtn := g.AddButton("x50 y353 w220 h34","設定 8 點登入座標（F7 記錄）")
global ClearPointsBtn := g.AddButton("x285 y353 w120 h34","清除座標")
global RecordPointBtn := g.AddButton("x420 y353 w170 h34","記錄目前位置（同 F7）")
g.AddText("x50 y408 w940","依序：伺服器 → 分流 → 連線 → 帳號 → 密碼 → 登入 → 左側角色 → 開始遊戲。設定中：移動滑鼠到目標後按 F7 記錄。")

; --- Tab 6 Location ---
MainTabs.UseTab(6)
g.AddGroupBox("x30 y273 w1010 h225","地圖 / 位置判定")
g.AddText("x50 y308 w85","判定門檻")
global ConfEdit := g.AddEdit("x135 y303 w60 Number",IniRead(INI,"Recognition","Confidence","70"))
g.AddText("x225 y308 w105","拉遠滾輪次數")
global ZoomCountEdit := g.AddEdit("x335 y303 w60 Number",IniRead(INI,"Recognition","ZoomCount","8"))
g.AddText("x425 y308 w60","前點卡")
global ReturnKeyEdit := g.AddEdit("x490 y303 w60",IniRead(INI,"Recognition","ReturnKey","W"))

global LocationNowTxt := g.AddText("x50 y350 w930 h28","判定位置：不確定")
g.AddText("x50 y398 w70","測試帳號")
global LocationProfileDDL := g.AddDropDownList("x120 y393 w180")
global TestLocationBtn := g.AddButton("x315 y393 w180 h32","測試選定帳號位置")
g.AddText("x510 y398 w500 h24","背景監控不切換視窗；此按鈕只測試下拉選定帳號。")
g.AddText("x50 y445 w930 h38","怪物區 / 復活點參與安全邏輯；精確地圖名稱僅供通知與記錄。信心不足時顯示「地圖無法確認」。")

; --- Tab 7 Monitoring ---
MainTabs.UseTab(7)
g.AddGroupBox("x30 y273 w1010 h225","監控 / 假在線設定")
global SoftEnableCB := g.AddCheckBox("x50 y308 w160","啟用多帳號假在線偵測")
SoftEnableCB.Value := softEnabled
g.AddText("x50 y353 w120","HP 靜止候選")
global SoftIdleEdit := g.AddEdit("x170 y348 w55 Number",softIdleSec)
g.AddText("x230 y353 w35","秒")
g.AddText("x300 y353 w90","二次確認")
global SoftConfirmEdit := g.AddEdit("x390 y348 w55 Number",softConfirmSec)
g.AddText("x450 y353 w35","秒")
g.AddText("x520 y353 w90","最少帳號")
global SoftMinVotesEdit := g.AddEdit("x610 y348 w55 Number",softMinVotes)
global SoftMultiAssistCB := g.AddCheckBox("x700 y348 w220","多視窗輔助判定（60秒）")
SoftMultiAssistCB.Value := softMultiAssist
global SoftAutoRecoverCB := g.AddCheckBox("x50 y398 w420","假在線確認後自動 Recovery")
SoftAutoRecoverCB.Value := softAutoRecover
g.AddText("x50 y443 w930","兩階段判定：HP 同步靜止達門檻後進入疑似狀態；二次確認仍異常時，自動關閉該批異常視窗並加入 Recovery Queue。")
global TestEvidenceBtn := g.AddButton("x50 y480 w190 h30","測試20秒雙螢幕記錄")
g.AddText("x260 y486 w720","F7 長按 0.3 秒：緊急停止全部自動化；不關閉遊戲、不解除綁定。")

; --- Tab 8 Logs ---
MainTabs.UseTab(8)
global LogViewerBtn := g.AddButton("x50 y298 w180 h34","執行紀錄 / Log")
global SaveAllBtn := g.AddButton("x245 y298 w150 h34","儲存全部設定")
global Status := g.AddText("x50 y358 w950 h30","狀態：待命")
g.AddText("x50 y408 w930","可關閉「假在線確認後自動 Recovery」改為只通報；開啟時，二次確認成立會自動重新登入。")

MainTabs.UseTab()

; Events
LV.OnEvent("ItemSelect", OnProfileSelect)
LV.OnEvent("ItemCheck", OnProfileCheck)
LaunchLV.OnEvent("ItemSelect", OnLaunchProfileSelect)
LaunchLV.OnEvent("ItemCheck", OnLaunchProfileCheck)
EnabledCB.OnEvent("Click", ProfileOptionChanged)
LaunchCB.OnEvent("Click", ProfileOptionChanged)
DeathDetectCB.OnEvent("Click", ProfileOptionChanged)
DeathNotifyCB.OnEvent("Click", ProfileOptionChanged)
SoftDetectCB.OnEvent("Click", ProfileOptionChanged)
SaveProfileBtn.OnEvent("Click", SaveSelectedProfile)
AddProfileBtn.OnEvent("Click", AddProfile)
PasswordShowBtn.OnEvent("Click", ToggleNativePasswordVisibility)
DeleteProfileBtn.OnEvent("Click", DeleteProfile)
RefreshGamesBtn.OnEvent("Click", RefreshGames)
GameList.OnEvent("Change", OnGameListChanged)
BindBtn.OnEvent("Click", BindSelected)
UnbindBtn.OnEvent("Click", UnbindSelected)
RecordPosBtn.OnEvent("Click", RecordWindowPosition)
CenterBtn.OnEvent("Click", ShowSelectedGame)
ShowSelectedBtn.OnEvent("Click", ShowSelectedGame)
BatchStartBtn.OnEvent("Click", BatchStartChecked)
StartMonitorBtn.OnEvent("Click", StartMonitoring)
StopMonitorBtn.OnEvent("Click", StopMonitoring)
ManualRecoverBtn.OnEvent("Click", ManualRecover)
DiscordTestBtn.OnEvent("Click", TestDiscordWebhook)
DeathDiscordTestBtn.OnEvent("Click", TestDeathDiscordWebhook)
DeathAlarmTestBtn.OnEvent("Click", TestDeathAlarm)
DeathAlarmStopBtn.OnEvent("Click", StopDeathAlarm)
SetupBtn.OnEvent("Click", StartSetup)
ClearPointsBtn.OnEvent("Click", ClearPoints)
RecordPointBtn.OnEvent("Click", RecordSetupPoint)
SaveAllBtn.OnEvent("Click", SaveGeneral)
LogViewerBtn.OnEvent("Click", ShowLogViewer)
TestLocationBtn.OnEvent("Click", TestSelectedLocation)
ResetDeathStatsBtn.OnEvent("Click", ResetDeathStats)
CheckHpBtn.OnEvent("Click", CheckAllHpReadability)
CalibrateHpBtn.OnEvent("Click", StartDynamicHPCalibration)
TestEvidenceBtn.OnEvent("Click", (*)=>StartSoftEvidenceCapture("手動測試20秒雙螢幕記錄"))
BrowseLauncherBtn.OnEvent("Click", BrowseLauncher)
g.OnEvent("Close", (*) => ExitApp())


SetupKeyMonitor() {
    global setupMode,invSetupMode,invStartHotkey,invPauseHotkey,invStopHotkey
    ; F6/F7 以及背包開始/暫停/終止全部使用 GetAsyncKeyState。
    ; 遊戲吃掉一般 AHK Hotkey 時仍可偵測。
    if setupMode
        CheckSetupApiHotkey("F7", 0x76, RecordSetupPoint)
    if invSetupMode
        CheckSetupApiHotkey("F6", 0x75, InventoryCleanerSetupHotkey)

    CheckInventoryAsyncHotkey(invStartHotkey, InventoryHotkeyStart)
    CheckInventoryAsyncHotkey(invPauseHotkey, InventoryHotkeyPause)
    CheckInventoryAsyncHotkey(invStopHotkey, InventoryHotkeyStop)
}

InventoryHotkeyStart() {
    global invRunning
    if invRunning
        return
    StartMultiInventoryCleaner()
}

InventoryHotkeyPause() {
    ToggleInventoryPause()
}

InventoryHotkeyStop() {
    StopMultiInventoryCleaner()
}

CheckInventoryAsyncHotkey(keyName, callback) {
    global invControlKeyState
    vk:=InventoryHotkeyToVk(keyName)
    if !vk
        return
    state:=DllCall("GetAsyncKeyState","Int",vk,"Short")
    down:=(state & 0x8000)!=0
    previous:=invControlKeyState.Has(keyName) ? invControlKeyState[keyName] : false
    if down && !previous {
        invControlKeyState[keyName]:=true
        ; 以一次性 timer 脫離 GetAsyncKeyState 掃描 callback，再執行控制動作。
        SetTimer(callback,-1)
    }
    if !down
        invControlKeyState[keyName]:=false
}

InventoryHotkeyToVk(keyName) {
    ; 本版遊戲內控制鍵限定 F1~F12，才能可靠用 GetAsyncKeyState。
    keyName:=Trim(keyName)
    if !RegExMatch(keyName,"i)^F(1[0-2]|[1-9])$",&m)
        return 0
    return 0x6F + (m[1]+0)
}

CheckSetupApiHotkey(name, vk, callback) {
    global setupKeyState
    state := DllCall("GetAsyncKeyState", "Int", vk, "Short")
    down := (state & 0x8000) != 0
    previous := setupKeyState[name]

    if (down && !previous) {
        setupKeyState[name] := true
        SetTimer callback, -1
    }
    if !down
        setupKeyState[name] := false
}

SetTimer SetupKeyMonitor, 20
; v1.3.7.1 safety rollback: Network Watch timer disabled to guarantee GUI startup
CleanupOldLogs(30)
RefreshProfileLV()
RefreshGames()
; v1.1: one safe background auto-pair pass at startup. No focus stealing.
SetTimer AutoBindGames, -150
UpdateSummary()

; v1.3.9.8 monitored location scan runtime
global monitorLocationScanBusy:=false
global monitorLocationScanIndex:=1
 ; Startup Fast Path：先讓 WebView 首頁完成，再啟動背景監控 Timer。
; MonitorTick / HP ROI / Memory HP 於 WebNavigationCompleted 啟動。
; v1.3.9.8: 每 8 秒輪到一個 Monitor ON 視窗做一次地圖辨識，避免同時搶前景。
; v1.3.10.3: 地圖辨識改為監控綁定 / Recovery 後事件觸發一次，不再週期輪詢
SetTimer EmergencyStopKeyMonitor, 50
SetTimer AutoWindowSwitchTick, 250
; H-006: 安靜模式累積通知，時段結束後合併送出（啟動後 5 秒檢查一次，之後每 60 秒）。
global QUIET_QUEUE_FILE := A_ScriptDir "\Logs\quiet_queue.txt"
SetTimer QuietFlushTick, -5000
SetTimer QuietFlushTick, 60000
; Network Watch 延後啟動，避免 WebView/GUI 啟動階段被網路探測阻塞。
; Network Watch 僅作佐證，延後到 WebView 完成後啟動。
LoadSwitchStopHotkey()
SkillComboInit()   ; H-027 技能組合快速施法（預設關閉）
g.Show("Hide w1080 h748")
SetTimer InitWebUI, -50

LoadProfiles() {
    global profiles, PROFILE_INI
    profiles := []
    count := Integer(IniRead(PROFILE_INI,"General","Count","0"))
    Loop count {
        sec := "Profile_" A_Index
        enc := IniRead(PROFILE_INI,sec,"Password","")
        pw := ""
        if enc != "" {
            try pw := DPAPIUnprotect(enc)
        }
        profiles.Push({
            enabled: Integer(IniRead(PROFILE_INI,sec,"Enabled","1")),
            launchEnabled: Integer(IniRead(PROFILE_INI,sec,"LaunchEnabled","1")),
            deathDetect: Integer(IniRead(PROFILE_INI,sec,"DeathDetect","1")),
            deathNotify: Integer(IniRead(PROFILE_INI,sec,"DeathNotify","1")),
            softDetect: Integer(IniRead(PROFILE_INI,sec,"SoftDetect","1")),
            softAutoRecover: Integer(IniRead(PROFILE_INI,sec,"SoftAutoRecover","0")),
            recoveryFirst: Integer(IniRead(PROFILE_INI,sec,"RecoveryFirst","0")),
            deathAlarm: Integer(IniRead(PROFILE_INI,sec,"DeathAlarm","1")),
            dailyItems: DailyNormalizeItems(IniRead(PROFILE_INI,sec,"DailyItems",DAILY_ALL_ITEMS)),
            dailyMode: IniRead(PROFILE_INI,sec,"DailyMode","town"),
            dailyWeapon: IniRead(PROFILE_INI,sec,"DailyWeapon",""),
            mboxEnabled: Integer(IniRead(PROFILE_INI,sec,"MBoxEnabled","0")),
            mboxKey: IniRead(PROFILE_INI,sec,"MBoxKey","e"),
            partyLeader: Integer(IniRead(PROFILE_INI,sec,"PartyLeader","0")),
            partyMembers: IniRead(PROFILE_INI,sec,"PartyMembers",""),
            partyRemote: IniRead(PROFILE_INI,sec,"PartyRemote",""),
            partyAccept: Integer(IniRead(PROFILE_INI,sec,"PartyAccept","0")),
            partyAcceptFrom: IniRead(PROFILE_INI,sec,"PartyAcceptFrom",""),
            switchEnabled: Integer(IniRead(PROFILE_INI,sec,"SwitchEnabled","1")),
            switchSeconds: Max(1,Integer(IniRead(PROFILE_INI,sec,"SwitchSeconds","10"))),
            switchKeys: IniRead(PROFILE_INI,sec,"SwitchKeys",""),
            inventoryEnabled: Integer(IniRead(PROFILE_INI,sec,"InventoryEnabled","0")),
            name: IniRead(PROFILE_INI,sec,"Name","帳號" A_Index),
            account: IniRead(PROFILE_INI,sec,"Account",""),
            password: pw,
            hwnd: 0, pid: 0, state:"未綁定", recoveries:0, failures:0,
            winX: Integer(IniRead(PROFILE_INI,sec,"WinX","0")),
            winY: Integer(IniRead(PROFILE_INI,sec,"WinY","0")),
            winW: Integer(IniRead(PROFILE_INI,sec,"WinW","0")),
            winH: Integer(IniRead(PROFILE_INI,sec,"WinH","0")),
            hasPos: Integer(IniRead(PROFILE_INI,sec,"HasPos","0")),
            charName: IniRead(PROFILE_INI,sec,"CharName",""),
            loginChar: IniRead(PROFILE_INI,sec,"LoginChar",""),
            loginCharList: IniRead(PROFILE_INI,sec,"LoginCharList",""),
            hpDeadSince:0,hpFullSince:0,hpEventOpen:0,hpEventTick:0,hpEventNo:Integer(IniRead(PROFILE_INI,sec,"DeathCount","0")),hpReviveNo:Integer(IniRead(PROFILE_INI,sec,"ReviveCount","0")),
            hpNoReviveAlerted:0,hpDeathTime:"",hpLastRatio:-1,hpLastChangeTick:A_TickCount,hpUnreadableSince:0,hpUnreadableLogged:0,
            memHp:-1,memHpMin:-1,memHpMax:-1,memHpLearnedMax:Integer(IniRead(PROFILE_INI,sec,"MemoryHPLearnedMax","0")),memHpConfirmedMax:Integer(IniRead(PROFILE_INI,sec,"MemoryHPConfirmedMax","0")),memHpArmed:0,memHpStale:0,memHpPlausibleStreak:0,memHpUnarmedSince:A_TickCount,memHpSuspectLogged:0,memHpLearnedMaxDirty:0,memHpLearnedMaxSaveTick:A_TickCount,memHpChanges:0,memHpLastChangeTick:A_TickCount,memHpReadOk:0,memHpState:"等待監控",memSoftState:"正常",memSoftAlerted:0,memHpZeroStreak:0,memHpAliveStreak:0,memHpMaxStaticMs:0,memHpStaticCount:0,memHpWasStatic:0,memHpSessionPid:0,memHpGraceUntil:0,memHpOffset:MEMORY_HP_RUNTIME_OFFSET,memHpCalibrating:0,
            locType:"不確定",locConf:0,mapName:"地圖無法確認",mapConf:0
        })
    }
}

SaveProfiles() {
    global profiles, PROFILE_INI
    IniWrite profiles.Length, PROFILE_INI, "General", "Count"
    for i,p in profiles {
        sec := "Profile_" i
        IniWrite Lic_EnabledToSave(p), PROFILE_INI, sec, "Enabled"
        IniWrite Lic_LaunchToSave(p), PROFILE_INI, sec, "LaunchEnabled"
        IniWrite p.deathDetect, PROFILE_INI, sec, "DeathDetect"
        IniWrite p.deathNotify, PROFILE_INI, sec, "DeathNotify"
        IniWrite p.softDetect, PROFILE_INI, sec, "SoftDetect"
        IniWrite (p.HasOwnProp("softAutoRecover") ? p.softAutoRecover : 0), PROFILE_INI, sec, "SoftAutoRecover"
        IniWrite (p.HasOwnProp("recoveryFirst") ? p.recoveryFirst : 0), PROFILE_INI, sec, "RecoveryFirst"
        IniWrite (p.HasOwnProp("deathAlarm") ? p.deathAlarm : 1), PROFILE_INI, sec, "DeathAlarm"
        IniWrite DailyItemsOf(p), PROFILE_INI, sec, "DailyItems"
        IniWrite DailyModeOf(p), PROFILE_INI, sec, "DailyMode"
        IniWrite DailyWeaponOf(p), PROFILE_INI, sec, "DailyWeapon"
        IniWrite (MBoxOn(p) ? 1 : 0), PROFILE_INI, sec, "MBoxEnabled"
        IniWrite MBoxKeyOf(p), PROFILE_INI, sec, "MBoxKey"
        IniWrite (ApIsLeader(p) ? 1 : 0), PROFILE_INI, sec, "PartyLeader"
        IniWrite (p.HasOwnProp("partyMembers") ? p.partyMembers : ""), PROFILE_INI, sec, "PartyMembers"
        IniWrite (p.HasOwnProp("partyRemote") ? p.partyRemote : ""), PROFILE_INI, sec, "PartyRemote"
        IniWrite (p.HasOwnProp("partyAccept") && p.partyAccept ? 1 : 0), PROFILE_INI, sec, "PartyAccept"
        IniWrite (p.HasOwnProp("partyAcceptFrom") ? p.partyAcceptFrom : ""), PROFILE_INI, sec, "PartyAcceptFrom"
        IniWrite p.switchEnabled, PROFILE_INI, sec, "SwitchEnabled"
        IniWrite p.switchSeconds, PROFILE_INI, sec, "SwitchSeconds"
        IniWrite p.switchKeys, PROFILE_INI, sec, "SwitchKeys"
        IniWrite (p.HasOwnProp("inventoryEnabled") ? p.inventoryEnabled : 0), PROFILE_INI, sec, "InventoryEnabled"
        IniWrite p.name, PROFILE_INI, sec, "Name"
        IniWrite p.account, PROFILE_INI, sec, "Account"
        IniWrite DPAPIProtect(p.password), PROFILE_INI, sec, "Password"
        IniWrite p.winX, PROFILE_INI, sec, "WinX"
        IniWrite p.winY, PROFILE_INI, sec, "WinY"
        IniWrite p.winW, PROFILE_INI, sec, "WinW"
        IniWrite p.winH, PROFILE_INI, sec, "WinH"
        IniWrite p.hasPos, PROFILE_INI, sec, "HasPos"
        IniWrite (p.HasOwnProp("charName") ? p.charName : ""), PROFILE_INI, sec, "CharName"
        IniWrite (p.HasOwnProp("loginChar") ? p.loginChar : ""), PROFILE_INI, sec, "LoginChar"
        IniWrite (p.HasOwnProp("loginCharList") ? p.loginCharList : ""), PROFILE_INI, sec, "LoginCharList"
        IniWrite p.hpEventNo, PROFILE_INI, sec, "DeathCount"
        IniWrite p.hpReviveNo, PROFILE_INI, sec, "ReviveCount"
        IniWrite (p.HasOwnProp("memHpLearnedMax") ? p.memHpLearnedMax : 0), PROFILE_INI, sec, "MemoryHPLearnedMax"
        IniWrite (p.HasOwnProp("memHpConfirmedMax") ? p.memHpConfirmedMax : 0), PROFILE_INI, sec, "MemoryHPConfirmedMax"
    }
}

DPAPIProtect(text) {
    if text = ""
        return ""
    bytes := Buffer(StrPut(text,"UTF-8"))
    n := StrPut(text, bytes, "UTF-8") - 1
    inBlob := Buffer(A_PtrSize=8 ? 16 : 8,0)
    NumPut("UInt",n,inBlob,0), NumPut("Ptr",bytes.Ptr,inBlob,A_PtrSize=8 ? 8 : 4)
    outBlob := Buffer(A_PtrSize=8 ? 16 : 8,0)
    ok := DllCall("Crypt32.dll\CryptProtectData","Ptr",inBlob.Ptr,"Ptr",0,"Ptr",0,"Ptr",0,"Ptr",0,"UInt",1,"Ptr",outBlob.Ptr)
    if !ok
        throw Error("Windows DPAPI 密碼加密失敗。")
    cb := NumGet(outBlob,0,"UInt"), ptr := NumGet(outBlob,A_PtrSize=8 ? 8 : 4,"Ptr")
    hex := ""
    Loop cb
        hex .= Format("{:02X}",NumGet(ptr,A_Index-1,"UChar"))
    DllCall("LocalFree","Ptr",ptr)
    return hex
}

DPAPIUnprotect(hex) {
    if hex = ""
        return ""
    cb := StrLen(hex)//2
    data := Buffer(cb,0)
    Loop cb
        NumPut("UChar",Integer("0x" SubStr(hex,(A_Index-1)*2+1,2)),data,A_Index-1)
    inBlob := Buffer(A_PtrSize=8 ? 16 : 8,0)
    NumPut("UInt",cb,inBlob,0), NumPut("Ptr",data.Ptr,inBlob,A_PtrSize=8 ? 8 : 4)
    outBlob := Buffer(A_PtrSize=8 ? 16 : 8,0)
    ok := DllCall("Crypt32.dll\CryptUnprotectData","Ptr",inBlob.Ptr,"Ptr",0,"Ptr",0,"Ptr",0,"Ptr",0,"UInt",1,"Ptr",outBlob.Ptr)
    if !ok
        throw Error("Windows DPAPI 密碼解密失敗。")
    n := NumGet(outBlob,0,"UInt"), ptr := NumGet(outBlob,A_PtrSize=8 ? 8 : 4,"Ptr")
    tmp := Buffer(n+1,0)
    DllCall("RtlMoveMemory","Ptr",tmp.Ptr,"Ptr",ptr,"UPtr",n)
    DllCall("LocalFree","Ptr",ptr)
    return StrGet(tmp,n,"UTF-8")
}

RefreshProfileLV() {
    global LV,LaunchLV,profiles,refreshingLV,recoveryStage
    refreshingLV:=true
    LV.Delete(),LaunchLV.Delete()
    for i,p in profiles {
        loc:=NotificationLocationText(p)
        hpText:=MemoryHPDisplayStatus(p)
        stage:=recoveryStage.Has(i) ? recoveryStage[i] : (ProfileGameAlive(p) ? "遊戲中" : "—")
        LV.Add(p.enabled ? "Check" : "",i,p.name,p.state,stage,p.pid,p.hwnd,hpText,p.deathDetect ? "ON":"OFF",p.hpEventNo,p.hpReviveNo,p.softDetect ? "ON":"OFF",loc,p.recoveries,p.failures)
        LaunchLV.Add(p.launchEnabled ? "Check" : "",i,p.name,p.account,p.launchEnabled ? "ON":"OFF")
    }
    try {
        oldChoice:=LocationProfileDDL.Value
        names:=[]
        for p in profiles
            names.Push(p.name)
        LocationProfileDDL.Delete()
        if names.Length
            LocationProfileDDL.Add(names)
        if names.Length
            LocationProfileDDL.Choose((oldChoice>=1 && oldChoice<=names.Length) ? oldChoice : 1)
    }
    refreshingLV:=false
    UpdateSummary()
}

OnProfileCheck(ctrl, row, checked) {
    global profiles, refreshingLV, EnabledCB, Status
    if refreshingLV || row < 1 || row > profiles.Length
        return
    profiles[row].enabled := checked ? 1 : 0
    EnabledCB.Value := profiles[row].enabled
    SaveProfiles()
    ; 勾選只代表此 Profile 納入「開始監控」範圍，不會立即啟動 Recovery。
    Status.Text := "狀態：" profiles[row].name " → " (checked ? "已勾選監控" : "已取消監控")
    SetTimer RefreshProfileLV, -10
}

OnLaunchProfileCheck(ctrl, row, checked) {
    global profiles, refreshingLV, LaunchCB, Status
    if refreshingLV || row < 1 || row > profiles.Length
        return
    profiles[row].launchEnabled := checked ? 1 : 0
    LaunchCB.Value := profiles[row].launchEnabled
    SaveProfiles()
    Status.Text := "狀態：" profiles[row].name " → " (checked ? "已勾選自動登入" : "已取消自動登入")
    SetTimer RefreshProfileLV, -10
}

OnLaunchProfileSelect(ctrl,row,selected) {
    global LV
    if !selected
        return
    LV.Modify(0,"-Select")
    LV.Modify(row,"Select Focus Vis")
    OnProfileSelect(LV,row,true)
}

OnProfileSelect(ctrl,row,selected) {
    global profiles,NameEdit,AccountEdit,PasswordEdit,EnabledCB,LaunchCB,DeathDetectCB,DeathNotifyCB,SoftDetectCB,selectedProfileRow
    if !selected || row<1 || row>profiles.Length
        return
    selectedProfileRow:=row
    p:=profiles[row]
    NameEdit.Value:=p.name, AccountEdit.Value:=p.account, PasswordEdit.Value:=p.password
    EnabledCB.Value:=p.enabled, LaunchCB.Value:=p.launchEnabled
    DeathDetectCB.Value:=p.deathDetect, DeathNotifyCB.Value:=p.deathNotify, SoftDetectCB.Value:=p.softDetect
    UpdateLocationText(p)
    UpdateBindingInfo(p)
    SyncGameListToProfile(row)
}


ProfileOptionChanged(*) {
    global selectedProfileRow,profiles,EnabledCB,LaunchCB,DeathDetectCB,DeathNotifyCB,SoftDetectCB,Status,LV
    row:=selectedProfileRow
    if row<1 || row>profiles.Length
        return
    p:=profiles[row]
    p.enabled:=EnabledCB.Value ? 1 : 0
    p.launchEnabled:=LaunchCB.Value ? 1 : 0
    p.deathDetect:=DeathDetectCB.Value ? 1 : 0
    p.deathNotify:=DeathNotifyCB.Value ? 1 : 0
    p.softDetect:=SoftDetectCB.Value ? 1 : 0
    SaveProfiles()
    RefreshProfileLV()
    try LV.Modify(row,"Select Vis")
    Status.Text:="狀態：" p.name " 個別監控/通報設定已立即儲存"
}

SaveSelectedProfile(*) {
    global LV,profiles,NameEdit,AccountEdit,PasswordEdit,EnabledCB,LaunchCB,DeathDetectCB,DeathNotifyCB,SoftDetectCB,Status
    row:=LV.GetNext()
    if !row {
        MsgBox "請先選一個帳號。", APP_TITLE
        return
    }
    p:=profiles[row]
    p.name:=Trim(NameEdit.Value), p.account:=Trim(AccountEdit.Value), p.password:=PasswordEdit.Value
    p.enabled:=EnabledCB.Value, p.launchEnabled:=LaunchCB.Value
    p.deathDetect:=DeathDetectCB.Value, p.deathNotify:=DeathNotifyCB.Value, p.softDetect:=SoftDetectCB.Value
    SaveProfiles(), RefreshProfileLV()
    LV.Modify(row,"Select Vis")
    Status.Text:="狀態：已保存 " p.name
}

AddProfile(*) {
    global profiles,MEMORY_HP_RUNTIME_OFFSET
    profiles.Push({enabled:0,launchEnabled:0,deathDetect:1,deathNotify:1,softDetect:1,softAutoRecover:0,switchEnabled:1,switchSeconds:10,switchKeys:"",inventoryEnabled:0,name:"帳號" (profiles.Length+1),account:"",password:"",hwnd:0,pid:0,state:"未綁定",recoveries:0,failures:0,winX:0,winY:0,winW:0,winH:0,hasPos:0,hpDeadSince:0,hpFullSince:0,hpEventOpen:0,hpEventTick:0,hpEventNo:0,hpReviveNo:0,hpNoReviveAlerted:0,hpDeathTime:"",hpLastRatio:-1,hpLastChangeTick:A_TickCount,hpUnreadableSince:0,hpUnreadableLogged:0,memHp:-1,memHpMin:-1,memHpMax:-1,memHpLearnedMax:0,memHpLearnedMaxDirty:0,memHpLearnedMaxSaveTick:A_TickCount,memHpChanges:0,memHpLastChangeTick:A_TickCount,memHpReadOk:0,memHpState:"等待監控",memSoftState:"正常",memSoftAlerted:0,memHpZeroStreak:0,memHpAliveStreak:0,memHpMaxStaticMs:0,memHpStaticCount:0,memHpWasStatic:0,memHpSessionPid:0,memHpGraceUntil:0,memHpOffset:MEMORY_HP_RUNTIME_OFFSET,memHpCalibrating:0,locType:"不確定",locConf:0,mapName:"地圖無法確認",mapConf:0})
    SaveProfiles(), RefreshProfileLV()
    AddRecentEvent("已新增帳號 Profile（預設監控 OFF / 啟動勾選 OFF）")
}

DeleteProfile(*) {
    global LV,profiles
    row:=LV.GetNext()
    if !row
        return
    profiles.RemoveAt(row), SaveProfiles(), RefreshProfileLV()
}

RefreshGames(*) {
    global GameList,gameRows,GAME_TITLE,profiles,LV
    GameList.Delete(), gameRows:=[]
    for hwnd in WinGetList("ahk_exe game.exe") {
        if WinGetTitle("ahk_id " hwnd) != GAME_TITLE
            continue
        pid:=WinGetPID("ahk_id " hwnd)
        mm:=WinGetMinMax("ahk_id " hwnd)
        try WinGetClientPos &x,&y,&w,&h,"ahk_id " hwnd
        catch
            x:=0,y:=0,w:=0,h:=0

        owner:=""
        for p in profiles {
            if (p.hwnd=hwnd || (p.pid=pid && pid!=0)) {
                owner:=p.name
                break
            }
        }

        try WinGetPos &wx,&wy,&ww,&wh,"ahk_id " hwnd
        catch
            wx:=0,wy:=0,ww:=w,wh:=h
        gameRows.Push({hwnd:hwnd,pid:pid,w:w,h:h,wx:wx,wy:wy,ww:ww,wh:wh,owner:owner})
        bindText:=owner!="" ? "（已綁定：" owner "）" : "（未綁定）"
        label:="PID：" pid "　HWND：" hwnd "　" w "x" h "　" bindText "　" (mm=-1 ? "最小化":"可見")
        GameList.Add([label])
    }
    if gameRows.Length {
        ; 優先跳到目前選定帳號已綁定的遊戲視窗；沒有綁定才選第一個。
        row:=LV.GetNext()
        if row
            SyncGameListToProfile(row)
        else
            GameList.Choose(1)
    }
}

AutoBindGames(*) {
    global profiles,gameRows,Status,LV,webSelectedProfile,webSelectedGame

    ; v1.1: refresh only reads window metadata. It never activates a game window.
    RefreshGames()
    if !profiles.Length || !gameRows.Length {
        AddRecentEvent("自動配對：沒有可配對的 Profile 或 game.exe")
        return
    }

    used:=Map()
    ; Preserve every still-valid existing binding first.
    for i,p in profiles {
        if ProfileGameAlive(p) {
            for gi,grow in gameRows {
                if (p.hwnd=grow.hwnd) || (p.pid && p.pid=grow.pid) {
                    used[gi]:=i
                    break
                }
            }
        }
    }

    boundCount:=0
    ; v1.3.18.0 第 0 輪：讀遊戲記憶體裡的角色名稱，和帳號記住的角色名稱比對。
    ; 不看視窗位置，視窗搬到其他螢幕也能配對；沒記過角色名稱的帳號，帳號名稱和角色同名也算。
    gameNames:=Map()
    for gi,grow in gameRows
        if !used.Has(gi)
            gameNames[gi]:=ReadGameCharName(grow.pid)
    for pi,p in profiles {
        if ProfileGameAlive(p)
            continue
        want:=(p.HasOwnProp("charName") && p.charName!="") ? p.charName : p.name
        matchGi:=0,matches:=0
        for gi,charName in gameNames {
            if !used.Has(gi) && charName!="" && charName=want
                matchGi:=gi,matches+=1
        }
        if matches!=1
            continue
        grow:=gameRows[matchGi]
        p.hwnd:=grow.hwnd
        p.pid:=grow.pid
        p.state:="已自動綁定"
        used[matchGi]:=pi
        boundCount+=1
        AddRecentEvent("自動配對成功｜" p.name " → PID " grow.pid "｜依角色名稱 " want)
    }

    ; First pass: saved window position. Only bind when the nearest candidate is
    ; close enough and clearly better than the second candidate.
    for pi,p in profiles {
        if ProfileGameAlive(p) || !p.hasPos
            continue
        bestGi:=0
        bestScore:=999999
        secondScore:=999999
        for gi,grow in gameRows {
            if used.Has(gi) || !CharNameCompatible(p,gameNames.Has(gi) ? gameNames[gi] : "")
                continue
            score:=Abs(grow.wx-p.winX)+Abs(grow.wy-p.winY)+Abs(grow.ww-p.winW)+Abs(grow.wh-p.winH)
            if score<bestScore {
                secondScore:=bestScore
                bestScore:=score
                bestGi:=gi
            } else if score<secondScore {
                secondScore:=score
            }
        }
        ; <=220 tolerates small border/display differences. With multiple candidates,
        ; require an 80-point margin so ambiguous layouts are never guessed.
        if bestGi && bestScore<=220 && (secondScore=999999 || secondScore-bestScore>=80) {
            grow:=gameRows[bestGi]
            p.hwnd:=grow.hwnd
            p.pid:=grow.pid
            p.state:="已自動綁定"
            used[bestGi]:=pi
            boundCount+=1
            AddRecentEvent("自動配對成功｜" p.name " → PID " grow.pid "｜依視窗位置")
        }
    }

    ; Second pass: only one Profile and one game remain. This is deterministic.
    freeProfiles:=[]
    freeGames:=[]
    for pi,p in profiles
        if !ProfileGameAlive(p)
            freeProfiles.Push(pi)
    for gi,grow in gameRows
        if !used.Has(gi)
            freeGames.Push(gi)

    if freeProfiles.Length=1 && freeGames.Length=1
        && CharNameCompatible(profiles[freeProfiles[1]],gameNames.Has(freeGames[1]) ? gameNames[freeGames[1]] : "") {
        pi:=freeProfiles[1]
        gi:=freeGames[1]
        p:=profiles[pi]
        grow:=gameRows[gi]
        p.hwnd:=grow.hwnd
        p.pid:=grow.pid
        p.state:="已自動綁定"
        used[gi]:=pi
        boundCount+=1
        AddRecentEvent("自動配對成功｜" p.name " → PID " grow.pid "｜唯一候選")
    }

    if boundCount {
        ; v1.3.10.9：啟動自動配對只建立 PID/HWND 綁定，不做 MAP_BIND_SCAN。
        ; 地圖辨識會切換/前景化遊戲視窗，六開環境會造成啟動慢且逐一搶焦點。
        ; 位置資訊沿用既有結果，待 Recovery / 使用者主動操作時再更新。
        SaveProfiles()
        RefreshProfileLV()
        RefreshGames()
        Status.Text:="狀態：自動配對完成｜新增 " boundCount " 個綁定"
    } else {
        Status.Text:="狀態：自動配對完成｜沒有安全可確認的新配對"
        AddRecentEvent("自動配對完成｜沒有安全可確認的新配對，保留手動綁定")
    }
}

; 遊戲視窗裡的角色名稱跟帳號記住的不同 → 不能用位置 / 唯一候選硬配。名稱讀不到（還在登入畫面）就不限制。
CharNameCompatible(p, gameCharName) {
    return gameCharName="" || !p.HasOwnProp("charName") || p.charName="" || p.charName=gameCharName
        || (p.HasOwnProp("loginChar") && p.loginChar!="" && p.loginChar=gameCharName)
}

; 已綁定且角色已進入遊戲時，記住這個帳號的角色名稱，下次自動配對用。
ProfileLearnCharName(p) {
    name:=ReadGameCharName(p.pid)
    if name="" || (p.HasOwnProp("charName") && p.charName=name)
        return
    old:=p.HasOwnProp("charName") ? p.charName : ""
    p.charName:=name
    SaveProfiles()
    EventLog(p.name,"CHAR_NAME_LEARNED",(old="" ? "" : old " → ") name)
}

SyncGameListToProfile(row) {
    global profiles,gameRows,GameList,BindingInfoTxt
    if row<1 || row>profiles.Length || !gameRows.Length
        return
    p:=profiles[row]
    if !p.hwnd && !p.pid
        return
    for gi,grow in gameRows {
        if (p.hwnd && grow.hwnd=p.hwnd) || (p.pid && grow.pid=p.pid) {
            GameList.Choose(gi)
            return
        }
    }
}

OnGameListChanged(*) {
    global GameList,gameRows,profiles,LV,selectedProfileRow,Status
    gi:=GameList.Value
    if gi<1 || gi>gameRows.Length
        return
    grow:=gameRows[gi]
    ownerRow:=0
    for i,p in profiles {
        if (p.hwnd && p.hwnd=grow.hwnd) || (p.pid && p.pid=grow.pid) {
            ownerRow:=i
            break
        }
    }

    ; 只做 UI 對應選取，絕不因下拉選擇而改變綁定。
    if ownerRow {
        LV.Modify(0,"-Select")
        LV.Modify(ownerRow,"Select Focus Vis")
        selectedProfileRow:=ownerRow
        OnProfileSelect(LV,ownerRow,true)
        Status.Text:="狀態：此遊戲視窗目前綁定 → " profiles[ownerRow].name
    } else {
        Status.Text:="狀態：此遊戲視窗目前尚未綁定帳號"
    }
}

BindSelected(*) {
    global LV,GameList,gameRows,profiles,Status
    row:=LV.GetNext(), gi:=GameList.Value
    if (!row || !gi) {
        MsgBox "請同時選擇一個帳號與一個遊戲視窗。", APP_TITLE
        return
    }
    hwnd:=gameRows[gi].hwnd
    pid:=gameRows[gi].pid
    ; prevent accidental duplicate binding by either HWND or PID
    for i,p in profiles
        if (i!=row && ((p.hwnd=hwnd) || (p.pid=pid && pid!=0))) {
            MsgBox "這個 game.exe 已綁定給：" p.name,APP_TITLE
            return
        }
    p:=profiles[row], p.hwnd:=hwnd, p.pid:=pid, p.state:="已綁定"
    if p.enabled
        ScanProfileLocationOnce(p,"MANUAL_BIND")
    SaveProfiles()
    RefreshProfileLV()
    LV.Modify(row,"Select Vis")
    UpdateBindingInfo(p)
    RefreshGames()
    SyncGameListToProfile(row)
    Status.Text:="狀態：" p.name " 已綁定 PID " pid " / HWND " hwnd
}


UnbindSelected(*) {
    global LV,profiles,Status
    row:=LV.GetNext()
    if !row {
        MsgBox "請先選一個帳號。", APP_TITLE
        return
    }
    p:=profiles[row]
    oldPid:=p.pid
    oldHwnd:=p.hwnd

    ; 只解除 Profile 與遊戲視窗的關聯，不關閉 game.exe，
    ; 也不刪除帳密、監控設定、視窗位置或八點座標。
    p.pid:=0
    p.hwnd:=0
    p.state:="未綁定"
    p.hpDeadSince:=0
    p.hpFullSince:=0
    p.hpLastRatio:=-1
    p.hpLastChangeTick:=A_TickCount

    SaveProfiles()
    RefreshProfileLV()
    LV.Modify(row,"Select Vis")
    UpdateBindingInfo(p)
    RefreshGames()
    Status.Text:="狀態：" p.name " 已解除綁定（原 PID " oldPid " / HWND " oldHwnd "）"
}

RecordWindowPosition(*) {
    global LV,profiles,Status
    row:=LV.GetNext()
    if !row {
        MsgBox "請先選一個帳號。", APP_TITLE
        return
    }
    p:=profiles[row]
    if !p.hwnd || !WinExist("ahk_id " p.hwnd) {
        MsgBox "這個帳號目前沒有可用的綁定遊戲視窗。", APP_TITLE
        return
    }
    WinGetPos &x,&y,&w,&h,"ahk_id " p.hwnd
    p.winX:=x, p.winY:=y, p.winW:=w, p.winH:=h, p.hasPos:=1
    SaveProfiles()
    RefreshProfileLV()
    PushWebState()
    memText:=MemoryHPDisplayStatus(p)
    Status.Text:="狀態：" p.name " 已記錄視窗位置 X" x " Y" y " " w "x" h "｜HP=" memText
    msg:="已記錄視窗位置：X=" x " Y=" y " W=" w " H=" h
    msg.="`n`nHP 背景監控：" memText "`nMemory HP 不受視窗遮蔽影響。"
    MsgBox msg,APP_TITLE
}

RestoreProfileWindowPosition(idx, hwnd) {
    global profiles
    p:=profiles[idx]
    if !p.hasPos || !hwnd || !WinExist("ahk_id " hwnd)
        return false
    ; 只有目標矩形至少與目前某個 Monitor WorkArea 相交才移動，避免第二螢幕離線時硬搬到不可見區域。
    if !IsSavedRectOnAvailableMonitor(p.winX,p.winY,p.winW,p.winH) {
        EventLog(p.name,"WINDOW_LAYOUT_WAIT","記錄位置所屬螢幕目前不存在｜X" p.winX " Y" p.winY " " p.winW "x" p.winH)
        return false
    }
    try {
        if WinGetMinMax("ahk_id " hwnd)=-1
            WinRestore "ahk_id " hwnd
        Sleep 120
        WinMove p.winX,p.winY,p.winW,p.winH,"ahk_id " hwnd
        Sleep 220
        WinGetPos &x,&y,&w,&h,"ahk_id " hwnd
        ok := Abs(x-p.winX)<=4 && Abs(y-p.winY)<=4 && Abs(w-p.winW)<=8 && Abs(h-p.winH)<=8
        EventLog(p.name,ok?"WINDOW_LAYOUT_RESTORED":"WINDOW_LAYOUT_VERIFY_WARN",
            "目標=" p.winX "," p.winY "," p.winW "x" p.winH "｜實際=" x "," y "," w "x" h)
        return ok
    } catch as err {
        EventLog(p.name,"WINDOW_LAYOUT_FAIL",err.Message)
        return false
    }
}


LoadWindowLayoutConfig() {
    global INI,layoutAutoRestore
    layoutAutoRestore := (IniRead(INI,"WindowLayout","AutoRestoreOnMonitorStart","1")+0)=1
}

SetLayoutAutoRestore(raw) {
    global INI,layoutAutoRestore,layoutStatus
    layoutAutoRestore := (raw+0)=1
    IniWrite layoutAutoRestore?1:0,INI,"WindowLayout","AutoRestoreOnMonitorStart"
    layoutStatus := layoutAutoRestore ? "啟動監控時自動還原：ON" : "啟動監控時自動還原：OFF"
}

IsSavedRectOnAvailableMonitor(x,y,w,h) {
    cnt:=MonitorGetCount()
    Loop cnt {
        MonitorGetWorkArea A_Index,&l,&t,&r,&b
        ; 至少 120x80 區域落在某個目前存在的 WorkArea，才視為目標螢幕可用。
        ix:=Max(0,Min(x+w,r)-Max(x,l))
        iy:=Max(0,Min(y+h,b)-Max(y,t))
        if ix>=120 && iy>=80
            return true
    }
    return false
}

RestoreAllProfileWindows(reason:="手動") {
    global profiles,layoutStatus,layoutRestored,layoutSkipped,processingQueue,activeRecoveryHwnd
    layoutRestored:=0, layoutSkipped:=0
    if processingQueue || activeRecoveryHwnd {
        layoutStatus:="自動重新登入中，暫不還原視窗配置"
        return
    }
    layoutStatus:=reason "：還原中"
    for idx,p in profiles {
        if !p.hasPos || !ProfileGameAlive(p) {
            layoutSkipped+=1
            continue
        }
        if RestoreProfileWindowPosition(idx,p.hwnd)
            layoutRestored+=1
        else
            layoutSkipped+=1
    }
    layoutStatus:=reason "完成｜成功 " layoutRestored "｜略過/等待 " layoutSkipped
    AddRecentEvent("視窗配置：" layoutStatus)
}

SaveAllCurrentWindowPositions(*) {
    global profiles,layoutStatus
    saved:=0
    for p in profiles {
        if !ProfileGameAlive(p)
            continue
        try {
            WinGetPos &x,&y,&w,&h,"ahk_id " p.hwnd
            p.winX:=x,p.winY:=y,p.winW:=w,p.winH:=h,p.hasPos:=1
            saved+=1
            EventLog(p.name,"WINDOW_LAYOUT_SAVED","X" x " Y" y " " w "x" h)
        }
    }
    SaveProfiles()
    layoutStatus:="已記錄目前全部在線視窗位置｜" saved " 個"
    AddRecentEvent("視窗配置：" layoutStatus)
    PushWebState()
}

ShowSelectedGame(*) {
    global GameList,gameRows
    gi:=GameList.Value
    if !gi
        return
    hwnd:=gameRows[gi].hwnd
    ; 清單是舊的：那個遊戲視窗已經關閉時不要丟錯誤視窗
    if !hwnd || !WinExist("ahk_id " hwnd) {
        MsgBox "這個遊戲視窗已經不存在（可能已關閉或重新啟動），請稍候清單更新後再選。",APP_TITLE,"Icon!"
        return
    }
    if WinGetMinMax("ahk_id " hwnd)=-1
        WinRestore "ahk_id " hwnd
    WinActivate "ahk_id " hwnd
}

SaveGeneral(*) {
    global INI,LauncherEdit,PostKeysEdit,ReturnKeyEdit,ConfEdit,ZoomCountEdit,Status
    global DiscordEnableCB,DiscordWebhookEdit,DiscordPcEdit,DeathDiscordEnableCB,DeathDiscordWebhookEdit,SoftEnableCB,SoftIdleEdit,SoftConfirmEdit,SoftMinVotesEdit,SoftAutoRecoverCB,SoftMultiAssistCB,DeathResetOnMonitorCB,DeathAlarmEnableCB,DeathAlarmSecondsEdit
    IniWrite LauncherEdit.Value,INI,"General","Launcher"
    IniWrite PostKeysEdit.Value,INI,"General","PostKeys"
    IniWrite ReturnKeyEdit.Value,INI,"Recognition","ReturnKey"
    IniWrite ConfEdit.Value,INI,"Recognition","Confidence"
    IniWrite ZoomCountEdit.Value,INI,"Recognition","ZoomCount"
    IniWrite DiscordEnableCB.Value,INI,"Discord","Enabled"
    IniWrite DPAPIProtect(Trim(DiscordWebhookEdit.Value)),INI,"Discord","Webhook"
    IniWrite Trim(DiscordPcEdit.Value),INI,"Discord","PCName"
    IniWrite DeathDiscordEnableCB.Value,INI,"DeathDiscord","Enabled"
    IniWrite DPAPIProtect(Trim(DeathDiscordWebhookEdit.Value)),INI,"DeathDiscord","Webhook"
    global QuietEnableCB,QuietStartEdit,QuietEndEdit
    qs:=Quiet_ParseTime(QuietStartEdit.Value,-1), qe:=Quiet_ParseTime(QuietEndEdit.Value,-1)
    if (qs<0 || qe<0) {
        MsgBox "夜間安靜模式的時間格式不正確，請用 HH:mm（例如 01:00）。已改用預設 01:00 ～ 08:00。","夜間安靜模式","Icon!"
        qs:=60, qe:=480
    }
    QuietStartEdit.Value:=Quiet_FormatTime(qs), QuietEndEdit.Value:=Quiet_FormatTime(qe)
    IniWrite QuietEnableCB.Value,INI,"QuietHours","Enabled"
    IniWrite QuietStartEdit.Value,INI,"QuietHours","Start"
    IniWrite QuietEndEdit.Value,INI,"QuietHours","End"
    IniWrite DeathResetOnMonitorCB.Value,INI,"DeathAlert","ResetOnMonitorStart"
    IniWrite DeathAlarmEnableCB.Value,INI,"DeathAlert","SoundEnabled"
    IniWrite Max(5,Min(300,DeathAlarmSecondsEdit.Value+0)),INI,"DeathAlert","SoundSeconds"
    IniWrite SoftEnableCB.Value,INI,"SoftDisconnect","Enabled"
    IniWrite SoftIdleEdit.Value,INI,"SoftDisconnect","IdleSeconds"
    IniWrite SoftConfirmEdit.Value,INI,"SoftDisconnect","ConfirmSeconds"
    IniWrite SoftMinVotesEdit.Value,INI,"SoftDisconnect","MinVotes"
    IniWrite SoftMultiAssistCB.Value,INI,"SoftDisconnect","MultiAssist"
    IniWrite SoftAutoRecoverCB.Value,INI,"SoftDisconnect","AutoRecover"
    SaveProfiles()
    Status.Text:="狀態：設定已保存"
}

BatchStartChecked(*) {
    global running,abortRequested,profiles,recoveryQueue,queued,processingQueue,Status
    if !PointsConfigured() && !LoginMemoryAvailable() {
        MsgBox "找不到完整 8 點登入座標。請先完成登入座標校正。", APP_TITLE
        return
    }

    selected := 0
    for p in profiles
        if p.launchEnabled
            selected += 1
    if selected = 0 {
        MsgBox "請先在帳號清單左側勾選這次要自動開啟的帳號。", APP_TITLE
        return
    }

    SaveGeneral()
    abortRequested := false
    emergencyStop := false
    running := true

    ; 依 Profile 順序處理。已存在且仍有效的綁定視窗直接納入監控；
    ; 沒有有效視窗的帳號則排入 Recovery Queue，自動開 Launcher 登入。
    for i,p in profiles {
        if !p.launchEnabled
            continue
        if ProfileGameAlive(p) {
            p.state := p.enabled ? "監控中" : "已登入（未監控）"
            EventLog(p.name, "BATCH_SKIP", "既有 PID " p.pid " / HWND " p.hwnd " 仍有效，直接監控")
        } else {
            p.hwnd := 0
            p.pid := 0
            EnqueueRecovery(i, "勾選帳號自動啟動")
        }
    }

    RefreshProfileLV()
    Status.Text := "狀態：已開始依序自動登入左側勾選帳號｜是否監控依右側勾選決定"
    if (!processingQueue && recoveryQueue.Length)
        SetTimer ProcessNextRecovery, -10
}

RestartCheckedAccounts(*) {
    global profiles,processingQueue,abortRequested,emergencyStop,running
    selected:=0
    for p in profiles
        if p.launchEnabled
            selected+=1
    if selected=0 {
        MsgBox "請先在『帳號管理』勾選要啟動 / 重啟的帳號。", APP_TITLE
        return
    }
    abortRequested:=false
    emergencyStop:=false
    running:=true
    for i,p in profiles {
        if !p.launchEnabled
            continue
        ; 先關閉該 Profile 現有遊戲，再沿用穩定 Recovery Queue 重新登入。
        if ProfileGameAlive(p) {
            try ProcessClose p.pid
            Sleep 350
        }
        p.hwnd:=0, p.pid:=0
        EnqueueRecovery(i,"勾選帳號手動重啟")
    }
    SaveProfiles()
    RefreshProfileLV()
    AddRecentEvent("已將勾選帳號加入重啟 Queue，共 " selected " 個")
    if !processingQueue
        SetTimer ProcessNextRecovery,-10
}

StartMonitoring(*) {
    global running,abortRequested,profiles,Status,emergencyStop,DeathResetOnMonitorCB
    emergencyStop:=false
    if !PointsConfigured() && !LoginMemoryAvailable() {
        MsgBox "找不到完整 8 點登入座標。請先用 v0.5.x 完成座標校正；v0.6 會沿用同一個 HIHIYONG_AutoRecovery.ini。",APP_TITLE
        return
    }
    for p in profiles {
        if p.enabled && !ProfileGameAlive(p) {
            MsgBox "帳號「" p.name "」目前沒有有效的 PID + HWND 綁定。若要自動開啟並登入，請使用「啟動勾選帳號」。",APP_TITLE
            return
        }
    }
    SaveGeneral()
    abortRequested:=false, running:=true
    ResetSoftDisconnectRuntime()
    if DeathResetOnMonitorCB.Value {
        for p in profiles {
            if p.enabled {
                p.hpEventNo:=0
                p.hpReviveNo:=0
            }
        }
        SaveProfiles()
        EventLog("GLOBAL","HP_STATS_AUTO_RESET","開始監控：已依設定清除啟用帳號死亡 / 復活累積")
        AddRecentEvent("開始監控：死亡 / 復活累積已自動清除")
    }
    for p in profiles {
        if p.enabled {
            p.state:="監控中"
            ; v0.7.5.7: 重新監控後重新累積 HP 靜止時間，不沿用 F7/停止前資料。
            p.hpLastRatio:=-1
            p.hpLastChangeTick:=A_TickCount
            p.hpUnreadableSince:=0
            p.hpUnreadableLogged:=0
            ResetMemoryHPState(p)
            StartMemoryHPSession(p,p.pid,"MONITOR_START_REDETECT")
        }
    }
    ; 監控啟動/重新綁定時，每個 Monitor ON 視窗只辨識一次位置。
    ScanAllMonitoredLocationsOnce("MONITOR_START")
    RefreshProfileLV()
    Status.Text:="狀態：僅監控已勾選 Profile｜每 2 秒驗證 game.exe PID + HWND｜位置已於綁定時辨識一次"
}


EmergencyStopKeyMonitor() {
    global emergencyF10Down,emergencyF10Triggered
    ; v1.3.9.4: F10 is the dedicated emergency stop.  Physical mouse/Alt-Tab no longer pauses Recovery.
    down:=(DllCall("GetAsyncKeyState","Int",0x79,"Short") & 0x8000)!=0
    if down {
        if !emergencyF10Down
            emergencyF10Down:=A_TickCount
        if !emergencyF10Triggered && A_TickCount-emergencyF10Down>=120 {
            emergencyF10Triggered:=true
            EmergencyStopAll()
        }
    } else {
        emergencyF10Down:=0
        emergencyF10Triggered:=false
    }
}

EmergencyStopAll() {
    global running,abortRequested,emergencyStop,recoveryQueue,queued,profiles,Status
    emergencyStop:=true
    abortRequested:=true
    running:=false
    recoveryQueue:=[]
    queued:=Map()
    ResetSoftDisconnectRuntime()
    for p in profiles {
        if p.state="監控中" || p.state="排隊恢復" || p.state="恢復中" || p.state="恢復失敗" || p.state="載入中"
            p.state:="人工操作"
    }
    EventLog("GLOBAL","EMERGENCY_STOP","F10 手動終止｜停止監控 / Recovery / 自動鍵鼠；保留 game.exe 與綁定")
    AddRecentEvent("F10 緊急停止｜等待人工操作")
    Status.Text:="狀態：已強制停止自動化－等待人工操作"
    RefreshProfileLV()
}

StopMonitoring(*) {
    global running,abortRequested,recoveryQueue,queued,processingQueue,profiles,Status
    running:=false, abortRequested:=true, recoveryQueue:=[], queued:=Map()
    ResetSoftDisconnectRuntime()
    for p in profiles
        if p.enabled
            p.state:="已停止"
    RefreshProfileLV()
    Status.Text:="狀態：已停止全部監控 / 恢復"
}

MonitorTick() {
    global running,processingQueue,profiles,recoveryQueue,queued,fastLoginCritical
    if fastLoginCritical
        return
    if !running
        return
    for i,p in profiles {
        if !p.enabled
            continue
        ; 只有真正處於「監控中」才做 HWND 消失判斷。
        ; 避免 Recovery/健康確認期間仍拿舊 HWND 再次排入 Queue。
        if (p.state != "監控中")
            continue
        if !ProfileGameAlive(p)
            EnqueueRecovery(i,"偵測到 game.exe PID / HWND 綁定失效")
        ; v0.7.4.2: 背景監控禁止 WinActivate / 位置輪詢，避免搶前景視窗。
    }
    if (!processingQueue && recoveryQueue.Length)
        SetTimer ProcessNextRecovery,-10
}

UpdateBindingInfo(p) {
    global BindingInfoTxt
    if !p.pid || !p.hwnd {
        try BindingInfoTxt.Text:="PID：-　HWND：-　- x -　（未綁定）"
        return
    }

    cw:="-", ch:="-"
    if WinExist("ahk_id " p.hwnd) {
        try WinGetClientPos &cx,&cy,&cw,&ch,"ahk_id " p.hwnd
    }
    sizeText:=(cw!="-" && ch!="-") ? (cw "x" ch) : "尺寸無法取得"
    posText:=p.hasPos ? ("　記錄位置：" p.winX "," p.winY " " p.winW "x" p.winH) : ""
    try BindingInfoTxt.Text:="PID：" p.pid "　HWND：" p.hwnd "　" sizeText "　（綁定：" p.name "）" posText
}

AddRecentEvent(text) {
    global recentEvents,EventLV
    stamp:=FormatTime(,"HH:mm:ss")
    recentEvents.Push({t:stamp,msg:text})
    if webReady
        WebPushEvent("",text,stamp)
    while recentEvents.Length>50
        recentEvents.RemoveAt(1)
    try {
        EventLV.Delete()
        lastRow:=0
        for e in recentEvents
            lastRow:=EventLV.Add("",e.t,e.msg)
        if lastRow
            EventLV.Modify(lastRow,"Vis")
    }
}

UpdateSummary() {
    global profiles,recoveryQueue,SummaryTxt
    mon:=0, abnormal:=0
    for p in profiles {
        if p.state="監控中"
            mon+=1
        if p.state="需要人工處理" || p.state="恢復失敗"
            abnormal+=1
    }
    try SummaryTxt.Text:="監控中：" mon "　異常：" abnormal "　Recovery Queue：" recoveryQueue.Length
}

; v1.3.12.6: 使用者在校正時確認的最大 HP 優先；已學習最大 HP 可能被舊 offset 的錯誤值灌高。
ProfileMaxHP(p) {
    global memoryHpLiveMax
    ; v1.3.13.0: Game.pdb 模式下直接使用遊戲記憶體中的最大 HP。
    if p.pid && (m:=memoryHpLiveMax.Get(p.pid,0))>0
        return m
    confirmed:=p.HasOwnProp("memHpConfirmedMax") ? p.memHpConfirmedMax+0 : 0
    learned:=p.HasOwnProp("memHpLearnedMax") ? p.memHpLearnedMax+0 : 0
    return Max(confirmed,learned)
}

MemoryHPDisplayStatus(p) {
    if p.HasOwnProp("memHpStale") && p.memHpStale
        return "HP：位址待校正"
    if !p.HasOwnProp("memHpReadOk") || !p.memHpReadOk
        return "HP：等待/不可讀"
    maxHp:=ProfileMaxHP(p)
    if maxHp<=0
        maxHp:=p.memHp+0
    return "HP：" Format("{:,}",p.memHp+0) " / " Format("{:,}",maxHp)
}

ResetHPState(p) {
    p.hpDeadSince:=0,p.hpFullSince:=0,p.hpEventOpen:=0,p.hpEventTick:=0
    p.hpNoReviveAlerted:=0,p.hpDeathTime:="",p.hpLastRatio:=-1,p.hpLastChangeTick:=A_TickCount
}

HPAndSoftMonitorTick() {
    global fastLoginCritical
    if fastLoginCritical
        return
    ; v0.7.5.5: Discord HTTP is asynchronous, so one profile's death/revive
    ; notification cannot stall the 1-second HP scan of the remaining profiles.
    global running,profiles,HP_ALIVE_RED,HP_DEAD_RED,HP_DEATH_CONFIRM_MS,HP_REVIVE_CONFIRM_MS,hpReadableStatus
    if !running
        return
    ; Server-disconnect dialog is independent from HP. Confirmed events directly enter Recovery.
    ServerDisconnectMonitorTick()
    gap:=Max(0.001,HP_ALIVE_RED-HP_DEAD_RED)
    deadTh:=HP_DEAD_RED+gap*0.25
    fullTh:=HP_DEAD_RED+gap*0.85
    for i,p in profiles {
        if !p.enabled || p.state!="監控中" || !ProfileGameAlive(p)
            continue
        ; v1.3.11.5: Memory HP 可讀時，日常監控完全不再掃描畫面 HP ROI。
        ; ROI 僅在 Memory HP READ_FAIL 時作死亡偵測備援；登入 Loading Safe/HUD 畫面辨識流程不受影響。
        ; v1.3.13.0: Game.pdb 模式下記憶體是唯一依據；登入 / Loading 期間不改用畫面 HP，避免把未出現的 HUD 誤判為死亡。
        if p.memHpReadOk || GameOffsetsReady(p.pid) {
            p.hpUnreadableSince:=0
            p.hpUnreadableLogged:=0
            hpReadableStatus[i]:="Memory"
            continue
        }
        if !IsHpRoiVisible(p.hwnd) {
            hpReadableStatus[i]:="被遮蔽"
            ; visible-screen BitBlt 的安全限制：若 HP ROI 被另一個視窗蓋住，
            ; 不可把遮蓋畫面誤判為此角色死亡。
            p.hpDeadSince:=0
            p.hpFullSince:=0
            ; v0.7.5.7: 不可讀期間不得累積假在線票數；恢復可讀後重新計時。
            p.hpLastRatio:=-1
            p.hpLastChangeTick:=A_TickCount
            if !p.hpUnreadableSince
                p.hpUnreadableSince:=A_TickCount
            if !p.hpUnreadableLogged && A_TickCount-p.hpUnreadableSince>=5000 {
                p.hpUnreadableLogged:=1
                EventLog(p.name,"HP_FALLBACK_UNREADABLE","Memory HP READ_FAIL，且畫面 HP ROI 連續 5 秒被遮住/不可讀；視覺備援死亡判定暫停")
            }
            continue
        }
        p.hpUnreadableSince:=0
        p.hpUnreadableLogged:=0
        hpReadableStatus[i]:="可讀"
        rr:=HPGetRedRatio(p.hwnd)
        if rr<0 {
            p.hpDeadSince:=0
            p.hpFullSince:=0
            continue
        }

        ; Any meaningful HP fill change resets soft-disconnect idle timer.
        if p.hpLastRatio<0 || Abs(rr-p.hpLastRatio)>=0.002
            p.hpLastChangeTick:=A_TickCount
        p.hpLastRatio:=rr

        ; v1.3.11.1: 畫面 HP 只在 Memory HP 不可讀時作死亡偵測備援。
        if p.deathDetect && !p.memHpReadOk {
            if !p.hpEventOpen {
                p.hpFullSince:=0
                if rr<=deadTh {
                    if p.hpDeadSince=0
                        p.hpDeadSince:=A_TickCount
                    if A_TickCount-p.hpDeadSince>=HP_DEATH_CONFIRM_MS {
                        p.hpEventOpen:=1,p.hpEventTick:=A_TickCount,p.hpEventNo+=1,p.hpNoReviveAlerted:=0
                        p.hpDeathTime:=FormatTime(,"yyyy-MM-dd HH:mm:ss"),p.hpDeadSince:=0
                        DeathStatsRecord(p)
                        AddRecentEvent("☠ " p.name " 死亡 #" p.hpEventNo)
                        EventLog(p.name,"DEATH","HP=0 連續 5 秒｜事件 #" p.hpEventNo)
                        SaveProfiles()
                        ; 正常死亡只建立事件；等復活結案後再發一則 Discord。
                    }
                } else p.hpDeadSince:=0
            } else {
                if !p.hpNoReviveAlerted && A_TickCount-p.hpEventTick>=30000 {
                    p.hpNoReviveAlerted:=1
                    AddRecentEvent("⚠ " p.name " 死亡超過 30 秒未復活")
                    EventLog(p.name,"DEATH_30S","事件 #" p.hpEventNo)
                    if p.deathNotify
                        SendDeathEventDiscord(p,"NO_REVIVE")
                    ; 本機警報音獨立於 Discord 通知（v1.3.12.0 設計）；v1.3.13.0 移除重複呼叫。
                    StartDeathAlarm(0, p)
                }
                if rr>=fullTh {
                    if p.hpFullSince=0
                        p.hpFullSince:=A_TickCount
                    if A_TickCount-p.hpFullSince>=HP_REVIVE_CONFIRM_MS {
                        dur:=Round((A_TickCount-p.hpEventTick)/1000)
                        p.hpReviveNo+=1
                        DeathStatsReviveRecord(p)
                        AddRecentEvent("♥ " p.name " 復活 #" p.hpReviveNo)
                        EventLog(p.name,"REVIVE","死亡事件 #" p.hpEventNo " 結案｜" dur " 秒")
                        SaveProfiles()
                        if p.deathNotify
                            SendDeathClosedDiscord(p,dur)
                        p.hpEventOpen:=0,p.hpEventTick:=0,p.hpFullSince:=0,p.hpNoReviveAlerted:=0,p.hpDeathTime:=""
                        p.hpLastChangeTick:=A_TickCount
                    }
                } else p.hpFullSince:=0
            }
        }
    }
    RefreshProfileLV()
}


ResetMemoryHPState(p) {
    global MEMORY_HP_RUNTIME_OFFSET
    p.memHp:=-1
    p.memHpMin:=-1
    p.memHpMax:=-1
    p.memHpChanges:=0
    p.memHpLastChangeTick:=A_TickCount
    p.memHpReadOk:=0
    p.memHpState:="等待監控"
    p.memSoftState:="正常"
    p.memSoftAlerted:=0
    p.memHpZeroStreak:=0
    p.memHpAliveStreak:=0
    p.memHpMaxStaticMs:=0
    p.memHpStaticCount:=0
    p.memHpWasStatic:=0
    p.memHpSessionPid:=0
    p.memHpGraceUntil:=0
    ; v1.3.12.6: 每個 session 都要先連續讀到合理 HP（>0 且不超過最大 HP）才啟用死亡判定，
    ; 避免 offset 失效時把讀到的 0 當成死亡。memHpStale=此 session 的 offset 已確定不可用。
    p.memHpArmed:=0
    p.memHpStale:=0
    p.memHpPlausibleStreak:=0
    p.memHpUnarmedSince:=A_TickCount
    p.memHpSuspectLogged:=0
    if !p.HasOwnProp("memHpOffset")
        p.memHpOffset:=MEMORY_HP_RUNTIME_OFFSET
    if !p.HasOwnProp("memHpCalibrating")
        p.memHpCalibrating:=0
}

StartMemoryHPSession(p, newPid, reason:="PID_REBIND") {
    global MEMORY_HP_RECOVERY_GRACE_MS
    oldSessionPid:=p.HasOwnProp("memHpSessionPid") ? p.memHpSessionPid : 0
    if oldSessionPid && oldSessionPid!=newPid
        CloseMemoryHPHandle(oldSessionPid)
    ResetMemoryHPState(p)
    p.memHpSessionPid:=newPid
    p.memHpGraceUntil:=A_TickCount+MEMORY_HP_RECOVERY_GRACE_MS
    ; v1.3.12.0: every login / PID session performs one fresh HP-offset detection.
    ; If the learned maximum is available, scan game.exe module for that exact value and
    ; prefer the candidate nearest the last working offset. This is read-only.
    DetectMemoryHPOffsetForSession(p,newPid,reason)
    hp:=0
    if newPid && ReadMemoryHP(newPid,&hp,p.memHpOffset) {
        p.memHp:=hp
        p.memHpMin:=hp
        p.memHpMax:=hp
        ; v1.3.12.6: baseline 尚未驗證，不更新已學習最大 HP（舊版會被錯誤 offset 的值灌高）。
        p.memHpReadOk:=0
        p.memHpState:=p.memHpStale ? "HP 位址待校正" : "HP 確認中"
        p.memHpLastChangeTick:=A_TickCount
        EventLog(p.name,"MEMORY_HP_SESSION","新 PID " newPid "｜HP baseline=" hp "｜連續讀到合理 HP 後才啟用死亡判定｜" reason)
    } else {
        p.memHpState:="等待新 PID HP"
        EventLog(p.name,"MEMORY_HP_SESSION","新 PID " newPid "｜等待首次 Memory HP｜假在線保護 30 秒｜" reason)
    }
}

CloseMemoryHPHandle(pid) {
    global memoryHpHandles,memoryHpModuleBases,memoryHpModuleSizes
    if h:=memoryHpHandles.Get(pid,0)
        try DllCall("CloseHandle","Ptr",h)
    try memoryHpHandles.Delete(pid)
    try memoryHpModuleBases.Delete(pid)
    try memoryHpModuleSizes.Delete(pid)
    GameForgetPid(pid)
}

GetGameModuleBase(pid, hProc:=0) {
    global memoryHpModuleBases,memoryHpModuleSizes
    ; 只讀一次（遊戲關閉時其他計時器會移除這個 PID 的快取，Has 與取值之間可能被插隊）
    if b:=memoryHpModuleBases.Get(pid,0)
        return b

    ; v1.3.11.13: use Toolhelp module snapshot instead of PSAPI EnumProcessModules.
    ; This avoids intermittent PSAPI module enumeration failures seen during long multi-client monitoring.
    TH32CS_SNAPMODULE:=0x00000008
    TH32CS_SNAPMODULE32:=0x00000010
    snap:=DllCall("CreateToolhelp32Snapshot","UInt",TH32CS_SNAPMODULE|TH32CS_SNAPMODULE32,"UInt",pid,"Ptr")
    if snap=-1 || !snap
        return 0

    ; MODULEENTRY32W: x64 size = 1080 bytes. dwSize must be initialized.
    me:=Buffer(1080,0)
    NumPut("UInt",me.Size,me,0)
    moduleBase:=0
    try {
        if DllCall("Module32FirstW","Ptr",snap,"Ptr",me.Ptr,"Int") {
            moduleBase:=NumGet(me,24,"Ptr")
            memoryHpModuleSizes[pid]:=NumGet(me,32,"UInt")
        }
    } finally {
        DllCall("CloseHandle","Ptr",snap)
    }

    ; 影像大小 0 = game.exe 剛啟動、模組資訊還沒填好：不快取，下次重新取得（否則版本會一直是 XXXXXXXX-0）
    if moduleBase && memoryHpModuleSizes.Get(pid,0)
        memoryHpModuleBases[pid]:=moduleBase
    return moduleBase
}

GetGameModuleSize(pid) {
    global memoryHpModuleSizes
    if sz:=memoryHpModuleSizes.Get(pid,0)
        return sz
    GetGameModuleBase(pid)
    return memoryHpModuleSizes.Get(pid,0)
}

; v1.3.12.6: game.exe 版本識別 = PE header TimeDateStamp + 映像大小。維修更新後會改變。
GetGameBuildStamp(pid) {
    global memoryHpHandles
    hProc:=memoryHpHandles.Get(pid,0)
    if !hProc {
        hProc:=DllCall("OpenProcess","UInt",0x0410,"Int",0,"UInt",pid,"Ptr")
        if !hProc
            return ""
        memoryHpHandles[pid]:=hProc
    }
    base:=GetGameModuleBase(pid,hProc)
    if !base
        return ""
    buf:=Buffer(4,0),bytesRead:=0
    if !DllCall("ReadProcessMemory","Ptr",hProc,"Ptr",base+0x3C,"Ptr",buf.Ptr,"UPtr",4,"UPtr*",&bytesRead,"Int") || bytesRead!=4
        return ""
    peOffset:=NumGet(buf,0,"UInt")
    if !DllCall("ReadProcessMemory","Ptr",hProc,"Ptr",base+peOffset+8,"Ptr",buf.Ptr,"UPtr",4,"UPtr*",&bytesRead,"Int") || bytesRead!=4
        return ""
    return Format("{:08X}-{:X}",NumGet(buf,0,"UInt"),GetGameModuleSize(pid))
}

DetectMemoryHPOffsetForSession(p,pid,reason:="LOGIN_MONITOR") {
    global MEMORY_HP_RUNTIME_OFFSET,MEMORY_HP_BUILD
    ; v1.3.12.2: do NOT search for MaxHP and call it CurrentHP.
    ; Rebind to the last dynamically validated module-relative offset only.
    p.memHpOffset:=MEMORY_HP_RUNTIME_OFFSET
    if GameOffsetsReady(pid) {
        EventLog(p.name,"HP_SOURCE_PDB","使用 Game.pdb 位置讀取 HP（Build " GameBuildOf(pid) "）｜" reason)
        return true
    }
    if GameOffsetsResolving() {
        EventLog(p.name,"HP_SOURCE_PENDING","正在由 Game.pdb 解析新版位置｜暫停死亡判定｜" reason)
        return false
    }
    ; v1.3.12.6: game.exe 已更新（維修）→ 舊 offset 一律不用，等待自動校正。
    build:=GetGameBuildStamp(pid)
    if MEMORY_HP_BUILD!="" && build!="" && build!=MEMORY_HP_BUILD {
        p.memHpStale:=1
        EventLog(p.name,"HP_OFFSET_STALE_BUILD","game.exe 版本已變更（" MEMORY_HP_BUILD " → " build "）｜停用舊 offset 0x" Format("{:X}",p.memHpOffset) "｜暫停死亡判定，等待自動校正｜" reason)
        return false
    }
    hp:=0
    if ReadMemoryHP(pid,&hp,p.memHpOffset) {
        maxHp:=ProfileMaxHP(p)
        ; v1.3.12.6: HP=0 不再算通過（舊版 hp>=0 讓失效 offset 讀到的 0 直接變成死亡）。
        if hp>0 && (maxHp<=0 || hp<=maxHp*1.20) {
            EventLog(p.name,"HP_OFFSET_REUSE_OK","使用已驗證 offset 0x" Format("{:X}",p.memHpOffset) "｜HP=" hp "｜" reason)
            return true
        }
    }
    EventLog(p.name,"HP_OFFSET_REUSE_PENDING","offset 0x" Format("{:X}",p.memHpOffset) " 目前 HP=" hp "｜尚未讀到合理血量（可能仍在 Loading）；暫停死亡判定持續觀察｜" reason)
    return false
}

ReadMemoryHP(pid, &hp, offset:=0) {
    global MEMORY_HP_RUNTIME_OFFSET,memoryHpHandles,memoryHpLiveMax
    if !offset
        offset:=MEMORY_HP_RUNTIME_OFFSET

    hp:=0
    if !pid
        return false

    ; v1.3.13.0: 有對應版本的 Game.pdb 位置時，直接讀角色的目前 / 最大 HP，不使用校正 offset。
    ; 角色物件尚未初始化（登入、選角、Loading）時視為讀取失敗。
    if GameOffsetsReady(pid) {
        hpMax:=0
        if !ReadGameHP(pid,&hp,&hpMax)
            return false
        memoryHpLiveMax[pid]:=hpMax
        return true
    }

    hProc:=memoryHpHandles.Get(pid,0)
    if !hProc {
        hProc:=DllCall("OpenProcess","UInt",0x0410,"Int",0,"UInt",pid,"Ptr")
        if !hProc
            return false
        memoryHpHandles[pid]:=hProc
    }

    moduleBase:=GetGameModuleBase(pid,hProc)
    if !moduleBase {
        CloseMemoryHPHandle(pid)
        return false
    }

    hpAddress:=moduleBase + offset
    buf:=Buffer(4,0), bytesRead:=0
    ok:=DllCall("ReadProcessMemory","Ptr",hProc,"Ptr",hpAddress,"Ptr",buf.Ptr,"UPtr",4,"UPtr*",&bytesRead,"Int")
    if !ok || bytesRead!=4 {
        CloseMemoryHPHandle(pid)
        return false
    }

    hp:=NumGet(buf,0,"UInt")
    if hp=0xCCCCCCCC || hp>2000000000
        return false
    return true
}

MemoryHPConfirmDeath(p) {
    p.hpEventOpen:=1
    p.hpEventTick:=A_TickCount
    p.hpEventNo+=1
    DeathStatsRecord(p)
    RecoveryGuardNoteDeath(p)
    p.hpNoReviveAlerted:=0
    p.hpDeathTime:=FormatTime(,"yyyy-MM-dd HH:mm:ss")
    p.hpDeadSince:=0
    p.hpFullSince:=0
    p.memSoftState:="正常"
    p.memSoftAlerted:=0
    AddRecentEvent("☠ " p.name " 死亡 #" p.hpEventNo "｜Memory HP")
    EventLog(p.name,"DEATH","Memory HP 連續確認為 0｜事件 #" p.hpEventNo)
    SaveProfiles()
}

MemoryHPConfirmRevive(p) {
    dur:=Round((A_TickCount-p.hpEventTick)/1000)
    p.hpReviveNo+=1
    DeathStatsReviveRecord(p)
    AddRecentEvent("♥ " p.name " 復活 #" p.hpReviveNo "｜Memory HP")
    EventLog(p.name,"REVIVE","Memory HP > 0｜死亡事件 #" p.hpEventNo " 結案｜" dur " 秒")
    SaveProfiles()
    if p.deathNotify
        SendDeathClosedDiscord(p,dur)
    p.hpEventOpen:=0
    p.hpEventTick:=0
    p.hpFullSince:=0
    p.hpNoReviveAlerted:=0
    p.hpDeathTime:=""
    p.hpLastChangeTick:=A_TickCount
    p.memHpLastChangeTick:=A_TickCount
    p.memSoftState:="正常"
    p.memSoftAlerted:=0
}

UpdateLearnedMaxHP(p,hp) {
    global PROFILE_INI,profiles
    if hp<=0
        return
    if !p.HasOwnProp("memHpLearnedMax")
        p.memHpLearnedMax:=0
    if !p.HasOwnProp("memHpLearnedMaxDirty")
        p.memHpLearnedMaxDirty:=0
    if !p.HasOwnProp("memHpLearnedMaxSaveTick")
        p.memHpLearnedMaxSaveTick:=0

    if hp>p.memHpLearnedMax {
        oldMax:=p.memHpLearnedMax
        p.memHpLearnedMax:=hp
        p.memHpLearnedMaxDirty:=1
        EventLog(p.name,"HP_MAX_UPDATE","角色最大血量 " oldMax " → " hp)
    }

    ; v1.3.11.13: even if HP no longer rises, flush a pending learned max after 5 sec.
    ; Previous logic returned early when hp<=learned max, so a newly learned max could remain unsaved forever.
    if p.memHpLearnedMaxDirty && A_TickCount-p.memHpLearnedMaxSaveTick>=5000 {
        for i,q in profiles {
            if q==p {
                try {
                    IniWrite p.memHpLearnedMax, PROFILE_INI, "Profile_" i, "MemoryHPLearnedMax"
                    p.memHpLearnedMaxDirty:=0
                    p.memHpLearnedMaxSaveTick:=A_TickCount
                }
                break
            }
        }
    }
}

MemoryHPMonitorTick() {
    global profiles,running,SoftEnableCB,SoftIdleEdit,SoftConfirmEdit,SoftMinVotesEdit,SoftMultiAssistCB,fastLoginCritical
    global MEMORY_HP_ZERO_CONFIRM_SAMPLES,MEMORY_HP_ALIVE_CONFIRM_SAMPLES
    if !running || fastLoginCritical
        return
    idleMs:=Max(30,SoftIdleEdit.Value+0)*1000
    confirmMs:=Max(5,SoftConfirmEdit.Value+0)*1000
    for i,p in profiles {
        if !p.enabled || p.state!="監控中" || !ProfileGameAlive(p) {
            if p.pid
                CloseMemoryHPHandle(p.pid)
            p.memHpReadOk:=0
            p.memHpState:="未監控"
            p.memSoftState:="正常"
            p.memSoftAlerted:=0
            p.memHpZeroStreak:=0
            p.memHpAliveStreak:=0
            continue
        }
        ; v1.3.12.2: dynamic HP calibration owns the candidate reads for this profile.
        ; Never interpret calibration values as death/fake-online evidence.
        if p.HasOwnProp("memHpCalibrating") && p.memHpCalibrating {
            p.memHpState:="角色血量校正中"
            p.memHpReadOk:=0
            p.memHpZeroStreak:=0
            p.memHpAliveStreak:=0
            continue
        }
        ; v1.3.11.2: PID is the Memory-HP session boundary. Never inherit stale HP/static timers from an old game.exe.
        if !p.HasOwnProp("memHpSessionPid") || p.memHpSessionPid!=p.pid
            StartMemoryHPSession(p,p.pid,"MONITOR_PID_CHANGE")
        hp:=0
        if !ReadMemoryHP(p.pid,&hp,p.memHpOffset) {
            p.memHpReadOk:=0
            p.memHpState:="READ_FAIL"
            p.memSoftState:="讀取失敗"
            p.memSoftAlerted:=0
            p.memHpZeroStreak:=0
            p.memHpAliveStreak:=0
            p.memHpLastChangeTick:=A_TickCount
            continue
        }
        ; v1.3.12.6: 尚未確認 offset 有效前，讀到的值不能當死亡／假在線／最大 HP 的依據。
        if !p.memHpArmed {
            maxHp:=ProfileMaxHP(p)
            plausible:=hp>0 && (maxHp<=0 || hp<=maxHp*1.20)
            if !p.memHpStale && plausible {
                p.memHpPlausibleStreak+=1
                if p.memHpPlausibleStreak>=MEMORY_HP_ALIVE_CONFIRM_SAMPLES {
                    p.memHpArmed:=1
                    p.memHpMin:=hp,p.memHpMax:=hp
                    EventLog(p.name,"HP_ARMED","offset 0x" Format("{:X}",p.memHpOffset) " 讀到合理 HP=" hp "｜啟用死亡判定")
                }
            } else {
                p.memHpPlausibleStreak:=0
            }
            if !p.memHpArmed {
                if !p.memHpSuspectLogged && A_TickCount-p.memHpUnarmedSince>=MEMORY_HP_SUSPECT_MS && GameOffsetsReady(p.pid) {
                    ; v1.3.13.0: Game.pdb 位置已驗證（vftable 相符），HP 持續為 0 代表角色本身是死亡狀態，不是位址失效。
                    p.memHpSuspectLogged:=1
                    EventLog(p.name,"HP_ZERO_AT_START","Game.pdb 模式 HP 持續為 0｜角色可能處於死亡狀態，復活後自動啟用死亡判定")
                } else if !p.memHpSuspectLogged && A_TickCount-p.memHpUnarmedSince>=MEMORY_HP_SUSPECT_MS {
                    p.memHpSuspectLogged:=1
                    if !p.memHpStale {
                        p.memHpStale:=1
                        EventLog(p.name,"HP_OFFSET_SUSPECT","offset 0x" Format("{:X}",p.memHpOffset) " 連續 " Floor(MEMORY_HP_SUSPECT_MS/1000) " 秒讀不到合理 HP（最後 HP=" hp "）｜判定失效，等待自動校正")
                    }
                    if p.HasOwnProp("memHpConfirmedMax") && p.memHpConfirmedMax>0
                        AddRecentEvent("⚠ " p.name " HP 位址失效（維修更新？）｜暫停死亡判定，等待自動校正")
                    else
                        AddRecentEvent("⚠ " p.name " HP 位址失效｜尚未確認最大 HP，請按「校正已勾選角色血量」")
                }
                p.memHp:=hp
                p.memHpReadOk:=0
                p.memHpState:=p.memHpStale ? "HP 位址待校正" : "HP 確認中"
                p.memSoftState:="正常"
                p.memSoftAlerted:=0
                p.memHpZeroStreak:=0
                p.memHpAliveStreak:=0
                p.memHpLastChangeTick:=A_TickCount
                continue
            }
        }
        p.memHpReadOk:=1
        p.memHpState:="READ_OK"
        changed:=(p.memHp<0 || hp!=p.memHp)
        if changed {
            wasSoft:=p.memSoftState
            p.memHp:=hp
            p.memHpChanges+=1
            p.memHpLastChangeTick:=A_TickCount
            p.memHpWasStatic:=0
            if p.memHpMin<0 || hp<p.memHpMin
                p.memHpMin:=hp
            if p.memHpMax<0 || hp>p.memHpMax
                p.memHpMax:=hp
            UpdateLearnedMaxHP(p,hp)
            p.memSoftState:="正常"
            p.memSoftAlerted:=0
            if wasSoft="疑似假在線" || wasSoft="已確認假在線"
                EventLog(p.name,"SOFT_FALSE_POSITIVE","Memory HP 恢復變化；取消 " wasSoft)
        } else {
            p.memHp:=hp
            UpdateLearnedMaxHP(p,hp)
        }

        if hp=0 {
            p.memHpZeroStreak+=1
            p.memHpAliveStreak:=0
        } else {
            p.memHpAliveStreak+=1
            p.memHpZeroStreak:=0
        }
        if p.deathDetect {
            if !p.hpEventOpen && p.memHpZeroStreak>=MEMORY_HP_ZERO_CONFIRM_SAMPLES {
                MemoryHPConfirmDeath(p)
                p.memHpZeroStreak:=0
            } else if p.hpEventOpen {
                if !p.hpNoReviveAlerted && A_TickCount-p.hpEventTick>=30000 {
                    p.hpNoReviveAlerted:=1
                    AddRecentEvent("⚠ " p.name " 死亡超過 30 秒未復活")
                    EventLog(p.name,"DEATH_30S","事件 #" p.hpEventNo "｜Memory HP")
                    if p.deathNotify
                        SendDeathEventDiscord(p,"NO_REVIVE")
                    ; 本機警報音獨立於 Discord 通知（v1.3.12.0 設計）。
                    StartDeathAlarm(0, p)
                }
                if hp>0 && p.memHpAliveStreak>=MEMORY_HP_ALIVE_CONFIRM_SAMPLES {
                    MemoryHPConfirmRevive(p)
                    p.memHpAliveStreak:=0
                } else if hp=0 {
                    ReviveStuckCheck(p)
                }
            }
        }

        staticMs:=A_TickCount-p.memHpLastChangeTick
        if staticMs>p.memHpMaxStaticMs
            p.memHpMaxStaticMs:=staticMs
        if staticMs>=idleMs && !p.memHpWasStatic {
            p.memHpWasStatic:=1
            p.memHpStaticCount+=1
        } else if staticMs<idleMs {
            p.memHpWasStatic:=0
        }
        ; After Recovery/PID rebind, collect HP immediately but suppress fake-online Recovery for 30s.
        if p.HasOwnProp("memHpGraceUntil") && A_TickCount<p.memHpGraceUntil {
            p.memSoftState:="Recovery 保護"
            p.memSoftAlerted:=0
            continue
        }
        if !SoftEnableCB.Value || !p.softDetect || p.hpEventOpen {
            p.memSoftState:="正常"
            p.memSoftAlerted:=0
            continue
        }
        ; v1.3.18.8：伺服器時間只在收到伺服器封包時更新（GLCharacter::MsgProcess → SetCurrentTime），
        ; 停住代表伺服器沒有送資料。平常最長只停 22 秒（10/21～22 共 3500 筆紀錄），
        ; 停 SOFT_SRV_SUSPECT_SEC 秒標示疑似，停 SOFT_SRV_CONFIRM_SEC 秒且血量 / 金幣 / 背包同樣沒變就確認。
        srvSec:=SignalServerStaticSec(p)
        if srvSec>=SOFT_SRV_CONFIRM_SEC && staticMs>=SOFT_SRV_CONFIRM_SEC*1000 {
            p.memSoftState:="已確認假在線"
            if !p.memSoftAlerted {
                p.memSoftAlerted:=1
                SoftDisconnectConfirmed(i,p,"伺服器 " srvSec " 秒沒有送資料（血量 / 金幣 / 背包也沒有變化）")
            }
            continue
        }
        if srvSec>=SOFT_SRV_SUSPECT_SEC {
            if p.memSoftState!="疑似假在線" {
                p.memSoftState:="疑似假在線"
                AddRecentEvent("⚠ " p.name " 疑似假在線｜伺服器 " srvSec " 秒沒有送資料")
                EventLog(p.name,"SOFT_SUSPECT","伺服器時間 " srvSec " 秒未更新｜進入確認")
            }
            continue
        }
        ; 多視窗輔助判定：各角色 60 秒血量無變化即成為候選，達到指定帳號數便確認。
        ; 30 秒 Recovery 保護只排除該角色的假在線投票，不阻塞 Recovery Queue。
        if SoftMultiAssistCB.Value {
            if staticMs < 60000 {
                p.memSoftState:="正常"
                p.memSoftAlerted:=0
            } else {
                p.memSoftState:="等待其他角色確認"
            }
            continue
        }
        if staticMs<idleMs {
            p.memSoftState:="正常"
            p.memSoftAlerted:=0
            continue
        }
        if staticMs < idleMs+confirmMs {
            if p.memSoftState!="疑似假在線" {
                p.memSoftState:="疑似假在線"
                AddRecentEvent("⚠ " p.name " 疑似假在線｜Memory HP 靜止 " Floor(staticMs/1000) " 秒")
                EventLog(p.name,"SOFT_SUSPECT","Memory HP=" hp "｜靜止達 " Floor(staticMs/1000) " 秒｜進入二次確認")
            }
            continue
        }
        p.memSoftState:="已確認假在線"
        if p.memSoftAlerted
            continue
        p.memSoftAlerted:=1
        SoftDisconnectConfirmed(i,p,"血量 " Floor(staticMs/1000) " 秒沒有變化（HP " hp "）")
    }
    MaybeStartAutoHPCalibration()
    if SoftEnableCB.Value && SoftMultiAssistCB.Value
        EvaluateMultiWindowFakeOnline()
}

; 確認假在線後的動作：通知；該帳號開啟「假在線自動恢復」時關閉遊戲並排入自動重新登入。
SoftDisconnectConfirmed(i, p, detail) {
    autoRecover:=p.HasOwnProp("softAutoRecover") ? p.softAutoRecover : 0
    EventLog(p.name,"SOFT_DISCONNECT_CONFIRMED",detail "｜AutoRecover=" (autoRecover?"ON":"OFF"))
    if autoRecover {
        AddRecentEvent("🔌 " p.name " 已確認假在線｜自動重新登入")
        ReportEventShot(p,"🔴 HIHIYONG 已確認假在線`n角色：" p.name "`n" detail "`n將自動重新登入。（附上當下畫面）")
        oldPid:=p.pid
        CloseMemoryHPHandle(oldPid)
        try ProcessClose oldPid
        Sleep 350
        EnqueueRecovery(i,"SOFT_DISCONNECT｜" detail)
    } else {
        AddRecentEvent("⚠ " p.name " 已確認假在線｜這個角色沒有開啟自動恢復")
        ReportEventShot(p,"⚠️ HIHIYONG 假在線警告`n角色：" p.name "`n" detail "`n這個角色沒有開啟假在線自動恢復，請人工確認。（附上當下畫面）")
    }
}

EvaluateMultiWindowFakeOnline() {
    global profiles,SoftMinVotesEdit
    required:=Max(2,SoftMinVotesEdit.Value+0)
    candidates:=[]
    for i,p in profiles {
        if !p.enabled || !p.softDetect || p.state!="監控中" || p.hpEventOpen || !ProfileGameAlive(p) || !p.memHpReadOk
            continue
        if p.HasOwnProp("memHpGraceUntil") && A_TickCount<p.memHpGraceUntil
            continue
        if A_TickCount-p.memHpLastChangeTick>=60000
            candidates.Push(i)
    }
    count:=candidates.Length
    for idx in candidates {
        p:=profiles[idx]
        p.memSoftState := count>=required ? "已確認假在線" : "等待其他角色確認（" count " / " required "）"
    }
    if count<required
        return
    names:=""
    for idx in candidates
        names.=(names="" ? "" : "、") profiles[idx].name
    EventLog("GLOBAL","SOFT_MULTI_CONFIRMED","多視窗共同判定成立｜60秒無血量變化=" count "｜門檻=" required "｜" names)
    for idx in candidates {
        p:=profiles[idx]
        if p.memSoftAlerted
            continue
        p.memSoftAlerted:=1
        staticSec:=Floor((A_TickCount-p.memHpLastChangeTick)/1000)
        if p.softAutoRecover {
            AddRecentEvent("🔌 " p.name " 多視窗共同確認假在線｜加入自動恢復")
            EventLog(p.name,"SOFT_DISCONNECT_CONFIRMED","多視窗共同判定｜角色血量 " staticSec " 秒無變化｜共同異常 " count "/" required)
            try SendDiscordMessage("🔴 HIHIYONG 已確認假在線`n角色：" p.name "`n多視窗共同判定：" count " 個角色血量超過 60 秒無變化`n將自動重新登入。")
            oldPid:=p.pid
            CloseMemoryHPHandle(oldPid)
            try ProcessClose oldPid
            Sleep 100
            EnqueueRecovery(idx,"SOFT_MULTI｜60秒多視窗共同判定")
        } else {
            AddRecentEvent("⚠ " p.name " 多視窗共同確認假在線｜此角色自動恢復已關閉")
            EventLog(p.name,"SOFT_REVIEW_REQUIRED","多視窗共同判定成立｜AutoRecover=OFF")
        }
    }
}


ServerDisconnectMonitorTick() {
    global profiles,serverDisconnectSeen,serverDisconnectHandled,serverDisconnectLast,serverDisconnectConfirmMs,netOutageActive
    if netOutageActive
        return
    for i,p in profiles {
        key:=String(i)
        if !p.enabled || p.state!="監控中" || !ProfileGameAlive(p) {
            if serverDisconnectSeen.Has(key)
                serverDisconnectSeen.Delete(key)
            if serverDisconnectHandled.Has(key)
                serverDisconnectHandled.Delete(key)
            continue
        }
        hit:=DetectServerDisconnectDialog(p.hwnd)
        if !hit {
            if serverDisconnectSeen.Has(key)
                serverDisconnectSeen.Delete(key)
            if serverDisconnectHandled.Has(key)
                serverDisconnectHandled.Delete(key)
            continue
        }
        if serverDisconnectHandled.Has(key)
            continue
        if !serverDisconnectSeen.Has(key) {
            serverDisconnectSeen[key]:=A_TickCount
            EventLog(p.name,"SERVER_DISCONNECT_CANDIDATE","偵測到遊戲內『網路連線中斷』提示，等待第二次確認")
            continue
        }
        if A_TickCount-serverDisconnectSeen[key] < serverDisconnectConfirmMs
            continue

        serverDisconnectHandled[key]:=true
        serverDisconnectLast:=FormatTime(,"yyyy-MM-dd HH:mm:ss") "｜" p.name
        EventLog(p.name,"SERVER_DISCONNECT_CONFIRMED","遊戲視窗/PID仍存在，但斷線提示連續確認；直接進入 Recovery")
        AddRecentEvent("🔌 " p.name "｜伺服器連線中斷 → Recovery")
        CaptureServerDisconnectEvidence(p)
        try RecoveryWebhook(p,"伺服器連線中斷 / 自動 Recovery","偵測到遊戲內『網路連線中斷』提示")
        if REPORT_ERROR_SHOTS
            ReportEventShot(p,"📸 " p.name " 斷線當下的遊戲畫面")
        try ProcessClose p.pid
        Sleep 350
        EnqueueRecovery(i,"SERVER_DISCONNECT｜遊戲內網路連線中斷提示")
    }
}

DetectServerDisconnectDialog(hwnd) {
    ; v1.2.0 conservative visible-screen detector learned from the supplied 2026-09-23 outage captures.
    ; It requires BOTH the fixed disconnect text and the fixed confirm-button template inside the
    ; center dialog region. No OCR and no HP signal are involved.
    if !hwnd || !WinExist("ahk_id " hwnd) || WinGetMinMax("ahk_id " hwnd)=-1
        return false
    try WinGetClientPos &cx,&cy,&cw,&ch,"ahk_id " hwnd
    catch
        return false
    if cw<700 || ch<500
        return false

    ; Do not trust screen pixels when another top-level window covers the dialog center.
    px:=cx+Round(cw*0.50), py:=cy+Round(ch*0.53)
    top:=DllCall("WindowFromPoint","Int64",(py<<32)|(px & 0xFFFFFFFF),"Ptr")
    if top && top!=hwnd {
        root:=DllCall("GetAncestor","Ptr",top,"UInt",2,"Ptr")
        if root!=hwnd
            return false
    }

    textTpl:=A_ScriptDir "\\DisconnectTemplates\\DisconnectText.bmp"
    okTpl:=A_ScriptDir "\\DisconnectTemplates\\DisconnectConfirm.bmp"
    if !FileExist(textTpl) || !FileExist(okTpl)
        return false

    ; Supplied screenshots show the dialog centered in the client. Search a deliberately wider box
    ; so small title-bar/DPI differences do not matter.
    x1:=cx+Round(cw*0.20), y1:=cy+Round(ch*0.36)
    x2:=cx+Round(cw*0.82), y2:=cy+Round(ch*0.70)
    textHit:=false, okHit:=false
    try textHit:=ImageSearch(&tx,&ty,x1,y1,x2,y2,"*85 " textTpl)
    try okHit:=ImageSearch(&bx,&by,x1,y1,x2,y2,"*65 " okTpl)
    return textHit && okHit
}

CaptureServerDisconnectEvidence(p) {
    root:=A_ScriptDir "\\ServerDisconnectEvidence"
    try DirCreate root
    stamp:=FormatTime(,"yyyy-MM-dd_HH-mm-ss")
    try WinGetClientPos &x,&y,&w,&h,"ahk_id " p.hwnd
    catch
        return
    file:=root "\\" stamp "_" SafeFileName(p.name) ".bmp"
    try SaveScreenRectBmp(x,y,w,h,file)
}

SafeFileName(name) {
    for ch in ["\\","/",":","*","?",Chr(34),"<",">","|"]
        name:=StrReplace(name,ch,"_")
    return name
}

LoadSwitchStopHotkey() {
    global INI,switchStopHotkey
    switchStopHotkey:=Trim(IniRead(INI,"WindowSwitch","StopHotkey",""))
    ApplySwitchStopHotkey(false)
}

ApplySwitchStopHotkey(showError:=true) {
    global switchStopHotkey,switchStopHotkeyApplied
    if switchStopHotkeyApplied!="" {
        try Hotkey switchStopHotkeyApplied,"Off"
        switchStopHotkeyApplied:=""
    }
    hk:=Trim(switchStopHotkey)
    if hk=""
        return true
    if StrUpper(hk)="F7" {
        if showError
            AddRecentEvent("視窗切換停止快捷鍵不可使用 F7（緊急停止保留鍵）")
        return false
    }
    try {
        Hotkey hk,StopAutoWindowSwitch,"On"
        switchStopHotkeyApplied:=hk
        return true
    } catch as e {
        if showError
            AddRecentEvent("停止快捷鍵設定失敗：" hk "｜" e.Message)
        return false
    }
}

SaveSwitchStopHotkey(rawValue) {
    global INI,switchStopHotkey
    old:=switchStopHotkey
    hk:=Trim(WebDecodeSimple(rawValue))
    switchStopHotkey:=hk
    if !ApplySwitchStopHotkey(true) {
        switchStopHotkey:=old
        ApplySwitchStopHotkey(false)
        return
    }
    IniWrite switchStopHotkey,INI,"WindowSwitch","StopHotkey"
    AddRecentEvent("視窗切換停止快捷鍵：" (switchStopHotkey!="" ? switchStopHotkey : "未設定"))
}

GetAutoSwitchRuntimeInfo() {
    global profiles,autoSwitchCurrentIdx,autoSwitchRunning,autoSwitchNextAt,autoSwitchRecoveryPaused,autoSwitchPausedRemainMs
    total:=0, eligible:=[]
    for i,p in profiles {
        if p.switchEnabled {
            total+=Max(1,p.switchSeconds+0)
            if ProfileGameAlive(p)
                eligible.Push(i)
        }
    }
    curName:="—",curHwnd:=0,nextName:="—",nextHwnd:=0,currentSeconds:=0
    if autoSwitchRunning && autoSwitchCurrentIdx>=1 && autoSwitchCurrentIdx<=profiles.Length {
        cp:=profiles[autoSwitchCurrentIdx]
        if cp.switchEnabled && ProfileGameAlive(cp)
            curName:=cp.name,curHwnd:=cp.hwnd,currentSeconds:=Max(1,cp.switchSeconds+0)
        if eligible.Length {
            pos:=0
            for j,idx in eligible
                if idx=autoSwitchCurrentIdx {
                    pos:=j
                    break
                }
            ni:=pos ? eligible[Mod(pos,eligible.Length)+1] : eligible[1]
            np:=profiles[ni],nextName:=np.name,nextHwnd:=np.hwnd
        }
    } else if eligible.Length {
        np:=profiles[eligible[1]],nextName:=np.name,nextHwnd:=np.hwnd
    }
    remain:=autoSwitchRunning ? (autoSwitchRecoveryPaused ? Ceil(autoSwitchPausedRemainMs/1000) : (autoSwitchNextAt>A_TickCount ? Ceil((autoSwitchNextAt-A_TickCount)/1000) : 0)) : 0
    return {total:total,currentName:curName,currentHwnd:curHwnd,nextName:nextName,nextHwnd:nextHwnd,remain:remain,currentSeconds:currentSeconds}
}

SwitchNextBoundGame(*) {
    global profiles
    static lastIdx:=0
    if !profiles.Length
        return
    Loop profiles.Length {
        lastIdx:=Mod(lastIdx,profiles.Length)+1
        p:=profiles[lastIdx]
        if p.switchEnabled && ProfileGameAlive(p) {
            if WinGetMinMax("ahk_id " p.hwnd)=-1
                try WinRestore "ahk_id " p.hwnd
            try WinActivate "ahk_id " p.hwnd
            AddRecentEvent("切換 HWND → " p.name "｜PID " p.pid)
            return
        }
    }
    AddRecentEvent("切換 HWND：目前沒有有效的已綁定遊戲視窗")
}

StartAutoWindowSwitch(*) {
    global autoSwitchRunning,autoSwitchNextAt,autoSwitchCurrentIdx,abortRequested,emergencyStop,autoSwitchRecoveryPaused,autoSwitchPausedRemainMs
    abortRequested:=false
    emergencyStop:=false
    autoSwitchRunning:=true
    autoSwitchCurrentIdx:=0
    autoSwitchNextAt:=A_TickCount
    autoSwitchRecoveryPaused:=false, autoSwitchPausedRemainMs:=0
    AddRecentEvent("遊戲視窗自動切換：已啟動")
}

StopAutoWindowSwitch(*) {
    global autoSwitchRunning,autoSwitchNextAt,autoSwitchRecoveryPaused,autoSwitchPausedRemainMs
    autoSwitchRunning:=false
    autoSwitchNextAt:=0
    autoSwitchRecoveryPaused:=false, autoSwitchPausedRemainMs:=0
    AddRecentEvent("遊戲視窗自動切換：已停止")
}

AutoWindowSwitchTick(*) {
    global autoSwitchRunning,autoSwitchNextAt,processingQueue,activeRecoveryHwnd,setupMode,emergencyStop
    global autoSwitchRecoveryPaused,autoSwitchPausedRemainMs
    if !autoSwitchRunning || emergencyStop || setupMode
        return

    ; Recovery / 自動登入擁有最高前景優先權：完整凍結 HWND 切換與自動按鍵倒數。
    if processingQueue || activeRecoveryHwnd {
        if !autoSwitchRecoveryPaused {
            autoSwitchPausedRemainMs:=autoSwitchNextAt>A_TickCount ? autoSwitchNextAt-A_TickCount : 0
            autoSwitchRecoveryPaused:=true
            AddRecentEvent("視窗自動切換暫停：Recovery / 自動登入執行中")
        }
        return
    }

    ; Recovery 完成後從原本剩餘秒數繼續，不會立刻切窗或補送按鍵。
    if autoSwitchRecoveryPaused {
        autoSwitchNextAt:=A_TickCount + Max(0,autoSwitchPausedRemainMs)
        autoSwitchRecoveryPaused:=false
        autoSwitchPausedRemainMs:=0
        AddRecentEvent("視窗自動切換恢復：Recovery / 自動登入已完成")
    }

    if autoSwitchNextAt && A_TickCount < autoSwitchNextAt
        return
    AutoSwitchNextGame()
}

AutoSwitchNextGame(*) {
    global profiles,autoSwitchCurrentIdx,autoSwitchNextAt,autoSwitchRunning
    if !autoSwitchRunning || !profiles.Length
        return false
    Loop profiles.Length {
        autoSwitchCurrentIdx:=Mod(autoSwitchCurrentIdx,profiles.Length)+1
        p:=profiles[autoSwitchCurrentIdx]
        if !p.switchEnabled || !ProfileGameAlive(p)
            continue
        try {
            if WinGetMinMax("ahk_id " p.hwnd)=-1
                WinRestore "ahk_id " p.hwnd
            WinActivate "ahk_id " p.hwnd
            if !WinWaitActive("ahk_id " p.hwnd,,2) {
                AddRecentEvent("自動切換略過：" p.name " 無法取得前景")
                continue
            }
            Sleep 180
            keys:=Trim(p.switchKeys)
            if keys!="" {
                for key in StrSplit(keys,",") {
                    key:=Trim(key)
                    if key=""
                        continue
                    SendOneKey(key)
                    Sleep 180
                }
            }
            sec:=Max(1,p.switchSeconds+0)
            autoSwitchNextAt:=A_TickCount + sec*1000
            AddRecentEvent("自動切換 → " p.name "｜停留 " sec " 秒" (keys!="" ? "｜按鍵 " keys : ""))
            return true
        } catch as e {
            AddRecentEvent("自動切換失敗：" p.name "｜" e.Message)
        }
    }
    autoSwitchNextAt:=A_TickCount+2000
    return false
}

SaveWindowSwitchSetting(rawValue) {
    global profiles
    txt:=WebDecodeSimple(rawValue)
    parts:=StrSplit(txt,"~")
    if parts.Length<4
        return
    idx:=parts[1]+0
    if idx<1 || idx>profiles.Length
        return
    p:=profiles[idx]
    p.switchEnabled:=(parts[2]+0) ? 1 : 0
    p.switchSeconds:=Max(1,Min(3600,parts[3]+0))
    p.switchKeys:=Trim(parts[4])
    SaveProfiles()
    AddRecentEvent("視窗切換設定已儲存：" p.name "｜" p.switchSeconds " 秒｜按鍵 " (p.switchKeys!="" ? p.switchKeys : "無"))
}

ResetAllDeathStats(*) {
    global profiles,APP_TITLE
    if MsgBox("確定要將全部帳號的死亡 / 復活累積次數歸零？","HIHIYONG", "YesNo Icon!")!="Yes"
        return
    for p in profiles {
        p.hpEventNo:=0
        p.hpReviveNo:=0
    }
    SaveProfiles()
    RefreshProfileLV()
    EventLog("GLOBAL","HP_STATS_RESET_ALL","全部帳號死亡 / 復活累積次數已重置")
    AddRecentEvent("已重置全部帳號死亡 / 復活次數")
}

SoftDisconnectConsensus() {
    global profiles,SoftEnableCB,SoftIdleEdit,SoftConfirmEdit,SoftMinVotesEdit
    global softCandidateSince,softAlerted,running,netOutageActive
    ; Network Watch 已確認本機/Internet 中斷時，不把所有帳號的 HP 靜止誤判為假在線。
    ; 網路恢復後，既有假在線/斷線視窗監控會重新開始判斷。
    if netOutageActive {
        ResetSoftDisconnectRuntime()
        return
    }
    if !running || !SoftEnableCB.Value {
        ResetSoftDisconnectRuntime()
        return
    }

    idleMs:=Max(30,SoftIdleEdit.Value+0)*1000
    confirmMs:=Max(5,SoftConfirmEdit.Value+0)*1000
    minVotes:=Max(3,SoftMinVotesEdit.Value+0)
    eligible:=0
    stale:=0
    staleIdx:=[]

    for i,p in profiles {
        if !p.enabled || !p.softDetect || p.state!="監控中" || p.hpEventOpen
            continue
        if p.locType!="怪物區"
            continue
        if !ProfileGameAlive(p) || WinGetMinMax("ahk_id " p.hwnd)=-1
            continue

        ; v0.7.5.7: HP ROI 必須此刻可讀才有資格投票。
        ; 被遮蔽/不可讀帳號不只排除，HPAndSoftMonitorTick 也會重設其 idle baseline。
        if !IsHpRoiVisible(p.hwnd)
            continue

        eligible+=1
        if p.hpLastRatio>=0 && A_TickCount-p.hpLastChangeTick>=idleMs {
            stale+=1
            staleIdx.Push(i)
        }
    }

    requiredVotes:=Max(minVotes,Ceil(eligible*0.60))
    if eligible>=minVotes && stale>=requiredVotes {
        if softCandidateSince=0 {
            softCandidateSince:=A_TickCount
            softAlerted:=false
            AddRecentEvent("疑似假在線：HP 同步靜止｜進入二次確認")
            EventLog("GLOBAL","SOFT_SUSPECT","HP同步靜止；開始20秒蒐證並等待二次確認")
            StartSoftEvidenceCapture("疑似假在線｜等待二次確認")
            return
        }

        if !softAlerted && A_TickCount-softCandidateSince>=confirmMs {
            softAlerted:=true
            names:=""
            for idx in staleIdx
                names.=(names="" ? "" : "、") profiles[idx].name

            if SoftAutoRecoverCB.Value {
                AddRecentEvent("🔌 假在線確認：" names "｜加入自動 Recovery")
                EventLog("GLOBAL","SOFT_DISCONNECT_CONFIRMED","HP同步靜止二次確認成立｜" names "｜自動 Recovery")
                try SendDiscordMessage("🔴 HIHIYONG 確認疑似假在線`n帳號：" names
                    . "`nHP 同步靜止已通過二次確認，將自動重新登入。"
                    . "`n已建立 20 秒畫面證據。")

                ; 僅處理本次二次確認仍 stale 的帳號；沿用既有 Recovery Queue / Loading Safe 核心。
                for idx in staleIdx {
                    p:=profiles[idx]
                    if !p.enabled || p.state!="監控中" || !ProfileGameAlive(p)
                        continue
                    EventLog(p.name,"SOFT_RECOVERY_TRIGGER","假在線二次確認成立｜關閉舊 game.exe 並加入 Recovery Queue")
                    try ProcessClose p.pid
                    Sleep 350
                    EnqueueRecovery(idx,"SOFT_DISCONNECT｜HP同步靜止二次確認")
                }
            } else {
                AddRecentEvent("⚠ 假在線已確認：" names "｜自動 Recovery 已關閉")
                EventLog("GLOBAL","SOFT_REVIEW_REQUIRED","HP同步靜止二次確認成立｜" names "｜AutoRecover=OFF")
                try SendDiscordMessage("⚠️ HIHIYONG 假在線警告`n帳號：" names
                    . "`nHP 同步靜止已通過二次確認；目前自動 Recovery 已關閉。"
                    . "`n已建立 20 秒畫面證據。")
            }
        }
    } else {
        if softCandidateSince {
            EventLog("GLOBAL","SOFT_FALSE_POSITIVE","HP/可讀性條件恢復，取消疑似假在線")
        }
        ResetSoftDisconnectRuntime()
    }
}

ResetSoftDisconnectRuntime() {
    global softCandidateSince,softAlerted
    softCandidateSince:=0
    softAlerted:=false
}


StartSoftEvidenceCapture(reason:="") {
    global softEvidenceBusy,softEvidenceDir,softEvidenceFrame,softEvidenceEndTick
    if softEvidenceBusy
        return
    root:=A_ScriptDir "\SoftDisconnectEvidence"
    try DirCreate root
    stamp:=FormatTime(,"yyyy-MM-dd_HH-mm-ss")
    softEvidenceDir:=root "\" stamp
    try DirCreate softEvidenceDir
    softEvidenceFrame:=0
    softEvidenceEndTick:=A_TickCount+20000
    softEvidenceBusy:=true
    try FileAppend "Start=" FormatTime(,"yyyy-MM-dd HH:mm:ss") "`r`nReason=" reason "`r`n",softEvidenceDir "\event.txt","UTF-8"
    EventLog("GLOBAL","SOFT_EVIDENCE","開始記錄兩個螢幕 20 秒｜" softEvidenceDir)
    SetTimer SoftEvidenceTick, -10
}

SoftEvidenceTick() {
    global softEvidenceBusy,softEvidenceDir,softEvidenceFrame,softEvidenceEndTick
    if !softEvidenceBusy
        return
    softEvidenceFrame+=1
    count:=MonitorGetCount()
    Loop Min(2,count) {
        n:=A_Index
        MonitorGet n,&l,&t,&r,&b
        file:=softEvidenceDir "\F" Format("{:02}",softEvidenceFrame) "_M" n ".bmp"
        SaveScreenRectBmp(l,t,r-l,b-t,file)
    }
    if A_TickCount>=softEvidenceEndTick {
        softEvidenceBusy:=false
        try FileAppend "End=" FormatTime(,"yyyy-MM-dd HH:mm:ss") "`r`nFrames=" softEvidenceFrame "`r`n",softEvidenceDir "\event.txt","UTF-8"
        EventLog("GLOBAL","SOFT_EVIDENCE","20 秒畫面記錄完成｜" softEvidenceDir)
        return
    }
    ; 1 fps x 20 sec, each frame contains monitor 1 and monitor 2.
    SetTimer SoftEvidenceTick,-1000
}

SaveScreenRectBmp(x,y,w,h,file) {
    if w<=0 || h<=0
        return false
    hdc:=DllCall("GetDC","Ptr",0,"Ptr")
    mem:=DllCall("CreateCompatibleDC","Ptr",hdc,"Ptr")
    bmi:=Buffer(40,0)
    NumPut("UInt",40,bmi,0)
    NumPut("Int",w,bmi,4)
    NumPut("Int",-h,bmi,8)
    NumPut("UShort",1,bmi,12)
    NumPut("UShort",32,bmi,14)
    bitsPtr:=0
    dib:=DllCall("CreateDIBSection","Ptr",hdc,"Ptr",bmi.Ptr,"UInt",0,"Ptr*",&bitsPtr,"Ptr",0,"UInt",0,"Ptr")
    if !dib {
        DllCall("DeleteDC","Ptr",mem)
        DllCall("ReleaseDC","Ptr",0,"Ptr",hdc)
        return false
    }
    old:=DllCall("SelectObject","Ptr",mem,"Ptr",dib,"Ptr")
    ok:=DllCall("BitBlt","Ptr",mem,"Int",0,"Int",0,"Int",w,"Int",h,"Ptr",hdc,"Int",x,"Int",y,"UInt",0x40CC0020)
    if ok {
        stride:=w*4
        imageSize:=stride*h
        fh:=FileOpen(file,"w")
        if fh {
            header:=Buffer(54,0)
            NumPut("UShort",0x4D42,header,0)
            NumPut("UInt",54+imageSize,header,2)
            NumPut("UInt",54,header,10)
            NumPut("UInt",40,header,14)
            NumPut("Int",w,header,18)
            NumPut("Int",-h,header,22)
            NumPut("UShort",1,header,26)
            NumPut("UShort",32,header,28)
            NumPut("UInt",0,header,30)
            NumPut("UInt",imageSize,header,34)
            fh.RawWrite(header,54)
            fh.RawWrite(BufferFromPtr(bitsPtr,imageSize),imageSize)
            fh.Close()
        }
    }
    DllCall("SelectObject","Ptr",mem,"Ptr",old)
    DllCall("DeleteObject","Ptr",dib)
    DllCall("DeleteDC","Ptr",mem)
    DllCall("ReleaseDC","Ptr",0,"Ptr",hdc)
    return ok
}

BufferFromPtr(ptr,size) {
    b:=Buffer(size,0)
    DllCall("RtlMoveMemory","Ptr",b.Ptr,"Ptr",ptr,"UPtr",size)
    return b
}


IsHpRoiVisible(hwnd) {
    global HP_ROI_X,HP_ROI_Y,HP_ROI_W,HP_ROI_H
    if !WinExist("ahk_id " hwnd)
        return false
    if WinGetMinMax("ahk_id " hwnd)=-1
        return false
    try WinGetClientPos &cx,&cy,&cw,&ch,"ahk_id " hwnd
    catch
        return false
    if cw<HP_ROI_X+HP_ROI_W || ch<HP_ROI_Y+HP_ROI_H
        return false

    ; Visible-screen BitBlt is only trustworthy when the HP ROI is not covered
    ; by another top-level window. Check five points across the ROI.
    pts := [
        [cx+HP_ROI_X+5, cy+HP_ROI_Y+5],
        [cx+HP_ROI_X+HP_ROI_W-5, cy+HP_ROI_Y+5],
        [cx+HP_ROI_X+5, cy+HP_ROI_Y+HP_ROI_H-5],
        [cx+HP_ROI_X+HP_ROI_W-5, cy+HP_ROI_Y+HP_ROI_H-5],
        [cx+HP_ROI_X+HP_ROI_W//2, cy+HP_ROI_Y+HP_ROI_H//2]
    ]
    for pt in pts {
        hAt:=DllCall("WindowFromPoint","Int64",(pt[2]<<32) | (pt[1] & 0xFFFFFFFF),"Ptr")
        if !hAt
            return false
        root:=DllCall("GetAncestor","Ptr",hAt,"UInt",2,"Ptr") ; GA_ROOT
        if root!=hwnd
            return false
    }
    return true
}

HPGetRedRatio(hwnd) {
    global HP_ROI_X,HP_ROI_Y,HP_ROI_W,HP_ROI_H
    try WinGetClientPos &cx,&cy,&cw,&ch,"ahk_id " hwnd
    catch
        return -1
    if cw<HP_ROI_X+HP_ROI_W || ch<HP_ROI_Y+HP_ROI_H
        return -1
    w:=HP_ROI_W,h:=HP_ROI_H,sx:=cx+HP_ROI_X,sy:=cy+HP_ROI_Y
    hdc:=DllCall("GetDC","Ptr",0,"Ptr")
    mem:=DllCall("CreateCompatibleDC","Ptr",hdc,"Ptr")
    bm:=DllCall("CreateCompatibleBitmap","Ptr",hdc,"Int",w,"Int",h,"Ptr")
    old:=DllCall("SelectObject","Ptr",mem,"Ptr",bm,"Ptr")
    ok:=DllCall("BitBlt","Ptr",mem,"Int",0,"Int",0,"Int",w,"Int",h,"Ptr",hdc,"Int",sx,"Int",sy,"UInt",0x40CC0020)
    stride:=w*4,bits:=Buffer(stride*h,0),bmi:=Buffer(40,0)
    NumPut("UInt",40,bmi,0),NumPut("Int",w,bmi,4),NumPut("Int",-h,bmi,8),NumPut("UShort",1,bmi,12),NumPut("UShort",32,bmi,14)
    got:=ok ? DllCall("GetDIBits","Ptr",mem,"Ptr",bm,"UInt",0,"UInt",h,"Ptr",bits.Ptr,"Ptr",bmi.Ptr,"UInt",0) : 0
    DllCall("SelectObject","Ptr",mem,"Ptr",old),DllCall("DeleteObject","Ptr",bm),DllCall("DeleteDC","Ptr",mem),DllCall("ReleaseDC","Ptr",0,"Ptr",hdc)
    if !got
        return -1
    red:=0,total:=w*h
    Loop h {
        y:=A_Index-1
        Loop w {
            x:=A_Index-1,off:=y*stride+x*4
            b:=NumGet(bits,off,"UChar"),gg:=NumGet(bits,off+1,"UChar"),r:=NumGet(bits,off+2,"UChar")
            if r>90 && r>gg*1.25 && r>b*1.20
                red+=1
        }
    }
    return red/total
}

RecognizeExactMap(hwnd) {
    ; Diagnostic-only exact map name. It NEVER controls Recovery.
    ; Uses visible-screen ImageSearch against known map-name templates.
    ; If no strong template match, returns 地圖無法確認.
    root:=A_ScriptDir "\MapTemplates"
    if !DirExist(root)
        return {name:"地圖無法確認",conf:0}
    if !WinExist("ahk_id " hwnd) || WinGetMinMax("ahk_id " hwnd)=-1
        return {name:"地圖無法確認",conf:0}
    try WinGetClientPos &cx,&cy,&cw,&ch,"ahk_id " hwnd
    catch
        return {name:"地圖無法確認",conf:0}
    ; v1.3.10.3: 右上角地圖名稱辨識。舊版 180x40 ROI 過窄，實際 UI 在不同視窗邊框/解析度下容易落出範圍。
    ; 仍只搜尋右上角，不掃全畫面，避免其他相似文字造成誤判。
    roiW:=Min(360,cw), roiH:=Min(110,ch)
    x1:=cx+Max(0,cw-roiW), y1:=cy, x2:=cx+cw-1, y2:=cy+roiH-1
    names:=["機械區","機械區_2區","裂變時空","童話世界","魔術區","異形空降區","波斯宮","末日禁地島","重力迴廊","學院廣場","鳳凰學院","聖門學院","玄岩學院"]
    types:=["NORMAL","NORMAL","NORMAL","NORMAL","NORMAL","NORMAL","NORMAL","NORMAL","NORMAL","REVIVE","REVIVE","REVIVE","REVIVE"]
    ; Start strict. We only expose a name when a template is visually close.
    variations:=[15,25,35,45]
    for v in variations {
        for i,name in names {
            f:=root "\" types[i] "__" name ".bmp"
            if !FileExist(f)
                continue
            try {
                if ImageSearch(&fx,&fy,x1,y1,x2,y2,"*" v " " f) {
                    conf:=v=15 ? 96 : (v=25 ? 90 : (v=35 ? 84 : 78))
                    return {name:name,conf:conf}
                }
            }
        }
    }
    return {name:"地圖無法確認",conf:0}
}


UpdateProfileLocation(p) {
    if !ProfileGameAlive(p) || WinGetMinMax("ahk_id " p.hwnd)=-1
        return
    ; Do not let server/login screens become 怪物區/復活點.
    rr:=HPGetRedRatio(p.hwnd)
    if rr<0.08 || rr>0.45 {
        p.locType:="不確定"
        p.locConf:=0
        p.mapName:="地圖無法確認"
        p.mapConf:=0
        return
    }
    try {
        f:=ExtractRecognitionFeatures(p.hwnd)
        r:=JudgeRecognitionFeature(f.redratio)
        if r.kind="normal"
            p.locType:="怪物區"
        else if r.kind="revive"
            p.locType:="復活點"
        else
            p.locType:="不確定"
        p.locConf:=r.conf
        ; Exact map is diagnostic/display only. It does not control Recovery.
        mr:=RecognizeExactMap(p.hwnd)
        p.mapName:=mr.name
        p.mapConf:=mr.conf
    }
}

UpdateLocationText(p) {
    global LocationNowTxt
    try LocationNowTxt.Text:="判定位置：" NotificationLocationText(p)
}

TestSelectedLocation(*) {
    global LocationProfileDDL,profiles,APP_TITLE
    row:=LocationProfileDDL.Value
    if !row || row>profiles.Length {
        MsgBox "請在地圖判定設定頁選擇測試帳號。",APP_TITLE
        return
    }
    p:=profiles[row]
    if !ProfileGameAlive(p) {
        MsgBox "此帳號目前沒有有效的 game.exe 綁定。",APP_TITLE
        return
    }
    WinActivate "ahk_id " p.hwnd
    if !WinWaitActive("ahk_id " p.hwnd,,2) {
        MsgBox "無法將選定遊戲視窗切到最上層，已取消位置判定。",APP_TITLE
        return
    }
    Sleep 700
    UpdateProfileLocation(p)
    UpdateLocationText(p)
    AddRecentEvent(p.name " 位置：" NotificationLocationText(p))
    RefreshProfileLV()
}


ScanProfileLocationOnce(p, reason:="MONITOR_BIND") {
    ; v1.3.10.3: 地圖只在監控綁定成功 / Recovery 取得新 HWND 後辨識一次。
    ; ImageSearch 依賴可見畫面，因此短暫切到該視窗；失敗只顯示不確定，絕不觸發 Recovery。
    global monitorLocationScanBusy
    if monitorLocationScanBusy || !ProfileGameAlive(p)
        return false
    monitorLocationScanBusy:=true
    ok:=false
    try {
        WinActivate "ahk_id " p.hwnd
        if WinWaitActive("ahk_id " p.hwnd,,1.5) {
            Sleep 350
            UpdateProfileLocation(p)
            ok:=true
            EventLog(p.name,"MAP_BIND_SCAN",reason "｜" NotificationLocationText(p))
            AddRecentEvent(p.name " 位置：" NotificationLocationText(p))
        }
    } finally {
        monitorLocationScanBusy:=false
    }
    return ok
}

ScanAllMonitoredLocationsOnce(reason:="MONITOR_START") {
    global profiles
    for p in profiles {
        if !p.enabled || !ProfileGameAlive(p)
            continue
        ScanProfileLocationOnce(p,reason)
        Sleep 120
    }
    RefreshProfileLV()
}

MonitorLocationScanTick() {
    ; v1.3.10.3 compatibility no-op：禁止週期性切換視窗掃地圖。
    return
}


StartDynamicHPCalibration(*) {
    global profiles,APP_TITLE,hpCalibration,HP_CALIBRATION_MS,memoryHpHandles
    if IsObject(hpCalibration) {
        MsgBox "目前已有角色正在進行血量校正。",APP_TITLE
        return
    }

    ; v1.3.12.5: the Home 「監控」 checkboxes are already multi-select.
    ; v1.3.12.6: 最大 HP 改由使用者依左上角 HP 欄位輸入；已學習最大 HP 可能被舊 offset 灌高，只當預設值。
    alive:=[]
    skipped:=[]
    for idx,p in profiles {
        if !p.enabled
            continue
        if !ProfileGameAlive(p) {
            skipped.Push(p.name "（未登入）")
            continue
        }
        alive.Push(idx)
    }
    if !alive.Length {
        MsgBox "目前沒有可校正的角色。`n`n請在首頁「監控」欄勾選一隻或多隻已登入的角色。",APP_TITLE
        return
    }

    intro:="接下來會逐一詢問勾選角色的最大 HP（遊戲左上角 HP 欄位的最大值）。"
        . "`n`n・同一版 game.exe 的 HP 位址相同，輸入一隻角色就能校正全部角色。"
        . "`n・不想校正的角色按「取消」略過。"
        . "`n・按下確定時角色需為滿血；之後 30 秒請讓角色正常打怪、受到傷害（掉血後回滿即可）。"
        . "`n・校正期間這些角色暫停死亡 / 假在線判定。"
    if MsgBox(intro,"多角色血量動態校正","OKCancel Iconi")!="OK"
        return

    rows:=[]
    for idx in alive {
        p:=profiles[idx]
        confirmed:=p.HasOwnProp("memHpConfirmedMax") ? p.memHpConfirmedMax+0 : 0
        defaultMax:=confirmed>0 ? confirmed : (p.HasOwnProp("memHpLearnedMax") ? p.memHpLearnedMax+0 : 0)
        ib:=InputBox("請輸入「" p.name "」左上角 HP 欄位顯示的最大 HP：","校正角色血量 - " p.name,"w380 h140",defaultMax>0 ? defaultMax : "")
        if ib.Result!="OK"
            continue
        value:=Trim(StrReplace(ib.Value,",",""))
        if !IsInteger(value) || Integer(value)<=0 {
            skipped.Push(p.name "（最大 HP 輸入無效）")
            continue
        }
        SetConfirmedMaxHP(idx,Integer(value))
        rows.Push(idx)
    }
    if !rows.Length {
        msg:="沒有輸入任何角色的最大 HP，未開始校正。"
        if skipped.Length
            msg.="`n`n略過：`n- " JoinNames(skipped)
        MsgBox msg,APP_TITLE
        return
    }
    BeginHPCalibration(rows,false)
}

; v1.3.12.6: 使用者確認的最大 HP 同時覆蓋已學習最大 HP（清掉被舊 offset 灌高的錯誤值）。
SetConfirmedMaxHP(idx,maxHp) {
    global profiles,PROFILE_INI
    p:=profiles[idx]
    oldLearned:=p.HasOwnProp("memHpLearnedMax") ? p.memHpLearnedMax+0 : 0
    p.memHpConfirmedMax:=maxHp
    p.memHpLearnedMax:=maxHp
    p.memHpLearnedMaxDirty:=0
    p.memHpLearnedMaxSaveTick:=A_TickCount
    try IniWrite maxHp, PROFILE_INI, "Profile_" idx, "MemoryHPConfirmedMax"
    try IniWrite maxHp, PROFILE_INI, "Profile_" idx, "MemoryHPLearnedMax"
    EventLog(p.name,"HP_MAX_CONFIRMED","使用者確認最大 HP=" maxHp "（原已學習 " oldLearned "）")
}

; v1.3.12.6: 維修後 offset 失效的角色，若已有使用者確認的最大 HP，就自動重新校正（不跳視窗）。
MaybeStartAutoHPCalibration() {
    global profiles,hpCalibration,hpAutoCalibNextTick,HP_AUTO_CALIB_RETRY_MS
    ; v1.3.13.0: Game.pdb 解析中或已可用時不需要動態校正。
    if IsObject(hpCalibration) || A_TickCount<hpAutoCalibNextTick || GameOffsetsResolving()
        return
    rows:=[]
    for idx,p in profiles {
        if !p.enabled || p.state!="監控中" || !p.HasOwnProp("memHpStale") || !p.memHpStale
            continue
        if GameOffsetsReady(p.pid)
            continue
        if !p.HasOwnProp("memHpConfirmedMax") || p.memHpConfirmedMax<=0 || !ProfileGameAlive(p)
            continue
        rows.Push(idx)
    }
    if !rows.Length
        return
    ; 先排定下次重試，掃描失敗時才不會每 50ms 重跑。
    hpAutoCalibNextTick:=A_TickCount+HP_AUTO_CALIB_RETRY_MS
    EventLog("GLOBAL","HP_AUTO_CALIBRATION","HP 位址失效｜自動校正 " rows.Length " 隻角色")
    BeginHPCalibration(rows,true)
}

ScanModuleForHPValue(hProc,moduleBase,moduleSize,maxHp) {
    candidates:=[]
    chunk:=1024*1024,pos:=0
    while pos<moduleSize {
        todo:=Min(chunk,moduleSize-pos)
        buf:=Buffer(todo,0),bytesRead:=0
        if DllCall("ReadProcessMemory","Ptr",hProc,"Ptr",moduleBase+pos,"Ptr",buf.Ptr,"UPtr",todo,"UPtr*",&bytesRead,"Int") && bytesRead>=4 {
            off:=0,limit:=bytesRead-4
            while off<=limit {
                if NumGet(buf,off,"UInt")=maxHp
                    candidates.Push({offset:pos+off,last:maxHp,changes:0,samples:0,dips:0,over:0})
                off+=4
            }
        }
        pos+=todo
    }
    return candidates
}

BeginHPCalibration(rows,auto) {
    global profiles,APP_TITLE,hpCalibration,hpCalibrationAuto,HP_CALIBRATION_MS,memoryHpHandles
    jobs:=[]
    noCandidate:=[]
    for row in rows {
        p:=profiles[row], maxHp:=p.memHpConfirmedMax+0
        hProc:=memoryHpHandles.Get(p.pid,0)
        if !hProc {
            hProc:=DllCall("OpenProcess","UInt",0x0410,"Int",0,"UInt",p.pid,"Ptr")
            if hProc
                memoryHpHandles[p.pid]:=hProc
        }
        if !hProc {
            EventLog(p.name,"HP_CALIBRATION_SKIP","OpenProcess 失敗")
            continue
        }
        moduleBase:=GetGameModuleBase(p.pid,hProc)
        moduleSize:=GetGameModuleSize(p.pid)
        if !moduleBase || !moduleSize {
            EventLog(p.name,"HP_CALIBRATION_SKIP","無法取得 game.exe module")
            continue
        }

        candidates:=ScanModuleForHPValue(hProc,moduleBase,moduleSize,maxHp)
        if !candidates.Length {
            EventLog(p.name,"HP_CALIBRATION_NO_CANDIDATE","MaxHP=" maxHp "｜module 無候選（當下可能不是滿血，或最大 HP 與遊戲顯示不同）")
            noCandidate.Push(p.name)
            continue
        }

        p.memHpCalibrating:=1
        p.memHpReadOk:=0
        p.memHpState:="角色血量校正中"
        p.memHpZeroStreak:=0,p.memHpAliveStreak:=0
        jobs.Push({row:row,pid:p.pid,maxHp:maxHp,startTick:A_TickCount,candidates:candidates,moduleBase:moduleBase,duration:HP_CALIBRATION_MS,done:0,build:GetGameBuildStamp(p.pid)})
        EventLog(p.name,"HP_CALIBRATION_START",(auto ? "自動" : "手動") "動態校正｜MaxHP=" maxHp "｜候選=" candidates.Length)
    }

    if !jobs.Length {
        if auto {
            EventLog("GLOBAL","HP_AUTO_CALIBRATION_RETRY","沒有角色找到 HP 候選（可能不是滿血）｜稍後自動重試")
        } else {
            msg:="勾選的角色都無法建立 HP 候選，沒有開始校正。"
            if noCandidate.Length
                msg.="`n`n記憶體中找不到輸入的最大 HP：" JoinNames(noCandidate)
                    . "`n請確認輸入的是左上角 HP 欄位的最大值，並在角色滿血時按下確定。"
            MsgBox msg,APP_TITLE
        }
        return false
    }
    hpCalibration:=jobs
    hpCalibrationAuto:=auto
    AddRecentEvent("🔎 " (auto ? "自動" : "多角色") "血量動態校正開始｜" jobs.Length " 隻｜30 秒")
    ; 高回復率：受傷後很快回滿，用 50ms 取樣才抓得到掉血。
    SetTimer DynamicHPCalibrationTick,50
    return true
}

DynamicHPCalibrationTick() {
    global hpCalibration,profiles,APP_TITLE,MEMORY_HP_RUNTIME_OFFSET,INI,memoryHpHandles,MEMORY_HP_RECOVERY_GRACE_MS
    global MEMORY_HP_BUILD,hpCalibrationAuto,hpAutoCalibNextTick,HP_AUTO_CALIB_RETRY_MS
    if !IsObject(hpCalibration) {
        SetTimer DynamicHPCalibrationTick,0
        return
    }

    allDone:=true
    for job in hpCalibration {
        if job.done
            continue
        allDone:=false
        if job.row<1 || job.row>profiles.Length {
            job.done:=1
            continue
        }
        p:=profiles[job.row]
        if p.pid!=job.pid || !ProfileGameAlive(p) {
            p.memHpCalibrating:=0,p.memHpState:="校正中止"
            EventLog(p.name,"HP_CALIBRATION_CANCEL","PID_CHANGED")
            job.done:=1
            continue
        }
        hProc:=memoryHpHandles.Get(job.pid,0)
        if !hProc {
            p.memHpCalibrating:=0,p.memHpState:="校正中止"
            job.done:=1
            continue
        }

        for item in job.candidates {
            buf:=Buffer(4,0),bytesRead:=0
            ok:=DllCall("ReadProcessMemory","Ptr",hProc,"Ptr",job.moduleBase+item.offset,"Ptr",buf.Ptr,"UPtr",4,"UPtr*",&bytesRead,"Int")
            if !ok || bytesRead!=4
                continue
            v:=NumGet(buf,0,"UInt")
            item.samples+=1
            if v=item.last
                continue
            item.changes+=1
            if v>job.maxHp*1.02
                item.over+=1
            ; 掉血：從滿血降到滿血以下（高回復率下會很快回滿，所以計算「掉血次數」）。
            if item.last>=job.maxHp && v<job.maxHp
                item.dips+=1
            item.last:=v
        }

        if A_TickCount-job.startTick<job.duration
            continue

        ; v1.3.12.6: HP 特徵＝曾從滿血掉下來、且從未超過最大 HP。
        best:=0
        hpLike:=[]
        for item in job.candidates {
            if item.over>0 || item.dips<1 || item.changes<2
                continue
            hpLike.Push(item)
            if !IsObject(best) || item.dips>best.dips || (item.dips=best.dips && item.changes>best.changes)
                best:=item
        }
        if !IsObject(best) {
            p.memHpCalibrating:=0,p.memHpState:="校正失敗"
            EventLog(p.name,"HP_CALIBRATION_FAIL","30 秒內沒有偵測到掉血（候選=" job.candidates.Length "）｜請讓角色受到傷害後再校正")
            job.done:=1
            continue
        }
        ; 行為完全相同的候選（例如 HP 的顯示用複本）都能代表 HP，交給多角色共識挑選，不再直接判失敗。
        tied:=[]
        for item in hpLike
            if item.dips=best.dips && item.changes=best.changes
                tied.Push(item.offset)

        p.memHpCalibrating:=0,p.memHpState:="校正完成，等待套用"
        EventLog(p.name,"HP_CALIBRATION_OK","offset=0x" Format("{:X}",best.offset) "｜掉血=" best.dips "｜Changes=" best.changes "｜Samples=" best.samples "｜同行為候選=" tied.Length)
        job.resultOffset:=best.offset
        job.resultOffsets:=tied
        job.done:=1
    }

    if !allDone {
        ; Re-evaluate after finishing jobs in this tick.
        allDone:=true
        for job in hpCalibration
            if !job.done {
                allDone:=false
                break
            }
    }
    if !allDone
        return

    SetTimer DynamicHPCalibrationTick,0
    ; Pick the consensus module-relative offset. A maintenance build should normally
    ; yield the same offset in every game.exe. Only persist a clear consensus.
    ; v1.3.12.6: 每隻角色可投給多個行為相同的候選；票數相同時取最小 offset。
    counts:=Map(),okCount:=0,build:=""
    for job in hpCalibration {
        if !job.HasOwnProp("resultOffsets")
            continue
        okCount+=1
        if build="" && job.build!=""
            build:=job.build
        for off in job.resultOffsets
            counts[off]:=counts.Has(off) ? counts[off]+1 : 1
    }
    bestOff:=-1,bestN:=0
    for off,n in counts
        if n>bestN || (n=bestN && off<bestOff)
            bestOff:=off,bestN:=n

    total:=hpCalibration.Length
    if bestOff>=0 {
        bestKey:=Format("{:X}",bestOff)
        MEMORY_HP_RUNTIME_OFFSET:=bestOff
        try IniWrite bestOff,INI,"MemoryHP","LastDetectedOffset"
        if build!="" {
            MEMORY_HP_BUILD:=build
            try IniWrite build,INI,"MemoryHP","BuildStamp"
        }
        for p in profiles {
            if !ProfileGameAlive(p)
                continue
            p.memHpOffset:=bestOff
            ; 套用後仍要重新「連續讀到合理 HP」才啟用死亡判定，不直接相信校正結果。
            p.memHpArmed:=0,p.memHpStale:=0,p.memHpPlausibleStreak:=0
            p.memHpUnarmedSince:=A_TickCount,p.memHpSuspectLogged:=0
            p.memHpZeroStreak:=0,p.memHpAliveStreak:=0
            p.memHpGraceUntil:=A_TickCount+MEMORY_HP_RECOVERY_GRACE_MS
        }
        hpAutoCalibNextTick:=0
        EventLog("GLOBAL","HP_CALIBRATION_APPLIED","offset=0x" bestKey "｜成功 " okCount "/" total "｜同意 " bestN " 隻｜Build=" build)
        AddRecentEvent("✓ " (hpCalibrationAuto ? "自動" : "多角色") " HP 校正完成｜成功 " okCount "/" total "｜offset 0x" bestKey "（" bestN " 隻同意）")
        if !hpCalibrationAuto
            MsgBox "多角色血量校正完成。`n`n成功：" okCount " / " total
                . "`n共識 Offset：0x" bestKey
                . "`n同意角色：" bestN " 隻"
                . "`n`n已套用至目前遊戲程序，並記錄目前 game.exe 版本；之後維修更新會自動重新校正。",APP_TITLE
    } else {
        EventLog("GLOBAL","HP_CALIBRATION_NONE","沒有角色偵測到掉血｜" (hpCalibrationAuto ? Floor(HP_AUTO_CALIB_RETRY_MS/1000) " 秒後自動重試" : "手動校正結束"))
        AddRecentEvent("⚠ HP 校正失敗｜沒有角色偵測到掉血" (hpCalibrationAuto ? "，稍後自動重試" : ""))
        if hpCalibrationAuto
            hpAutoCalibNextTick:=A_TickCount+HP_AUTO_CALIB_RETRY_MS
        else
            MsgBox "校正結束，但 30 秒內沒有角色偵測到掉血。`n`n請讓角色在打怪、會受到傷害的地方，再按一次校正。",APP_TITLE
    }
    hpCalibration:=0
    hpCalibrationAuto:=false
}

CancelDynamicHPCalibration(reason) {
    global hpCalibration,profiles,hpCalibrationAuto
    hpCalibrationAuto:=false
    SetTimer DynamicHPCalibrationTick,0
    if IsObject(hpCalibration) {
        for job in hpCalibration {
            if job.row>=1 && job.row<=profiles.Length {
                p:=profiles[job.row]
                p.memHpCalibrating:=0
                p.memHpState:="校正中止"
                EventLog(p.name,"HP_CALIBRATION_CANCEL",reason)
            }
        }
    }
    hpCalibration:=0
}

CheckAllHpReadability(*) {
    global profiles,APP_TITLE
    total:=0
    readable:=0
    bad:=[]
    for i,p in profiles {
        if !p.enabled || !p.deathDetect
            continue
        total+=1
        hp:=0
        ok:=ProfileGameAlive(p) && ReadMemoryHP(p.pid,&hp,p.memHpOffset)
        ; v1.3.12.6: 讀得到但數值不合理（0、超過最大 HP、位址已失效）也算不可監控。
        if ok {
            maxHp:=ProfileMaxHP(p)
            if (p.HasOwnProp("memHpStale") && p.memHpStale) || hp<=0 || (maxHp>0 && hp>maxHp*1.20)
                ok:=false
        }
        if ok {
            readable+=1
            p.memHp:=hp
            p.memHpReadOk:=1
            p.memHpState:="READ_OK"
        } else {
            p.memHpReadOk:=0
            p.memHpState:="READ_FAIL"
            bad.Push(p.name)
        }
    }
    RefreshProfileLV()
    msg:="Memory HP 可監控：" readable " / " total
    if bad.Length
        msg.="`nMemory 無法讀取：" JoinNames(bad) "`n畫面 HP ROI 僅保留為內部備援，不再要求視窗保持未遮蔽。"
    MsgBox msg,APP_TITLE
}

JoinNames(arr) {
    out:=""
    for name in arr
        out.=(out="" ? "" : "、") name
    return out
}

ResetDeathStats(*) {
    global LV,profiles,APP_TITLE
    row:=LV.GetNext()
    if !row {
        MsgBox "請先在首頁 / 監控選擇一個帳號。",APP_TITLE
        return
    }
    p:=profiles[row]
    p.hpEventNo:=0
    p.hpReviveNo:=0
    SaveProfiles()
    EventLog(p.name,"HP_STATS_RESET","死亡 / 復活累積次數已重置")
    RefreshProfileLV()
}



; 角色目前所在地圖（記憶體）；地圖沒變就沿用上次結果，查不到時 15 秒後才重試。
ProfileMapInfo(p) {
    if !p.pid || !ProfileGameAlive(p) || !GameOffsetsReady(p.pid) || !GameCharacterLoaded(p.pid)
        return 0
    mapId:=ReadGameMapId(p.pid)
    if mapId=""
        return 0
    if p.HasOwnProp("memMapId") && p.memMapId=mapId && (IsObject(p.memMapInfo) || A_TickCount-p.memMapTick<15000)
        return p.memMapInfo
    p.memMapId:=mapId,p.memMapTick:=A_TickCount
    p.memMapInfo:=GameMapInfo(p.pid,mapId)
    return p.memMapInfo
}

NotificationLocationText(p) {
    global ConfEdit
    threshold:=70
    try threshold:=Max(1,Min(100,ConfEdit.Value+0))
    catch
        threshold:=70

    ; v1.3.18.3：遊戲記憶體讀得到地圖時，直接顯示完整地圖名稱（與遊戲右上角相同）。
    info:=ProfileMapInfo(p)
    if IsObject(info)
        return info.name (info.peace ? "（安全區）" : "")

    ; v1.3.9.8: 首頁統一顯示「區域類型 / 精確地圖」。
    ; 精確地圖信心不足時保留第一層區域判定，不以一次辨識失敗觸發 Recovery。
    mapText := (p.mapName!="" && p.mapName!="地圖無法確認" && p.mapConf>=threshold) ? p.mapName : "不確定"
    if p.locType="怪物區"
        return "怪物區 / " mapText
    if p.locType="復活點"
        return "一般區 / " mapText
    return "不確定 / " mapText
}


SendDeathClosedDiscord(p,dur) {
    loc:=NotificationLocationText(p)
    deathTime:=p.hpDeathTime!="" ? p.hpDeathTime : "-"
    msg:="☠️ HIHIYONG 死亡事件 #" DeathStatsEventNo(p) " 已結案"
        . "`n角色：" p.name
        . "`n死亡時間：" deathTime
        . "`n復活時間：" FormatTime(,"yyyy-MM-dd HH:mm:ss")
        . "`n死亡持續：約 " dur " 秒"
        . "`n判定位置：" loc
        . "`n今日死亡：" DeathStatsTodayText(p)
    try SendDeathDiscordMessage(msg)
}

SendDeathEventDiscord(p,kind,dur:=0) {
    ; v0.7.5.0: 只使用最近一次已快取的位置，禁止死亡通知觸發 WinActivate。
    loc:=NotificationLocationText(p)
    if kind="DEATH"
        msg:="☠️ 角色死亡通知`n角色：" p.name "`n判定位置：" loc "`n死亡事件：#" DeathStatsEventNo(p) "`n死亡時間：" p.hpDeathTime
    else if kind="NO_REVIVE"
        msg:="🚨 死亡超過 30 秒未復活`n角色：" p.name "`n判定位置：" loc "`n死亡事件：#" DeathStatsEventNo(p) "`n死亡時間：" p.hpDeathTime
    else
        msg:="♥️ 角色復活通知`n角色：" p.name "`n判定位置：" loc "`n死亡事件：#" DeathStatsEventNo(p) "`n死亡持續：約 " dur " 秒"
    try SendDeathDiscordMessage(msg)
}

SendDeathDiscordMessage(msg,force:=false) {
    global DeathDiscordEnableCB,DeathDiscordWebhookEdit
    if !force && !DeathDiscordEnableCB.Value
        return
    url:=Trim(DeathDiscordWebhookEdit.Value)
    if url=""
        return
    payload:='{"content":"' JsonEscape(msg) '","username":"HIHIYONG Death Monitor"}'
    SendDiscordAsync(url,payload)
}

StartDeathAlarm(seconds:=0, p:=0) {
    global DeathAlarmEnableCB,DeathAlarmSecondsEdit,deathAlarmRunning,deathAlarmUntil,deathAlarmPhase
    if !DeathAlarmEnableCB.Value
        return
    ; H-020：每個角色可以各自關掉警報音（預設開）。p = 觸發警報的角色；測試按鈕沒有角色，一定會響
    if IsObject(p) && p.HasOwnProp("deathAlarm") && !p.deathAlarm
        return
    if seconds<=0
        seconds:=Max(5,Min(300,DeathAlarmSecondsEdit.Value+0))
    deathAlarmRunning:=true
    deathAlarmUntil:=A_TickCount+seconds*1000
    deathAlarmPhase:=0
    SetTimer DeathAlarmTick,100
}

DeathAlarmTick() {
    global deathAlarmRunning,deathAlarmUntil,deathAlarmPhase
    if !deathAlarmRunning || A_TickCount>=deathAlarmUntil {
        StopDeathAlarm()
        return
    }
    deathAlarmPhase+=1
    if Mod(deathAlarmPhase,8)=1 {
        try {
            SoundBeep(980,420)
        }
    } else if Mod(deathAlarmPhase,8)=5 {
        try {
            SoundBeep(1320,420)
        }
    }
}

StopDeathAlarm(*) {
    global deathAlarmRunning
    deathAlarmRunning:=false
    SetTimer DeathAlarmTick,0
}

TestDeathAlarm(*) {
    StartDeathAlarm(10)
}

TestDeathDiscordWebhook(*) {
    global DeathDiscordWebhookEdit,APP_TITLE
    if Trim(DeathDiscordWebhookEdit.Value)="" {
        MsgBox "請先輸入死亡通知 Webhook。",APP_TITLE
        return
    }
    try {
        SendDeathDiscordMessage("🟢 HIHIYONG Death Monitor 測試通知",true)
        MsgBox "死亡通知測試已送出。",APP_TITLE
    } catch as e {
        MsgBox "死亡通知測試失敗：`n" e.Message,APP_TITLE
    }
}

BrowseLauncher(*) {
    global LauncherEdit
    p:=FileSelect(1,, "選擇 HIHIYONG Launcher", "Executable (*.exe)")
    if p!=""
        LauncherEdit.Value:=p
}



RecoveryWebhook(p,stage,detail:="") {
    global DiscordEnableCB,DiscordPcEdit
    if !DiscordEnableCB.Value
        return
    pc:=Trim(DiscordPcEdit.Value)
    if pc=""
        pc:=A_ComputerName
    msg:="🔄 HIHIYONG Recovery"
        . "`n電腦：" pc
        . "`n角色：" p.name
        . "`n階段：" stage
        . "`n時間：" FormatTime(,"yyyy-MM-dd HH:mm:ss")
    if detail!=""
        msg.="`n說明：" detail
    if p.locType!="不確定"
        msg.="`n判定位置：" NotificationLocationText(p)
    try SendDiscordMessage(msg)
    catch as e
        EventLog(p.name,"DISCORD_FAIL",e.Message)
}

CleanupFailedRecoveryWindow() {
    global activeRecoveryHwnd,activeRecoveryPid,activeRecoveryCommitted
    ; v1.3.7.4: 一旦已確認進入遊戲（HUD/HP可信），失敗處理不得再關閉該 game.exe。
    if activeRecoveryCommitted {
        activeRecoveryHwnd:=0
        activeRecoveryPid:=0
        activeRecoveryCommitted:=false
        return
    }
    if activeRecoveryPid {
        try ProcessClose activeRecoveryPid
        catch
            try {
                if activeRecoveryHwnd && WinExist("ahk_id " activeRecoveryHwnd)
                    WinClose "ahk_id " activeRecoveryHwnd
            }
    }
    activeRecoveryHwnd:=0
    activeRecoveryPid:=0
    activeRecoveryCommitted:=false
}

ManualRecover(*) {
    global LV, profiles, manualRecovery, processingQueue, abortRequested
    row:=LV.GetNext()
    if !row {
        MsgBox "請先選一個帳號。", APP_TITLE
        return
    }
    if row > profiles.Length
        return
    abortRequested := false
    manualRecovery[row] := true
    EnqueueRecovery(row,"手動恢復")
    ; 手動恢復不要求先按「開始監控」。
    if !processingQueue
        SetTimer ProcessNextRecovery, -10
}

ProcessNextRecovery() {
    global processingQueue,recoveryQueue,queued,profiles,running,abortRequested,Status,manualRecovery,MAX_AUTO_FAILURES,activeRecoveryHwnd,activeRecoveryPid,activeRecoveryCommitted,recoveryUserPauseLogged,fastLoginCritical,foregroundOwner
    if processingQueue || !recoveryQueue.Length
        return
    ; v1.3.14.0: 另一個帳號正在做進入遊戲後的前景操作，或有帳號剛按下開始遊戲仍在等待載入時，先不開始下一個登入。
    if foregroundOwner!="" || AsyncLoadingBlocksQueue() {
        SetTimer ProcessNextRecovery,-1000
        return
    }
    idx := recoveryQueue[1]
    isManual := manualRecovery.Has(idx)
    if (!running && !isManual)
        return
    processingQueue:=true
    foregroundOwner:="login"
    idx:=recoveryQueue.RemoveAt(1)
    if queued.Has(idx)
        queued.Delete(idx)
    p:=profiles[idx]
    activeRecoveryCommitted:=false
    recoveryUserPauseLogged:=false
    p.state:="恢復中"
    RefreshProfileLV()
    EventLog(p.name, "RECOVERY_START", "開始恢復" Focus_RecentNote(focusRecent, A_Now))
    RecoveryBatchNote()
    AddRecentEvent(p.name " 開始 Recovery")
    asyncLoading:=false
    try {
        oldBoundPid:=p.pid
        newHwnd:=RecoverProfile(idx,&asyncLoading)
        if asyncLoading
            AsyncLoadingRegister(idx,newHwnd,oldBoundPid)
        else
            FinalizeRecovery(idx,newHwnd,oldBoundPid)
    } catch as e {
        if HandleRecoveryException(idx,e) {
            foregroundOwner:=""
            processingQueue:=false
            return
        }
    }
    foregroundOwner:=""
    if manualRecovery.Has(idx)
        manualRecovery.Delete(idx)
    RefreshProfileLV()
    processingQueue:=false
    ScheduleNextRecovery(3000)
}

ScheduleNextRecovery(delayMs) {
    global recoveryQueue,running,manualRecovery
    if recoveryQueue.Length {
        ; 全域監控中可繼續處理一般 Queue；未監控時只處理下一個手動要求。
        nextIdx := recoveryQueue[1]
        if running || manualRecovery.Has(nextIdx)
            SetTimer ProcessNextRecovery,-delayMs
    }
}

; 已確認進入遊戲（RecoverProfile 或背景載入完成）：綁定新視窗、位置補正、回到監控。
FinalizeRecovery(idx, newHwnd, oldBoundPid) {
    global profiles,running,Status,ReturnKeyEdit,ConfEdit,activeRecoveryHwnd,activeRecoveryPid,activeRecoveryCommitted,recoveryUserPauseLogged
    p:=profiles[idx]
    ; Recovery 一取得新遊戲 HWND 就先更新 Profile；PID change starts a brand-new Memory HP session.
    p.hwnd:=newHwnd
    p.pid:=WinGetPID("ahk_id " newHwnd)
    if oldBoundPid && oldBoundPid!=p.pid
        CloseMemoryHPHandle(oldBoundPid)
    ResetHPState(p)
    StartMemoryHPSession(p,p.pid,"RECOVERY_REBIND")
    if p.enabled {
        ScanProfileLocationOnce(p,"RECOVERY_REBIND")
        ; v1.3.10.4: RecoverProfile 的首次共識可能判成怪物區，但 Recovery_REBIND
        ; 再掃描卻確認為一般區（復活點）。舊版會直接 RECOVERY_OK，漏掉前點卡。
        ; 這裡以綁定後的最終位置為準補做一次前點，並再次確認已回怪物區。
        ; H-032：記憶體已確認在怪物地圖時，畫面掃描誤判成復活點也不能再按前點卡（耗用一張還會被傳走）。
        if p.locType="復活點" && (fieldNow:=RecoveryLeftTown(newHwnd))!="" {
            EventLog(p.name,"RECOGNITION_MEMORY","畫面掃描判成復活點，但記憶體確認在怪物地圖（" fieldNow "）｜不按前點卡")
            p.locType:="怪物區"
        }
        if p.locType="復活點" {
            EventLog(p.name,"NORMAL_AREA_ACTION","RECOVERY_REBIND 確認一般區｜開始前點")
            Status.Text:="狀態：" p.name "｜一般區確認，使用前點卡"
            key:=RecoveryUseReturnCard(newHwnd,p)
            EnsureRecoveryFocus(newHwnd,p.name)
            Sleep 700
            VerifyInGameHUD(newHwnd,p,"一般區前點後")
            if (left:=RecoveryLeftTown(newHwnd))!="" {
                EventLog(p.name,"RECOGNITION_MEMORY","記憶體確認已離開城裡（" left "）｜怪物區")
                decision3:="normal"
            } else {
                if (still:=RecoveryTownName(newHwnd))!="" {
                    EventLog(p.name,"RETURN_CARD_FAIL","一般區前點後記憶體確認仍在 " still)
                    throw Error("一般區前點後記憶體確認仍在 " still "（前點卡沒有生效）。")
                }
                decision3:=ConsensusLocation(newHwnd,Integer(ConfEdit.Value))
                EventLog(p.name,"NORMAL_AREA_ACTION_CHECK","前點後位置判定=" decision3)
            }
            if decision3!="normal"
                throw Error("一般區前點後未確認回到怪物區。")
            p.locType:="怪物區"
            p.locConf:=100
            EventLog(p.name,"NORMAL_AREA_ACTION_OK","前點完成｜已確認回到怪物區")
            RestoreProfileWindowPosition(idx,newHwnd)
        }
    }
    ; v0.7.5.4: RecoverProfile 已完成「HUD存在 + 位置安全流程 + PostKeys」。
    ; 後續被怪物打死屬死亡事件，不再倒推成登入失敗。
    p.state := running && p.enabled ? "監控中" : "已恢復（未監控）"
    p.recoveries+=1, p.failures:=0
    EventLog(p.name, "RECOVERY_OK", "新 PID " p.pid " / HWND " newHwnd "｜已確認進入遊戲")
    RecoveryGuardArm(p)
    RecoveryWebhook(p,"Recovery 成功","PID " p.pid "｜已確認進入遊戲")
    activeRecoveryHwnd:=0
    activeRecoveryPid:=0
    activeRecoveryCommitted:=false
    recoveryUserPauseLogged:=false
    AddRecentEvent(p.name " Recovery 成功｜" NotificationLocationText(p) "｜PID " p.pid)
    Status.Text:="狀態：" p.name " 恢復成功｜" NotificationLocationText(p) "｜PID " p.pid " / HWND " newHwnd "｜已回到監控"
}

; Recovery 失敗處理；F10 / 停止監控中止時回傳 true（呼叫端直接結束，不排下一個）。
HandleRecoveryException(idx, e) {
    global profiles,abortRequested,Status,manualRecovery,MAX_AUTO_FAILURES,activeRecoveryHwnd,activeRecoveryPid,activeRecoveryCommitted,fastLoginCritical
    p:=profiles[idx]
    if abortRequested {
        p.state:="人工操作"
        EventLog(p.name,"RECOVERY_ABORTED","F7 / 停止監控中止 Recovery；保留目前 game.exe 供人工操作")
        activeRecoveryHwnd:=0
        activeRecoveryPid:=0
        Status.Text:="狀態：Recovery 已中止－等待人工操作"
        if manualRecovery.Has(idx)
            manualRecovery.Delete(idx)
        RefreshProfileLV()
        fastLoginCritical:=false
        return true
    }
    p.failures += 1
    fastLoginCritical:=false   ; 登入關鍵區中途失敗也要解除，否則排隊重啟的 Timer 會一直被擋住（2026-10-26 椰奶卡在選角後沒有自動重啟）
    EventLog(p.name, "RECOVERY_FAIL", e.Message)

    ; v1.3.7.4 Login Commit Point：
    ; HUD/HP 已證明進入遊戲後，即使後續位置/按鍵判斷失敗，也保留 game.exe，
    ; 不再把「已登入」倒推成「登入失敗」並完整重啟。
    committedFailure := activeRecoveryCommitted
    CleanupFailedRecoveryWindow()

    if committedFailure {
        p.state := "需要人工確認"
        reason := "已確認進入遊戲，後續流程異常；已保留 game.exe｜" e.Message
        EventLog(p.name, "LOGIN_COMMITTED_SAFE", reason)
        RecoveryWebhook(p,"已登入－保留遊戲視窗",reason)
        Status.Text := "狀態：" p.name " 已進入遊戲；後續異常但已保留視窗，不自動關閉"
    } else if p.failures >= MAX_AUTO_FAILURES {
        p.state := "需要人工處理"
        reason := "連續自動恢復失敗 " p.failures " 次｜最後原因：" e.Message
        EventLog(p.name, "MANUAL_REQUIRED", reason)
        RecoveryWebhook(p,"需要人工處理",reason)
        Status.Text := "狀態：" p.name " 需要人工處理：" reason
    } else {
        p.state := "恢復失敗"
        Status.Text := "狀態：" p.name " 恢復失敗：" e.Message "｜5 秒後完整重啟再試"
        SetTimer (() => RetryProfile(idx)), -5000
    }
    return false
}

RetryProfile(idx) {
    global running,profiles
    if running && idx<=profiles.Length && profiles[idx].enabled && profiles[idx].state="恢復失敗"
        EnqueueRecovery(idx,"失敗後 5 秒完整重啟再嘗試")
}

ForceEnglishInput(hwnd, profileName:="") {
    ; v1.3.8.0 IME Safe Login：要求目標遊戲 thread 切到 English (US)。
    ; 不依賴使用者目前的注音/倉頡/Shift 狀態。
    if !hwnd || !WinExist("ahk_id " hwnd)
        return false
    try {
        hkl:=DllCall("LoadKeyboardLayoutW","Str","00000409","UInt",0x00000001,"Ptr")
        if hkl {
            ; WM_INPUTLANGCHANGEREQUEST = 0x0050
            PostMessage 0x0050, 0, hkl,, "ahk_id " hwnd
            Sleep 120
            if profileName!=""
                EventLog(profileName,"IME_SAFE","登入輸入前要求 English (US) keyboard layout")
            return true
        }
    }
    return false
}

GetPointScreenPos(hwnd,key,&px,&py,&cw:=0,&ch:=0) {
    global points
    if !points.Has(key) || !WinExist("ahk_id " hwnd)
        return false
    WinGetClientPos &x,&y,&w,&h,"ahk_id " hwnd
    if w<=0 || h<=0
        return false
    p:=points[key]
    usePixel:=false
    try usePixel := (p.rx!="" && p.ry!="" && p.cw!="" && p.ch!="" && Abs(w-p.cw)<=4 && Abs(h-p.ch)<=4)
    if usePixel {
        px:=Round(x+p.rx), py:=Round(y+p.ry)
    } else {
        px:=Round(x+p.nx*w), py:=Round(y+p.ny*h)
    }
    cw:=w, ch:=h
    return true
}

ScreenTemplatePath(key) {
    global SCREEN_TEMPLATE_DIR
    return SCREEN_TEMPLATE_DIR "\\" key ".bmp"
}

CaptureScreenReadyTemplate(hwnd,key) {
    global SCREEN_TEMPLATE_DIR
    if !DirExist(SCREEN_TEMPLATE_DIR)
        DirCreate SCREEN_TEMPLATE_DIR
    if !GetPointScreenPos(hwnd,key,&px,&py)
        return false
    ; 小 ROI 足以辨認按鈕/輸入欄，速度遠快於全畫面比對。
    tw:=72, th:=40
    return SaveScreenRectBmp(px-Floor(tw/2),py-Floor(th/2),tw,th,ScreenTemplatePath(key))
}

GetBootScreenSignature(hwnd) {
    if !WinExist("ahk_id " hwnd)
        return ""
    try WinGetClientPos &x,&y,&w,&h,"ahk_id " hwnd
    catch
        return ""
    if w<=0 || h<=0
        return ""
    pts := [[0.20,0.20],[0.50,0.20],[0.80,0.20],[0.30,0.55],[0.70,0.55],[0.50,0.82]]
    sig := w "x" h
    for pt in pts {
        sx:=Round(x+w*pt[1]), sy:=Round(y+h*pt[2])
        c:=0
        try {
            c:=PixelGetColor(sx,sy,"RGB")
        } catch {
            c:=0
        }
        ; 降低些微動畫/壓縮雜訊敏感度，只保留 RGB 高位。
        r:=(c>>16)&0xF8, g:=(c>>8)&0xF8, b:=c&0xF8
        sig .= "|" Format("{:02X}{:02X}{:02X}",r,g,b)
    }
    return sig
}

BootSignatureDistance(a,b) {
    if a="" || b=""
        return 0
    aa:=StrSplit(a,"|"), bb:=StrSplit(b,"|")
    if aa.Length!=bb.Length
        return 999
    diff:=0
    Loop aa.Length-1 {
        i:=A_Index+1
        if aa[i]!=bb[i]
            diff++
    }
    return diff
}

WaitBootLoadingSafe(hwnd,profileName,timeoutSec:=45,minWaitSec:=10,stableSec:=2) {
    global abortRequested,Status
    start:=A_TickCount
    baseline:=""
    changedSince:=0
    lastSig:=""
    EventLog(profileName,"BOOT_LOADING_WAIT","game.exe 已建立｜等待 Loading -> Server 畫面轉場；期間禁止八點座標")
    while A_TickCount-start < timeoutSec*1000 {
        if abortRequested
            throw Error("F10 已終止 Recovery。")
        if !WinExist("ahk_id " hwnd)
            throw Error("Boot Loading 等待期間 game.exe 視窗已消失。")
        EnsureRecoveryFocus(hwnd,profileName)
        sig:=GetBootScreenSignature(hwnd)
        elapsed:=(A_TickCount-start)/1000
        if baseline="" && sig!=""
            baseline:=sig
        dist:=BootSignatureDistance(baseline,sig)

        ; Server 畫面可能有動畫，因此不再要求整張畫面連續完全靜止。
        ; 最短保護期後，只要畫面已相對初始 Loading 發生足夠大的轉場並維持 1.4 秒，即視為 Ready。
        if elapsed>=minWaitSec && dist>=3 {
            if !changedSince
                changedSince:=A_TickCount
            if A_TickCount-changedSince>=1400 {
                EventLog(profileName,"SERVER_READY","偵測到 Loading -> Server 畫面轉場｜等待 " Round(elapsed,1) " 秒｜特徵差異 " dist "/6")
                return true
            }
        } else if dist<2 {
            changedSince:=0
        }

        ; 防止特徵點剛好落在動畫區：18 秒後若 client 已正常存在，採保守時間 Gate 放行。
        ; 這比 v1.3.9.4 的「必須完全靜止」更適合伺服器選單有動畫的畫面。
        if elapsed>=18 {
            try WinGetClientPos &cx,&cy,&cw,&ch,"ahk_id " hwnd
            catch {
                cw:=0, ch:=0
            }
            if cw>=640 && ch>=480 {
                EventLog(profileName,"SERVER_READY_FALLBACK","未取得穩定轉場特徵｜已完成 18 秒 Boot 保護且遊戲 Client 正常，允許開始登入")
                return true
            }
        }
        Status.Text:="狀態：" profileName "｜等待 Server Ready｜" Round(elapsed,1) "s｜轉場差異 " dist "/6｜F10 可終止"
        lastSig:=sig
        Sleep 300
    }
    EventLog(profileName,"BOOT_LOADING_TIMEOUT","等待 " timeoutSec " 秒仍無法確認 Server Ready；保留 game.exe，不執行八點座標")
    return false
}

WaitStageVisualReady(hwnd, profileName, stageName, baselineSig := "", minWaitSec := 4, timeoutSec := 15, requireChange := true, requiredDist := 2, stableMs := 1200) {
    global abortRequested,Status
    start:=A_TickCount
    stableSince:=0
    lastSig:=""
    maxDist:=0
    while A_TickCount-start < timeoutSec*1000 {
        if abortRequested
            throw Error("使用者停止測試。")
        if !hwnd || !WinExist("ahk_id " hwnd)
            throw Error(stageName " 等待期間遊戲視窗已消失。")
        EnsureRecoveryFocus(hwnd,profileName)
        sig:=GetBootScreenSignature(hwnd)
        elapsed:=(A_TickCount-start)/1000
        dist:=baselineSig!="" ? BootSignatureDistance(baselineSig,sig) : 0
        if dist>maxDist
            maxDist:=dist

        changedOK:=!requireChange || baselineSig="" || maxDist>=requiredDist
        sameAsLast:=(lastSig!="" && BootSignatureDistance(lastSig,sig)=0)
        if elapsed>=minWaitSec && changedOK && sameAsLast {
            if !stableSince
                stableSince:=A_TickCount
            if A_TickCount-stableSince>=stableMs {
                EventLog(profileName,"STAGE_READY",stageName "｜畫面已穩定｜等待 " Round(elapsed,1) " 秒｜最大轉場差異 " maxDist "/6")
                return true
            }
        } else if !sameAsLast {
            stableSince:=0
        }
        Status.Text:="狀態：" profileName "｜" stageName "｜等待畫面穩定 " Round(elapsed,1) "s｜轉場差異 " maxDist "/6｜F10 可終止"
        lastSig:=sig
        Sleep 300
    }

    ; 沒有樣板時採保守 fallback：已等待完整 timeout 且 Client 仍正常才允許下一步。
    ; 不因辨識失敗關閉 game.exe，並留下明確 Log 供不同電腦比對。
    try WinGetClientPos &cx,&cy,&cw,&ch,"ahk_id " hwnd
    catch {
        cw:=0, ch:=0
    }
    if cw>=640 && ch>=480 {
        EventLog(profileName,"STAGE_READY_FALLBACK",stageName "｜" timeoutSec " 秒內未取得可靠 Ready 特徵；Client 正常，採慢電腦保護後放行｜最大轉場差異 " maxDist "/6")
        return true
    }
    return false
}

WaitScreenReady(hwnd,key,profileName,timeoutSec:=60) {
    global abortRequested,Status,recoveryStage,profiles
    tpl:=ScreenTemplatePath(key)
    if !FileExist(tpl) {
        EventLog(profileName,"SCREEN_GATE_BLOCKED","缺少 " key " 畫面樣板；Fail-Closed 已阻止座標操作，請重新設定 8 點建立 Screen Ready 樣板")
        return false
    }
    stageNames:=Map("server","等待伺服器畫面","channel","等待分流畫面","connect","等待連線畫面","account","等待登入畫面","password","等待密碼欄","login","等待登入按鈕","char","等待角色畫面","startgame","等待開始遊戲")
    stage:=stageNames.Has(key) ? stageNames[key] : "等待畫面 " key
    idx:=0
    for i,p in profiles {
        if (p.name = profileName) {
            idx := i
            break
        }
    }
    if idx {
        recoveryStage[idx]:=stage
        RefreshProfileLV()
    }
    start:=A_TickCount
    stable:=0
    while A_TickCount-start < timeoutSec*1000 {
        if abortRequested
            throw Error("使用者停止測試。")
        EnsureRecoveryFocus(hwnd,profileName)
        if !GetPointScreenPos(hwnd,key,&px,&py)
            throw Error("無法取得 Screen Ready 座標：" key)
        ; 只在預期位置附近搜尋，避免同畫面其他相似按鈕造成誤判。
        x1:=px-70, y1:=py-50, x2:=px+70, y2:=py+50
        hit:=false
        try hit:=ImageSearch(&fx,&fy,x1,y1,x2,y2,"*55 " tpl)
        if hit {
            stable+=1
            if stable>=2 {
                EventLog(profileName,"SCREEN_READY",stage " Ready｜" Round((A_TickCount-start)/1000,1) " 秒")
                return true
            }
        } else stable:=0
        Status.Text:="狀態：" profileName "｜" stage "｜辨識中 " Round((A_TickCount-start)/1000,1) "s"
        Sleep 300
    }
    EventLog(profileName,"SCREEN_READY_TIMEOUT",stage "｜" timeoutSec " 秒內未確認")
    throw Error(stage " Timeout：" timeoutSec " 秒內未確認畫面 Ready。")
}

; 送按鍵 / 文字前確認遊戲視窗在前景；被搶走時重新切回一次，還是不行就停止（不把帳密打到別的視窗）。
EnsureActiveForInput(hwnd, label) {
    if WinActive("ahk_id " hwnd)
        return
    ActivateGame(hwnd)
    if !WinWaitActive("ahk_id " hwnd,,1)
        throw Error("輸入" label "前遊戲視窗不在前景（被其他視窗搶走），已停止輸入。")
}

FillLoginField(hwnd, pointKey, value, label, profileName) {
    global abortRequested

    if abortRequested
        throw Error("Recovery 已被中止。")
    if !hwnd || !WinExist("ahk_id " hwnd)
        throw Error("遊戲視窗已消失。")
    if LoginGuardInWorld(hwnd,profileName,"輸入" label)
        throw Error("角色已經在遊戲世界中，已停止輸入" label "（不打字）。")

    ; 每個欄位都重新確認 Recovery 視窗在前景，並避免其他電腦的 IME 狀態干擾帳密。
    ActivateGame(hwnd)
    ForceEnglishInput(hwnd, profileName)
    if !WinWaitActive("ahk_id " hwnd,,2)
        throw Error("無法將遊戲視窗切到前景以輸入" label "。")

    ; 點欄位後不要立刻送字，留時間讓遊戲 UI 接收焦點。
    ClickPoint(hwnd, pointKey)
    Sleep 300

    ; 按鍵與 SendText 都是送給「目前的前景視窗」：前景被別的視窗（例如凌晨搶焦點的程式、別的遊戲視窗）搶走時
    ; 絕不能送，否則帳密會打到別的地方。
    EnsureActiveForInput(hwnd,label)

    ; 明確清空欄位。Ctrl+A 與 Backspace 分開送，避免遊戲漏掉組合鍵。
    SendEvent "{Ctrl down}a{Ctrl up}"
    Sleep 120
    SendEvent "{Backspace}"
    Sleep 120

    ; SendText 對特殊字元較安全；輸入後再等待，避免下一個 Click 吃掉尾字。
    EnsureActiveForInput(hwnd,label)
    SendText value
    Sleep 350

    ; 不把帳密內容寫進 Log，只記錄長度，方便判斷 DPAPI/設定是否異常。
    EventLog(profileName, "LOGIN_INPUT", label "已輸入｜字元數=" StrLen(value))
}

FastTrace(profileName, stepName, startTick, note := "") {
    ms := A_TickCount - startTick
    detail := stepName "｜實際 " Round(ms/1000,2) " 秒"
    if note != ""
        detail .= "｜" note
    EventLog(profileName,"FAST_STEP",detail)
    return ms
}

; v1.3.14.0: asyncLoading 回傳 true 代表已按下開始遊戲、改由 AsyncLoadingTick 在背景等待角色載入；
; 此時回傳的 hwnd 尚未進入遊戲，後半段（RecoverProfileEnterGame）稍後才執行。
RecoverProfile(idx, &asyncLoading:=false) {
    global profiles,LauncherEdit,PostKeysEdit,ReturnKeyEdit,ConfEdit,Status,GAME_TITLE,UPDATE_TITLE,abortRequested,activeRecoveryHwnd,activeRecoveryPid,activeRecoveryCommitted,recoveryUserPauseLogged,recoveryStage,fastLoginCritical
    asyncLoading:=false
    p:=profiles[idx]
    ; 原本綁定的遊戲視窗還在、PID 沒變、角色已在遊戲世界（只是標題暫時不同等原因被判成綁定失效）：
    ; 不啟動 Launcher 開第二個遊戲（同一組帳密會被拒絕，或把好好的角色踢下線），直接重新綁定。
    if (live:=LoginExistingWorldHwnd(p.pid,p.hwnd)) {
        activeRecoveryHwnd:=live, activeRecoveryPid:=p.pid, activeRecoveryCommitted:=true
        EventLog(p.name,"RECOVERY_REUSE_EXISTING","原綁定的遊戲視窗還在、角色已在遊戲世界（視窗標題暫時不同等原因被判成綁定失效）｜不啟動 Launcher，直接重新綁定")
        return RecoverProfileEnterGame(idx,live,90)
    }
    launcher:=Trim(LauncherEdit.Value)
    if !FileExist(launcher)
        throw Error("找不到 Launcher：" launcher)
    if (p.account="" || p.password="")
        throw Error("帳號或密碼未設定。")

    old:=SnapshotGamePids()

    EventLog(p.name, "STEP", "啟動 Launcher")
    Status.Text:="狀態：" p.name "｜啟動 Launcher..."
    Run '"' launcher '"'
    updater:=WinWait(UPDATE_TITLE,,20)
    if !updater
        throw Error("Launcher/Updater Timeout：20 秒內沒有找到 Updater。")
    EventLog(p.name, "STEP", "Updater 已出現")
    WinActivate "ahk_id " updater
    try WinWaitActive "ahk_id " updater,,5
    WaitSeconds(5)
    hwnd:=WaitGameWithRepeatedEnter(old,updater,180)
    if !hwnd
        throw Error("Game Window Timeout：180 秒內沒有找到新 HIHIYong 視窗。")
    activeRecoveryHwnd:=hwnd
    activeRecoveryPid:=WinGetPID("ahk_id " hwnd)
    activeRecoveryCommitted:=false
    recoveryUserPauseLogged:=false
    EventLog(p.name, "STEP", "新 game.exe PID " activeRecoveryPid " / HWND " hwnd)

    ; 找到的遊戲其實已經在遊戲裡（例如視窗標題暫時變了而被誤判為新視窗）：不走登入流程，不點擊、不打字，
    ; 直接做登入後的確認 / 按鍵 / 視窗位置。
    if LoginGuardInWorld(hwnd,p.name,"登入流程") {
        ; 先確認這是這個帳號的遊戲：沒有被別的帳號綁定、角色名稱相符；否則停下來（game.exe 已標成保留，不會被關）
        otherName:=""
        for qi,q in profiles
            if qi!=idx && q.pid && q.pid=activeRecoveryPid
                otherName:=q.name
        charNow:=ReadGameCharName(activeRecoveryPid)
        if otherName!="" || !CharNameCompatible(p,charNow)
            throw Error("找到的遊戲視窗已在遊戲世界中，但不是這個帳號的角色（" (otherName!="" ? "已綁定給 " otherName : "角色「" charNow "」與記住的不同") "）；已停止並保留遊戲，請手動確認。")
        EventLog(p.name,"RECOVERY_ALREADY_IN_GAME","找到的遊戲視窗已在遊戲世界中｜略過登入，直接做登入後確認")
        return RecoverProfileEnterGame(idx,hwnd,90)
    }

    ; v1.3.9.4 ServerReady：game.exe 出現不等於伺服器畫面 Ready。
    ; Loading 階段禁止八點座標；此階段任何 Gate 失敗也必須保留 game.exe。
    EnsureRecoveryFocus(hwnd,p.name)
    activeRecoveryCommitted:=true   ; 暫時保護：Boot Gate 失敗時 Cleanup 不得關 game.exe
    EventLog(p.name, "STEP", "開始 Boot Loading Safe / Screen Ready 登入流程")

    serverTpl:=ScreenTemplatePath("server")
    if LoginMemoryGate(hwnd,"server",p.name,60) {
        ; H-033：記憶體已確認伺服器畫面
    } else if FileExist(serverTpl) {
        if !WaitScreenReady(hwnd,"server",p.name,60)
            throw Error("伺服器畫面尚未 Ready；已禁止執行 server 座標並保留 game.exe。")
    } else {
        EventLog(p.name,"SCREEN_GATE_FALLBACK","缺少 server 畫面樣板｜改用 Boot Loading Safe，不會立即失敗或提前點座標")
        if !WaitBootLoadingSafe(hwnd,p.name,45,10,2)
            throw Error("Boot Loading Safe Timeout；已保留 game.exe，不執行 server 座標。")
    }
    ; Server Ready 後才解除 Boot 階段保護；後續仍沿用既有 Recovery 錯誤處理。
    activeRecoveryCommitted:=false
    EventLog(p.name,"LOGIN_SEQUENCE_START","Server Ready Gate 通過｜開始八點登入座標")
    fastLoginCritical:=true
    EventLog(p.name,"FAST_LOGIN_GUARD_ON","登入關鍵區啟動｜暫停 HP / 假在線 / Network Watch / Web UI 背景刷新；F10 緊急停止保留")
    EventLog(p.name,"FAST_LOGIN_START","第2~6步快速登入模式｜Channel 1.2s / Connect 1.2s / Account 2.0s")
    _t:=A_TickCount
    ClickPoint(hwnd,"server")
    FastTrace(p.name,"01 Server Click",_t)
    recoveryStage[idx]:="伺服器已選擇"

    if LoginMemoryGate(hwnd,"channel",p.name,60) {
        ; 記憶體已確認分流清單
    } else if FileExist(ScreenTemplatePath("channel")) {
        if !WaitScreenReady(hwnd,"channel",p.name,60)
            throw Error("分流畫面尚未 Ready；已禁止執行 channel 座標。")
    } else {
        EventLog(p.name,"FAST_LOGIN","缺少 channel 樣板｜快速登入等待 1.2 秒")
        _t:=A_TickCount
        WaitSeconds(1.2)
        FastTrace(p.name,"02 Channel Wait",_t,"目標 1.2 秒")
    }
    _t:=A_TickCount
    ClickPoint(hwnd,"channel")
    FastTrace(p.name,"02 Channel Click",_t)
    recoveryStage[idx]:="分流已選擇"

    if LoginMemoryGate(hwnd,"connect",p.name,60) {
        ; 記憶體已確認連線按鈕
    } else if FileExist(ScreenTemplatePath("connect")) {
        if !WaitScreenReady(hwnd,"connect",p.name,60)
            throw Error("連線畫面尚未 Ready；已禁止執行 connect 座標。")
    } else {
        EventLog(p.name,"FAST_LOGIN","缺少 connect 樣板｜快速登入等待 1.2 秒")
        _t:=A_TickCount
        WaitSeconds(1.2)
        FastTrace(p.name,"03 Connect Wait",_t,"目標 1.2 秒")
    }
    _t:=A_TickCount
    ClickPoint(hwnd,"connect")
    FastTrace(p.name,"03 Connect Click",_t)
    recoveryStage[idx]:="等待登入畫面"

    ; 帳密畫面 Ready 後才開始輸入；未 Ready 絕不 fallback 等秒數後硬輸入。
    if LoginMemoryGate(hwnd,"account",p.name,60) {
        Sleep 120
    } else if FileExist(ScreenTemplatePath("account")) {
        if !WaitScreenReady(hwnd,"account",p.name,60)
            throw Error("登入畫面尚未 Ready；已禁止帳密輸入。")
        Sleep 120
    } else {
        EventLog(p.name,"FAST_LOGIN","缺少 account 樣板｜快速登入等待 2.0 秒")
        _t:=A_TickCount
        WaitSeconds(2)
        FastTrace(p.name,"04 Account Screen Wait",_t,"目標 2.0 秒")
    }
    ; v1.2.4: 帳密輸入改成獨立、帶等待的安全流程。
    ; 避免 ClickPoint 後焦點尚未真正落在 Edit、或上一個欄位的按鍵仍在處理，
    ; 導致帳號/密碼缺字、串欄或輸入到錯誤位置。
    _t:=A_TickCount
    FillLoginField(hwnd, "account", p.account, "帳號", p.name)
    FastTrace(p.name,"04 Account Input",_t)
    _t:=A_TickCount
    FillLoginField(hwnd, "password", p.password, "密碼", p.name)
    FastTrace(p.name,"05 Password Input",_t)
    _t:=A_TickCount
    WaitSeconds(0.5)
    FastTrace(p.name,"06 Login PreWait",_t,"目標 0.5 秒")
    _t:=A_TickCount
    ActivateGame(hwnd)
    ; v1.3.10.14：Login 前先記錄畫面特徵，供第7步判斷 Login -> 角色畫面是否真的完成轉場。
    _loginBaseline:=GetBootScreenSignature(hwnd)
    ClickPoint(hwnd,"login")
    FastTrace(p.name,"06 Login Click",_t)
    ; FastLoginTrace：第2~6步期間不反覆重建帳號 ListView，避免 GUI 更新拖慢登入。
    RefreshProfileLV()
    if LoginMemoryGate(hwnd,"char",p.name,90) {
        ; 記憶體已確認選角畫面（角色清單已載入）
    } else if FileExist(ScreenTemplatePath("char")) {
        if !WaitScreenReady(hwnd,"char",p.name,60)
            throw Error("角色畫面尚未 Ready；已禁止執行 char 座標。")
    } else {
        EventLog(p.name,"CHAR_READY_GUARD","缺少 char 樣板｜改用 Login 畫面轉場 + 穩定判斷；最短 4 秒 / 最長 15 秒")
        if !WaitStageVisualReady(hwnd,p.name,"角色畫面 Ready",_loginBaseline,4,15,true,2,1200)
            throw Error("角色畫面 Ready 判斷失敗；已保留 game.exe。")
    }
    picked:=LoginPickChar(hwnd,p)
    if !picked {
        ClickPoint(hwnd,"char")
        LoginEnsureSelected(hwnd,p)   ; 選角畫面剛出現時點了常沒反應：用記憶體確認選到了，沒選到再點
    }
    if LoginMemoryGate(hwnd,"startgame",p.name,30) {
        ; 記憶體已確認「開始遊戲」按鈕出現（角色已選好）
    } else if FileExist(ScreenTemplatePath("startgame")) {
        if !WaitScreenReady(hwnd,"startgame",p.name,60)
            throw Error("開始遊戲畫面尚未 Ready；已禁止執行 startgame 座標。")
    } else {
        EventLog(p.name,"STARTGAME_READY_GUARD","缺少 startgame 樣板｜等待角色選取後畫面穩定；最短 1.5 秒 / 最長 6 秒")
        if !WaitStageVisualReady(hwnd,p.name,"開始遊戲 Ready","",1.5,6,false,0,900)
            throw Error("開始遊戲 Ready 判斷失敗；已保留 game.exe。")
    }
    if picked
        LoginConfirmChar(hwnd,p)
    ClickPoint(hwnd,"startgame")
    fastLoginCritical:=false
    EventLog(p.name,"FAST_LOGIN_GUARD_OFF","Start Game 已送出｜恢復背景監控 Timer")
    EventLog(p.name, "STEP", "角色已送出開始遊戲，進入 Loading Safe 等待 HUD")

    ; v1.3.14.0: 有 Game.pdb 位置時改由背景依記憶體判斷角色是否載入完成；
    ; 載入很慢時佇列可以先處理下一個帳號，不再因 90 秒看不到 HUD 就判定失敗。
    if AsyncLoadingAvailable(hwnd) {
        recoveryStage[idx]:="等待進入遊戲（背景）"
        asyncLoading:=true
        return hwnd
    }
    return RecoverProfileEnterGame(idx,hwnd,90)
}

; 開始遊戲之後：確認 HUD → 登入後按鍵 → 位置辨識 → 恢復視窗位置。需要前景操作。
RecoverProfileEnterGame(idx, hwnd, hudTimeoutSec:=90) {
    global profiles,PostKeysEdit,ReturnKeyEdit,ConfEdit,Status,activeRecoveryCommitted,recoveryStage
    p:=profiles[idx]

    ; v1.3.9.1 Loading Safe：按下開始遊戲後，畫面可能長時間停在 Loading。
    ; 從這一刻起禁止失敗清理關閉 game.exe；即使 HUD 尚未出現，也保留視窗供人工確認。
    activeRecoveryCommitted:=true
    recoveryStage[idx]:="等待進入遊戲"
    RefreshProfileLV()
    EventLog(p.name,"LOADING_SAFE","Start Game 已送出；最長等待 " hudTimeoutSec " 秒確認 HUD，期間絕不因 HP=0 關閉 game.exe")

    threshold:=Integer(ConfEdit.Value)
    if threshold<50 || threshold>99
        threshold:=70

    ; visible-screen BitBlt：Recovery 的 HP / 位置判定前必須確認目標 HWND 在最上層。
    EnsureRecoveryFocus(hwnd,p.name)
    Sleep 300

    ; location recognition is forbidden until the in-game HUD is proven.
    ; 不再只取 3 次 HP 就判定失敗；Loading 期間持續等待，HUD 一出現立即通過。
    hudState:=WaitForInGameHUD(hwnd,p,hudTimeoutSec)
    recoveryStage[idx]:="遊戲中"
    EventLog(p.name,"LOGIN_COMMIT","HUD/HP 已確認進入遊戲；後續異常將保留 game.exe")
    if hudState="dead" {
        ; 已進遊戲但剛好死亡：不是登入失敗。交給死亡監控，不關閉 game.exe。
        p.locType:="不確定"
        EventLog(p.name,"INGAME_DEAD","已確認進入遊戲，但 HP 為死亡狀態；交由死亡監控接手")
        RestoreProfileWindowPosition(idx, hwnd)
        Sleep 500
        global hpReadableStatus
        hpReadableStatus[idx]:=IsHpRoiVisible(hwnd) ? "ROI可讀" : "ROI不可讀"
        return hwnd
    }

    ; v1.3.7.6 Fast PostKeys：HUD 已確認 ALIVE 後先保命，再做耗時的位置辨識。
    ; 使用原本 PostKeys 設定，不硬編碼；目前設定為 F5,F6,A。
    post:=Trim(PostKeysEdit.Value)
    if post!="" {
        ActivateGame(hwnd)
        for key in StrSplit(post,",") {
            key:=Trim(key)
            if key!="" {
                ; v1.3.21.0：F6 是開關，已經開著就不按（重試進入遊戲時不會把自動攻擊按掉）。
                if StrUpper(key)="F6" && RecoveryAutoAttackOn(hwnd)
                    continue
                ; H-032：這個鍵是快捷欄的寵物卡時，改由下面依寵物狀態判斷（寵物已經在外面再按會把它收起來）。
                if RecoveryPetKeyHandled(hwnd,key)
                    continue
                SendOneKey(key)
                Sleep 300
            }
        }
        EventLog(p.name,"POST_KEYS_FAST","LOGIN_COMMIT 後立即送出 " post "｜再進行位置辨識")
        AutoAttackVerifyAfterPostKeys(hwnd,p.name,post)
    }

    NormalizeCameraZoom(hwnd), WaitSeconds(1)
    ; H-032：位置以遊戲記憶體為準（在城裡 → 復活點；在怪物地圖 → 正常），讀不到才用畫面辨識。
    town:=RecoveryTownName(hwnd)
    if town!="" {
        decision:="revive"
        EventLog(p.name,"RECOGNITION_MEMORY","記憶體確認角色在 " town "｜使用前點卡（略過畫面辨識）")
    } else if (field:=RecoveryLeftTown(hwnd))!="" {
        decision:="normal"
        EventLog(p.name,"RECOGNITION_MEMORY","記憶體確認角色在怪物地圖（" field "）｜略過畫面辨識")
    } else {
        decision:=ConsensusLocation(hwnd,threshold)
        EventLog(p.name, "RECOGNITION", "讀不到地圖，改用畫面辨識｜首次位置判定=" decision)
    }
    if decision="normal"
        p.locType:="怪物區"
    else if decision="revive"
        p.locType:="復活點"

    if decision="revive" {
        Status.Text:="狀態：" p.name "｜確認復活點，使用前點卡"
        key:=RecoveryUseReturnCard(hwnd,p)
        Status.Text:="狀態：" p.name "｜已使用前點卡 " key
        EnsureRecoveryFocus(hwnd,p.name)
        Sleep 700
        VerifyInGameHUD(hwnd,p,"前點卡 " StrUpper(key) " 後")
        ; 前點卡後：記憶體確認已離開城裡就是怪物區；讀不到才用畫面（不再重新拉視角）。
        if (left:=RecoveryLeftTown(hwnd))!="" {
            EventLog(p.name,"RECOGNITION_MEMORY","記憶體確認已離開城裡（" left "）｜怪物區")
            decision2:="normal"
        } else {
            if (still:=RecoveryTownName(hwnd))!="" {
                EventLog(p.name,"RETURN_CARD_FAIL","前點卡後記憶體確認仍在 " still)
                throw Error("前點卡後記憶體確認仍在 " still "（前點卡沒有生效）。")
            }
            decision2:=ConsensusLocation(hwnd,threshold)
            EventLog(p.name, "RECOGNITION", "前點卡後位置判定=" decision2)
        }
        if decision2!="normal"
            throw Error("前點卡後未確認為正常打怪區。")
        p.locType:="怪物區"
    } else if decision!="normal" {
        ; v1.3.7.5: 已登入但位置 Unknown 仍保留 game.exe，
        ; 但不能提前 return，必須繼續走原本 PostKeys（F5/F6/A）流程。
        p.locType:="不確定"
        EventLog(p.name,"LOCATION_UNKNOWN_SAFE","已確認登入，位置判定不確定；Fast PostKeys 已先執行，保留 game.exe")
    }

    ; PostKeys 已於 LOGIN_COMMIT 後立即送出，這裡不可重複送第二次。

    ; 寵物放在最後：前點卡傳送換地圖會把寵物收起來，所以位置處理完（已在怪物區）才確認並開啟。
    try RecoveryEnsurePet(hwnd,p)

    ; 所有需要前景操作的登入/辨識/按鍵完成後，再把新視窗放回此 Profile 的固定位置。
    RestoreProfileWindowPosition(idx, hwnd)
    Sleep 500
    global hpReadableStatus
    hpReadableStatus[idx]:=IsHpRoiVisible(hwnd) ? "ROI可讀" : "ROI不可讀"
    EventLog(p.name, "POST_KEYS", "Fast PostKeys 已送出 " post "｜位置辨識完成並恢復視窗位置｜MemoryHP=" MemoryHPDisplayStatus(p) "｜畫面ROI僅登入/備援用途")
    return hwnd
}





WaitForInGameHUD(hwnd, p, timeoutSec:=90) {
    global abortRequested
    start:=A_TickCount
    lastLog:=0
    memSince:=0
    while (A_TickCount-start < timeoutSec*1000) {
        if abortRequested
            throw Error("使用者停止。")
        if !hwnd || !WinExist("ahk_id " hwnd)
            throw Error("LOADING_WINDOW_LOST｜Start Game 後遊戲視窗已消失。")

        alive:=0
        deadHud:=0
        ratios:=""
        Loop 2 {
            rr:=HPGetRedRatio(hwnd)
            ratios.=(ratios="" ? "" : ",") Round(rr*100,1) "%"
            if rr>=0.08 && rr<=0.45
                alive+=1
            else if rr>=0.002 && rr<=0.03
                deadHud+=1
            if A_Index<2
                Sleep 250
        }
        if alive>=2 {
            EventLog(p.name,"INGAME_GATE_OK","Loading Safe｜HUD=ALIVE｜HP RedRatio=" ratios)
            return "alive"
        }
        if deadHud>=2 {
            EventLog(p.name,"INGAME_GATE_OK","Loading Safe｜HUD=DEAD｜HP RedRatio=" ratios)
            return "dead"
        }

        ; v1.3.21.0：畫面被擋住 / 截不到時，記憶體確認角色在遊戲世界裡 10 秒就放行
        ; （2026-10-23 小柯基、欸等欸等了 60 秒看不到血條就判定失敗，停在學院）。
        mem:=RecoveryMemoryGate(hwnd)
        if mem="" {
            memSince:=0
        } else if !memSince {
            memSince:=A_TickCount
        } else if A_TickCount-memSince>=10000 {
            EventLog(p.name,"INGAME_GATE_MEMORY","畫面看不到血條（HP RedRatio=" ratios "），但記憶體確認角色已在遊戲中｜" mem)
            return mem
        }

        ; Loading / 黑畫面常見為 0%。這不是登入失敗，只代表 HUD 尚未出現。
        if (A_TickCount-lastLog >= 5000) {
            remain:=Max(0,Ceil((timeoutSec*1000-(A_TickCount-start))/1000))
            EventLog(p.name,"LOADING_WAIT","HUD 尚未出現｜HP RedRatio=" ratios "｜剩餘 " remain " 秒")
            lastLog:=A_TickCount
        }
        Sleep 500
    }
    EventLog(p.name,"LOADING_TIMEOUT","等待 " timeoutSec " 秒仍未確認 HUD；保留 game.exe，不自動重啟")
    throw Error("LOADING_TIMEOUT｜等待遊戲 HUD 超時；已保留 game.exe 供人工確認。")
}

VerifyInGameHUD(hwnd, p, stage:="") {
    ; Cross-check the calibrated HP ROI:
    ; alive HUD ~=30%, dead HUD ~=0.44%; server/login screen observed ~=0%.
    ; A dead character is still "successfully in game" and must NOT become LOGIN_NOT_COMPLETED.
    if !hwnd || !WinExist("ahk_id " hwnd)
        throw Error("LOGIN_NOT_COMPLETED｜遊戲視窗不存在。")

    alive:=0
    deadHud:=0
    ratios:=""
    Loop 3 {
        rr:=HPGetRedRatio(hwnd)
        ratios.=(ratios="" ? "" : ",") Round(rr*100,1) "%"
        if rr>=0.08 && rr<=0.45
            alive+=1
        else if rr>=0.002 && rr<=0.03
            deadHud+=1
        if A_Index<3
            Sleep 350
    }

    if alive>=2 {
        EventLog(p.name,"INGAME_GATE_OK",(stage!="" ? stage "｜" : "") "HUD=ALIVE｜HP RedRatio=" ratios)
        return "alive"
    }
    if deadHud>=2 {
        EventLog(p.name,"INGAME_GATE_OK",(stage!="" ? stage "｜" : "") "HUD=DEAD｜HP RedRatio=" ratios)
        return "dead"
    }

    detail:=(stage!="" ? stage "｜" : "") "未找到可信遊戲 HUD｜HP RedRatio=" ratios
    if (mem:=RecoveryMemoryGate(hwnd))!="" {
        EventLog(p.name,"INGAME_GATE_MEMORY",detail "｜記憶體確認角色在遊戲中｜" mem)
        return mem
    }
    EventLog(p.name,"LOGIN_NOT_COMPLETED",detail)
    throw Error("LOGIN_NOT_COMPLETED｜" detail)
}

ConsensusLocation(hwnd, threshold := 70) {
    global abortRequested, Status
    reviveVotes := 0
    normalVotes := 0
    unknownVotes := 0
    firstNormalConf := 0

    Loop 5 {
        if abortRequested
            throw Error("使用者停止。")

        n := A_Index
        f := ExtractRecognitionFeatures(hwnd)
        r := JudgeRecognitionFeature(f.redratio)
        valid := (r.kind != "unknown" && r.conf >= threshold)

        if (n = 1 && valid && r.kind = "normal")
            firstNormalConf := r.conf

        if valid {
            if (r.kind = "revive")
                reviveVotes += 1
            else if (r.kind = "normal")
                normalVotes += 1
        } else {
            unknownVotes += 1
        }

        Status.Text := "狀態：位置判定 " n "/5｜" DecisionName(r.kind)
            . " " r.conf "%｜票數 復活 " reviveVotes " / 正常 " normalVotes
            . " / 無效 " unknownVotes

        ; v0.7.5.4: 怪物區優先快速保命。
        ; 單次 >=90% 直接通過；否則前兩次都為有效 normal 即通過。
        if (n = 1 && valid && r.kind = "normal" && r.conf >= 90) {
            Status.Text := "狀態：高信心快速確認正常區｜1 次通過"
            return "normal"
        }
        if (n = 2 && normalVotes = 2) {
            Status.Text := "狀態：快速確認正常打怪區｜2 次通過"
            return "normal"
        }

        ; 復活點維持保守 4/5；其餘正常結果最多看到第 5 次。
        if (reviveVotes >= 4) {
            Status.Text := "狀態：位置確認｜復活點 4/5 多數決通過"
            return "revive"
        }
        if (normalVotes >= 4) {
            Status.Text := "狀態：位置確認｜正常打怪區 4/5 多數決通過"
            return "normal"
        }

        if (n < 5)
            Sleep 400
    }
    return "unknown"
}

QuickHealthCheck(hwnd, threshold := 70) {
    global abortRequested, Status
    if threshold < 50 || threshold > 99
        threshold := 70
    revive := 0
    normal := 0
    Loop 3 {
        if abortRequested
            throw Error("使用者停止。")
        if !WinExist("ahk_id " hwnd)
            throw Error("健康確認時遊戲視窗已消失。")
        f := ExtractRecognitionFeatures(hwnd)
        r := JudgeRecognitionFeature(f.redratio)
        if (r.kind = "revive" && r.conf >= threshold)
            revive += 1
        else if (r.kind = "normal" && r.conf >= threshold)
            normal += 1
        Status.Text := "狀態：Recovery 健康確認 " A_Index "/3｜" DecisionName(r.kind) " " r.conf "%"
        if A_Index < 3
            Sleep 400
    }
    ; 只有 3 次都明確為復活點才判失敗，避免正常區短暫沒有紅色特徵造成誤重登。
    if revive = 3
        return "revive"
    if normal >= 2
        return "normal"
    return "uncertain"
}

JsonEscape(text) {
    text := StrReplace(text, "\", "\\")
    text := StrReplace(text, '"', '\"')
    text := StrReplace(text, "`r", "")
    text := StrReplace(text, "`n", "\n")
    text := StrReplace(text, "`t", "\t")
    return text
}

; H-006: 安靜時段內的非緊急通知先存檔（force=true 不攔；圖片 SendDiscordImage 不攔）。
QuietHoldMessage(message, force := false) {
    global DiscordWebhookEdit,QuietEnableCB,QuietStartEdit,QuietEndEdit
    try
        return Quiet_TryHold(QUIET_QUEUE_FILE,QuietEnableCB.Value,QuietStartEdit.Value,QuietEndEdit.Value
            ,message,force,DiscordWebhookEdit.Value,A_Hour*60+A_Min)
    catch
        return false
}

; H-006: 時段結束後把累積的通知合併送出（啟動時與每 60 秒檢查）。
QuietFlushTick() {
    global DiscordEnableCB,QuietEnableCB,QuietStartEdit,QuietEndEdit
    try {
        if !DiscordEnableCB.Value
            return
        if !FileExist(QUIET_QUEUE_FILE)
            return
        ; 開關被取消勾選時（佇列非空）不受時段限制，直接送出。
        n:=Quiet_Flush(QUIET_QUEUE_FILE,(m)=>SendDiscordMessage(m,true),A_Hour*60+A_Min
            ,Quiet_ParseTime(QuietStartEdit.Value,60),Quiet_ParseTime(QuietEndEdit.Value,480),QuietEnableCB.Value)
        if n
            EventLog("","QUIET_FLUSH","已合併送出 " n " 則安靜時段通知")
    }
}

SendDiscordMessage(message, force := false) {
    global DiscordEnableCB,DiscordWebhookEdit
    if (!force && !DiscordEnableCB.Value)
        return false
    if QuietHoldMessage(message,force)
        return true
    url := Trim(DiscordWebhookEdit.Value)
    if url = ""
        return false
    if !RegExMatch(url, "i)^https://(canary\.|ptb\.)?discord(app)?\.com/api/webhooks/")
        throw Error("Discord Webhook URL 格式不正確。")
    payload := '{"content":"' JsonEscape(message) '","username":"HIHIYONG Recovery"}'
    SendDiscordAsync(url,payload)
    return true
}

SendDiscordAsync(url,payload) {
    global pendingHttp
    req:=ComObject("WinHttp.WinHttpRequest.5.1")
    req.SetTimeouts(3000,3000,3000,5000)
    req.Open("POST",url,true)
    req.SetRequestHeader("Content-Type","application/json; charset=utf-8")
    req.Send(payload)
    pendingHttp.Push({req:req,tick:A_TickCount})
    SetTimer CleanupDiscordAsync,-1000
}

CleanupDiscordAsync() {
    global pendingHttp
    keep:=[]
    for item in pendingHttp {
        done:=false
        try done:=(item.req.ReadyState=4)
        catch
            done:=true
        if !done && A_TickCount-item.tick<15000
            keep.Push(item)
    }
    pendingHttp:=keep
    if pendingHttp.Length
        SetTimer CleanupDiscordAsync,-1000
}

FriendlyFailure(reason) {
    if InStr(reason,"前點卡後未確認")
        return {title:"返回野怪區失敗", text:"已使用前點卡，但仍無法確認角色回到正常怪區。"}
    if InStr(reason,"位置判定不確定")
        return {title:"區域判定異常", text:"無法可靠確認目前位於正常怪區或復活點。"}
    if InStr(reason,"Launcher") || InStr(reason,"Updater")
        return {title:"遊戲啟動失敗", text:"Launcher / Updater 未能正常完成啟動。"}
    if InStr(reason,"Game Window") || InStr(reason,"遊戲視窗")
        return {title:"遊戲重啟失敗", text:"等待新的 HIHIYong 遊戲視窗逾時或視窗未正常建立。"}
    if InStr(reason,"登入")
        return {title:"帳號登入失敗", text:"自動登入流程未能正常完成。"}
    if InStr(reason,"健康確認")
        return {title:"恢復後狀態異常", text:"Recovery 完成後健康確認未通過。"}
    return {title:"自動恢復失敗", text:reason}
}

SendDiscordManualAlert(profileName, reason) {
    global DiscordEnableCB,DiscordPcEdit
    if !DiscordEnableCB.Value
        return
    pc := Trim(DiscordPcEdit.Value)
    if pc = ""
        pc := A_ComputerName
    friendly := FriendlyFailure(reason)
    msg := "🔴 HIHIYONG｜" friendly.title
        . "`n電腦：" pc
        . "`n帳號：" profileName
        . "`n時間：" FormatTime(, "yyyy-MM-dd HH:mm:ss")
        . "`n說明：" friendly.text
        . "`n狀態：已停止此帳號自動恢復"
        . "`n請人工登入確認；其他帳號繼續運作。"
    try SendDiscordMessage(msg)
    catch as e
        EventLog(profileName, "DISCORD_FAIL", e.Message)
}

TestDiscordWebhook(*) {
    global DiscordWebhookEdit,DiscordPcEdit,Status
    if Trim(DiscordWebhookEdit.Value) = "" {
        MsgBox "請先貼上 Discord Webhook URL。", APP_TITLE
        return
    }
    pc := Trim(DiscordPcEdit.Value)
    if pc = ""
        pc := A_ComputerName
    try {
        SendDiscordMessage("🟢 HIHIYONG Recovery 測試通知`n電腦：" pc
            . "`n時間：" FormatTime(, "yyyy-MM-dd HH:mm:ss")
            . "`nWebhook 連線正常。", true)
        Status.Text := "狀態：Discord 測試通知已送出"
        MsgBox "測試通知已送出，請查看 Discord 頻道。", APP_TITLE
    } catch as e {
        Status.Text := "狀態：Discord 測試失敗：" e.Message
        MsgBox "Discord 測試失敗：`n" e.Message, APP_TITLE
    }
}

GetDailyLogPath() {
    dir := A_ScriptDir "\Logs"
    if !DirExist(dir)
        DirCreate dir
    return dir "\HIHIYONG_" FormatTime(, "yyyy-MM-dd") ".log"
}

EventLog(profileName, eventType, message := "") {
    try {
        line := FormatTime(, "yyyy-MM-dd HH:mm:ss") " | " profileName " | " eventType
        if message != ""
            line .= " | " StrReplace(StrReplace(message, "`r", " "), "`n", " ")
        FileAppend line "`r`n", GetDailyLogPath(), "UTF-8"
    }
}

CleanupOldLogs(days := 30) {
    dir := A_ScriptDir "\Logs"
    if !DirExist(dir)
        return
    Loop Files dir "\HIHIYONG_*.log", "F" {
        if DateDiff(A_Now, A_LoopFileTimeModified, "Days") > days
            try FileDelete A_LoopFileFullPath
    }
}


ShowLogViewer(*) {
    global profiles
    lg := Gui("+Resize","HIHIYONG 執行紀錄")
    lg.SetFont("s9","Microsoft JhengHei")
    lg.AddText("x12 y12 w50","帳號")
    names := ["全部"]
    for p in profiles
        names.Push(p.name)
    acct := lg.AddDropDownList("x65 y8 w145 Choose1",names)
    abnormal := lg.AddCheckBox("x222 y10 w90","只看異常")
    refresh := lg.AddButton("x320 y7 w78 h28","重新整理")
    folder := lg.AddButton("x408 y7 w110 h28","開啟 Log 資料夾")
    clear := lg.AddButton("x528 y7 w88 h28","清除今日")
    list := lg.AddListView("x12 y45 w930 h455 Grid",["時間","帳號","類型","結果 / 說明"])
    list.ModifyCol(1,145), list.ModifyCol(2,115), list.ModifyCol(3,150), list.ModifyCol(4,500)

    ReloadLog(*) {
        list.Delete()
        path := GetDailyLogPath()
        if !FileExist(path)
            return
        filterAcct := acct.Text
        onlyBad := abnormal.Value
        txt := FileRead(path,"UTF-8")
        for line in StrSplit(txt,"`n","`r") {
            if Trim(line) = ""
                continue
            parts := StrSplit(line," | ")
            if parts.Length < 3
                continue
            tm := parts[1], who := parts[2], typ := parts[3]
            msg := ""
            if parts.Length >= 4 {
                Loop parts.Length - 3 {
                    n := A_Index + 3
                    msg .= (msg = "" ? "" : " | ") parts[n]
                }
            }
            if (filterAcct != "全部" && who != filterAcct)
                continue
            if onlyBad {
                isBad := InStr(typ,"FAIL") || InStr(typ,"MANUAL") || InStr(typ,"CRASH") || InStr(typ,"LOST")
                if !isBad
                    continue
            }
            list.Add("",tm,who,typ,msg)
        }
    }

    OpenLogFolder(*) {
        dir := A_ScriptDir "\Logs"
        if !DirExist(dir)
            DirCreate dir
        Run dir
    }

    ClearToday(*) {
        path := GetDailyLogPath()
        if FileExist(path) {
            ans := MsgBox("確定清除今天的執行紀錄？","HIHIYONG","YesNo Icon!")
            if ans = "Yes"
                FileDelete path
        }
        ReloadLog()
    }

    refresh.OnEvent("Click",ReloadLog)
    acct.OnEvent("Change",ReloadLog)
    abnormal.OnEvent("Click",ReloadLog)
    folder.OnEvent("Click",OpenLogFolder)
    clear.OnEvent("Click",ClearToday)
    ReloadLog()
    lg.Show("w955 h520")
}

NormalizeCameraZoom(hwnd) {
    global abortRequested, Status, ZoomCountEdit
    if abortRequested
        throw Error("使用者停止。")
    ActivateGame(hwnd)
    Sleep 300

    ; 將游標放到遊戲 Client 中央，避免滾輪落在其他程式。
    WinGetClientPos &x, &y, &w, &h, "ahk_id " hwnd
    if (w <= 0 || h <= 0)
        throw Error("無法取得遊戲 Client 尺寸。")
    DllCall("SetCursorPos", "Int", x + w//2, "Int", y + h//2)
    Sleep 200

    ; HIHIYong 實測：WheelUp 才是把第三人稱鏡頭拉遠。
    ; 多送幾格沒有副作用：到達最大距離後遊戲會停在上限。
    zoomCount := Integer(ZoomCountEdit.Value)
    if (zoomCount < 1 || zoomCount > 30)
        zoomCount := 8
    Status.Text := "狀態：正在將視角拉遠｜WheelUp × " zoomCount
    Loop zoomCount {
        if abortRequested
            throw Error("使用者停止。")
        SendEvent "{WheelUp}"
        Sleep 80
    }
    Sleep 500
}


JudgeRecognitionFeature(redratio) {
    ; 使用 v0.9 實測樣本的安全帶：
    ; <=1.0% 偏復活點；>=1.3% 偏正常打怪區；中間不硬猜。
    if (redratio <= 0.010) {
        conf := Min(99, Round(72 + (0.010-redratio)/0.010*27))
        return {kind:"revive", conf:conf}
    }
    if (redratio >= 0.013) {
        conf := Min(99, Round(72 + (redratio-0.013)/0.037*27))
        return {kind:"normal", conf:conf}
    }
    return {kind:"unknown", conf:0}
}

DecisionName(kind) {
    if kind = "revive"
        return "復活點"
    if kind = "normal"
        return "正常打怪區"
    return "無法判斷"
}

ExtractRecognitionFeatures(hwnd) {
    global abortRequested
    if abortRequested
        throw Error("使用者停止。")
    if !WinExist("ahk_id " hwnd)
        throw Error("遊戲視窗不存在。")

    if (WinGetMinMax("ahk_id " hwnd) = -1) {
        WinRestore "ahk_id " hwnd
        Sleep 250
    }
    ActivateGame(hwnd)
    Sleep 500

    WinGetClientPos &sx, &sy, &w, &h, "ahk_id " hwnd
    if (w < 900 || h < 700)
        throw Error("遊戲 Client 尺寸異常。")

    hdcScreen := DllCall("GetDC", "Ptr", 0, "Ptr")
    hdcMem := DllCall("CreateCompatibleDC", "Ptr", hdcScreen, "Ptr")
    hbm := DllCall("CreateCompatibleBitmap", "Ptr", hdcScreen, "Int", w, "Int", h, "Ptr")
    old := DllCall("SelectObject", "Ptr", hdcMem, "Ptr", hbm, "Ptr")

    ok := DllCall("BitBlt", "Ptr", hdcMem, "Int", 0, "Int", 0, "Int", w, "Int", h,
        "Ptr", hdcScreen, "Int", sx, "Int", sy, "UInt", 0x40CC0020)

    if !ok {
        DllCall("SelectObject", "Ptr", hdcMem, "Ptr", old)
        DllCall("DeleteObject", "Ptr", hbm), DllCall("DeleteDC", "Ptr", hdcMem)
        DllCall("ReleaseDC", "Ptr", 0, "Ptr", hdcScreen)
        throw Error("遊戲畫面擷取失敗。")
    }

    stride := w * 4
    bits := Buffer(stride*h, 0)
    bmi := Buffer(40, 0)
    NumPut("UInt",40,bmi,0), NumPut("Int",w,bmi,4), NumPut("Int",-h,bmi,8)
    NumPut("UShort",1,bmi,12), NumPut("UShort",32,bmi,14)

    got := DllCall("GetDIBits","Ptr",hdcMem,"Ptr",hbm,"UInt",0,"UInt",h,
        "Ptr",bits.Ptr,"Ptr",bmi.Ptr,"UInt",0)

    DllCall("SelectObject","Ptr",hdcMem,"Ptr",old)
    DllCall("DeleteObject","Ptr",hbm), DllCall("DeleteDC","Ptr",hdcMem)
    DllCall("ReleaseDC","Ptr",0,"Ptr",hdcScreen)
    if !got
        throw Error("遊戲畫面讀取失敗。")

    x1:=Round(w*0.176), x2:=Round(w*0.830)
    y1:=Round(h*0.156), y2:=Round(h*0.807)
    red:=0, count:=0, step:=5
    py:=y1
    while py<=y2 {
        px:=x1
        while px<=x2 {
            off:=py*stride+px*4
            b:=NumGet(bits,off,"UChar"), g:=NumGet(bits,off+1,"UChar"), r:=NumGet(bits,off+2,"UChar")
            if (r>130 && r>g*1.35 && r>b*1.25)
                red+=1
            count+=1, px+=step
        }
        py+=step
    }
    if !count
        throw Error("沒有取得有效辨識像素。")
    return {redratio:red/count, w:w, h:h}
}


SnapshotGamePids() {
    old := Map()
    ; 標題不論：視窗標題暫時改變（對話框、更新中）的既有遊戲程序也要算「舊的」，
    ; 否則標題改回來後會被當成這次新開的遊戲，在已經登入的遊戲上跑登入流程。
    for hwnd in WinGetList("ahk_exe game.exe") {
        try {
            pid := WinGetPID("ahk_id " hwnd)
            old[String(pid)] := true
        }
    }
    return old
}

ProfileGameAlive(p) {
    global GAME_TITLE
    if (!p.pid || !p.hwnd)
        return false
    if !WinExist("ahk_id " p.hwnd)
        return false
    try {
        if WinGetPID("ahk_id " p.hwnd) != p.pid
            return false
        if WinGetProcessName("ahk_id " p.hwnd) != "game.exe"
            return false
        if WinGetTitle("ahk_id " p.hwnd) != GAME_TITLE
            return false
    } catch {
        return false
    }
    return true
}

FindNewGameByPid(oldPids) {
    global GAME_TITLE
    for hwnd in WinGetList("ahk_exe game.exe") {
        try {
            if WinGetTitle("ahk_id " hwnd) != GAME_TITLE
                continue
            pid := WinGetPID("ahk_id " hwnd)
            if !oldPids.Has(String(pid))
                return {hwnd:hwnd, pid:pid}
        }
    }
    return 0
}

WaitGameWithRepeatedEnter(oldPids, updaterHwnd, timeoutSec := 180) {
    global abortRequested, Status
    start := A_TickCount
    nextEnter := 0
    while (A_TickCount - start < timeoutSec * 1000) {
        if abortRequested
            throw Error("使用者停止測試。")

        found := FindNewGameByPid(oldPids)
        if found
            return found.hwnd

        if (A_TickCount >= nextEnter) {
            if WinExist("ahk_id " updaterHwnd) {
                try WinActivate "ahk_id " updaterHwnd
                Sleep 100
                SendEvent "{Enter}"
                elapsed := Floor((A_TickCount - start) / 1000)
                Status.Text := "狀態：等待新 game.exe PID｜已等待 " elapsed " 秒｜每 3 秒送 Enter"
            }
            nextEnter := A_TickCount + 3000
        }
        Sleep 200
    }
    return 0
}

WaitForNewGameWindow(oldPids, timeoutSec) {
    global abortRequested
    start := A_TickCount
    while (A_TickCount-start < timeoutSec*1000) {
        if abortRequested
            throw Error("使用者停止測試。")
        found := FindNewGameByPid(oldPids)
        if found
            return found.hwnd
        Sleep 250
    }
    return 0
}

EnsureRecoveryFocus(hwnd, profileName := "") {
    global abortRequested,Status
    if abortRequested
        throw Error("使用者停止測試。")
    if !hwnd || !WinExist("ahk_id " hwnd)
        throw Error("遊戲視窗已消失。")

    ; v1.3.9.4: 移除 User Override / A_TimeIdlePhysical。
    ; Recovery 執行期間不再因滑鼠、鍵盤或 Alt+Tab 暫停；需要接手時一律按 F10。
    if WinActive("ahk_id " hwnd)
        return true

    Loop 20 {
        if abortRequested
            throw Error("F10 已終止 Recovery。")
        WinActivate "ahk_id " hwnd
        if WinWaitActive("ahk_id " hwnd,,0.12)
            return true
        Sleep 40
    }
    ; v1.3.21.0：其他程式（凌晨跳出的命令視窗、Zoom、Chrome…）搶走前景時，3 秒內常切不回來
    ; （2026-10-23 欸等、抽因此沒按到 F6）。改為每 5 秒再試，最多 RECOVERY_FOCUS_RETRY_SEC 秒。
    global RECOVERY_FOCUS_RETRY_SEC
    who:="?"
    try who:=WinGetProcessName("A")
    EventLog(profileName!="" ? profileName : "GLOBAL","FOCUS_RETRY","遊戲視窗被其他程式擋住（目前前景：" who "）｜每 5 秒重試，最多 " RECOVERY_FOCUS_RETRY_SEC " 秒")
    start:=A_TickCount
    while A_TickCount-start<RECOVERY_FOCUS_RETRY_SEC*1000 {
        if abortRequested
            throw Error("F10 已終止 Recovery。")
        if !WinExist("ahk_id " hwnd)
            throw Error("遊戲視窗已消失。")
        try DllCall("SwitchToThisWindow","Ptr",hwnd,"Int",1)
        WinActivate "ahk_id " hwnd
        if WinWaitActive("ahk_id " hwnd,,1) {
            EventLog(profileName!="" ? profileName : "GLOBAL","FOCUS_RETRY_OK","已切回遊戲視窗（等待 " Round((A_TickCount-start)/1000) " 秒）")
            return true
        }
        Sleep 4000
    }
    throw Error("無法將 Recovery 遊戲視窗切到最上層。")
}

ActivateGame(hwnd) {
    global profiles,activeRecoveryHwnd
    name:=""
    if (activeRecoveryHwnd=hwnd) {
        for p in profiles {
            if p.hwnd=hwnd {
                name:=p.name
                break
            }
        }
    }
    return EnsureRecoveryFocus(hwnd,name)
}

ClickPoint(hwnd,key,ov:="") {
    global points, abortRequested, profiles, activeRecoveryHwnd, recoveryStage
    if abortRequested
        throw Error("使用者停止測試。")
    if hwnd && LoginGuardInWorld(hwnd,"Recovery","點擊登入座標 " key)
        throw Error("角色已經在遊戲世界中，已停止登入點擊（不盲點）：" key)
    ; H-033：能從遊戲記憶體找到這個登入步驟的位置就直接用（ov = 呼叫端指定的位置，例如選角的第 N 隻）；找不到才用預設點。
    mem:=IsObject(ov) ? ov : LoginUiClickPoint(hwnd,key)
    if !IsObject(mem) && !points.Has(key)
        throw Error("缺少登入座標：" key)

    ; 每一點都重新鎖定本輪 Recovery HWND，絕不沿用其他遊戲視窗的位置。
    EnsureRecoveryFocus(hwnd)
    if !WinExist("ahk_id " hwnd)
        throw Error("遊戲視窗已消失。")

    WinGetClientPos &x,&y,&w,&h,"ahk_id " hwnd
    if w<=0 || h<=0
        throw Error("無法取得 Recovery 遊戲 Client 尺寸。")

    if IsObject(mem)
        p:={nx:mem.x/1024,ny:mem.y/768,rx:mem.x,ry:mem.y,cw:1024,ch:768}
    else
        p:=points[key]
    if p.nx<0 || p.nx>1 || p.ny<0 || p.ny>1
        throw Error("登入座標超出遊戲視窗：" key "｜請重新校正 8 點座標。")

    ; v1.3.7.7 Coord Lock：
    ; 校正尺寸與目前 Client 幾乎相同時，使用 Client 內固定 RX/RY。
    ; 只有尺寸真的不同時才退回 NX/NY 比例座標。
    usePixel:=false
    try {
        if (p.rx!="" && p.ry!="" && p.cw!="" && p.ch!="")
            usePixel := Abs(w-p.cw)<=4 && Abs(h-p.ch)<=4
    }
    if usePixel {
        px:=Round(x+p.rx)
        py:=Round(y+p.ry)
        mode:="PIXEL"
    } else {
        ; 尺寸不同才做比例換算；Screen Ready 絕不參與座標計算。
        px:=Round(x+p.nx*w)
        py:=Round(y+p.ny*h)
        mode:="RATIO"
    }

    ; v1.3.9.1：每次點擊留下完整座標證據，方便直接定位跨電腦 / DPI / HWND 問題。
    traceName:="Recovery"
    try {
        ; Recovery 中優先用目前 HWND 真正綁定的 Profile；避免舊 HWND 尚未回寫時誤記成其他帳號。
        for rp in profiles {
            if rp.hwnd=hwnd {
                traceName:=rp.name
                break
            }
        }
        if (traceName="Recovery" && activeRecoveryHwnd=hwnd) {
            ; 無現成綁定時，由目前 Recovery 狀態名稱補正；只影響 Log，不影響點擊。
            for i,rp in profiles {
                if recoveryStage.Has(i) && recoveryStage[i]!="" && InStr(rp.state,"恢復") {
                    traceName:=rp.name
                    break
                }
            }
        }
    }
    EventLog(traceName,"CLICK_TRACE",key "｜HWND=" hwnd "｜Client=" x "," y " " w "x" h "｜Mode=" mode (IsObject(mem) ? "（記憶體）" : "") "｜Target=" px "," py)

    DllCall("SetCursorPos","Int",px,"Int",py)
    Sleep 80

    ; 游標移動後再次確認 HWND 與 Client 原點。
    ; 若這 80ms 內視窗被移動，重新計算一次，避免點到舊螢幕座標。
    EnsureRecoveryFocus(hwnd)
    WinGetClientPos &x2,&y2,&w2,&h2,"ahk_id " hwnd
    if (x2!=x || y2!=y || w2!=w || h2!=h) {
        if usePixel && Abs(w2-p.cw)<=4 && Abs(h2-p.ch)<=4 {
            px:=Round(x2+p.rx)
            py:=Round(y2+p.ry)
        } else {
            px:=Round(x2+p.nx*w2)
            py:=Round(y2+p.ny*h2)
            mode:="RATIO"
        }
        DllCall("SetCursorPos","Int",px,"Int",py)
        Sleep 60
    }

    ; 最後一次前景驗證後才真正 MouseDown/Up。
    EnsureRecoveryFocus(hwnd)
    DllCall("mouse_event","UInt",0x0002,"UInt",0,"UInt",0,"UInt",0,"UPtr",0)
    Sleep 80
    DllCall("mouse_event","UInt",0x0004,"UInt",0,"UInt",0,"UInt",0,"UPtr",0)
}

GetWindowDpiSafe(hwnd) {
    try {
        dpi := DllCall("User32.dll\GetDpiForWindow","Ptr",hwnd,"UInt")
        return dpi>0 ? dpi : 96
    } catch {
        return 96
    }
}

GetCoordTargetInfo(hwnd:=0) {
    global GAME_TITLE
    if !hwnd || !WinExist("ahk_id " hwnd) {
        active:=WinExist("A")
        if active && WinExist(GAME_TITLE " ahk_id " active)
            hwnd:=active
        else {
            list:=WinGetList(GAME_TITLE)
            if list.Length
                hwnd:=list[1]
        }
    }
    if !hwnd || !WinExist("ahk_id " hwnd)
        return {valid:false, hwnd:0, x:0, y:0, w:0, h:0, dpi:96}
    WinGetClientPos &x,&y,&w,&h,"ahk_id " hwnd
    return {valid:true, hwnd:hwnd, x:x, y:y, w:w, h:h, dpi:GetWindowDpiSafe(hwnd)}
}

TestLoginCoordinates(*) {
    global points,pointKeys,pointNames,setupMode,setupHwnd,abortRequested,coordDiagnosticText,APP_TITLE
    if setupMode {
        MsgBox "目前正在設定 8 點座標，請先完成或取消設定後再測試。", APP_TITLE
        return
    }
    for k in pointKeys {
        if !points.Has(k) {
            MsgBox "8 點座標尚未完整設定，請先完成座標校正。", APP_TITLE
            return
        }
    }

    info:=GetCoordTargetInfo(setupHwnd)
    if !info.valid {
        MsgBox "找不到 HIHIYong 遊戲視窗，無法測試座標。", APP_TITLE
        return
    }

    coordDiagnosticText := "測試開始｜Client " info.x "," info.y " " info.w "x" info.h
        . "｜DPI " info.dpi " (" Round(info.dpi/96*100) "%)"
    AddRecentEvent(coordDiagnosticText)

    ; Diagnostic only: move cursor to each saved point. NEVER click.
    Loop pointKeys.Length {
        if abortRequested
            break
        if !WinExist("ahk_id " info.hwnd) {
            coordDiagnosticText := "測試中止：原遊戲視窗已消失"
            AddRecentEvent(coordDiagnosticText)
            return
        }
        WinGetClientPos &x,&y,&w,&h,"ahk_id " info.hwnd
        k:=pointKeys[A_Index]
        p:=points[k]
        if p.nx<0 || p.nx>1 || p.ny<0 || p.ny>1 {
            coordDiagnosticText := "測試失敗：" pointNames[A_Index] " 的 NX/NY 超出 0~1"
            AddRecentEvent(coordDiagnosticText)
            MsgBox coordDiagnosticText, APP_TITLE
            return
        }
        px:=Round(x+p.nx*w)
        py:=Round(y+p.ny*h)
        coordDiagnosticText := "測試 " A_Index "/8 " pointNames[A_Index]
            . "｜Client " w "x" h
            . "｜NX/NY " Round(p.nx,4) "," Round(p.ny,4)
            . "｜Cursor " px "," py
        AddRecentEvent(coordDiagnosticText)
        DllCall("SetCursorPos","Int",px,"Int",py)
        Sleep 1400
    }
    if !abortRequested {
        coordDiagnosticText := "8 點安全測試完成｜只移動滑鼠，未執行任何點擊"
        AddRecentEvent(coordDiagnosticText)
    }
}


WaitSeconds(sec) {
    global abortRequested
    Loop sec*10 {
        if abortRequested
            throw Error("使用者停止測試。")
        Sleep 100
    }
}

SendOneKey(key) {
    global abortRequested
    if abortRequested
        throw Error("使用者停止測試。")
    if RegExMatch(key, "i)^F([1-9]|1[0-2])$")
        SendEvent "{" StrUpper(key) "}"
    else if (StrLower(key) = "space")
        SendEvent "{Space}"
    else if (StrLower(key) = "enter")
        SendEvent "{Enter}"
    else if (StrLower(key) = "tab")
        SendEvent "{Tab}"
    else if StrLen(key) = 1
        SendEvent key
    else
        SendEvent "{" key "}"
}



StartSetup(*) {
    global setupMode, setupIndex, setupHwnd, setupTemp, Status, CoordStatus, GAME_TITLE
    if setupMode {
        MsgBox "目前已在設定座標。將滑鼠移到下一個指定位置後按 F7。", APP_TITLE
        return
    }

    hwnds := WinGetList(GAME_TITLE)
    if hwnds.Length = 0 {
        MsgBox "請先開啟一個 HIHIYong 遊戲視窗，停在任一登入相關畫面後再開始設定。`n`n設定過程可隨登入流程切換畫面，F7 會一直以同一個遊戲視窗為基準記錄。", APP_TITLE
        return
    }

    ; 優先使用目前作用中的 HIHIYong；否則取第一個
    active := WinExist("A")
    found := false
    for h in hwnds {
        if (h = active) {
            setupHwnd := h
            found := true
            break
        }
    }
    if !found
        setupHwnd := hwnds[1]

    setupMode := true
    setupKeyState["F7"] := false
    setupIndex := 1
    setupTemp := Map()
    Status.Text := "狀態：座標設定中"
    UpdateSetupPrompt()
}

RecordSetupPoint(*) {
    global setupMode, setupIndex, setupHwnd, setupTemp, pointKeys, pointNames, points, INI, CoordStatus, Status
    if !setupMode
        return
    if !WinExist("ahk_id " setupHwnd) {
        CancelSetup("設定取消：原本的遊戲視窗已消失。")
        return
    }

    MouseGetPos &mx, &my
    WinGetClientPos &x, &y, &w, &h, "ahk_id " setupHwnd

    rx := mx - x
    ry := my - y

    ; 同時存相對比例，視窗大小不同時可等比例換算
    nx := rx / Max(1,w)
    ny := ry / Max(1,h)
    key := pointKeys[setupIndex]

    ; v1.1.2: reject coordinates outside the actual client area instead of silently saving bad values.
    if nx < 0 || nx > 1 || ny < 0 || ny > 1 {
        coordDiagnosticText := "記錄失敗：" pointNames[setupIndex] "｜Mouse " mx "," my
            . "｜Client " x "," y " " w "x" h "｜NX/NY=" Round(nx,4) "," Round(ny,4)
        MsgBox "目前滑鼠不在設定中的 HIHIYong Client 範圍內。`n`n"
            . coordDiagnosticText
            . "`n`n請把滑鼠移到正確按鈕後再按 F7 / 記錄目前點。", APP_TITLE
        return
    }

    ; v1.3.7.7：除了 NX/NY，再保存「Client 內固定像素座標」與校正尺寸。
    ; HIHIYong Client 尺寸一致時優先使用 RX/RY，避免比例換算與多視窗位置造成誤差。
    setupTemp[key] := {nx:nx, ny:ny, rx:rx, ry:ry, cw:w, ch:h}
    ; v1.3.8.0：F7 除了座標，也記錄該階段的小型 Screen Ready 樣板。
    try {
        if !DirExist(SCREEN_TEMPLATE_DIR)
            DirCreate SCREEN_TEMPLATE_DIR
        SaveScreenRectBmp(mx-36,my-20,72,40,ScreenTemplatePath(key))
    }
    dpi := GetWindowDpiSafe(setupHwnd)
    backX := Round(x + nx*w)
    backY := Round(y + ny*h)
    coordDiagnosticText := "已記錄 " setupIndex "/8 " pointNames[setupIndex]
        . "｜Mouse " mx "," my
        . "｜Client " x "," y " " w "x" h
        . "｜DPI " dpi " (" Round(dpi/96*100) "%)"
        . "｜NX/NY " Round(nx,4) "," Round(ny,4)
        . "｜回算 " backX "," backY
    AddRecentEvent(coordDiagnosticText)

    setupIndex += 1
    if setupIndex > pointKeys.Length {
        for k, v in setupTemp {
            points[k] := v
            IniWrite v.nx, INI, "Point_" k, "NX"
            IniWrite v.ny, INI, "Point_" k, "NY"
            IniWrite v.rx, INI, "Point_" k, "RX"
            IniWrite v.ry, INI, "Point_" k, "RY"
            IniWrite v.cw, INI, "Point_" k, "CW"
            IniWrite v.ch, INI, "Point_" k, "CH"
        }
        IniWrite 1, INI, "Coordinates", "Configured"
        ; v1.0.2: verify persisted coordinates immediately.
        LoadPoints()
        setupMode := false
        CoordStatus.Text := "座標狀態：已設定 8/8"
        Status.Text := "狀態：登入座標設定完成"
        MsgBox "8 個登入座標與 Screen Ready 畫面樣板已全部保存。`n`n之後 Recovery 會先辨識畫面 Ready，再執行下一步。", APP_TITLE
    } else {
        UpdateSetupPrompt()
    }
}

UpdateSetupPrompt() {
    global setupIndex, pointNames, CoordStatus
    CoordStatus.Text := "座標設定 " setupIndex "/8：請把滑鼠移到【" pointNames[setupIndex] "】後按 F7 記錄"
}

CancelSetup(msg := "座標設定已取消，舊座標保持不變。") {
    global setupMode, setupIndex, setupTemp, Status, CoordStatus
    setupMode := false
    setupIndex := 0
    setupTemp := Map()
    CoordStatus.Text := "座標狀態：" (PointsConfigured() ? "已設定 8/8" : "尚未完整設定")
    Status.Text := "狀態：" msg
}

ClearPoints(*) {
    global points, INI, CoordStatus, Status
    answer := MsgBox("確定清除全部 8 個登入座標？","HIHIYONG Auto Recovery","YesNo Icon?")
    if answer != "Yes"
        return
    points := Map()
    try IniDelete INI, "Coordinates"
    for k in ["server","channel","connect","account","password","login","char","startgame"] {
        try IniDelete INI, "Point_" k
        try FileDelete ScreenTemplatePath(k)
    }
    CoordStatus.Text := "座標狀態：尚未完整設定"
    Status.Text := "狀態：登入座標已清除"
}

LoadPoints() {
    global points, INI, pointKeys
    points := Map()
    for k in pointKeys {
        nx := IniRead(INI,"Point_" k,"NX","")
        ny := IniRead(INI,"Point_" k,"NY","")
        rx := IniRead(INI,"Point_" k,"RX","")
        ry := IniRead(INI,"Point_" k,"RY","")
        cw := IniRead(INI,"Point_" k,"CW","")
        ch := IniRead(INI,"Point_" k,"CH","")
        if (nx!="" && ny!="") {
            ; 舊版座標沒有 RX/RY/CW/CH 仍可使用 NX/NY，相容既有 INI。
            points[k] := {
                nx:Number(nx), ny:Number(ny),
                rx:rx!="" ? Number(rx) : "",
                ry:ry!="" ? Number(ry) : "",
                cw:cw!="" ? Number(cw) : "",
                ch:ch!="" ? Number(ch) : ""
            }
        }
    }
}

PointsConfigured() {
    global points, pointKeys
    if points.Count != pointKeys.Length
        return false
    for k in pointKeys
        if !points.Has(k)
            return false
    return true
}


; ============================================================
; v1.2.1 Window Auto Switch
; Input channel intentionally uses a local hihiyong:// navigation
; command instead of WebMessageReceived. This avoids the failed
; v0.9.2 JS->AHK bridge while preserving the stable v0.7.5.9 core.
; ============================================================

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
    items.Push([coordsOk,"登入座標",PointsConfigured() ? "8/8 已設定" : (coordsOk ? "直接讀遊戲畫面（不需要記位置）" : "尚未完成 8 點")])
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
    SoftMinVotesEdit.Value:=Max(2,p[4]+0)
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


ToggleNativePasswordVisibility(*) {
    global PasswordEdit,PasswordShowBtn
    try {
        ; EM_SETPASSWORDCHAR = 0xCC. 0 = 顯示；● = 隱藏。
        static shown := false
        shown := !shown
        SendMessage 0xCC, shown ? 0 : 0x25CF, 0, PasswordEdit.Hwnd
        PasswordEdit.Redraw()
        PasswordShowBtn.Text := shown ? "隱藏密碼" : "顯示密碼"
    }
}



LoadInventoryControlHotkeys() {
    global INI,invStartHotkey,invPauseHotkey,invStopHotkey
    invStartHotkey:=IniRead(INI,"InventoryCleaner","StartHotkey","F3")
    invPauseHotkey:=IniRead(INI,"InventoryCleaner","PauseHotkey","F8")
    invStopHotkey:=IniRead(INI,"InventoryCleaner","StopHotkey","F9")
}

NormalizeInventoryHotkey(hk) {
    hk:=Trim(hk)
    return RegExMatch(hk,"i)^F(1[0-2]|[1-9])$") ? StrUpper(hk) : ""
}

InventoryControlKeyConflict(hk,except:="") {
    global invStartHotkey,invPauseHotkey,invStopHotkey
    if hk="F6" || hk="F7"
        return true
    if except!="start" && hk=invStartHotkey
        return true
    if except!="pause" && hk=invPauseHotkey
        return true
    if except!="stop" && hk=invStopHotkey
        return true
    return false
}

SaveInventoryStartHotkey(raw) {
    global INI,invStartHotkey,invStatus,invControlKeyState
    hk:=NormalizeInventoryHotkey(raw)
    if hk="" || InventoryControlKeyConflict(hk,"start") {
        invStatus:="啟動鍵無效/衝突：請使用未占用的 F1~F12（F6/F7 保留）"
        return
    }
    invStartHotkey:=hk, invControlKeyState:=Map()
    IniWrite hk,INI,"InventoryCleaner","StartHotkey"
    invStatus:="啟動鍵已設定：" hk
}

SaveInventoryPauseHotkey(raw) {
    global INI,invPauseHotkey,invStatus,invControlKeyState
    hk:=NormalizeInventoryHotkey(raw)
    if hk="" || InventoryControlKeyConflict(hk,"pause") {
        invStatus:="暫停鍵無效/衝突：請使用未占用的 F1~F12（F6/F7 保留）"
        return
    }
    invPauseHotkey:=hk, invControlKeyState:=Map()
    IniWrite hk,INI,"InventoryCleaner","PauseHotkey"
    invStatus:="暫停/繼續鍵已設定：" hk
}

SaveInventoryStopHotkey(raw) {
    global INI,invStopHotkey,invStatus,invControlKeyState
    hk:=NormalizeInventoryHotkey(raw)
    if hk="" || InventoryControlKeyConflict(hk,"stop") {
        invStatus:="終止鍵無效/衝突：請使用未占用的 F1~F12（F6/F7 保留）"
        return
    }
    invStopHotkey:=hk, invControlKeyState:=Map()
    IniWrite hk,INI,"InventoryCleaner","StopHotkey"
    invStatus:="終止鍵已設定：" hk
}

ToggleInventoryPause(*) {
    global invRunning,invPaused,invStatus
    if !invRunning
        return
    invPaused:=!invPaused
    invStatus:=invPaused ? "⏸ 已暫停｜再次按暫停鍵後接續原動作" : "▶ 已繼續"
}

InventoryPauseGate() {
    global invPaused,invStopRequested,invStatus
    while invPaused && !invStopRequested {
        invStatus:="⏸ 已暫停｜等待繼續"
        Sleep 50
    }
    return !invStopRequested
}


; PowerShell -EncodedCommand 用的字串（桌面捷徑也會用到）：
PowerShellEncodedCommand(text) {
    ; CryptBinaryToStringW: UTF-16LE bytes -> Base64, no CR/LF.
    ; v1.3.22.0：StrPut 回傳的是位元組數（含結尾 0），原本當成字元數會多編一倍的 0，較長的指令會執行失敗。
    bytes := StrPut(text, "UTF-16")
    buf := Buffer(bytes, 0)
    StrPut(text, buf, "UTF-16")
    flags := 0x40000001
    size := 0
    if !DllCall("Crypt32\CryptBinaryToStringW","Ptr",buf.Ptr,"UInt",bytes-2,"UInt",flags,"Ptr",0,"UIntP",&size)
        return ""
    out := Buffer(size*2,0)
    if !DllCall("Crypt32\CryptBinaryToStringW","Ptr",buf.Ptr,"UInt",bytes-2,"UInt",flags,"Ptr",out.Ptr,"UIntP",&size)
        return ""
    return StrGet(out,"UTF-16")
}

LoadInventoryBindings() {
    global INI,invBindings
    invBindings:=[]
    cnt:=IniRead(INI,"InventoryBindings","Count","0")+0
    Loop cnt {
        sec:="InventoryBinding" A_Index
        name:=IniRead(INI,sec,"Name","清理視窗 " A_Index)
        pid:=IniRead(INI,sec,"PID","0")+0
        hwnd:=IniRead(INI,sec,"HWND","0")+0
        enabled:=(IniRead(INI,sec,"Enabled","1")+0)=1
        invBindings.Push({name:name,pid:pid,hwnd:hwnd,enabled:enabled})
    }
}

SaveInventoryBindings() {
    global INI,invBindings
    old:=IniRead(INI,"InventoryBindings","Count","0")+0
    IniWrite invBindings.Length,INI,"InventoryBindings","Count"
    Loop Max(old,invBindings.Length) {
        sec:="InventoryBinding" A_Index
        if A_Index<=invBindings.Length {
            b:=invBindings[A_Index]
            IniWrite b.name,INI,sec,"Name"
            IniWrite b.pid,INI,sec,"PID"
            IniWrite b.hwnd,INI,sec,"HWND"
            IniWrite b.enabled?1:0,INI,sec,"Enabled"
        } else {
            try IniDelete INI,sec
        }
    }
}

InventoryBindingAlive(b) {
    if !b.hwnd || !WinExist("ahk_id " b.hwnd)
        return false
    try {
        pid:=WinGetPID("ahk_id " b.hwnd)
        return pid=b.pid && ProcessExist(pid)
    }
    return false
}

GetInventoryGameWindows() {
    global GAME_TITLE
    arr:=[]
    try {
        for hwnd in WinGetList(GAME_TITLE) {
            try {
                pid:=WinGetPID("ahk_id " hwnd)
                if pid && ProcessExist(pid)
                    arr.Push({pid:pid,hwnd:hwnd,title:WinGetTitle("ahk_id " hwnd)})
            }
        }
    }
    return arr
}

ScanInventoryWindows(*) {
    global invStatus
    wins:=GetInventoryGameWindows()
    invStatus:="掃描完成｜找到 " wins.Length " 個 HIHIYong 視窗"
    AddRecentEvent("背包清理獨立綁定：" invStatus)
}

ShowInventoryCandidateWindow(raw) {
    hwnd:=raw+0
    if !hwnd || !WinExist("ahk_id " hwnd) {
        AddRecentEvent("背包清理：顯示視窗失敗｜HWND 已不存在")
        return
    }
    try {
        if WinGetMinMax("ahk_id " hwnd)=-1
            WinRestore "ahk_id " hwnd
        WinActivate "ahk_id " hwnd
        if WinWaitActive("ahk_id " hwnd,,2)
            AddRecentEvent("背包清理：已顯示 HWND " hwnd)
    }
}

AddInventoryBindingFromProfile(raw) {
    global profiles,invBindings,invStatus
    idx:=raw+0
    if idx<1 || idx>profiles.Length
        return
    p:=profiles[idx]
    if !ProfileGameAlive(p) {
        invStatus:="加入失敗：" p.name " 目前沒有有效 PID / HWND"
        return
    }
    for b in invBindings
        if b.hwnd=p.hwnd {
            invStatus:="此視窗已在背包清理清單：" b.name
            return
        }
    invBindings.Push({name:p.name,pid:p.pid,hwnd:p.hwnd,enabled:true})
    SaveInventoryBindings()
    invStatus:="已從帳號管理加入：" p.name " / HWND " p.hwnd
}

AddInventoryBinding(raw) {
    global invBindings,invStatus
    ; raw = hwnd~自訂名稱
    parts:=StrSplit(raw,"~")
    hwnd:=parts[1]+0
    ; Web action parser 已先完成 URL decode，這裡直接使用 rawValue 內的名稱。
    ; v1.3.2 誤用了不存在的 UriDecode()，會觸發 #Warn。
    name:=parts.Length>=2 ? parts[2] : ""
    if !hwnd || !WinExist("ahk_id " hwnd) {
        invStatus:="綁定失敗：HWND 已不存在"
        return
    }
    try pid:=WinGetPID("ahk_id " hwnd)
    catch {
        invStatus:="綁定失敗：無法取得 PID"
        return
    }
    for b in invBindings
        if b.hwnd=hwnd {
            invStatus:="此 HWND 已經綁定"
            return
        }
    if name=""
        name:="清理視窗 " (invBindings.Length+1)
    invBindings.Push({name:name,pid:pid,hwnd:hwnd,enabled:true})
    SaveInventoryBindings()
    invStatus:="已獨立綁定 " name " / HWND " hwnd
    AddRecentEvent("背包清理：" invStatus)
}

RemoveInventoryBinding(raw) {
    global invBindings,invStatus
    idx:=raw+0
    if idx<1 || idx>invBindings.Length
        return
    name:=invBindings[idx].name
    invBindings.RemoveAt(idx)
    SaveInventoryBindings()
    invStatus:="已解除清理綁定：" name
}

SetInventoryBindingChecked(raw) {
    global invBindings
    parts:=StrSplit(raw,"~")
    if parts.Length<2
        return
    idx:=parts[1]+0,on:=parts[2]+0
    if idx<1 || idx>invBindings.Length
        return
    invBindings[idx].enabled:=on?true:false
    SaveInventoryBindings()
}

LoadInventoryCleanerConfig() {
    global INI,invConfigured,invGridNX,invGridNY,invStepNX,invStepNY,invDropNX,invDropNY
    global invPageNX,invPageNY,invStartPage,invStartRow,invEndPage,invEndRow,invSpeed,invSetupHotkey
    invConfigured := (IniRead(INI,"InventoryCleaner","Configured","0")+0)=1
    invGridNX := IniRead(INI,"InventoryCleaner","GridNX","0")+0
    invGridNY := IniRead(INI,"InventoryCleaner","GridNY","0")+0
    invStepNX := IniRead(INI,"InventoryCleaner","StepNX","0")+0
    invStepNY := IniRead(INI,"InventoryCleaner","StepNY","0")+0
    invDropNX := IniRead(INI,"InventoryCleaner","DropNX","0")+0
    invDropNY := IniRead(INI,"InventoryCleaner","DropNY","0")+0
    invPageNX := [], invPageNY := []
    Loop 5 {
        invPageNX.Push(IniRead(INI,"InventoryCleaner","PageNX" A_Index,"0")+0)
        invPageNY.Push(IniRead(INI,"InventoryCleaner","PageNY" A_Index,"0")+0)
    }
    invStartPage:=Max(1,Min(5,IniRead(INI,"InventoryCleaner","StartPage","1")+0))
    invStartRow:=Max(1,Min(10,IniRead(INI,"InventoryCleaner","StartRow","1")+0))
    invEndPage:=Max(1,Min(5,IniRead(INI,"InventoryCleaner","EndPage","5")+0))
    invEndRow:=Max(1,Min(10,IniRead(INI,"InventoryCleaner","EndRow","6")+0))
    invSpeed:=IniRead(INI,"InventoryCleaner","Speed","STABLE")
    invSetupHotkey:=IniRead(INI,"InventoryCleaner","SetupHotkey","F6")
    ; v1.3.3.1：不使用一般 Hotkey F6；由 SetupKeyMonitor + GetAsyncKeyState 捕捉。
}

SaveInventoryCleanerConfig() {
    global INI,invConfigured,invGridNX,invGridNY,invStepNX,invStepNY,invDropNX,invDropNY
    global invPageNX,invPageNY,invStartPage,invStartRow,invEndPage,invEndRow,invSpeed,invSetupHotkey
    IniWrite invConfigured?1:0,INI,"InventoryCleaner","Configured"
    IniWrite invGridNX,INI,"InventoryCleaner","GridNX"
    IniWrite invGridNY,INI,"InventoryCleaner","GridNY"
    IniWrite invStepNX,INI,"InventoryCleaner","StepNX"
    IniWrite invStepNY,INI,"InventoryCleaner","StepNY"
    IniWrite invDropNX,INI,"InventoryCleaner","DropNX"
    IniWrite invDropNY,INI,"InventoryCleaner","DropNY"
    Loop 5 {
        IniWrite invPageNX.Length>=A_Index ? invPageNX[A_Index] : 0,INI,"InventoryCleaner","PageNX" A_Index
        IniWrite invPageNY.Length>=A_Index ? invPageNY[A_Index] : 0,INI,"InventoryCleaner","PageNY" A_Index
    }
    IniWrite invStartPage,INI,"InventoryCleaner","StartPage"
    IniWrite invStartRow,INI,"InventoryCleaner","StartRow"
    IniWrite invEndPage,INI,"InventoryCleaner","EndPage"
    IniWrite invEndRow,INI,"InventoryCleaner","EndRow"
    IniWrite invSpeed,INI,"InventoryCleaner","Speed"
    IniWrite invSetupHotkey,INI,"InventoryCleaner","SetupHotkey"
}

StartInventoryCleanerSetup(idx) {
    global invBindings,invSetupMode,invSetupStep,invSetupProfile,invSetupPts,invStatus,setupKeyState
    if idx<1 || idx>invBindings.Length || !InventoryBindingAlive(invBindings[idx]) {
        AddRecentEvent("背包座標設定：請選擇清理頁已獨立綁定且在線的視窗")
        return
    }
    invSetupMode:=true, invSetupStep:=1, invSetupProfile:=idx, invSetupPts:=[]
    setupKeyState["F6"]:=false
    invStatus:="座標設定 1/9"
    InventoryCleanerShowSetupTip()
}

InventoryCleanerShowSetupTip() {
    global invSetupMode,invSetupStep,invSetupHotkey
    if !invSetupMode
        return
    names:=["第一頁：第1行第1格","第一頁：第1行第2格","第一頁：第10行第1格（用來校正第8~10行累積誤差）",
            "背包第1頁頁籤","背包第2頁頁籤","背包第3頁頁籤","背包第4頁頁籤","背包第5頁頁籤","丟棄位置"]
    ToolTip "背包座標設定 " invSetupStep "/9`n`n請把滑鼠移到：`n" names[invSetupStep] "`n`n按 " invSetupHotkey " 記錄"
}

InventoryCleanerSetupHotkey(*) {
    global invSetupMode,invSetupStep,invSetupProfile,invSetupPts,invBindings,invConfigured
    global invGridNX,invGridNY,invStepNX,invStepNY,invDropNX,invDropNY,invPageNX,invPageNY,invStatus
    if !invSetupMode
        return
    b:=invBindings[invSetupProfile]
    if !InventoryBindingAlive(b)
        return
    WinGetClientPos &cx,&cy,&cw,&ch,"ahk_id " b.hwnd
    MouseGetPos &mx,&my
    nx:=(mx-cx)/cw, ny:=(my-cy)/ch
    if nx<0 || nx>1 || ny<0 || ny>1 {
        ToolTip "滑鼠不在目前校正角色的遊戲 Client 內"
        SetTimer InventoryCleanerShowSetupTip,-1200
        return
    }
    invSetupPts.Push({nx:nx,ny:ny})
    SoundBeep 1000,60
    if invSetupStep=9 {
        invGridNX:=invSetupPts[1].nx, invGridNY:=invSetupPts[1].ny
        invStepNX:=invSetupPts[2].nx-invSetupPts[1].nx
        invStepNY:=(invSetupPts[3].ny-invSetupPts[1].ny)/9
        invPageNX:=[], invPageNY:=[]
        Loop 5 {
            invPageNX.Push(invSetupPts[A_Index+3].nx)
            invPageNY.Push(invSetupPts[A_Index+3].ny)
        }
        invDropNX:=invSetupPts[9].nx, invDropNY:=invSetupPts[9].ny
        invConfigured:=true, invSetupMode:=false, invSetupStep:=0
        invStatus:="座標設定完成"
        SaveInventoryCleanerConfig()
        ToolTip "✓ 背包 9 點座標設定完成"
        SetTimer () => ToolTip(),-2500
        AddRecentEvent("背包清理：9 點座標設定完成（Client-relative，可套用多視窗）")
        return
    }
    invSetupStep+=1
    invStatus:="座標設定 " invSetupStep "/9"
    SetTimer InventoryCleanerShowSetupTip,-500
}

SaveInventoryCleanerSettings(raw) {
    global invStartPage,invStartRow,invEndPage,invEndRow,invSpeed
    parts:=StrSplit(raw,"~")
    if parts.Length<5
        return
    invStartPage:=Max(1,Min(5,parts[1]+0))
    invStartRow:=Max(1,Min(10,parts[2]+0))
    invEndPage:=Max(1,Min(5,parts[3]+0))
    invEndRow:=Max(1,Min(10,parts[4]+0))
    invSpeed:=parts[5]="FAST" ? "FAST" : "STABLE"
    SaveInventoryCleanerConfig()
    AddRecentEvent("背包清理設定已儲存")
}

SetInventoryProfileChecked(raw) {
    ; v1.3.2 保留舊 action 相容，但清理選擇已完全獨立。
    SetInventoryBindingChecked(raw)
}

InventoryCleanerCountSlots(sp,sr,ep,er) {
    total:=0
    Loop ep-sp+1 {
        page:=sp+A_Index-1
        maxRows:=page=5?6:10
        a:=page=sp?sr:1, b:=page=ep?Min(er,maxRows):maxRows
        if b>=a
            total+=(b-a+1)*6
    }
    return total
}

StartMultiInventoryCleaner(*) {
    global invBindings,invConfigured,invRunning,invStopRequested,invTotal,invProcessed,invStatus,invPaused
    global invStartPage,invStartRow,invEndPage,invEndRow,processingQueue,activeRecoveryHwnd
    if invRunning
        return
    if !invConfigured {
        AddRecentEvent("背包清理：尚未完成 9 點座標設定")
        return
    }
    if processingQueue || activeRecoveryHwnd {
        AddRecentEvent("背包清理：Recovery / 自動登入執行中，暫不啟動")
        return
    }
    selected:=0
    for b in invBindings
        if b.enabled && InventoryBindingAlive(b)
            selected+=1
    if !selected {
        AddRecentEvent("背包清理：沒有勾選可清理的在線角色")
        return
    }
    invTotal:=InventoryCleanerCountSlots(invStartPage,invStartRow,invEndPage,invEndRow)*selected
    invProcessed:=0, invStopRequested:=false, invPaused:=false, invRunning:=true, invStatus:="準備開始"
    SetTimer RunMultiInventoryCleaner,-1
}

StopMultiInventoryCleaner(*) {
    global invStopRequested,invStatus,invPaused
    invStopRequested:=true
    invPaused:=false
    invStatus:="等待安全終止"
}

InventoryCleanerWaitRecovery() {
    global processingQueue,activeRecoveryHwnd,invStopRequested,invStatus
    if !(processingQueue || activeRecoveryHwnd)
        return !invStopRequested
    invStatus:="⏸ Recovery 中暫停"
    while (processingQueue || activeRecoveryHwnd) && !invStopRequested
        Sleep 100
    return !invStopRequested
}

RunMultiInventoryCleaner(*) {
    global invBindings,invRunning,invStopRequested,invCurrentProfile,invStatus,invProcessed
    global invStartPage,invStartRow,invEndPage,invEndRow
    try {
        for idx,b in invBindings {
            if invStopRequested
                break
            if !b.enabled || !InventoryBindingAlive(b)
                continue
            if !InventoryCleanerWaitRecovery()
                break
            invCurrentProfile:=idx
            invStatus:="清理中：" b.name " / HWND " b.hwnd
            WinActivate "ahk_id " b.hwnd
            if !WinWaitActive("ahk_id " b.hwnd,,3) {
                AddRecentEvent("背包清理略過：" b.name "｜無法切到前景")
                continue
            }
            Sleep 500
            page:=invStartPage
            while page<=invEndPage && !invStopRequested {
                if !InventoryCleanerWaitRecovery()
                    break
                if !InventoryCleanerSelectPage(b.hwnd,page)
                    break
                maxRows:=page=5?6:10
                rs:=page=invStartPage?invStartRow:1
                re:=page=invEndPage?Min(invEndRow,maxRows):maxRows
                row:=rs
                while row<=re && !invStopRequested {
                    col:=1
                    while col<=6 && !invStopRequested {
                        if !InventoryCleanerWaitRecovery()
                            break
                        if !InventoryCleanerProcessSlot(b.hwnd,col-1,row-1)
                            break
                        invProcessed+=1
                        col+=1
                    }
                    row+=1
                }
                page+=1
            }
            AddRecentEvent("背包清理完成視窗：" b.name " / HWND " b.hwnd)
            Sleep 500
        }
    } catch as err {
        AddRecentEvent("背包清理錯誤：" err.Message)
    }
    invRunning:=false, invCurrentProfile:=0, invPaused:=false
    invStatus:=invStopRequested ? "已終止" : "全部清理完成"
    invStopRequested:=false
}

InventoryCleanerPoint(hwnd,nx,ny,&x,&y) {
    if !WinExist("ahk_id " hwnd)
        return false
    WinGetClientPos &cx,&cy,&cw,&ch,"ahk_id " hwnd
    x:=Round(cx+cw*nx), y:=Round(cy+ch*ny)
    return true
}

InventoryCleanerMove(x,y,steps,delay) {
    global invStopRequested
    if !InventoryPauseGate()
        return false
    MouseGetPos &sx,&sy
    Loop steps {
        if invStopRequested
            return false
        if !InventoryPauseGate()
            return false
        r:=A_Index/steps
        DllCall("SetCursorPos","Int",Round(sx+(x-sx)*r),"Int",Round(sy+(y-sy)*r))
        Sleep delay
    }
    DllCall("SetCursorPos","Int",x,"Int",y)
    return true
}

InventoryCleanerClick(hold:=90) {
    global invStopRequested
    if invStopRequested || !InventoryPauseGate()
        return false
    DllCall("mouse_event","UInt",0x0002,"Int",0,"Int",0,"UInt",0,"UPtr",0)
    Sleep hold
    DllCall("mouse_event","UInt",0x0004,"Int",0,"Int",0,"UInt",0,"UPtr",0)
    return !invStopRequested
}

InventoryCleanerTiming() {
    global invSpeed
    if invSpeed="FAST"
        return {steps:8,stepDelay:10,item:180,pickup:250,drop:250,after:350,page:600,hold:80}
    return {steps:15,stepDelay:20,item:400,pickup:500,drop:500,after:700,page:1000,hold:100}
}

InventoryCleanerSelectPage(hwnd,page) {
    global invPageNX,invPageNY
    if !InventoryPauseGate()
        return false
    t:=InventoryCleanerTiming()
    if !InventoryCleanerPoint(hwnd,invPageNX[page],invPageNY[page],&x,&y)
        return false
    if !InventoryCleanerMove(x,y,t.steps,t.stepDelay)
        return false
    Sleep 150
    if !InventoryCleanerClick(t.hold)
        return false
    Sleep t.page
    return true
}

InventoryCleanerProcessSlot(hwnd,col,row) {
    global invGridNX,invGridNY,invStepNX,invStepNY,invDropNX,invDropNY
    if !InventoryPauseGate()
        return false
    t:=InventoryCleanerTiming()
    nx:=invGridNX+col*invStepNX, ny:=invGridNY+row*invStepNY
    if !InventoryCleanerPoint(hwnd,nx,ny,&ix,&iy)
        return false
    if !InventoryCleanerMove(ix,iy,t.steps,t.stepDelay)
        return false
    Sleep t.item
    if !InventoryCleanerClick(t.hold)
        return false
    Sleep t.pickup
    if !InventoryCleanerPoint(hwnd,invDropNX,invDropNY,&dx,&dy)
        return false
    if !InventoryCleanerMove(dx,dy,t.steps,t.stepDelay)
        return false
    Sleep t.drop
    if !InventoryCleanerClick(t.hold)
        return false
    Sleep t.after
    return true
}


BuildInventoryProfileCandidatesJson() {
    global profiles
    out:="[", first:=true
    for i,p in profiles {
        if !ProfileGameAlive(p)
            continue
        if !first
            out.=","
        first:=false
        out.='{"index":' i ',"name":"' JsonEscapeWeb(p.name) '","pid":' p.pid ',"hwnd":' p.hwnd '}'
    }
    return out "]"
}

BuildInventoryBindingsJson() {
    global invBindings
    out:="["
    for i,b in invBindings {
        if i>1
            out.=","
        alive:=InventoryBindingAlive(b)
        out.='{"index":' i ',"name":"' JsonEscapeWeb(b.name) '","pid":' b.pid ',"hwnd":' b.hwnd ',"enabled":' (b.enabled?"true":"false") ',"alive":' (alive?"true":"false") '}'
    }
    return out "]"
}

BuildInventoryWindowsJson() {
    wins:=GetInventoryGameWindows()
    out:="["
    for i,w in wins {
        if i>1
            out.=","
        out.='{"pid":' w.pid ',"hwnd":' w.hwnd ',"title":"' JsonEscapeWeb(w.title) '","charName":"' JsonEscapeWeb(ReadGameCharName(w.pid)) '"}'
    }
    return out "]"
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
