; ============================================================================
; v1.3.13.0 InventoryStats：每日背包 / 金幣統計。
;
; 每 5 秒讀一次各角色的背包與金幣，和上一次比較：
; - 道具數量增加 → 計入「今日新增」；減少 → 計入「今日減少」（使用、販賣、丟棄）。
;   v1.3.18.0 起以背包 + 銀行 + 身上裝備合併計算，只留打怪拾取（見 InventoryStatsSample）。
; - 新 PID（重新登入 / Recovery）只建立基準，不會把整個背包算成新增。
; - v1.3.22.0 角色間轉移：A 少了某道具 N 個、INV_XFER_WINDOW_SEC 秒內 B 剛好多了同一道具 N 個
;   （金幣則是金額完全相同），視為自己角色之間的交易 / 丟給對方，兩邊都不算拾取 / 減少，
;   改記在 xferIn / xferOut；先讀到哪一邊都可以配對（後讀到的一方把先記上的那筆扣回來）。
;   數量必須完全相同才配對（打怪多半一次撿 1 個，轉移多半是一整疊）；減少道具的同一輪金幣增加 = 賣給 NPC，不配對。
; 結果存在 Stats\Inventory_yyyy-MM-dd.ini，每 60 秒與程式結束時寫入。
; ============================================================================

global INV_STATS_INTERVAL_MS := 5000
global INV_STATS_SAVE_MS := 60000
global INV_STATS_EMPTY_CONFIRM := 3   ; 背包突然讀到空的（換地圖瞬間）要連續幾次才採信
global invStatsDay := ""
global invStatsLedger := Map()         ; 角色名稱 → 今日紀錄
global invStatsLastSave := 0
global INV_XFER_WINDOW_SEC := 120
global invXferRecent := []             ; 還沒配對的變動：{name,key,n,dir("+"/"-"),tick,hour}

InventoryStatsFile(day) {
    global STATS_DIR
    return STATS_DIR "\Inventory_" day ".ini"
}

NewInventoryStatsEntry() {
    ; hourMoney / hourItems：小時（0～23）→ 該小時的金幣增加 / 打怪拾取個數（v1.3.18.8 每小時收益曲線）
    return {moneyStart:"",moneyNow:"",moneyGain:0,moneySpend:0,gained:Map(),removed:Map(),hourMoney:Map(),hourItems:Map(),xferIn:Map(),xferOut:Map(),dirty:0}
}

InventoryStatsEntry(name) {
    global invStatsLedger
    if !invStatsLedger.Has(name)
        invStatsLedger[name]:=NewInventoryStatsEntry()
    return invStatsLedger[name]
}

InventoryStatsInit() {
    global invStatsDay,invStatsLedger,invStatsLastSave,STATS_DIR
    if !DirExist(STATS_DIR)
        DirCreate STATS_DIR
    invStatsDay:=FormatTime(,"yyyy-MM-dd")
    invStatsLedger:=LoadInventoryLedger(invStatsDay)
    invStatsLastSave:=A_TickCount
    OnExit(InventoryStatsOnExit)
}

InventoryStatsOnExit(*) {
    InventoryStatsSave(true)
}

InventoryStatsTick() {
    global profiles,fastLoginCritical,invStatsDay,invStatsLastSave,INV_STATS_SAVE_MS
    if fastLoginCritical
        return
    day:=FormatTime(,"yyyy-MM-dd")
    if day!=invStatsDay
        InventoryStatsRollover(day)
    for p in profiles {
        if p.enabled && p.pid && ProfileGameAlive(p)
            InventoryStatsSample(p)
    }
    if A_TickCount-invStatsLastSave>=INV_STATS_SAVE_MS
        InventoryStatsSave()
}

