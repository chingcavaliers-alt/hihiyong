; ============================================================================
; v1.3.13.0 GameData：依 Game.pdb 解析出的位置直接讀取角色資料（唯讀）。
;
; HIHIYONG_GameOffsets.ini 由 tools\resolve_game_offsets.py 從 game.exe + Game.pdb 產生。
; game.exe 版本（維修更新）改變時會在背景自動重新解析，不需要手動校正 HP。
; 解析失敗時，HP 退回 v1.3.12.6 的 offset + 動態校正流程。
; ============================================================================

global GAME_OFFSETS_INI := A_ScriptDir "\HIHIYONG_GameOffsets.ini"
global STATS_DIR := A_ScriptDir "\Stats"
global ITEM_NAMES_INI := STATS_DIR "\ItemNames.ini"
global GAME_OFFSETS_DB_DIR := A_ScriptDir "\offsets_db"
global gameOffsetsKnownTried := Map()   ; build → 已找過已知版本資料夾
global GAME_OFFSETS_RESOLVE_TIMEOUT_MS := 60000
; 需要的解析工具版本（tools\resolve_game_offsets.py 的 TOOL_VERSION）；INI 較舊時自動重新解析。
global GAME_OFFSETS_TOOL_VERSION := 20
global gameMapInfoCache := Map()      ; "主ID-子ID" → {name, peace}（地圖清單在遊戲執行期間不變）
global gameOffsets := Map()
global gameBuildByPid := Map()        ; pid → game.exe 版本（每個 PID 只讀一次 PE header）
global memoryHpLiveMax := Map()       ; pid → 最近一次讀到的最大 HP
global itemNameCache := Map()
global itemTimeLimitCache := Map()    ; "主ID-子ID" → 時間限制（秒）
global itemSuitCache := Map()         ; "主ID-子ID" → 裝備部位（EMSUIT）
global itemTypeCache := Map()         ; "主ID-子ID" → 道具類型（EMITEM_TYPE）
global GAME_BOX_ITEM_TYPES := Map(12,1,20,1,22,1,60,1,79,1)   ; ITEM_BOX / PREMIUMSET / RANDOMITEM / REWARD_BOX / GACHA_BOX
global GAME_EQUIP_SLOT_COUNT := 23    ; EMSLOT：0 頭、1 上衣、2 褲子、3 手套、4 鞋子、5 右手武器、6 左手、7 項鍊、8 手鐲…
global GAME_EQUIP_SLOT_NAMES := ["頭部","上衣","褲子","手套","鞋子","右手武器","左手","項鍊","手鐲","右戒指","左戒指","翅膀"
    ,"右手武器(副)","左手(副)","坐騎","腰帶","交換","血寶","重生","額外1","額外2","持有","烙印"]
global gameOffsetsResolvePid := 0
global gameOffsetsResolveBuild := ""
global gameOffsetsResolveStart := 0
global gameOffsetsResolveTried := Map() ; build → 已自動嘗試過（失敗不重複執行）

; MSVC x64 std::map 節點：_Left, _Parent, _Right, _Color, _Isnil, _Myval(key, value)
global STDMAP_NODE_ISNIL := 0x19
global STDMAP_NODE_VALUE_PTR := 0x28
global STDMAP_NODE_SIZE := 0x30
; std::map<std::string,std::string> 節點：key 字串在 +0x20、value 字串在 +0x40（MSVC x64 std::string = 32 bytes）
global STDMAP_STR_KEY := 0x20
global STDMAP_STR_VALUE := 0x40
global STDMAP_MAX_DEPTH := 64
; SITEM.strName 是字串表的 key（例如 IN_001_254），要再查 GLStringTable 才是顯示名稱。
global ITEM_NAME_KEY_PATTERN := "^[A-Z]{2}_\d+_\d+$"

LoadGameOffsets() {
    global gameOffsets,GAME_OFFSETS_INI
    gameOffsets:=Map()
    if !FileExist(GAME_OFFSETS_INI)
        return false
    try section:=IniRead(GAME_OFFSETS_INI,"GameOffsets")
    catch
        return false
    for line in StrSplit(section,"`n","`r") {
        pos:=InStr(line,"=")
        if pos
            gameOffsets[SubStr(line,1,pos-1)]:=SubStr(line,pos+1)
    }
    return GameOffsetsLoadedOk()
}

GameOffsetsLoadedOk() {
    global gameOffsets,GAME_OFFSETS_TOOL_VERSION
    return gameOffsets.Has("Status") && gameOffsets["Status"]="OK"
        && gameOffsets.Has("ToolVersion") && Integer(gameOffsets["ToolVersion"])>=GAME_OFFSETS_TOOL_VERSION
}

GameOffset(key) {
    global gameOffsets
    return gameOffsets.Has(key) ? Integer(gameOffsets[key]) : 0
}

GameBuildOf(pid) {
    global gameBuildByPid
    if (build:=gameBuildByPid.Get(pid,""))!=""
        return build
    build:=GetGameBuildStamp(pid)
    ; 影像大小為 0 = game.exe 剛啟動、模組還沒載完：不是正式版本，不快取、當作還讀不到
    if build="" || RegExMatch(build,"-0$")
        return ""
    gameBuildByPid[pid]:=build
    return build
}

; 這個 PID 的 game.exe 是否已有對應版本的 Game.pdb 位置；沒有就在背景開始解析。
GameOffsetsReady(pid) {
    global gameOffsets
    if !pid
        return false
    build:=GameBuildOf(pid)
    if build=""
        return false
    if GameOffsetsLoadedOk() && gameOffsets.Has("Build") && gameOffsets["Build"]=build
        return true
    ; 沒有 Game.pdb 的電腦：先找隨程式附上的「已知版本」位置資料
    if GameOffsetsUseKnownBuild(build)
        return true
    StartGameOffsetsResolve(pid,build)
    return false
}

; 已知版本資料夾 offsets_db\<Build>.ini：由有 Game.pdb 的電腦解析後隨發佈包 / 更新一起發出。
; 命中就複製成目前使用的位置檔並載入；回傳是否已可用。每個版本只試一次，失敗不重複。
GameOffsetsUseKnownBuild(build) {
    ; 版本字串會變成檔名：只接受「十六進位-十六進位」，且影像大小不是 0（遊戲還沒載完）
    if !RegExMatch(build,"^[0-9A-F]+-[0-9A-F]*[1-9A-F][0-9A-F]*\z")
        return false
    ; 多個計時器同時查同一版本時，不讓另一個在標記與套用之間插隊；Critical 是整個執行緒的設定，結束時一定要還原
    prevCritical:=Critical("On")
    try return GameOffsetsApplyKnownBuild(build)
    finally Critical(prevCritical)
}

