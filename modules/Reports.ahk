; ============================================================================
; v1.3.18.8 Reports：截圖存證、定時截圖、每日報表（Discord）。
;
; - 異常截圖：假在線、伺服器斷線、卡復活、每日道具失敗、自動攻擊閒置時，
;   存下當下遊戲畫面到 Logs\Shots\，並附在 Discord 通知裡。
; - 定時截圖：每 SnapshotMinutes 分鐘把所有監控中的遊戲視窗拼成一張圖發到 Discord。
; - 每日報表：每天 DailyTime 發出「昨天」的摘要（金幣、打怪拾取、死亡、重新登入次數）；
;   網頁可隨時發送「今天到目前為止」的報表。
; 截圖用 PrintWindow（視窗被蓋住也拍得到）；拍到全黑時改截螢幕上的視窗區域。
; 圖片與通知都走「斷線 / 自動重新登入通知」的 Discord Webhook。
;
; 設定：HIHIYONG_AutoRecovery.ini [Reports]
;   DailyTime=08:00        每日報表時間（留空 = 不發）
;   SnapshotMinutes=60     定時截圖間隔（0 = 不發）
;   ErrorShots=1           異常時截圖
; ============================================================================

global REPORT_DAILY_TIME := IniRead(INI,"Reports","DailyTime","08:00")
global REPORT_SNAPSHOT_MIN := Integer(IniRead(INI,"Reports","SnapshotMinutes","60"))
global REPORT_ERROR_SHOTS := Integer(IniRead(INI,"Reports","ErrorShots","1"))
global REPORT_SHOT_DIR := A_ScriptDir "\Logs\Shots"
global REPORT_CELL_W := 480, REPORT_CELL_H := 360, REPORT_LABEL_H := 28
global reportLastSnapshotTick := A_TickCount

ReportsSaveSettings(raw) {
    global INI,REPORT_DAILY_TIME,REPORT_SNAPSHOT_MIN,REPORT_ERROR_SHOTS
    parts:=StrSplit(raw,"~")
    if parts.Length<3
        return
    t:=Trim(parts[1])
    REPORT_DAILY_TIME:=RegExMatch(t,"^([01]?\d|2[0-3]):([0-5]\d)$",&m) ? Format("{:02}:{}",m[1],m[2]) : ""
    REPORT_SNAPSHOT_MIN:=Max(0,Integer("0" parts[2]))
    REPORT_ERROR_SHOTS:=parts[3]="1" ? 1 : 0
    IniWrite REPORT_DAILY_TIME,INI,"Reports","DailyTime"
    IniWrite REPORT_SNAPSHOT_MIN,INI,"Reports","SnapshotMinutes"
    IniWrite REPORT_ERROR_SHOTS,INI,"Reports","ErrorShots"
    AddRecentEvent("✓ 報表 / 截圖設定已儲存")
}

ReportsJson() {
    global REPORT_DAILY_TIME,REPORT_SNAPSHOT_MIN,REPORT_ERROR_SHOTS
    return ',"reportDailyTime":"' JsonEscapeWeb(REPORT_DAILY_TIME) '","reportSnapshotMin":' REPORT_SNAPSHOT_MIN ',"reportErrorShots":' (REPORT_ERROR_SHOTS ? "true" : "false")
}

; 每 30 秒：到時間就發每日報表 / 定時截圖。
ReportsTick() {
    global INI,REPORT_DAILY_TIME,REPORT_SNAPSHOT_MIN,reportLastSnapshotTick,fastLoginCritical
    if fastLoginCritical
        return
    if REPORT_DAILY_TIME!="" && StrCompare(FormatTime(,"HH:mm"),REPORT_DAILY_TIME)>=0 {
        today:=FormatTime(,"yyyy-MM-dd")
        if IniRead(INI,"Reports","LastDailyReport","")!=today {
            IniWrite today,INI,"Reports","LastDailyReport"
            ReportSendDaily(FormatTime(DateAdd(A_Now,-1,"Days"),"yyyy-MM-dd"))
        }
    }
    if REPORT_SNAPSHOT_MIN>0 && A_TickCount-reportLastSnapshotTick>=REPORT_SNAPSHOT_MIN*60000 {
        reportLastSnapshotTick:=A_TickCount
        ReportSendSnapshot("⏱️ 定時截圖")
    }
}