InventoryStatsSample(p) {
    global INV_STATS_EMPTY_CONFIRM
    if !GameOffsetsReady(p.pid)
        return
    hpNow:=0,hpMax:=0,money:=0,expNow:=0
    ; 最大 HP 為 0 代表角色還沒進入遊戲（登入 / 選角畫面），不取樣。
    if !ReadGameHP(p.pid,&hpNow,&hpMax) || hpMax<=0 || !ReadGameMoney(p.pid,&money)
        return
    ProfileLearnCharName(p)
    invCount:=0,bankCount:=0
    items:=ReadGameHoldings(p.pid,&invCount,&bankCount)
    if !IsObject(items)
        return
    ReadGameExp(p.pid,&expNow)
    e:=InventoryStatsEntry(p.name)

    if !p.HasOwnProp("invSnapPid") || p.invSnapPid!=p.pid {
        p.invSnapPid:=p.pid,p.invSnapItems:=items,p.invSnapMoney:=money,p.invSnapExp:=expNow,p.invSnapEmpty:=0,p.invSnapInvCount:=invCount,p.invSnapBankCount:=bankCount
        if e.moneyStart=""
            e.moneyStart:=money
        e.moneyNow:=money
        e.dirty:=1
        for key in items
            GameItemName(key,p.pid)
        return
    }
    if !invCount && p.invSnapInvCount {
        p.invSnapEmpty+=1
        if p.invSnapEmpty<INV_STATS_EMPTY_CONFIRM
            return
    }
    p.invSnapEmpty:=0
    ; 銀行剛載入（重新登入後第一次打開銀行分頁）：銀行裡原本的東西不算新增，重新建立基準。
    if !p.invSnapBankCount && bankCount {
        p.invSnapItems:=items,p.invSnapMoney:=money,p.invSnapExp:=expNow,p.invSnapInvCount:=invCount,p.invSnapBankCount:=bankCount
        return
    }

    changed:=false
    diff:=money-p.invSnapMoney
    hour:=String(A_Hour+0)
    if diff>0 {
        if !InvXferMatch(p.name,"$money",diff,"+",hour) {
            e.moneyGain+=diff
            e.hourMoney[hour]:=(e.hourMoney.Has(hour) ? e.hourMoney[hour] : 0)+diff
        }
    } else if diff<0 {
        if !InvXferMatch(p.name,"$money",-diff,"-",hour)
            e.moneySpend+=-diff
    }
    if diff
        changed:=true
    ; v1.3.18.0：只統計打怪拾取。背包 + 銀行 + 身上裝備合併計算，存倉 / 穿脫不會變動；
    ; 每日道具更換、錄製中、買東西（同一輪金幣減少）、開禮盒變出來的道具都不算新增。
    skipAll:=InventoryStatsBusy(p) || diff<0
    fromBox:=Map()
    for key,old in p.invSnapItems {
        n:=items.Has(key) ? items[key] : 0
        if n>=old
            continue
        changed:=true
        if !GameItemIsBox(p.pid,key) {
            if !InventoryStatsBusy(p) && !InventoryStatsIgnored(key,p.pid) {
                ; 同一輪金幣增加 = 賣給 NPC，不當成轉移
                if diff>0 || !InvXferMatch(p.name,key,old-n,"-",hour)
                    e.removed[key]:=(e.removed.Has(key) ? e.removed[key] : 0)+old-n
            }
            continue
        }
        contents:=GameBoxItems(p.pid,key)
        if !contents.Length
            skipAll:=true
        for k in contents
            fromBox[k]:=1
    }
    for key,n in items {
        old:=p.invSnapItems.Has(key) ? p.invSnapItems[key] : 0
        if n<=old
            continue
        changed:=true
        if skipAll || fromBox.Has(key) || InventoryStatsIgnored(key,p.pid)
            continue
        if InvXferMatch(p.name,key,n-old,"+",hour)
            continue
        e.gained[key]:=(e.gained.Has(key) ? e.gained[key] : 0)+n-old
        e.hourItems[hour]:=(e.hourItems.Has(hour) ? e.hourItems[hour] : 0)+n-old
        GameItemName(key,p.pid)
    }
    if e.moneyStart=""
        e.moneyStart:=p.invSnapMoney
    e.moneyNow:=money
    if expNow!=p.invSnapExp
        changed:=true
    p.invSnapItems:=items,p.invSnapMoney:=money,p.invSnapExp:=expNow,p.invSnapInvCount:=invCount,p.invSnapBankCount:=bankCount
    if changed {
        e.dirty:=1
        ; 高回復率下 HP 常停在滿血；金幣 / 經驗 / 背包有變化也代表角色正在活動，延後假在線判定。
        p.memHpLastChangeTick:=A_TickCount
    }
}

