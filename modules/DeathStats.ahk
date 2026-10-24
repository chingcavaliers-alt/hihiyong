; ============================================================================
; v1.3.18.7 DeathStats：每日角色死亡次數。
;
; 每次確認死亡（記憶體 HP 或畫面備援）時記一次，存在 Stats\Deaths.ini：
;   [yyyy-MM-dd]            角色名稱=當天死亡次數
;   [LastDeath]             角色名稱=最後一次死亡時間（yyyy-MM-dd HH:mm:ss）
; 與原本累計的「死亡事件 #N」分開，不受「開始監控時清除死亡累積」影響。
; ============================================================================

global DEATH_STATS_INI := STATS_DIR "\Deaths.ini"

DeathStatsRecord(p) {
    global DEATH_STATS_INI,STATS_DIR
    day:=FormatTime(,"yyyy-MM-dd")
    DeathStatsLoad(p)
    p.deathToday+=1
    p.deathLast:=FormatTime(,"yyyy-MM-dd HH:mm:ss")
    try {
        if !DirExist(STATS_DIR)
            DirCreate STATS_DIR
        EnsureUnicodeIni(DEATH_STATS_INI)
        IniWrite p.deathToday,DEATH_STATS_INI,day,p.name
        IniWrite p.deathLast,DEATH_STATS_INI,"LastDeath",p.name
    } catch as err {
        EventLog(p.name,"DEATH_STATS_FAIL",err.Message)
    }
}

; 讀取今天 / 昨天的次數（換日或程式剛啟動時從檔案重新載入）。
DeathStatsLoad(p) {
    global DEATH_STATS_INI
    day:=FormatTime(,"yyyy-MM-dd")
    if p.HasOwnProp("deathDay") && p.deathDay=day
        return
    yesterday:=FormatTime(DateAdd(A_Now,-1,"Days"),"yyyy-MM-dd")
    p.deathDay:=day
    p.deathToday:=Integer(IniRead(DEATH_STATS_INI,day,p.name,"0"))
    p.deathYesterday:=Integer(IniRead(DEATH_STATS_INI,yesterday,p.name,"0"))
    p.deathLast:=IniRead(DEATH_STATS_INI,"LastDeath",p.name,"")
}

; 網頁用 JSON 欄位：今日 / 昨日次數與最後死亡時間（今天的只顯示時分）。
DeathStatsJson(p) {
    DeathStatsLoad(p)
    last:=p.deathLast
    if last!="" && SubStr(last,1,10)=p.deathDay
        last:=SubStr(last,12,5)
    else if last!=""
        last:=SubStr(last,6,11)
    return ',"deathToday":' p.deathToday ',"deathYesterday":' p.deathYesterday ',"deathLast":"' JsonEscapeWeb(last) '"'
}