GameOffsetsApplyKnownBuild(build) {
    global gameOffsets,gameOffsetsKnownTried,GAME_OFFSETS_INI,GAME_OFFSETS_DB_DIR,GAME_OFFSETS_TOOL_VERSION
    if gameOffsetsKnownTried.Has(build)
        return false
    gameOffsetsKnownTried[build]:=1
    src:=GAME_OFFSETS_DB_DIR "\" build ".ini"
    if !FileExist(src)
        return false
    ; 先在暫存裡驗證，通過才覆寫使用中的位置檔，避免壞檔蓋掉原本可用的
    cand:=Map()
    try {
        for line in StrSplit(IniRead(src,"GameOffsets"),"`n","`r") {
            pos:=InStr(line,"=")
            if pos
                cand[SubStr(line,1,pos-1)]:=SubStr(line,pos+1)
        }
    }
    if cand.Get("Status","")!="OK" || cand.Get("Build","")!=build
        || !IsInteger(cand.Get("ToolVersion","")) || Integer(cand["ToolVersion"])<GAME_OFFSETS_TOOL_VERSION {
        EventLog("GLOBAL","GAME_OFFSETS_DB_FAIL","已知版本 " build " 的位置資料版本過舊或內容不符，改由 Game.pdb 解析")
        return false
    }
    try FileCopy(src,GAME_OFFSETS_INI,true)
    catch as err {
        EventLog("GLOBAL","GAME_OFFSETS_DB_FAIL","無法套用已知版本 " build "：" err.Message)
        return false
    }
    gameOffsets:=cand
    EventLog("GLOBAL","GAME_OFFSETS_DB","使用隨程式附上的已知版本位置資料 " build "（不需要 Game.pdb）")
    return true
}

GameOffsetsResolving() {
    global gameOffsetsResolvePid
    return gameOffsetsResolvePid && ProcessExist(gameOffsetsResolvePid)
}

FindPythonLauncher() {
    ; v1.3.18.6：優先使用資料夾附帶的 Python（runtime\python），換電腦不用另外安裝
    bundled:=A_ScriptDir "\runtime\python\python.exe"
    if FileExist(bundled)
        return '"' bundled '"'
    for path in [A_WinDir "\py.exe", EnvGet("LOCALAPPDATA") "\Programs\Python\Launcher\py.exe"]
        if FileExist(path)
            return '"' path '" -3'
    return ""
}

StartGameOffsetsResolve(pid,build) {
    global gameOffsetsResolvePid,gameOffsetsResolveBuild,gameOffsetsResolveStart,gameOffsetsResolveTried,GAME_OFFSETS_INI
    global GAME_OFFSETS_TOOL_VERSION
    tryKey:=build "#" GAME_OFFSETS_TOOL_VERSION
    if GameOffsetsResolving() || gameOffsetsResolveTried.Has(tryKey)
        return
    gameOffsetsResolveTried[tryKey]:=A_TickCount
    exe:=""
    try exe:=ProcessGetPath(pid)
    pdb:=RegExReplace(exe,"[^\\]+$","Game.pdb")
    if exe="" || !FileExist(pdb) {
        EventLog("GLOBAL","GAME_OFFSETS_UNAVAILABLE","找不到 Game.pdb，也沒有這個版本（" build "）的已知位置資料（" exe "）｜HP 改用動態校正；快捷欄 / 寵物 / 前點卡自動判別停用")
        return
    }
    python:=FindPythonLauncher()
    if python="" {
        EventLog("GLOBAL","GAME_OFFSETS_UNAVAILABLE","找不到 Python（py.exe）｜HP 改用動態校正")
        AddRecentEvent("⚠ 找不到 Python，無法自動解析新版遊戲資料位置")
        return
    }
    cmd:=python ' -I "' A_ScriptDir '\tools\resolve_game_offsets.py" --exe "' exe '" --out "' GAME_OFFSETS_INI '" --db "' GAME_OFFSETS_DB_DIR '"'
    newPid:=0
    try Run(cmd,A_ScriptDir,"Hide",&newPid)
    catch as err {
        EventLog("GLOBAL","GAME_OFFSETS_FAIL","無法執行解析工具：" err.Message)
        return
    }
    gameOffsetsResolvePid:=newPid
    gameOffsetsResolveBuild:=build
    gameOffsetsResolveStart:=A_TickCount
    EventLog("GLOBAL","GAME_OFFSETS_RESOLVE","game.exe 版本 " build "｜由 Game.pdb 解析 HP / 金幣 / 背包位置")
    AddRecentEvent("🔎 偵測到 game.exe 版本 " build "，正在由 Game.pdb 解析資料位置")
    SetTimer GameOffsetsResolveTick,500
}

GameOffsetsResolveTick() {
    global gameOffsets,gameOffsetsResolvePid,gameOffsetsResolveBuild,gameOffsetsResolveStart,GAME_OFFSETS_RESOLVE_TIMEOUT_MS,profiles
    if GameOffsetsResolving() {
        if A_TickCount-gameOffsetsResolveStart<GAME_OFFSETS_RESOLVE_TIMEOUT_MS
            return
        try ProcessClose gameOffsetsResolvePid
        EventLog("GLOBAL","GAME_OFFSETS_FAIL","解析逾時 " Floor(GAME_OFFSETS_RESOLVE_TIMEOUT_MS/1000) " 秒｜HP 改用動態校正")
    }
    SetTimer GameOffsetsResolveTick,0
    gameOffsetsResolvePid:=0
    if LoadGameOffsets() && gameOffsets["Build"]=gameOffsetsResolveBuild {
        EventLog("GLOBAL","GAME_OFFSETS_OK","Build=" gameOffsets["Build"] "｜Gaea=" gameOffsets["GaeaInstanceRva"] "｜HP=Char+" gameOffsets["HpNowOffset"] "｜Money=Char+" gameOffsets["MoneyOffset"])
        AddRecentEvent("✓ 已取得新版遊戲資料位置（HP / 金幣 / 背包），不需要校正")
        ; 讓目前的 session 改用新位置，並重新走「連續讀到合理 HP 才啟用死亡判定」。
        for p in profiles {
            if !p.HasOwnProp("memHpStale") || !ProfileGameAlive(p)
                continue
            p.memHpStale:=0,p.memHpArmed:=0,p.memHpPlausibleStreak:=0
            p.memHpUnarmedSince:=A_TickCount,p.memHpSuspectLogged:=0
        }
    } else {
        err:=gameOffsets.Has("Error") ? gameOffsets["Error"] : "沒有產生結果"
        EventLog("GLOBAL","GAME_OFFSETS_FAIL",err "｜HP 改用動態校正")
        AddRecentEvent("⚠ Game.pdb 解析失敗，HP 改用動態校正（詳見 Log）")
    }
}

