; ============================================================================
; v1.3.18.9 KillStats：每日擊殺統計（依地圖、怪物種類）。
;
; 每秒讀各角色周圍的怪物清單（GLLandManClient.m_GlobCROWList）：
; - 看過「活著」的怪，之後變成倒下 / 死亡（m_Action = GLAT_FALLING / GLAT_DIE，或 HP 為 0）視為死亡。
; - 剛進地圖時就已經倒在地上的不算；換地圖時清掉追蹤，不會把舊畫面的怪算進來。
; v1.3.18.10 歸屬：只算自己角色打過的怪（滿等角色經驗值不會增加，無法用經驗值判斷）。
; - 每 KILL_HIT_TICK_MS 記錄每個角色正在打的怪：m_sTargetID（一般攻擊）、m_sTARIDS（技能命中，最多 24 隻）、
;   m_sMyTargetID（自動狩獵目標）。
; - 怪死掉時，最近 KILL_HIT_WINDOW_MS 內打過牠的角色中，最後打到的那個得到這次擊殺（最接近最後一擊）。
; - 沒有任何自己角色打過的（別的玩家打死的）不算；同一隻怪被多個角色畫面看到只算一次。
; 結果存在 Stats\Kills_yyyy-MM-dd.ini：[角色名稱] 地圖名稱｜怪物名稱=次數，每 60 秒與程式結束時寫入。
; ============================================================================

global KILL_TICK_MS := 1000
global KILL_HIT_TICK_MS := 200
global KILL_HIT_WINDOW_MS := 6000     ; 怪死掉前多久內打過才算
global KILL_DEDUP_MS := 5000          ; 同一隻怪在不同角色畫面上倒下的時間差容許值
global KILL_SAVE_MS := 60000
global KILL_MAX_CROWS := 400          ; 一次最多讀幾隻（防止讀到錯誤的清單時卡住）
global KILL_LEDGER_VERSION := 2       ; v1 用「最近的角色」歸屬，數字不準，載入時作廢
global GLAT_FALLING := 9, GLAT_DIE := 10, CROW_MOB := 2
global killDay := ""
global killLedger := Map()            ; 角色名稱 → Map("地圖｜怪物" → 次數)
global killDirty := Map()
global killRecent := Map()            ; "地圖ID|GlobID|怪物ID" → 記錄時間（去除重複）
global killCrowNames := Map()         ; "主ID-子ID" → 怪物名稱
global killLastSave := 0
global killUnowned := 0               ; 今天沒有自己角色打過、所以沒算的死亡數（只寫進紀錄檔供檢查）

KillStatsFile(day) {
    global STATS_DIR
    return STATS_DIR "\Kills_" day ".ini"
}

KillStatsInit() {
    global killDay,killLedger,killLastSave
    killDay:=FormatTime(,"yyyy-MM-dd")
    killLedger:=LoadKillLedger(killDay)
    killLastSave:=A_TickCount
    OnExit(KillStatsOnExit)
}

KillStatsOnExit(*) {
    KillStatsSave()
}

LoadKillLedger(day) {
    global KILL_LEDGER_VERSION
    ledger:=Map()
    path:=KillStatsFile(day)
    if !FileExist(path)
        return ledger
    if Integer(IniRead(path,"_meta","Version","1"))<KILL_LEDGER_VERSION {
        ; 舊版歸屬方式算出的數字不準：改名保留，今天從頭開始記。
        try FileMove path,RegExReplace(path,"\.ini$","_v1.ini"),1
        return ledger
    }
    try names:=IniRead(path)
    catch
        return ledger
    for name in StrSplit(names,"`n","`r") {
        if name="" || name="_meta"
            continue
        counts:=Map()
        try section:=IniRead(path,name)
        catch
            continue
        for line in StrSplit(section,"`n","`r") {
            eq:=InStr(line,"=",,-1)
            if eq>1
                counts[SubStr(line,1,eq-1)]:=Integer(SubStr(line,eq+1))
        }
        ledger[name]:=counts
    }
    return ledger
}