; 角色間轉移配對。找得到「別的角色、同一道具、數量完全相同、方向相反、時間在範圍內」的未配對變動：
; 把那一筆當初記上的拾取 / 減少扣回來，兩邊記成轉移，回傳 true（呼叫端這一筆也不要記）。
; 找不到就把這筆放進待配對清單，回傳 false（呼叫端照常記）。key 為 "$money" 時是金幣。
InvXferMatch(name, key, n, dir, hour) {
    global invXferRecent,INV_XFER_WINDOW_SEC
    now:=A_TickCount
    while invXferRecent.Length && now-invXferRecent[1].tick>INV_XFER_WINDOW_SEC*1000
        invXferRecent.RemoveAt(1)
    for i,r in invXferRecent {
        if r.name=name || r.key!=key || r.n!=n || r.dir=dir
            continue
        invXferRecent.RemoveAt(i)
        other:=InventoryStatsEntry(r.name), me:=InventoryStatsEntry(name)
        if key="$money" {
            if r.dir="+" {
                other.moneyGain-=n
                other.hourMoney[r.hour]:=(other.hourMoney.Has(r.hour) ? other.hourMoney[r.hour] : 0)-n
            } else
                other.moneySpend-=n
        } else if r.dir="+" {
            other.gained[key]-=n
            other.hourItems[r.hour]:=(other.hourItems.Has(r.hour) ? other.hourItems[r.hour] : 0)-n
            if other.gained[key]<=0
                other.gained.Delete(key)
        } else {
            other.removed[key]-=n
            if other.removed[key]<=0
                other.removed.Delete(key)
        }
        from:=dir="-" ? me : other, to:=dir="-" ? other : me
        from.xferOut[key]:=(from.xferOut.Has(key) ? from.xferOut[key] : 0)+n
        to.xferIn[key]:=(to.xferIn.Has(key) ? to.xferIn[key] : 0)+n
        other.dirty:=1, me.dirty:=1
        fromName:=dir="-" ? name : r.name, toName:=dir="-" ? r.name : name
        EventLog("GLOBAL","INV_TRANSFER",fromName " → " toName "｜" (key="$money" ? "金幣 " n : GameItemName(key) " ×" n) "｜不算拾取")
        return true
    }
    invXferRecent.Push({name:name,key:key,n:n,dir:dir,tick:now,hour:hour})
    return false
}

; 每日道具（一日限時道具、每日分享禮包）不列入統計：手動更換、到期消失都不算新增 / 減少。
; pid 為 0 時（顯示舊紀錄）只依名稱判斷。
InventoryStatsIgnored(key, pid:=0) {
    global DAILY_ITEM_MAX_LIMIT
    name:=GameItemName(key,pid)
    if InStr(name,"1D") || InStr(name,"每日分享禮包")
        return true
    if !pid
        return false
    limit:=GameItemTimeLimit(pid,key)
    return limit>0 && limit<=DAILY_ITEM_MAX_LIMIT
}

; 這個角色正在跑每日道具更換或錄製示範：道具變動不是打怪來的。
InventoryStatsBusy(p) {
    global dailyRunning,recorder
    return (dailyRunning!="" && dailyRunning=p.name) || (IsObject(recorder) && recorder.pid=p.pid)
}

InventoryStatsRollover(day) {
    global invStatsDay,invStatsLedger,profiles,invXferRecent
    InventoryStatsSave(true)
    invXferRecent:=[]
    invStatsDay:=day
    invStatsLedger:=LoadInventoryLedger(day)
    for p in profiles {
        if p.HasOwnProp("invSnapMoney") && p.HasOwnProp("invSnapPid") && p.invSnapPid {
            e:=InventoryStatsEntry(p.name)
            if e.moneyStart=""
                e.moneyStart:=p.invSnapMoney
            e.moneyNow:=p.invSnapMoney
            e.dirty:=1
        }
    }
    EventLog("GLOBAL","INV_STATS_ROLLOVER","開始 " day " 背包統計")
}

InventoryStatsSave(force:=false) {
    global invStatsDay,invStatsLedger,invStatsLastSave
    invStatsLastSave:=A_TickCount
    if invStatsDay=""
        return
    path:=InventoryStatsFile(invStatsDay)
    EnsureUnicodeIni(path)
    for name,e in invStatsLedger {
        if !e.dirty && !force
            continue
        try {
            IniWrite e.moneyStart,path,name,"MoneyStart"
            IniWrite e.moneyNow,path,name,"MoneyNow"
            IniWrite e.moneyGain,path,name,"MoneyGain"
            IniWrite e.moneySpend,path,name,"MoneySpend"
            IniWrite SerializeItemCounts(e.gained),path,name,"Gained"
            IniWrite SerializeItemCounts(e.removed),path,name,"Removed"
            IniWrite SerializeItemCounts(e.hourMoney),path,name,"HourMoney"
            IniWrite SerializeItemCounts(e.hourItems),path,name,"HourItems"
            IniWrite SerializeItemCounts(e.xferIn),path,name,"XferIn"
            IniWrite SerializeItemCounts(e.xferOut),path,name,"XferOut"
            e.dirty:=0
        } catch as err {
            EventLog("GLOBAL","INV_STATS_SAVE_FAIL",name "｜" err.Message)
        }
    }
}