GameForgetPid(pid) {
    global gameBuildByPid,memoryHpLiveMax
    try gameBuildByPid.Delete(pid)
    try memoryHpLiveMax.Delete(pid)
}

GameProcHandle(pid) {
    global memoryHpHandles
    ; 只讀一次：Has() 與取值之間若被其他計時器（行程結束時關閉並移除 handle）插隊，會出現「Item has no value」
    h:=memoryHpHandles.Get(pid,0)
    if h
        return h
    h:=DllCall("OpenProcess","UInt",0x0410,"Int",0,"UInt",pid,"Ptr")
    if h
        memoryHpHandles[pid]:=h
    return h
}

GameReadBuf(hProc,addr,size) {
    buf:=Buffer(size,0),bytesRead:=0
    if !DllCall("ReadProcessMemory","Ptr",hProc,"Ptr",addr,"Ptr",buf.Ptr,"UPtr",size,"UPtr*",&bytesRead,"Int") || bytesRead!=size
        return 0
    return buf
}

; type: "UShort" / "UInt" / "Int64" / "Ptr"；讀取失敗回傳 ""。
GameReadNum(hProc,addr,type) {
    size:=type="UShort" ? 2 : (type="UInt" ? 4 : 8)
    buf:=GameReadBuf(hProc,addr,size)
    return buf ? NumGet(buf,0,type) : ""
}

GameVftableMatches(rva) {
    global gameOffsets
    for s in StrSplit(gameOffsets["GaeaVftableRvas"],"|")
        if Integer(s)=rva
            return true
    return false
}

; GLGaeaClient 物件位址；遊戲尚未初始化（vftable 不符）時回傳 0。
GameGaeaBase(pid) {
    if !GameOffsetsReady(pid)
        return 0
    hProc:=GameProcHandle(pid)
    base:=hProc ? GetGameModuleBase(pid,hProc) : 0
    if !base
        return 0
    inst:=base+GameOffset("GaeaInstanceRva")
    vf:=GameReadNum(hProc,inst,"Ptr")
    if vf="" || !GameVftableMatches(vf-base)
        return 0
    return inst
}

; 角色物件位址；遊戲尚未初始化時回傳 0。
GameCharBase(pid) {
    inst:=GameGaeaBase(pid)
    return inst ? inst+GameOffset("CharOffset") : 0
}

; 伺服器時間（time_t 秒）；舊版 offsets 檔沒有這個欄位時回傳 false。
ReadGameServerTime(pid,&serverTime) {
    serverTime:=0
    if !GameOffset("ServerTimeOffset")
        return false
    inst:=GameGaeaBase(pid)
    v:=inst ? GameReadNum(GameProcHandle(pid),inst+GameOffset("ServerTimeOffset"),"Int64") : ""
    if v=""
        return false
    serverTime:=v
    return true
}

; 角色是否已進入遊戲：伺服器已送來角色資料（最大 HP > 0）。
GameCharacterLoaded(pid) {
    hpNow:=0,hpMax:=0
    return ReadGameHP(pid,&hpNow,&hpMax) && hpMax>0
}

; 角色真的在遊戲世界裡：有角色資料，而且已經進入地圖。
; v1.3.21.0：選角畫面時遊戲就會先讀入角色資料（最大 HP > 0），但還沒有地圖；
; 只看 HP 會把「開始遊戲沒按到、停在選角畫面」誤判成已進入遊戲（2026-10-23 欸等欸）。
GameInWorld(pid) {
    return GameCharacterLoaded(pid) && ReadGameMapId(pid)!=""
}

ReadGameHP(pid,&hpNow,&hpMax) {
    hpNow:=0,hpMax:=0
    charBase:=GameCharBase(pid)
    if !charBase
        return false
    hProc:=GameProcHandle(pid)
    n:=GameReadNum(hProc,charBase+GameOffset("HpNowOffset"),"UInt")
    m:=GameReadNum(hProc,charBase+GameOffset("HpMaxOffset"),"UInt")
    if n="" || m=""
        return false
    hpNow:=n,hpMax:=m
    return true
}

ReadGameMoney(pid,&money) {
    money:=0
    charBase:=GameCharBase(pid)
    v:=charBase ? GameReadNum(GameProcHandle(pid),charBase+GameOffset("MoneyOffset"),"Int64") : ""
    if v=""
        return false
    money:=v
    return true
}

ReadGameExp(pid,&expNow) {
    expNow:=0
    charBase:=GameCharBase(pid)
    v:=charBase ? GameReadNum(GameProcHandle(pid),charBase+GameOffset("ExpNowOffset"),"Int64") : ""
    if v=""
        return false
    expNow:=v
    return true
}

; 背包內容：Map("主ID-子ID" → 數量)。讀到不一致的資料（遊戲正在改動背包）回傳 0，呼叫端略過這一輪。
ReadGameInventory(pid) {
    slots:=ReadGameInventorySlots(pid,"InvenOffset")
    if !IsObject(slots)
        return 0
    items:=Map()
    for s in slots
        items[s.key]:=(items.Has(s.key) ? items[s.key] : 0)+s.count
    return items
}

; 角色持有的全部道具（背包 + 銀行 + 身上裝備 + 滑鼠上拿著的）：Map("主ID-子ID" → 數量)。
; 在背包、銀行、裝備欄之間移動不會改變總數；任一部分讀取不一致回傳 0。
; invCount：其中背包本身有幾種道具（換地圖瞬間背包可能讀到空的，呼叫端據此判斷）。
; bankCount：銀行有幾格（銀行要打開一次銀行分頁才會載入，0 可能代表尚未載入）。
ReadGameHoldings(pid, &invCount:=0, &bankCount:=0) {
    invCount:=0,bankCount:=0
    items:=ReadGameInventory(pid)
    if !IsObject(items)
        return 0
    invCount:=items.Count
    if GameOffset("BankOffset") {
        bank:=ReadGameInventorySlots(pid,"BankOffset")
        if !IsObject(bank)
            return 0
        bankCount:=bank.Length
        for s in bank
            items[s.key]:=(items.Has(s.key) ? items[s.key] : 0)+s.count
    }
    equip:=ReadGameEquipment(pid)
    if IsObject(equip) {
        for s in equip
            if s
                items[s.key]:=(items.Has(s.key) ? items[s.key] : 0)+Max(1,s.count)
    }
    return items
}