KillStatsSave() {
    global killDay,killLedger,killDirty,killLastSave,killUnowned,STATS_DIR,KILL_LEDGER_VERSION
    killLastSave:=A_TickCount
    if killDay="" || !killDirty.Count
        return
    path:=KillStatsFile(killDay)
    try {
        if !DirExist(STATS_DIR)
            DirCreate STATS_DIR
        EnsureUnicodeIni(path)
        IniWrite KILL_LEDGER_VERSION,path,"_meta","Version"
        IniWrite killUnowned,path,"_meta","Unowned"
    }
    for name in killDirty {
        if !killLedger.Has(name)
            continue
        try {
            for key,n in killLedger[name]
                IniWrite n,path,name,key
        } catch as err {
            EventLog("GLOBAL","KILL_STATS_SAVE_FAIL",name "｜" err.Message)
        }
    }
    killDirty:=Map()
}

KillStatsTick() {
    global profiles,fastLoginCritical,killDay,killLedger,killLastSave,killUnowned,KILL_SAVE_MS
    if fastLoginCritical || !KillStatsReady()
        return
    day:=FormatTime(,"yyyy-MM-dd")
    if day!=killDay {
        KillStatsSave()
        killDay:=day
        killLedger:=LoadKillLedger(day)
        killUnowned:=0
    }
    for p in profiles {
        if p.enabled && p.pid && ProfileGameAlive(p)
            KillStatsSample(p)
    }
    KillStatsPruneRecent()
    if A_TickCount-killLastSave>=KILL_SAVE_MS
        KillStatsSave()
}

KillStatsReady() {
    return GameOffsetsLoadedOk() && GameOffset("LandCrowListOffset") && GameOffset("CharTarIdsOffset")
}

; 記錄每個角色這一刻正在打的怪：p.killHits[GlobID 低 16 位元] = 時間。
KillHitTick() {
    global profiles,fastLoginCritical,KILL_HIT_WINDOW_MS,CROW_MOB
    if fastLoginCritical || !KillStatsReady()
        return
    tOff:=GameOffset("CharTargetOffset"),nOff:=GameOffset("CharTarNumOffset"),idOff:=GameOffset("CharTarIdsOffset")
    lo:=Min(tOff,nOff,idOff),span:=Max(tOff+8,nOff+2,idOff+24*4)-lo
    now:=A_TickCount
    for p in profiles {
        if !p.enabled || !p.pid || !ProfileGameAlive(p) || !GameOffsetsReady(p.pid)
            continue
        charBase:=GameCharBase(p.pid)
        if !charBase
            continue
        hProc:=GameProcHandle(p.pid)
        b:=GameReadBuf(hProc,charBase+lo,span)
        if !b
            continue
        if !p.HasOwnProp("killHits")
            p.killHits:=Map()
        hits:=p.killHits
        if NumGet(b,tOff-lo,"UInt")=CROW_MOB
            hits[NumGet(b,tOff-lo+4,"UInt")&0xFFFF]:=now
        num:=Min(NumGet(b,nOff-lo,"UShort"),24)
        Loop num {
            o:=idOff-lo+(A_Index-1)*4
            if NumGet(b,o,"UShort")=CROW_MOB
                hits[NumGet(b,o+2,"UShort")]:=now
        }
        if (mt:=GameReadBuf(hProc,charBase+GameOffset("CharMyTargetOffset"),8)) && NumGet(mt,0,"UInt")=CROW_MOB
            hits[NumGet(mt,4,"UInt")&0xFFFF]:=now
        ; 清掉太舊的
        if hits.Count>200 {
            old:=[]
            for id,t in hits
                if now-t>KILL_HIT_WINDOW_MS
                    old.Push(id)
            for id in old
                hits.Delete(id)
        }
    }
}