; ---------------------------------------------------------------------------
; 每日報表
; ---------------------------------------------------------------------------

ReportSendDaily(day) {
    for part in ReportDailyText(day)
        try SendDiscordMessage(part)
    EventLog("GLOBAL","DAILY_REPORT","已發送 " day " 每日報表")
}

; 回傳要發送的訊息陣列（Discord 單則上限 2000 字，過長時分段）。
ReportDailyText(day) {
    global profiles,DEATH_STATS_INI,DiscordPcEdit
    ledger:=InventoryStatsLedgerFor(day)
    relog:=ReportCountLogEvents(day,"RECOVERY_OK")
    pc:=Trim(DiscordPcEdit.Value)
    if pc=""
        pc:=A_ComputerName
    totalMoney:=0,totalItems:=0,totalDeaths:=0,totalRelog:=0,totalKills:=0,allItems:=Map()
    lines:=[]
    for p in profiles {
        name:=p.name
        e:=ledger.Has(name) ? ledger[name] : 0
        gain:=e ? e.moneyGain-e.moneySpend : 0
        items:=0
        if e {
            for key,n in e.gained {
                if InventoryStatsIgnored(key)
                    continue
                items+=n
                allItems[key]:=(allItems.Has(key) ? allItems[key] : 0)+n
            }
        }
        deaths:=Integer(IniRead(DEATH_STATS_INI,day,name,"0"))
        re:=relog.Has(name) ? relog[name] : 0
        kills:=KillStatsTotal(name,day)
        if !e && !deaths && !re && !kills
            continue
        totalMoney+=gain,totalItems+=items,totalDeaths+=deaths,totalRelog+=re,totalKills+=kills
        lines.Push(name "：💰 " ReportMoney(gain,true) "｜⚔️ " kills " 隻｜📦 " items " 個｜💀 " deaths "｜🔄 " re)
    }
    head:="📊 HIHIYONG 每日報表｜" day "（" pc "）`n"
        . "💰 金幣 " ReportMoney(totalMoney,true) "　⚔️ 擊殺 " totalKills " 隻　📦 打怪拾取 " totalItems " 個　💀 死亡 " totalDeaths " 次　🔄 重新登入 " totalRelog " 次`n"
        . "──────────"
    top:=ReportTopItems(allItems,5)
    out:=[],cur:=head
    for l in lines {
        if StrLen(cur)+StrLen(l)>1800
            out.Push(cur),cur:=""
        cur.=(cur="" ? "" : "`n") l
    }
    if !lines.Length
        cur.="`n（這一天沒有統計資料）"
    if top!=""
        cur.="`n🏆 拾取最多：" top
    out.Push(cur)
    ; v1.3.22.0：假在線多半發生在凌晨，早上看報表就知道每個角色最後有沒有恢復
    rec:=ReportRecoverySummary(24)
    ; H-003：接在「最近 24 小時重新登入」後面一行 7 天成功率與最常卡住的步驟
    week:=RecView_WeekLine(A_ScriptDir "\Logs",FormatTime(,"yyyy-MM-dd"),7)
    if rec!="" && week!=""
        rec.="`n" week
    if rec!=""
        out.Push(rec)
    return out
}