; 背包 / 銀行每一格：[{key, x, y, count, born, disguiseKey, disguiseTime}]。
; invenKey：GameOffsets 的欄位名稱（"InvenOffset" = 背包、"BankOffset" = 銀行）。
ReadGameInventorySlots(pid, invenKey) {
    global STDMAP_NODE_ISNIL,STDMAP_NODE_VALUE_PTR,STDMAP_NODE_SIZE
    charBase:=GameCharBase(pid)
    if !charBase || !GameOffset(invenKey)
        return 0
    hProc:=GameProcHandle(pid)
    mapObj:=charBase+GameOffset(invenKey)+GameOffset("ItemMapOffset")
    head:=GameReadNum(hProc,mapObj,"Ptr")
    size:=GameReadNum(hProc,mapObj+8,"Ptr")
    if head="" || size="" || !head || size>2000
        return 0
    slots:=[]
    root:=GameReadNum(hProc,head+8,"Ptr")
    if root="" || !root || root=head
        return size=0 ? slots : 0

    customOff:=GameOffset("InvenItemCustomOffset")
    posOff:=GameOffset("InvenItemPosOffset")
    span:=customOff+Max(GameOffset("TurnNumOffset")+2,GameOffset("DisguiseTimeOffset")+8,GameOffset("BornTimeOffset")+8)
    stack:=[root],visited:=0
    while stack.Length {
        node:=stack.Pop()
        nb:=GameReadBuf(hProc,node,STDMAP_NODE_SIZE)
        if !nb
            return 0
        if NumGet(nb,STDMAP_NODE_ISNIL,"UChar")
            continue
        visited+=1
        if visited>size+8
            return 0
        itemPtr:=NumGet(nb,STDMAP_NODE_VALUE_PTR,"Ptr")
        if itemPtr {
            ib:=GameReadBuf(hProc,itemPtr,span)
            if !ib
                return 0
            slot:=GameItemCustomFromBuf(ib,customOff)
            if slot {
                ; 不可堆疊的道具 wTurnNum 可能是 0，至少算 1 個。
                slot.count:=Max(1,slot.count)
                slot.x:=NumGet(ib,posOff,"UShort"),slot.y:=NumGet(ib,posOff+2,"UShort")
                slots.Push(slot)
            }
        }
        left:=NumGet(nb,0,"Ptr"),right:=NumGet(nb,0x10,"Ptr")
        if left && left!=head
            stack.Push(left)
        if right && right!=head
            stack.Push(right)
    }
    ; 走訪到的節點數必須等於 map 大小；不一致代表讀取期間遊戲正在改動背包。
    return visited=size ? slots : 0
}

; 從緩衝區的 SITEMCUSTOM（位於 base 位移）取出道具資訊；空的欄位回傳 0。
GameItemCustomFromBuf(buf, base) {
    nid:=base+GameOffset("NativeIdOffset")
    mid:=NumGet(buf,nid,"UShort"),sid:=NumGet(buf,nid+2,"UShort")
    if mid=0xFFFF
        return 0
    dis:=base+GameOffset("DisguiseIdOffset")
    dmid:=NumGet(buf,dis,"UShort"),dsid:=NumGet(buf,dis+2,"UShort")
    return {key:mid "-" sid
        ,count:NumGet(buf,base+GameOffset("TurnNumOffset"),"UShort")
        ,born:NumGet(buf,base+GameOffset("BornTimeOffset"),"Int64")
        ,disguiseKey:dmid=0xFFFF ? "" : dmid "-" dsid
        ,disguiseTime:NumGet(buf,base+GameOffset("DisguiseTimeOffset"),"Int64")}
}

; 角色身上 23 個裝備欄：陣列索引 = EMSLOT + 1；空欄位為 0。
ReadGameEquipment(pid) {
    charBase:=GameCharBase(pid)
    size:=GameOffset("ItemCustomSize")
    if !charBase || !size
        return 0
    buf:=GameReadBuf(GameProcHandle(pid),charBase+GameOffset("PutOnItemsOffset"),size*GAME_EQUIP_SLOT_COUNT)
    if !buf
        return 0
    slots:=[]
    Loop GAME_EQUIP_SLOT_COUNT
        slots.Push(GameItemCustomFromBuf(buf,(A_Index-1)*size))
    return slots
}

; 角色身上的效果清單（右下角狀態圖示的資料來源）：[{id: "主-子", age: 數值}…]，空的格子不放入。
; 沒有這組欄位（舊的位置檔 / 解析失敗）或讀不到回傳 ""。age 是遊戲裡的 fAGE（剩餘還是已過時間要實測）。
ReadGameSkillFacts(pid) {
    if !GameOffset("SkillFactOffset") || !GameOffset("SkillFactCount") || !GameOffset("SkillFactSize")
        return ""
    charBase := GameCharBase(pid)
    if !charBase
        return ""
    cnt := GameOffset("SkillFactCount"), sz := GameOffset("SkillFactSize")
    buf := GameReadBuf(GameProcHandle(pid), charBase + GameOffset("SkillFactOffset"), cnt * sz)
    if !buf
        return ""
    out := []
    Loop cnt {
        at := (A_Index - 1) * sz
        mid := NumGet(buf, at + GameOffset("SkillFactIdOffset"), "UShort"), sid := NumGet(buf, at + GameOffset("SkillFactIdOffset") + 2, "UShort")
        if mid = 0xFFFF && sid = 0xFFFF
            continue
        age := NumGet(buf, at + GameOffset("SkillFactAgeOffset"), "Float")
        if !IsNumber(age) || age != age || age < 0 || age > 1000000
            continue
        out.Push({id: mid "-" sid, age: age})
    }
    ; 問號道具（命運箱子）效果：emType 不是 0 = 作用中，編號記成 "Q<emType>"，age = fTime
    if GameOffset("QItemFactOffset") {
        qb := GameReadBuf(GameProcHandle(pid), charBase + GameOffset("QItemFactOffset"), 12)
        if qb {
            qt := NumGet(qb, 0, "Int"), qf := NumGet(qb, GameOffset("QItemFactTimeOffset"), "Float")
            if qt > 0 && qt < 1000 && qf = qf && qf >= 0 && qf <= 1000000
                out.Push({id: "Q" qt, age: qf})
        }
    }
    return out
}