; 這隻怪（同一張地圖）最近被哪個角色打過；回傳最後打到的角色名稱，沒有回傳 ""。
; 幾個角色在同一次取樣內都還在打（同時圍毆同一團怪）時無法分辨誰補最後一刀，隨機選一個，
; 傷害相近的角色長期下來會接近平分；不這樣做的話永遠會算給清單排在前面的角色。
KillOwner(mapId,glob) {
    global profiles,KILL_HIT_WINDOW_MS,KILL_HIT_TICK_MS
    id:=glob&0xFFFF,cands:=[],bestTick:=0
    for p in profiles {
        if !p.HasOwnProp("killHits") || !p.HasOwnProp("killMapId") || p.killMapId!=mapId || !p.killHits.Has(id)
            continue
        t:=p.killHits[id]
        if A_TickCount-t<=KILL_HIT_WINDOW_MS {
            cands.Push({name:p.name,t:t})
            bestTick:=Max(bestTick,t)
        }
    }
    tied:=[]
    for c in cands
        if bestTick-c.t<=KILL_HIT_TICK_MS*1.5
            tied.Push(c.name)
    return tied.Length ? tied[Random(1,tied.Length)] : ""
}

; 讀一個角色周圍的怪物，找出這一秒倒下的。
KillStatsSample(p) {
    global killRecent,killLedger,killDirty,killUnowned,KILL_MAX_CROWS,GLAT_FALLING,GLAT_DIE
    pid:=p.pid
    if !GameOffsetsReady(pid)
        return
    inst:=GameGaeaBase(pid)
    if !inst
        return
    hProc:=GameProcHandle(pid)
    land:=GameReadNum(hProc,inst+GameOffset("LandPtrOffset"),"Ptr")
    if !land
        return
    idBuf:=GameReadBuf(hProc,land+GameOffset("LandMapIdOffset"),4)
    if !idBuf
        return
    mapId:=NumGet(idBuf,0,"UShort") "-" NumGet(idBuf,2,"UShort")
    ; 換地圖或換 PID（重新登入）：只重新建立追蹤，不計數。
    fresh:=!p.HasOwnProp("killTrack") || p.killMapId!=mapId || p.killPid!=pid
    track:=fresh ? Map() : p.killTrack
    p.killMapId:=mapId,p.killPid:=pid

    list:=land+GameOffset("LandCrowListOffset")
    amount:=GameReadNum(hProc,list,"UInt")
    node:=GameReadNum(hProc,list+GameOffset("CrowListHeadOffset"),"Ptr")
    if amount="" || node="" || amount>KILL_MAX_CROWS {
        p.killTrack:=track
        return
    }
    base:=GetGameModuleBase(pid,hProc)
    span:=Max(GameOffset("CrowActionOffset"),GameOffset("CrowGlobIdOffset"),GameOffset("CrowHpNowOffset"),GameOffset("CrowDataPtrOffset")+4)+4
    nextTrack:=Map(),mapName:=""
    Loop amount {
        if !node
            break
        nb:=GameReadBuf(hProc,node,GameOffset("CrowNodeNextOffset")+8)
        if !nb
            break
        node:=NumGet(nb,GameOffset("CrowNodeNextOffset"),"Ptr")
        crow:=NumGet(nb,GameOffset("CrowNodeDataOffset"),"Ptr")
        if !crow
            continue
        cb:=GameReadBuf(hProc,crow,span)
        if !cb || !KillCrowVftableOk(NumGet(cb,0,"Ptr")-base)
            continue
        glob:=NumGet(cb,GameOffset("CrowGlobIdOffset"),"UInt")
        nid:=NumGet(cb,GameOffset("CrowNativeIdOffset"),"UShort") "-" NumGet(cb,GameOffset("CrowNativeIdOffset")+2,"UShort")
        action:=NumGet(cb,GameOffset("CrowActionOffset"),"UInt")
        dead:=action=GLAT_FALLING || action=GLAT_DIE || NumGet(cb,GameOffset("CrowHpNowOffset"),"UInt")=0
        id:=glob "|" nid
        was:=track.Has(id) ? track[id] : ""
        nextTrack[id]:=dead ? 0 : 1
        if !dead || was!=1
            continue
        ; 活著 → 倒下。其他角色的畫面可能已經記過這一隻。
        key:=mapId "|" id
        if killRecent.Has(key)
            continue
        killRecent[key]:=A_TickCount
        owner:=KillOwner(mapId,glob)
        if owner="" {
            killUnowned+=1
            continue
        }
        if mapName="" {
            info:=GameMapInfo(pid,mapId)
            mapName:=info ? info.name : "地圖 " mapId
        }
        mob:=KillCrowName(pid,hProc,NumGet(cb,GameOffset("CrowDataPtrOffset"),"Ptr"),nid)
        if InStr(mob,"原石")   ; 挖礦（礦石也是怪物）不算擊殺
            continue
        if !killLedger.Has(owner)
            killLedger[owner]:=Map()
        k:=StrReplace(mapName "｜" mob,"=","＝")
        counts:=killLedger[owner]
        counts[k]:=(counts.Has(k) ? counts[k] : 0)+1
        killDirty[owner]:=1
    }
    p.killTrack:=nextTrack
}