; 最近 hours 小時內每個重新登入過的角色：次數與最後結果。沒有重新登入過回傳空字串。
ReportRecoverySummary(hours) {
    since:=FormatTime(DateAdd(A_Now,-hours,"Hours"),"yyyy-MM-dd HH:mm:ss")
    final:=Map("RECOVERY_CHECK_OK","✅ 完成（登入後檢查正常）","RECOVERY_CHECK_FIX","🛠️ 已自動補救（之後再檢查）"
        ,"RECOVERY_CHECK_FAIL","⚠️ 自動補救後仍不正常，需要看一下","RECOVERY_OK","✅ 已回到遊戲"
        ,"MANUAL_REQUIRED","❌ 需要人工處理","RECOVERY_FAIL","❌ 重新登入失敗（會自動重試）"
        ,"LOADING_CHARSELECT_STUCK","🔁 卡在選角畫面，重新登入中","RECOVERY_ABORTED","⏹ 已手動停止")
    roles:=Map(), order:=[]
    for day in [FormatTime(DateAdd(A_Now,-1,"Days"),"yyyy-MM-dd"),FormatTime(,"yyyy-MM-dd")] {
        path:=A_ScriptDir "\Logs\HIHIYONG_" day ".log"
        if !FileExist(path)
            continue
        try text:=FileRead(path,"UTF-8")
        catch
            continue
        Loop Parse text,"`n","`r" {
            parts:=StrSplit(A_LoopField," | ")
            if parts.Length<3 || StrCompare(parts[1],since)<0
                continue
            name:=parts[2], type:=parts[3]
            if type!="RECOVERY_START" && !final.Has(type)
                continue
            if !roles.Has(name) {
                if type!="RECOVERY_START"
                    continue
                roles[name]:={starts:0,ok:0,first:SubStr(parts[1],6,11),last:""}
                order.Push(name)
            }
            r:=roles[name]
            if type="RECOVERY_START"
                r.starts+=1
            else {
                r.last:=type
                if type="RECOVERY_OK"
                    r.ok+=1
            }
        }
    }
    if !order.Length
        return ""
    done:=0, lines:=[]
    for name in order {
        r:=roles[name]
        st:=r.last="" ? "🔄 重新登入中" : final[r.last]
        if r.last="RECOVERY_CHECK_OK" || r.last="RECOVERY_OK" || r.last="RECOVERY_CHECK_FIX"
            done+=1
        lines.Push(name "：" st "｜第一次 " r.first "｜登入 " r.starts " 次")
    }
    out:="🌙 最近 " hours " 小時重新登入：" order.Length " 個角色，" done " 個已回到遊戲`n──────────"
    for l in lines
        out.="`n" l
    return out
}

; 每個角色在當天紀錄中出現某事件的次數：Map(角色 → 次數)。
ReportCountLogEvents(day, type) {
    counts:=Map()
    path:=A_ScriptDir "\Logs\HIHIYONG_" day ".log"
    if !FileExist(path)
        return counts
    try text:=FileRead(path,"UTF-8")
    catch
        return counts
    Loop Parse text,"`n","`r" {
        parts:=StrSplit(A_LoopField," | ")
        if parts.Length>=3 && parts[3]=type
            counts[parts[2]]:=(counts.Has(parts[2]) ? counts[parts[2]] : 0)+1
    }
    return counts
}

ReportTopItems(items, n) {
    lines:=""
    for key,c in items
        lines.=(lines="" ? "" : "`n") Format("{:010}",c) "`t" key
    if lines=""
        return ""
    out:=""
    for i,line in StrSplit(Sort(lines,"R"),"`n") {
        if i>n
            break
        kv:=StrSplit(line,"`t")
        out.=(out="" ? "" : "、") GameItemName(kv[2]) " ×" Integer(kv[1])
    }
    return out
}

; 金幣簡寫：x.xx 億 / x 萬
ReportMoney(n, signed:=false) {
    sign:=signed && n>0 ? "+" : ""
    a:=Abs(n)
    if a>=100000000
        return sign Format("{:.2f}",n/100000000) " 億"
    if a>=10000
        return sign Round(n/10000) " 萬"
    return sign n
}

; ---------------------------------------------------------------------------
; 截圖
; ---------------------------------------------------------------------------