; 背包視窗的分頁狀態（H-024）：{open: 視窗開著, page: 目前頁 1～5（0 = 讀不到 / 不確定）, count: 頁數, rows: 可用列數（0 = 讀不到）, btns: [{l,r,t,b}…]（每頁的圓形頁籤，遊戲畫面座標）}。
; 背包是 6 欄 × 50 列，視窗每次顯示 10 列 = 一頁；「目前頁」= 哪一個「選取中」圓點可見。
; 沒有這組位置資料（舊的位置檔 / 解析失敗）或讀不到回傳 ""。
ReadGameInvUi(pid) {
    global gameOffsets
    if !GameOffsetsReady(pid) || !GameOffset("InnerInterfaceRva") || !GameOffset("InnerInvWindowOffset") || !GameOffset("InvPageButtonOffset") || !GameOffset("InvPageButtonSetOffset")
        return ""
    h:=GameProcHandle(pid),base:=h ? GetGameModuleBase(pid,h) : 0
    if !base
        return ""
    inner:=base+GameOffset("InnerInterfaceRva")
    vf:=GameReadNum(h,inner,"Ptr"),vfOk:=false
    if vf=""
        return ""
    for s in StrSplit(gameOffsets.Get("InnerInterfaceVftableRvas",""),"|")
        if s!="" && Integer(s)=vf-base
            vfOk:=true
    if !vfOk
        return ""
    iw:=GameReadNum(h,inner+GameOffset("InnerInvWindowOffset"),"Ptr")
    if iw="" || !iw
        return ""
    open:=GameReadNum(h,iw+GameOffset("UiVisibleOffset"),"UInt")=1
    pg:=GameReadNum(h,iw+GameOffset("InvWindowPageOffset"),"Ptr")
    cnt:=GameOffset("InvPageButtonCount")
    if pg="" || !pg || cnt<1 || cnt>8
        return ""
    res:={open:open,page:0,count:cnt,rows:0,btns:[]}
    ; 可用的列數（背包最下面幾列是打叉的、不能放東西：實機 46 列 = 第 5 頁只有前 6 列可用）；讀不到 = 0
    if GameOffset("InvPageUsableRowsOffset") {
        ur:=GameReadNum(h,pg+GameOffset("InvPageUsableRowsOffset"),"UInt")
        if ur!="" && ur>=1 && ur<=cnt*10
            res.rows:=ur
    }
    selected:=0
    Loop cnt {
        i:=A_Index-1
        bs:=GameReadNum(h,pg+GameOffset("InvPageButtonSetOffset")+i*8,"Ptr")
        b:=GameReadNum(h,pg+GameOffset("InvPageButtonOffset")+i*8,"Ptr")
        if bs="" || b="" || !bs || !b
            return ""
        sv:=GameReadNum(h,bs+GameOffset("UiVisibleOffset"),"UInt")
        if sv=""
            return ""
        if sv=1
            selected:=selected ? -1 : A_Index   ; 兩個以上同時選取 = 資料不可信
        rb:=GameReadBuf(h,b+GameOffset("UiRectOffset"),16)
        r:=0
        if rb {
            l:=NumGet(rb,0,"Float"),rt:=NumGet(rb,4,"Float"),t:=NumGet(rb,8,"Float"),bt:=NumGet(rb,12,"Float")
            ok:=true
            for v in [l,rt,t,bt]
                if !IsNumber(v) || v!=v || Abs(v)>5000
                    ok:=false
            ; 遊戲畫面是 1024x768：頁籤一定在畫面裡（位置偏移錯了讀到的垃圾值不能拿去點）
            if ok && rt>l && bt>t && l>=0 && rt<=1100 && t>=0 && bt<=800
                r:={l:l,r:rt,t:t,b:bt}
        }
        res.btns.Push(r)
    }
    res.page:=selected>0 ? selected : 0
    return res
}

; 道具快捷欄（畫面下方 6 格）：[{act, key: "主-子" 或 ""（空格）}…]；沒有這組位置資料 / 讀不到回傳 ""。
; act = 1 才是道具；其他（0 = 空）不是。
ReadGameActionQuick(pid) {
    if !GameOffsetsReady(pid) || !GameOffset("ActionQuickOffset") || !GameOffset("ActionQuickSize") || !GameOffset("ActionSlotIdOffset")
        return ""
    cb:=GameCharBase(pid)
    cnt:=GameOffset("ActionQuickCount"),sz:=GameOffset("ActionQuickSize")
    if !cb || cnt<1 || cnt>12 || sz<8 || sz>64
        return ""
    h:=GameProcHandle(pid)
    buf:=GameReadBuf(h,cb+GameOffset("ActionQuickOffset"),cnt*sz)
    if !buf
        return ""
    out:=[]
    Loop cnt {
        at:=(A_Index-1)*sz
        act:=NumGet(buf,at+GameOffset("ActionSlotActOffset"),"UShort")
        mid:=NumGet(buf,at+GameOffset("ActionSlotIdOffset"),"UShort"),sid:=NumGet(buf,at+GameOffset("ActionSlotIdOffset")+2,"UShort")
        out.Push({act:act,key:(act=1 && !(mid=0xFFFF && sid=0xFFFF)) ? mid "-" sid : ""})
    }
    return out
}

; 道具快捷欄各格「現在設定的鍵」（遊戲裡「快捷鍵設定」可以改成別的鍵，所以不能假設是 Q W E A S D）。
; 回傳 ["q","w","e","a","s","d"]（認不得的掃描碼 = ""）；沒有這組位置資料 / 讀不到回傳 ""。
ReadGameQuickKeys(pid) {
    static names:=Map(2,"1",3,"2",4,"3",5,"4",6,"5",7,"6",8,"7",9,"8",10,"9",11,"0",
        16,"q",17,"w",18,"e",19,"r",20,"t",21,"y",22,"u",23,"i",24,"o",25,"p",
        30,"a",31,"s",32,"d",33,"f",34,"g",35,"h",36,"j",37,"k",38,"l",
        44,"z",45,"x",46,"c",47,"v",48,"b",49,"n",50,"m",
        59,"F1",60,"F2",61,"F3",62,"F4",63,"F5",64,"F6",65,"F7",66,"F8",67,"F9",68,"F10",87,"F11",88,"F12")
    if !GameOffsetsReady(pid) || !GameOffset("QuickKeysRva")
        return ""
    cnt:=GameOffset("QuickKeysCount")
    h:=GameProcHandle(pid),base:=h ? GetGameModuleBase(pid,h) : 0
    if !base || cnt<1 || cnt>12
        return ""
    buf:=GameReadBuf(h,base+GameOffset("QuickKeysRva"),cnt*4)
    if !buf
        return ""
    out:=[]
    Loop cnt
        out.Push(names.Get(NumGet(buf,(A_Index-1)*4,"Int"),""))
    return out
}