KillStatsPruneRecent() {
    global killRecent,KILL_DEDUP_MS
    old:=[]
    for key,t in killRecent
        if A_TickCount-t>KILL_DEDUP_MS
            old.Push(key)
    for key in old
        killRecent.Delete(key)
}

KillCrowVftableOk(rva) {
    global gameOffsets
    if !gameOffsets.Has("CrowVftableRvas")
        return false
    for s in StrSplit(gameOffsets["CrowVftableRvas"],"|")
        if s!="" && Integer(s)=rva
            return true
    return false
}

; 怪物名稱：SCROWDATA.m_sBasic.m_szName（例如 CN_203_018）→ 怪物字串表。
KillCrowName(pid,hProc,dataPtr,nid) {
    global killCrowNames
    if killCrowNames.Has(nid)
        return killCrowNames[nid]
    name:=""
    if dataPtr && (nb:=GameReadBuf(hProc,dataPtr+GameOffset("CrowDataNameOffset"),33)) {
        code:=StrGet(nb,33,"CP0")
        if code!=""
            name:=GameStringLookup(pid,code,"CrowStringMapOffset")
        if name=""
            name:=code
    }
    if name=""
        return "怪物 " nid
    killCrowNames[nid]:=name
    return name
}

; 背包統計頁：[{"map":"波斯宮","total":123,"mobs":[{"name":"波斯女巫","count":60},…]},…]，依擊殺數由多到少。
KillStatsJson(name,day) {
    global killDay,killLedger
    ledger:=day=killDay ? killLedger : LoadKillLedger(day)
    if !ledger.Has(name)
        return "[]"
    maps:=Map()
    for key,n in ledger[name] {
        parts:=StrSplit(key,"｜",,2)
        if parts.Length<2 || n<=0
            continue
        if !maps.Has(parts[1])
            maps[parts[1]]:={total:0,mobs:""}
        m:=maps[parts[1]]
        m.total+=n
        m.mobs.=(m.mobs="" ? "" : "`n") Format("{:010}",n) "`t" parts[2]
    }
    lines:=""
    for mapName,m in maps
        lines.=(lines="" ? "" : "`n") Format("{:010}",m.total) "`t" mapName
    if lines=""
        return "[]"
    out:="["
    for i,line in StrSplit(Sort(lines,"R"),"`n") {
        mapName:=StrSplit(line,"`t",,2)[2]
        m:=maps[mapName],mobs:=""
        for j,ml in StrSplit(Sort(m.mobs,"R"),"`n") {
            mp:=StrSplit(ml,"`t",,2)
            mobs.=(j>1 ? "," : "") '{"name":"' JsonEscapeWeb(mp[2]) '","count":' Integer(mp[1]) '}'
        }
        out.=(i>1 ? "," : "") '{"map":"' JsonEscapeWeb(mapName) '","total":' m.total ',"mobs":[' mobs ']}'
    }
    return out "]"
}

; 每日報表用：某角色當天的總擊殺數。
KillStatsTotal(name,day) {
    global killDay,killLedger
    ledger:=day=killDay ? killLedger : LoadKillLedger(day)
    total:=0
    if ledger.Has(name)
        for key,n in ledger[name]
            total+=n
    return total
}
