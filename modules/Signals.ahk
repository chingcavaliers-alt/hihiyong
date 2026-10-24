; ============================================================================
; v1.3.14.0 Signals：記錄假在線的候選訊號（只記錄，不觸發任何動作）。
;
; 假在線時伺服器不再送資料：聊天、HP、經驗、金幣都停住。伺服器推送的時間
; GLGaeaClient.m_cServerTime 預期也會停止更新。這裡持續記錄它與其他訊號，
; 等實際遇到假在線時，用紀錄確認它是否可靠，再改成正式的判定依據。
;
; - 伺服器時間超過 SIGNAL_STALL_SEC 秒沒有變化 → Log：SIGNAL_SERVER_TIME_STALL
; - 恢復變化 → Log：SIGNAL_SERVER_TIME_RESUME（含停止秒數）
; - 每 SIGNAL_CSV_MS 毫秒寫一列 Logs\Signals_yyyy-MM-dd.csv
; ============================================================================

global SIGNAL_TICK_MS := 2000
global SIGNAL_STALL_SEC := 60
global SIGNAL_CSV_MS := 30000
global signalLastCsvTick := 0

SignalsTick() {
    global profiles,fastLoginCritical,signalLastCsvTick,SIGNAL_CSV_MS
    if fastLoginCritical
        return
    writeCsv:=A_TickCount-signalLastCsvTick>=SIGNAL_CSV_MS
    for p in profiles {
        if p.enabled && p.pid && ProfileGameAlive(p)
            SignalsSample(p,writeCsv)
    }
    if writeCsv
        signalLastCsvTick:=A_TickCount
}

SignalsSample(p,writeCsv) {
    global SIGNAL_STALL_SEC
    serverTime:=0
    if !GameOffsetsReady(p.pid) || !ReadGameServerTime(p.pid,&serverTime)
        return
    p.sigSampleTick:=A_TickCount
    ; 新 PID 重新開始計時
    if !p.HasOwnProp("sigPid") || p.sigPid!=p.pid {
        p.sigPid:=p.pid,p.sigSrvTime:=serverTime,p.sigSrvChangeTick:=A_TickCount,p.sigStallLogged:=0
        return
    }
    if serverTime!=p.sigSrvTime {
        if p.sigStallLogged {
            stalled:=Round((A_TickCount-p.sigSrvChangeTick)/1000)
            EventLog(p.name,"SIGNAL_SERVER_TIME_RESUME","伺服器時間恢復更新｜停止 " stalled " 秒｜" SignalsSummary(p))
        }
        p.sigSrvTime:=serverTime,p.sigSrvChangeTick:=A_TickCount,p.sigStallLogged:=0
    } else if !p.sigStallLogged && A_TickCount-p.sigSrvChangeTick>=SIGNAL_STALL_SEC*1000 {
        p.sigStallLogged:=1
        EventLog(p.name,"SIGNAL_SERVER_TIME_STALL","伺服器時間 " SIGNAL_STALL_SEC " 秒未更新｜" SignalsSummary(p))
    }
    if writeCsv
        SignalsWriteCsv(p,serverTime)
}

; 伺服器時間距上次更新的秒數；尚無資料回傳 -1。
; 取樣暫停過（例如其他帳號登入中的保護期間）時資料不可信，也回傳 -1，避免誤判假在線。
SignalServerStaticSec(p) {
    if !p.HasOwnProp("sigPid") || p.sigPid!=p.pid
        return -1
    if !p.HasOwnProp("sigSampleTick") || A_TickCount-p.sigSampleTick>6000
        return -1
    return Floor((A_TickCount-p.sigSrvChangeTick)/1000)
}

SignalsSummary(p) {
    hpStatic:=p.HasOwnProp("memHpLastChangeTick") ? Floor((A_TickCount-p.memHpLastChangeTick)/1000) : -1
    soft:=p.HasOwnProp("memSoftState") ? p.memSoftState : ""
    return "HP=" (p.HasOwnProp("memHp") ? p.memHp : "") "｜HP/金幣/經驗/背包 " hpStatic " 秒未變｜假在線狀態=" soft
}

SignalsWriteCsv(p,serverTime) {
    path:=A_ScriptDir "\Logs\Signals_" FormatTime(,"yyyy-MM-dd") ".csv"
    if !FileExist(path) {
        SplitPath path,,&dir
        if !DirExist(dir)
            DirCreate dir
        FileAppend "時間,角色,PID,HP,伺服器時間,伺服器時間未變秒數,活動未變秒數,金幣,背包道具數,假在線狀態`r`n",path,"UTF-8"
    }
    hpStatic:=p.HasOwnProp("memHpLastChangeTick") ? Floor((A_TickCount-p.memHpLastChangeTick)/1000) : ""
    money:=p.HasOwnProp("invSnapMoney") ? p.invSnapMoney : ""
    itemCount:=(p.HasOwnProp("invSnapItems") && IsObject(p.invSnapItems)) ? p.invSnapItems.Count : ""
    line:=FormatTime(,"HH:mm:ss") "," CsvField(p.name) "," p.pid "," (p.HasOwnProp("memHp") ? p.memHp : "")
        . "," serverTime "," SignalServerStaticSec(p) "," hpStatic "," money "," itemCount
        . "," CsvField(p.HasOwnProp("memSoftState") ? p.memSoftState : "") "`r`n"
    try FileAppend line,path,"UTF-8"
}