; 寵物現在是否在外面：1 = 在外面，0 = 不在，讀不到（舊位置檔 / 讀取失敗）回傳 -1。
ReadGamePetOut(pid) {
    if !GameOffsetsReady(pid) || !GameOffset("PetValidOffset")
        return -1
    inst:=GameGaeaBase(pid)
    v:=inst ? GameReadNum(GameProcHandle(pid),inst+GameOffset("PetValidOffset"),"UChar") : ""
    return v="" ? -1 : (v ? 1 : 0)
}
; 登入 / 選伺服器 / 選角畫面的控制項（COuterInterface 各頁）：每個控制項的名稱、位置（遊戲畫面座標，1024x768）與是否顯示。
; 回傳 {pages: Map(頁名 → {ptr,shown,l,r,t,b}), ctrls: [{page,depth,name,shown,l,r,t,b}]}；
; 沒有這組位置資料 / 物件還沒建立 / 已進入遊戲（頁面被遊戲釋放）時 pages 為空；讀不到回傳 ""。
; shown = 這個控制項自己和上面每一層都是顯示狀態（實際看得到）。
ReadGameLoginUi(pid, depth:=2) {
    static pageKeys:=["Server","Login","Char","CharLeft","SecPass","Message","Modal","Wait"]
    if !GameOffsetsReady(pid) || !GameOffset("OuterInstanceRva") || !GameOffset("UiChildListOffset")
        return ""
    h:=GameProcHandle(pid),base:=h ? GetGameModuleBase(pid,h) : 0
    if !base
        return ""
    inst:=base+GameOffset("OuterInstanceRva")
    vf:=GameReadNum(h,inst,"Ptr")
    if vf=""
        return ""
    ok:=false
    for s in StrSplit(gameOffsets.Get("OuterVftableRvas",""),"|")
        if s!="" && Integer(s)=vf-base
            ok:=true
    if !ok
        return ""
    res:={pages:Map(),ctrls:[]}
    for key in pageKeys {
        po:=GameOffset("Outer" key "PageOffset")
        if !po
            continue
        p:=GameReadNum(h,inst+po,"Ptr")
        if p="" || !p
            continue
        r:=GameUiRect(h,p)
        if !r
            continue
        shown:=GameReadNum(h,p+GameOffset("UiVisibleOffset"),"UChar")
        res.pages[key]:={ptr:p,shown:shown!="" && shown!=0,l:r.l,r:r.r,t:r.t,b:r.b}
        GameUiWalk(h,p,key,0,depth,res.pages[key].shown,res.ctrls)
    }
    return res
}

GameUiRect(h, p) {
    b:=GameReadBuf(h,p+GameOffset("UiRectOffset"),16)
    if !b
        return 0
    l:=NumGet(b,0,"Float"),r:=NumGet(b,4,"Float"),t:=NumGet(b,8,"Float"),bt:=NumGet(b,12,"Float")
    for v in [l,r,t,bt]
        if !IsNumber(v) || v!=v || Abs(v)>5000
            return 0
    return r>=l && bt>=t ? {l:l,r:r,t:t,b:bt} : 0
}

GameUiWalk(h, p, page, d, maxDepth, parentShown, out) {
    if d>=maxDepth
        return
    head:=GameReadNum(h,p+GameOffset("UiChildListOffset"),"Ptr"),cnt:=GameReadNum(h,p+GameOffset("UiChildListOffset")+8,"UInt64")
    if !head || cnt="" || cnt>300
        return
    node:=GameReadNum(h,head,"Ptr")
    Loop cnt {
        if !node || node=head
            break
        c:=GameReadNum(h,node+16,"Ptr")
        if c {
            r:=GameUiRect(h,c)
            sv:=GameReadNum(h,c+GameOffset("UiVisibleOffset"),"UChar")
            shown:=parentShown && sv!="" && sv!=0
            if r {
                nm:=""
                try nm:=ReadStdString(h,c+GameOffset("UiNameOffset"),"CP950")
                out.Push({page:page,depth:d+1,name:nm,shown:shown,l:r.l,r:r.r,t:r.t,b:r.b,ptr:c})
            }
            GameUiWalk(h,c,page,d+1,maxDepth,shown,out)
        }
        node:=GameReadNum(h,node,"Ptr")
    }
}
; 選角畫面的角色清單（DxGlobalStage.m_LobyStage）：{inLoby, count, selected, chars:[{id,name,level}]}。
; inLoby = 目前的遊戲階段就是大廳（登入 / 選角）；selected = 目前選到的格（從 0 開始，沒選 / 不明為 -1）。
; 沒有這組位置資料 / 讀不到回傳 ""。
ReadGameLobyChars(pid) {
    if !GameOffsetsReady(pid) || !GameOffset("GlobalStageRva") || !GameOffset("LobyCharInfoOffset")
        return ""
    h:=GameProcHandle(pid),base:=h ? GetGameModuleBase(pid,h) : 0
    if !base
        return ""
    gs:=base+GameOffset("GlobalStageRva")
    active:=GameReadNum(h,gs+GameOffset("GlobalStageActiveOffset"),"Ptr")
    loby:=gs+GameOffset("GlobalStageLobyOffset")
    if active=""
        return ""
    n:=GameReadNum(h,loby+GameOffset("LobyCharCountOffset"),"Int")
    sel:=GameReadNum(h,loby+GameOffset("LobyCharSelectOffset"),"UInt")
    if n="" || n<0 || n>16
        return ""
    res:={inLoby:active=loby,count:n,selected:(sel!="" && sel<n ? sel : -1),chars:[]}
    sz:=GameOffset("LobyCharInfoSize")
    Loop n {
        at:=loby+GameOffset("LobyCharInfoOffset")+(A_Index-1)*sz
        nb:=GameReadBuf(h,at+GameOffset("LobyCharNameOffset"),33)
        if !nb
            return ""
        res.chars.Push({id:GameReadNum(h,at+GameOffset("LobyCharIdOffset"),"UInt"),name:StrGet(nb,"CP950"),level:GameReadNum(h,at+GameOffset("LobyCharLevelOffset"),"UShort")})
    }
    return res
}
ReadGameCharClass(pid) {
    charBase:=GameCharBase(pid)
    v:=charBase ? GameReadNum(GameProcHandle(pid),charBase+GameOffset("CharClassOffset"),"UInt") : ""
    return v="" ? 0 : v
}