ReportSendSnapshot(title) {
    global profiles,REPORT_SHOT_DIR
    wins:=[]
    for p in profiles
        if p.enabled && p.hwnd && ProfileGameAlive(p)
            wins.Push({hwnd:p.hwnd,label:p.name "｜" NotificationLocationText(p)})
    if !wins.Length
        return false
    path:=ReportShotPath("Snapshot")
    if !ReportComposeWindows(wins,path) {
        EventLog("GLOBAL","SNAPSHOT_FAIL","無法建立截圖")
        return false
    }
    return SendDiscordImage(title "｜" FormatTime(,"MM-dd HH:mm") "（" wins.Length " 個遊戲視窗）",path)
}

; 異常時截圖並附在通知裡；關閉異常截圖或截不到時只發文字。
ReportEventShot(p, message) {
    global REPORT_ERROR_SHOTS
    path:=""
    if REPORT_ERROR_SHOTS && p.hwnd && WinExist("ahk_id " p.hwnd) {
        path:=ReportShotPath(p.name)
        if !CaptureWindowPng(p.hwnd,path)
            path:=""
    }
    if path!=""
        EventLog(p.name,"EVENT_SHOT","已保存畫面：" path)
    try path!="" ? SendDiscordImage(message,path) : SendDiscordMessage(message)
    return path
}

ReportShotPath(tag) {
    global REPORT_SHOT_DIR
    if !DirExist(REPORT_SHOT_DIR)
        DirCreate REPORT_SHOT_DIR
    return REPORT_SHOT_DIR "\" FormatTime(,"yyyyMMdd_HHmmss") "_" RegExReplace(tag,'[\\/:*?"<>|]',"_") ".png"
}

GdipEnsure() {
    static token:=0
    if !token {
        DllCall("LoadLibrary","Str","gdiplus","Ptr")
        si:=Buffer(24,0),NumPut("UInt",1,si)
        DllCall("gdiplus\GdiplusStartup","Ptr*",&token,"Ptr",si,"Ptr",0)
    }
}

SaveHBitmapPng(hbm, path) {
    GdipEnsure()
    bitmap:=0
    DllCall("gdiplus\GdipCreateBitmapFromHBITMAP","Ptr",hbm,"Ptr",0,"Ptr*",&bitmap)
    if !bitmap
        return false
    clsid:=Buffer(16)
    DllCall("ole32\CLSIDFromString","Str","{557CF406-1A04-11D3-9A73-0000F81EF32E}","Ptr",clsid)
    ok:=DllCall("gdiplus\GdipSaveImageToFile","Ptr",bitmap,"WStr",path,"Ptr",clsid,"Ptr",0)=0
    DllCall("gdiplus\GdipDisposeImage","Ptr",bitmap)
    return ok
}

; 遊戲視窗畫面（client 區域）→ HBITMAP；呼叫端負責 DeleteObject。
CaptureWindowBitmap(hwnd, &w, &h) {
    w:=0,h:=0
    try WinGetClientPos(&cx,&cy,&w,&h,"ahk_id " hwnd)
    catch
        return 0
    if w<=0 || h<=0
        return 0
    hdcScreen:=DllCall("GetDC","Ptr",0,"Ptr")
    hdc:=DllCall("CreateCompatibleDC","Ptr",hdcScreen,"Ptr")
    hbm:=DllCall("CreateCompatibleBitmap","Ptr",hdcScreen,"Int",w,"Int",h,"Ptr")
    obm:=DllCall("SelectObject","Ptr",hdc,"Ptr",hbm,"Ptr")
    ; PW_CLIENTONLY | PW_RENDERFULLCONTENT：被其他視窗蓋住也能拍到遊戲畫面
    ok:=DllCall("PrintWindow","Ptr",hwnd,"Ptr",hdc,"UInt",3)
    if !ok || ReportIsBlack(hdc,w,h) {
        ; 拍到全黑（部分顯示模式不支援）→ 改截螢幕上看得到的區域
        DllCall("BitBlt","Ptr",hdc,"Int",0,"Int",0,"Int",w,"Int",h,"Ptr",hdcScreen,"Int",cx,"Int",cy,"UInt",0x40CC0020)
    }
    DllCall("SelectObject","Ptr",hdc,"Ptr",obm)
    DllCall("DeleteDC","Ptr",hdc)
    DllCall("ReleaseDC","Ptr",0,"Ptr",hdcScreen)
    return hbm
}