LoadInventoryLedger(day) {
    ledger:=Map()
    path:=InventoryStatsFile(day)
    if !FileExist(path)
        return ledger
    try names:=IniRead(path)
    catch
        return ledger
    for name in StrSplit(names,"`n","`r") {
        if name=""
            continue
        e:=NewInventoryStatsEntry()
        moneyStart:=IniRead(path,name,"MoneyStart","")
        moneyNow:=IniRead(path,name,"MoneyNow","")
        e.moneyStart:=moneyStart="" ? "" : Integer(moneyStart)
        e.moneyNow:=moneyNow="" ? "" : Integer(moneyNow)
        e.moneyGain:=Integer(IniRead(path,name,"MoneyGain","0"))
        e.moneySpend:=Integer(IniRead(path,name,"MoneySpend","0"))
        e.gained:=ParseItemCounts(IniRead(path,name,"Gained",""))
        e.removed:=ParseItemCounts(IniRead(path,name,"Removed",""))
        e.hourMoney:=ParseItemCounts(IniRead(path,name,"HourMoney",""))
        e.hourItems:=ParseItemCounts(IniRead(path,name,"HourItems",""))
        e.xferIn:=ParseItemCounts(IniRead(path,name,"XferIn",""))
        e.xferOut:=ParseItemCounts(IniRead(path,name,"XferOut",""))
        ledger[name]:=e
    }
    return ledger
}

SerializeItemCounts(counts) {
    out:=""
    for key,n in counts
        out.=(out="" ? "" : "|") key ":" n
    return out
}

ParseItemCounts(text) {
    counts:=Map()
    for pair in StrSplit(text,"|") {
        kv:=StrSplit(pair,":")
        if kv.Length=2 && kv[1]!=""
            counts[kv[1]]:=Integer(kv[2])
    }
    return counts
}

InventoryStatsDays() {
    global STATS_DIR,invStatsDay
    days:=[]
    Loop Files STATS_DIR "\Inventory_*.ini" {
        if RegExMatch(A_LoopFileName,"^Inventory_(\d{4}-\d{2}-\d{2})\.ini$",&m)
            days.Push(m[1])
    }
    found:=false
    for d in days
        if d=invStatsDay
            found:=true
    if !found && invStatsDay!=""
        days.Push(invStatsDay)
    ; 新到舊
    sorted:=""
    for d in days
        sorted.=(sorted="" ? "" : "`n") d
    sorted:=Sort(sorted,"R")
    return StrSplit(sorted,"`n")
}

InventoryStatsLedgerFor(day) {
    global invStatsDay,invStatsLedger
    return day=invStatsDay ? invStatsLedger : LoadInventoryLedger(day)
}

InvXferItems(counts) {
    out:=Map()
    for k,n in counts
        if k!="$money"
            out[k]:=n
    return out
}

; 依數量由多到少排序的 JSON 陣列：[{"key":"12-3","name":"…","count":5},…]
ItemCountsJson(counts) {
    lines:=""
    for key,n in counts
        if n>0 && !InventoryStatsIgnored(key)   ; 舊紀錄裡的每日道具也不顯示
            lines.=(lines="" ? "" : "`n") Format("{:010}",n) "`t" key
    if lines=""
        return "[]"
    json:="["
    for i,line in StrSplit(Sort(lines,"R"),"`n") {
        parts:=StrSplit(line,"`t")
        key:=parts[2]
        json.=(i>1 ? "," : "") '{"key":"' key '","name":"' JsonEscapeWeb(GameItemName(key)) '","count":' Integer(parts[1]) '}'
    }
    return json "]"
}

; 24 小時陣列 JSON：[0 點, 1 點, …, 23 點]
HourlyJson(hours) {
    out:="["
    Loop 24 {
        h:=String(A_Index-1)
        out.=(A_Index>1 ? "," : "") (hours.Has(h) ? hours[h] : 0)
    }
    return out "]"
}