; 目前所在地圖（GLGaeaClient.m_pLandMClient → m_sMapID，"主ID-子ID"）；讀不到回傳 ""。
ReadGameMapId(pid) {
    inst:=GameGaeaBase(pid)
    if !inst
        return ""
    hProc:=GameProcHandle(pid)
    land:=GameReadNum(hProc,inst+GameOffset("LandPtrOffset"),"Ptr")
    if !land
        return ""
    buf:=GameReadBuf(hProc,land+GameOffset("LandMapIdOffset"),4)
    return buf ? NumGet(buf,0,"UShort") "-" NumGet(buf,2,"UShort") : ""
}

; 地圖資訊（GLMapList.m_MapList → SMAPNODE）：{name: 地圖名稱, peace: 是否安全區}；查不到回傳 0。
; m_MapList 是 stdext::hash_map，走訪它內部的 std::list（約數百張地圖，只在換地圖時查一次並快取）。
GameMapInfo(pid, mapId) {
    global gameMapInfoCache
    if mapId=""
        return 0
    if gameMapInfoCache.Has(mapId)
        return gameMapInfoCache[mapId]
    inst:=GameGaeaBase(pid)
    if !inst || !GameOffset("MapListOffset")
        return 0
    parts:=StrSplit(mapId,"-")
    hProc:=GameProcHandle(pid)
    list:=inst+GameOffset("MapListOffset")
    head:=GameReadNum(hProc,list,"Ptr"),size:=GameReadNum(hProc,list+8,"Ptr")
    if !head || size="" || size>20000
        return 0
    nodeOff:=GameOffset("MapNodeValueOffset")+GameOffset("MapPairNodeOffset")
    node:=GameReadNum(hProc,head,"Ptr")
    Loop size {
        if !node || node=head
            break
        idBuf:=GameReadBuf(hProc,node+nodeOff+GameOffset("MapIdInNodeOffset"),4)
        if !idBuf
            return 0
        if NumGet(idBuf,0,"UShort")=Integer(parts[1]) && NumGet(idBuf,2,"UShort")=Integer(parts[2]) {
            name:=Trim(ReadStdString(hProc,node+nodeOff+GameOffset("MapNameOffset"),"CP950"))
            ; 名稱若是字串表代碼（英數字），改查顯示文字
            if RegExMatch(name,"^[\x21-\x7E]+$") && (text:=GameStringLookup(pid,name))!=""
                name:=text
            peace:=GameReadNum(hProc,node+nodeOff+GameOffset("MapPeaceZoneOffset"),"UShort")
            info:={name:name,peace:peace!="" && (peace&0xFF)!=0}
            if name!=""
                gameMapInfoCache[mapId]:=info
            return info
        }
        node:=GameReadNum(hProc,node,"Ptr")
    }
    return 0
}

; 選擇盒 / 禮盒內容，依遊戲中顯示的順序：["主ID-子ID", …]。
; 先讀 SITEM.sBox.sITEMS；沒有內容時改讀 SITEM.sRandomBox.vecBOX（選擇盒可能用這個清單）。
GameBoxItems(pid, key) {
    node:=GameItemNode(pid,key)
    if !node
        return []
    hProc:=GameProcHandle(pid)
    item:=node+GameOffset("ItemNodeItemOffset")
    items:=[]
    count:=GameOffset("BoxItemCount"),size:=GameOffset("BoxItemSize")
    buf:=(count && size) ? GameReadBuf(hProc,item+GameOffset("BoxItemsOffset"),count*size) : 0
    if buf {
        Loop count {
            mid:=NumGet(buf,(A_Index-1)*size,"UShort"),sid:=NumGet(buf,(A_Index-1)*size+2,"UShort")
            if mid!=0xFFFF && (mid || sid)
                items.Push(mid "-" sid)
        }
    }
    if items.Length || !GameOffset("RandomItemSize")
        return items
    ; std::vector：+0 開頭指標、+8 結尾指標
    vec:=item+GameOffset("RandomBoxVecOffset")
    first:=GameReadNum(hProc,vec,"Ptr"),last:=GameReadNum(hProc,vec+8,"Ptr")
    size:=GameOffset("RandomItemSize")
    if !first || !last || last<=first || Mod(last-first,size) || (last-first)//size>32
        return items
    buf:=GameReadBuf(hProc,first,last-first)
    if !buf
        return items
    idOff:=GameOffset("RandomItemIdOffset")
    Loop (last-first)//size {
        mid:=NumGet(buf,(A_Index-1)*size+idOff,"UShort"),sid:=NumGet(buf,(A_Index-1)*size+idOff+2,"UShort")
        if mid!=0xFFFF
            items.Push(mid "-" sid)
    }
    return items
}

; 角色名稱（GLCharacter.m_szName，Big5）；角色尚未載入時回傳 ""。
ReadGameCharName(pid) {
    charBase:=GameCharBase(pid)
    buf:=charBase ? GameReadBuf(GameProcHandle(pid),charBase+GameOffset("CharNameOffset"),33) : 0
    return buf ? Trim(StrGet(buf,33,"CP950")) : ""
}

; 道具是不是禮盒 / 箱子（打開後會變出其他道具）：依道具類型，名稱含禮包 / 禮盒 / 選擇盒 也算。
GameItemIsBox(pid, key) {
    global itemTypeCache,GAME_BOX_ITEM_TYPES
    if !itemTypeCache.Has(key) && GameOffset("ItemTypeOffset") {
        node:=GameItemNode(pid,key)
        v:=node ? GameReadNum(GameProcHandle(pid),node+GameOffset("ItemNodeItemOffset")+GameOffset("ItemTypeOffset"),"UInt") : ""
        if v!=""
            itemTypeCache[key]:=v
    }
    if itemTypeCache.Has(key) && GAME_BOX_ITEM_TYPES.Has(itemTypeCache[key])
        return true
    name:=GameItemName(key,pid)
    return InStr(name,"禮包") || InStr(name,"禮盒") || InStr(name,"選擇盒")
}

; 裝備部位（SITEM.sSuitOp.emSuit：0 頭、1 上衣、2 褲子、3 手套、4 鞋子、5 手持武器…）；讀不到回傳 -1。
GameItemSuit(pid, key) {
    global itemSuitCache
    if itemSuitCache.Has(key)
        return itemSuitCache[key]
    node:=GameItemNode(pid,key)
    v:=node ? GameReadNum(GameProcHandle(pid),node+GameOffset("ItemNodeItemOffset")+GameOffset("SuitOffset"),"UInt") : ""
    if v=""
        return -1
    itemSuitCache[key]:=v
    return v
}