ReportIsBlack(hdc, w, h) {
    Loop 6 {
        y:=Floor(h*A_Index/7)
        Loop 6 {
            c:=DllCall("GetPixel","Ptr",hdc,"Int",Floor(w*A_Index/7),"Int",y,"UInt")
            if (c&0xFF)+((c>>8)&0xFF)+((c>>16)&0xFF)>30
                return false
        }
    }
    return true
}

CaptureWindowPng(hwnd, path) {
    w:=0,h:=0
    hbm:=CaptureWindowBitmap(hwnd,&w,&h)
    if !hbm
        return false
    ok:=SaveHBitmapPng(hbm,path)
    DllCall("DeleteObject","Ptr",hbm)
    return ok
}

; 多個遊戲視窗縮小後拼成一張（每列 3 個），每格下方標示角色名稱與地圖。
ReportComposeWindows(wins, path) {
    global REPORT_CELL_W,REPORT_CELL_H,REPORT_LABEL_H
    cols:=Min(3,wins.Length),rows:=Ceil(wins.Length/cols)
    cw:=REPORT_CELL_W,ch:=REPORT_CELL_H+REPORT_LABEL_H
    W:=cols*cw,H:=rows*ch
    hdcScreen:=DllCall("GetDC","Ptr",0,"Ptr")
    canvasDC:=DllCall("CreateCompatibleDC","Ptr",hdcScreen,"Ptr")
    canvas:=DllCall("CreateCompatibleBitmap","Ptr",hdcScreen,"Int",W,"Int",H,"Ptr")
    oc:=DllCall("SelectObject","Ptr",canvasDC,"Ptr",canvas,"Ptr")
    rc:=Buffer(16),NumPut("Int",0,"Int",0,"Int",W,"Int",H,rc)
    brush:=DllCall("CreateSolidBrush","UInt",0x2B1A10,"Ptr")
    DllCall("FillRect","Ptr",canvasDC,"Ptr",rc,"Ptr",brush)
    DllCall("DeleteObject","Ptr",brush)
    DllCall("SetStretchBltMode","Ptr",canvasDC,"Int",4)
    font:=DllCall("CreateFont","Int",-17,"Int",0,"Int",0,"Int",0,"Int",700,"UInt",0,"UInt",0,"UInt",0,"UInt",1,"UInt",0,"UInt",0,"UInt",5,"UInt",0,"Str","Microsoft JhengHei","Ptr")
    of:=DllCall("SelectObject","Ptr",canvasDC,"Ptr",font,"Ptr")
    DllCall("SetBkMode","Ptr",canvasDC,"Int",1)
    DllCall("SetTextColor","Ptr",canvasDC,"UInt",0xFFFFFF)
    srcDC:=DllCall("CreateCompatibleDC","Ptr",hdcScreen,"Ptr")
    for i,win in wins {
        x:=Mod(i-1,cols)*cw,y:=((i-1)//cols)*ch
        w:=0,h:=0
        hbm:=CaptureWindowBitmap(win.hwnd,&w,&h)
        if hbm {
            os:=DllCall("SelectObject","Ptr",srcDC,"Ptr",hbm,"Ptr")
            DllCall("StretchBlt","Ptr",canvasDC,"Int",x+2,"Int",y+2,"Int",cw-4,"Int",REPORT_CELL_H-4,"Ptr",srcDC,"Int",0,"Int",0,"Int",w,"Int",h,"UInt",0x00CC0020)
            DllCall("SelectObject","Ptr",srcDC,"Ptr",os)
            DllCall("DeleteObject","Ptr",hbm)
        }
        tr:=Buffer(16),NumPut("Int",x+8,"Int",y+REPORT_CELL_H,"Int",x+cw-8,"Int",y+ch,tr)
        DllCall("DrawText","Ptr",canvasDC,"Str",win.label,"Int",-1,"Ptr",tr,"UInt",0x24 | 0x8000)
    }
    DllCall("DeleteDC","Ptr",srcDC)
    DllCall("SelectObject","Ptr",canvasDC,"Ptr",of)
    DllCall("DeleteObject","Ptr",font)
    DllCall("SelectObject","Ptr",canvasDC,"Ptr",oc)
    DllCall("DeleteDC","Ptr",canvasDC)
    DllCall("ReleaseDC","Ptr",0,"Ptr",hdcScreen)
    ok:=SaveHBitmapPng(canvas,path)
    DllCall("DeleteObject","Ptr",canvas)
    return ok
}

; ---------------------------------------------------------------------------
; Discord：文字 + 圖片（multipart/form-data）
; ---------------------------------------------------------------------------

SendDiscordImage(message, path) {
    global DiscordEnableCB,DiscordWebhookEdit,pendingHttp
    if !DiscordEnableCB.Value
        return false
    url:=Trim(DiscordWebhookEdit.Value)
    if url="" || !RegExMatch(url,"i)^https://(canary\.|ptb\.)?discord(app)?\.com/api/webhooks/")
        return false
    if !FileExist(path)
        return SendDiscordMessage(message)
    boundary:=""
    body:=ReportMultipartBody(message,path,&boundary)
    req:=ComObject("WinHttp.WinHttpRequest.5.1")
    req.SetTimeouts(3000,5000,10000,20000)
    req.Open("POST",url,true)
    req.SetRequestHeader("Content-Type","multipart/form-data; boundary=" boundary)
    req.Send(body)
    pendingHttp.Push({req:req,tick:A_TickCount})
    SetTimer CleanupDiscordAsync,-1000
    return true
}

; multipart/form-data 內容（payload_json + 一張 PNG），回傳 VT_ARRAY|VT_UI1 供 WinHttp 傳送。
ReportMultipartBody(message, path, &boundary) {
    boundary:="----HIHIYONG" A_TickCount
    head:="--" boundary "`r`nContent-Disposition: form-data; name=`"payload_json`"`r`nContent-Type: application/json`r`n`r`n"
        . '{"content":"' JsonEscape(message) '","username":"HIHIYONG Recovery"}'
        . "`r`n--" boundary "`r`nContent-Disposition: form-data; name=`"files[0]`"; filename=`"screenshot.png`"`r`nContent-Type: image/png`r`n`r`n"
    tail:="`r`n--" boundary "--`r`n"
    hb:=Buffer(StrPut(head,"UTF-8")),StrPut(head,hb,"UTF-8"),hn:=hb.Size-1
    tb:=Buffer(StrPut(tail,"UTF-8")),StrPut(tail,tb,"UTF-8"),tn:=tb.Size-1
    f:=FileOpen(path,"r"),fn:=f.Length
    body:=ComObjArray(0x11,hn+fn+tn)
    pData:=0
    DllCall("oleaut32\SafeArrayAccessData","Ptr",ComObjValue(body),"Ptr*",&pData)
    DllCall("RtlMoveMemory","Ptr",pData,"Ptr",hb,"UPtr",hn)
    f.RawRead(pData+hn,fn)
    DllCall("RtlMoveMemory","Ptr",pData+hn+fn,"Ptr",tb,"UPtr",tn)
    DllCall("oleaut32\SafeArrayUnaccessData","Ptr",ComObjValue(body))
    f.Close()
    return body
}