InventoryStatsPushWeb(day:="") {
    global webReady,WVCore,invStatsDay,profiles
    if !webReady || !WVCore
        return
    if day=""
        day:=invStatsDay
    ledger:=InventoryStatsLedgerFor(day)
    roles:="",totalNet:=0,totalGain:=0,totalSpend:=0
    totalGained:=Map(),totalRemoved:=Map()
    for name,e in ledger {
        net:=(e.moneyStart!="" && e.moneyNow!="") ? e.moneyNow-e.moneyStart : 0
        totalNet+=net,totalGain+=e.moneyGain,totalSpend+=e.moneySpend
        for key,n in e.gained
            totalGained[key]:=(totalGained.Has(key) ? totalGained[key] : 0)+n
        for key,n in e.removed
            totalRemoved[key]:=(totalRemoved.Has(key) ? totalRemoved[key] : 0)+n
        live:=false
        for p in profiles
            if p.name=name && day=invStatsDay && p.HasOwnProp("invSnapPid") && p.invSnapPid && ProfileGameAlive(p)
                live:=true
        roles.=(roles="" ? "" : ",") '{"name":"' JsonEscapeWeb(name) '"'
            . ',"live":' (live ? "true" : "false")
            . ',"moneyStart":' (e.moneyStart="" ? "null" : e.moneyStart)
            . ',"moneyNow":' (e.moneyNow="" ? "null" : e.moneyNow)
            . ',"moneyNet":' net
            . ',"moneyGain":' e.moneyGain
            . ',"moneySpend":' e.moneySpend
            . ',"gained":' ItemCountsJson(e.gained)
            . ',"removed":' ItemCountsJson(e.removed)
            . ',"xferIn":' ItemCountsJson(InvXferItems(e.xferIn)) ',"xferOut":' ItemCountsJson(InvXferItems(e.xferOut))
            . ',"moneyXferIn":' (e.xferIn.Has("$money") ? e.xferIn["$money"] : 0) ',"moneyXferOut":' (e.xferOut.Has("$money") ? e.xferOut["$money"] : 0)
            . ',"hourMoney":' HourlyJson(e.hourMoney) ',"hourItems":' HourlyJson(e.hourItems)
            . ',"kills":' KillStatsJson(name,day) '}'
    }
    days:=""
    for d in InventoryStatsDays()
        days.=(days="" ? "" : ",") '"' d '"'
    payload:='{"type":"invstats","data":{"day":"' day '","today":"' invStatsDay '"'
        . ',"days":[' days ']'
        . ',"pdbReady":' (GameOffsetsLoadedOk() ? "true" : "false")
        . ',"roles":[' roles ']'
        . ',"totals":{"moneyNet":' totalNet ',"moneyGain":' totalGain ',"moneySpend":' totalSpend
        . ',"gained":' ItemCountsJson(totalGained) ',"removed":' ItemCountsJson(totalRemoved) '}}}'
    try WVCore.PostWebMessageAsJson(payload)
}

InventoryStatsExportCsv(day:="") {
    global invStatsDay,STATS_DIR
    if day=""
        day:=invStatsDay
    InventoryStatsSave(true)
    ledger:=InventoryStatsLedgerFor(day)
    csv:="日期,角色,類型,道具ID,道具名稱,數量`r`n"
    for name,e in ledger {
        net:=(e.moneyStart!="" && e.moneyNow!="") ? e.moneyNow-e.moneyStart : 0
        csv.=day "," CsvField(name) ",金幣淨變化,,," net "`r`n"
        csv.=day "," CsvField(name) ",金幣增加,,," e.moneyGain "`r`n"
        csv.=day "," CsvField(name) ",金幣減少,,," e.moneySpend "`r`n"
        for key,n in e.gained
            if !InventoryStatsIgnored(key)
                csv.=day "," CsvField(name) ",新增," key "," CsvField(GameItemName(key)) "," n "`r`n"
        for key,n in e.removed
            if !InventoryStatsIgnored(key)
                csv.=day "," CsvField(name) ",減少," key "," CsvField(GameItemName(key)) "," n "`r`n"
    }
    path:=STATS_DIR "\Inventory_" day ".csv"
    try FileDelete path
    FileAppend csv,path,"UTF-8"   ; UTF-8 含 BOM，Excel 才能正確顯示中文
    try Run('explorer.exe /select,"' path '"')
    AddRecentEvent("📄 已匯出 " day " 背包統計 CSV")
}

CsvField(text) {
    text:=String(text)
    if RegExMatch(text,'[",\r\n]')
        return '"' StrReplace(text,'"','""') '"'
    return text
}