; 道具的時間限制（秒，SITEM.sDrugOp.tTIME_LMT）；0 = 沒有限制或讀不到。
GameItemTimeLimit(pid, key) {
    global itemTimeLimitCache
    if itemTimeLimitCache.Has(key)
        return itemTimeLimitCache[key]
    node:=GameItemNode(pid,key)
    v:=node ? GameReadNum(GameProcHandle(pid),node+GameOffset("ItemNodeItemOffset")+GameOffset("ItemTimeLimitOffset"),"Int64") : ""
    if v=""
        return 0
    itemTimeLimitCache[key]:=v
    return v
}

LoadItemNameCache() {
    global itemNameCache,ITEM_NAMES_INI,ITEM_NAME_KEY_PATTERN
    itemNameCache:=Map()
    if !FileExist(ITEM_NAMES_INI)
        return
    try section:=IniRead(ITEM_NAMES_INI,"Names")
    catch
        return
    for line in StrSplit(section,"`n","`r") {
        pos:=InStr(line,"=")
        if !pos
            continue
        name:=SubStr(line,pos+1)
        ; v1.3.13.0 初版存的是字串表 key（IN_xxx_yyy），略過讓它重新查出中文名稱。
        if !RegExMatch(name,ITEM_NAME_KEY_PATTERN)
            itemNameCache[SubStr(line,1,pos-1)]:=name
    }
}

; 道具名稱：先查快取；沒有就從任一隻已登入角色的遊戲記憶體讀取（GLItemMan → GLStringTable）。
; 只有查到中文名稱才寫入快取檔；暫時只有 key 時回傳 key，下次再試。
GameItemName(key,pid:=0) {
    global itemNameCache,ITEM_NAMES_INI,profiles,ITEM_NAME_KEY_PATTERN
    if itemNameCache.Has(key)
        return itemNameCache[key]
    parts:=StrSplit(key,"-")
    if parts.Length!=2
        return ""
    if !pid {
        for p in profiles
            if p.pid && ProfileGameAlive(p) && GameOffsetsReady(p.pid) {
                pid:=p.pid
                break
            }
    }
    name:=pid ? ReadGameItemName(pid,Integer(parts[1]),Integer(parts[2])) : ""
    if RegExMatch(name,ITEM_NAME_KEY_PATTERN) {
        display:=GameStringLookup(pid,name)
        if display=""
            return name
        name:=display
    }
    if name!="" {
        itemNameCache[key]:=name
        EnsureUnicodeIni(ITEM_NAMES_INI)
        try IniWrite name,ITEM_NAMES_INI,"Names",key
    }
    return name
}

; MSVC std::string：+0 內嵌緩衝或指標、+0x10 長度、+0x18 容量（容量 ≥ 16 時資料在堆積）。
ReadStdString(hProc,addr,encoding:="CP950") {
    sb:=GameReadBuf(hProc,addr,32)
    if !sb
        return ""
    len:=NumGet(sb,0x10,"UPtr"),cap:=NumGet(sb,0x18,"UPtr")
    if len=0 || len>512 || cap<len
        return ""
    if cap<16
        return StrGet(sb,len,encoding)
    textBuf:=GameReadBuf(hProc,NumGet(sb,0,"Ptr"),len)
    return textBuf ? StrGet(textBuf,len,encoding) : ""
}

; 依 GLStringTable 的字串表（std::map，以 key 字典序排序）查顯示名稱；約 15 次讀取。
; mapKey："ItemStringMapOffset" = 道具 / 地圖、"CrowStringMapOffset" = 怪物（v1.3.18.9）。
GameStringLookup(pid,key,mapKey:="ItemStringMapOffset") {
    global STDMAP_NODE_ISNIL,STDMAP_STR_KEY,STDMAP_STR_VALUE,STDMAP_MAX_DEPTH
    if !GameOffsetsReady(pid) || !GameOffset("StringTableInstanceRva")
        return ""
    if mapKey!="ItemStringMapOffset" && !GameOffset(mapKey)
        return ""
    hProc:=GameProcHandle(pid)
    base:=hProc ? GetGameModuleBase(pid,hProc) : 0
    if !base
        return ""
    mapObj:=base+GameOffset("StringTableInstanceRva")+GameOffset(mapKey)
    head:=GameReadNum(hProc,mapObj,"Ptr")
    if !head
        return ""
    node:=GameReadNum(hProc,head+8,"Ptr")
    depth:=0
    while node && node!=head && depth<STDMAP_MAX_DEPTH {
        nb:=GameReadBuf(hProc,node,0x20)
        if !nb || NumGet(nb,STDMAP_NODE_ISNIL,"UChar")
            return ""
        nodeKey:=ReadStdString(hProc,node+STDMAP_STR_KEY,"CP0")
        if nodeKey=""
            return ""
        cmp:=StrCompare(key,nodeKey,true)
        if cmp=0
            return Trim(ReadStdString(hProc,node+STDMAP_STR_VALUE,"CP950"))
        node:=cmp<0 ? NumGet(nb,0,"Ptr") : NumGet(nb,0x10,"Ptr")
        depth+=1
    }
    return ""
}

ReadGameItemName(pid,mid,sid) {
    node:=GameItemNode(pid,mid "-" sid)
    if !node
        return ""
    return Trim(ReadStdString(GameProcHandle(pid),node+GameOffset("ItemNodeItemOffset")+GameOffset("ItemNameOffset")))
}

; GLItemMan.m_ppItem[主ID][子ID] → CItemNode 位址；不存在回傳 0。
GameItemNode(pid,key) {
    parts:=StrSplit(key,"-")
    if parts.Length!=2
        return 0
    mid:=Integer(parts[1]),sid:=Integer(parts[2])
    limit:=GameOffset("ItemIdLimit")
    if !GameOffsetsReady(pid) || mid>=limit || sid>=limit
        return 0
    hProc:=GameProcHandle(pid)
    base:=hProc ? GetGameModuleBase(pid,hProc) : 0
    if !base
        return 0
    pp:=GameReadNum(hProc,base+GameOffset("ItemManInstanceRva")+GameOffset("ItemManPpItemOffset"),"Ptr")
    row:=pp ? GameReadNum(hProc,pp+mid*8,"Ptr") : ""
    node:=row ? GameReadNum(hProc,row+sid*8,"Ptr") : ""
    return node ? node : 0
}

; IniWrite 只有在檔案本身是 UTF-16 時才能正確寫入中文角色名稱 / 道具名稱。
EnsureUnicodeIni(path) {
    if FileExist(path)
        return
    SplitPath path,,&dir
    if dir!="" && !DirExist(dir)
        DirCreate dir
    FileOpen(path,"w","UTF-16").Close()
}
