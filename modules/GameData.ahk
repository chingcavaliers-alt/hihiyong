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
global GAME_OFFSETS_TOOL_VERSION := 31
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
; 沒有 Game.pdb（或 pdb 解析失敗）時的後備：tools\derive_game_offsets.py 拿上一個已知版本的位置資料，從執行中的遊戲推算新位置
global gameOffsetsResolveKind := "pdb"   ; 目前背景工作是 "pdb"（Game.pdb 解析）還是 "derive"（遊戲記憶體推算）
global gameOffsetsDeriveTried := Map()   ; build → 上次開始推算的 A_TickCount
global gameOffsetsRefKept := Map(), gameOffsetsStaticTried := Map()   ; build → 已保留參考 exe / 已啟動離線比對
global GAME_OFFSETS_DERIVE_RETRY_MS := 300000
; 沒有這個版本的位置資料時，從 GitHub（offsets_db\<Build>.ini）補抓；還沒上傳就每 10 分鐘再試
global GAME_OFFSETS_REMOTE_RETRY_MS := 600000
global gameOffsetsRemoteReq := 0
global gameOffsetsRemoteBuild := ""
global gameOffsetsRemotePid := 0
global gameOffsetsRemoteStart := 0
global gameOffsetsRemoteTried := Map()  ; build → 上次開始下載的 A_TickCount
global gameOffsetsWaitBuild := ""       ; 目前在等位置資料的版本（空 = 沒在等）

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

; 隨程式附上的位置資料（offsets_db\<Build>.ini，更新時會換成作者驗證過的版本）和使用中的位置檔不一樣時，改用 offsets_db 的。
; 原本更新只換 offsets_db 的檔案，使用中的位置檔（HIHIYONG_GameOffsets.ini）要等遊戲版本再變才會重套：
; 本機推算出錯的位置（2026-11-09 另一台電腦的快捷鍵位置差 8 位元組，按錯鍵）就算更新到正確的檔案也一直留著。
global gameOffsetsDbSynced := false
GameOffsetsSyncFromDb() {
    global gameOffsets,GAME_OFFSETS_INI,GAME_OFFSETS_DB_DIR,GAME_OFFSETS_TOOL_VERSION,gameOffsetsDbSynced
    if gameOffsetsDbSynced
        return false
    gameOffsetsDbSynced:=true
    if !GameOffsetsLoadedOk()
        return false
    build:=gameOffsets.Get("Build","")
    src:=GAME_OFFSETS_DB_DIR "\" build ".ini"
    if build="" || !FileExist(src)
        return false
    cand:=Map()
    try {
        for line in StrSplit(IniRead(src,"GameOffsets"),"`n","`r") {
            pos:=InStr(line,"=")
            if pos
                cand[SubStr(line,1,pos-1)]:=SubStr(line,pos+1)
        }
    }
    if cand.Get("Status","")!="OK" || cand.Get("Build","")!=build
        || !IsInteger(cand.Get("ToolVersion","")) || Integer(cand["ToolVersion"])<GAME_OFFSETS_TOOL_VERSION
        return false
    diff:=""
    for k,v in cand {
        if k="ResolvedAt" || k="DerivedFrom"
            continue
        if gameOffsets.Get(k,"")!=v
            diff.=(diff="" ? "" : "、") k
    }
    if diff=""
        return false
    try FileCopy(src,GAME_OFFSETS_INI,true)
    catch as err {
        EventLog("GLOBAL","GAME_OFFSETS_DB_FAIL","位置資料不同步但無法套用 " build "：" err.Message)
        return false
    }
    gameOffsets:=cand
    EventLog("GLOBAL","GAME_OFFSETS_SYNC","使用中的位置檔和附上的 " build " 不同（" diff "），已改用附上的")
    return true
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
    global gameOffsetsWaitBuild
    if GameOffsetsLoadedOk() && gameOffsets.Has("Build") && gameOffsets["Build"]=build {
        if gameOffsetsWaitBuild=build
            gameOffsetsWaitBuild:=""
        GameOffsetsKeepRef(pid,build)
        return true
    }
    ; 沒有 Game.pdb 的電腦：先找隨程式附上的「已知版本」位置資料
    if GameOffsetsUseKnownBuild(build) {
        gameOffsetsWaitBuild:=""
        GameOffsetsKeepRef(pid,build)
        return true
    }
    gameOffsetsWaitBuild:=build
    GameOffsetsStartStatic(pid,build)
    StartGameOffsetsResolve(pid,build)
    return false
}

; ---------------------------------------------------------------- 離線比對 game.exe（不用登入）
; 每個已有位置資料的版本，把它的 game.exe 留一份在 game_ref\<版本>.exe（只留最新 3 份，不隨發佈包 / 更新發出）。
; 下次遊戲更新、新版位置資料還沒有時，tools\static_offsets.py 拿最新的參考 exe 和新 exe 比對，
; 先算出「候選」位置（game_ref\<新版>.static.ini，不會被採用）；等有人登入、由遊戲推算完成後，兩邊互相核對並寫進日誌。
GameOffsetsKeepRef(pid,build) {
    global GAME_OFFSETS_DB_DIR,gameOffsetsRefKept
    if gameOffsetsRefKept.Has(build) || !RegExMatch(build,"^[0-9A-F]+-[0-9A-F]*[1-9A-F][0-9A-F]*\z")
        return
    gameOffsetsRefKept[build]:=1
    dir:=A_ScriptDir "\game_ref",dst:=dir "\" build ".exe"
    exe:=""
    try exe:=ProcessGetPath(pid)
    if exe="" || FileExist(dst) || !FileExist(GAME_OFFSETS_DB_DIR "\" build ".ini")
        return
    try {
        DirCreate dir
        FileCopy exe,dst ".part",true
        FileMove dst ".part",dst,true
        names:=[]
        Loop Files dir "\*.exe"
            names.Push(A_LoopFileName)
        if names.Length>3 {
            names:=GameOffsetsSortNames(names)
            Loop names.Length-3 {
                SplitPath names[A_Index],,,,&nm
                try FileDelete dir "\" names[A_Index]
                try FileDelete dir "\" nm ".static.ini"
            }
        }
        EventLog("GLOBAL","GAME_OFFSETS_REF","已保留版本 " build " 的 game.exe 當離線比對參考")
    }
}

GameOffsetsSortNames(names) {
    s:=""
    for n in names
        s.=n "`n"
    return StrSplit(Sort(RTrim(s,"`n")),"`n")
}

GameOffsetsReadMap(path) {
    m:=Map()
    try {
        for line in StrSplit(IniRead(path,"GameOffsets"),"`n","`r") {
            pos:=InStr(line,"=")
            if pos
                m[SubStr(line,1,pos-1)]:=SubStr(line,pos+1)
        }
    }
    return m
}

GameOffsetsStartStatic(pid,build) {
    global gameOffsetsStaticTried,GAME_OFFSETS_DB_DIR
    if gameOffsetsStaticTried.Has(build) || !RegExMatch(build,"^[0-9A-F]+-[0-9A-F]*[1-9A-F][0-9A-F]*\z")
        return
    gameOffsetsStaticTried[build]:=1
    python:=FindPythonLauncher()
    exe:=""
    try exe:=ProcessGetPath(pid)
    tool:=A_ScriptDir "\tools\static_offsets.py",dir:=A_ScriptDir "\game_ref"
    if python="" || exe="" || !FileExist(tool) || !DirExist(dir)
        return
    names:=[]
    Loop Files dir "\*.exe"
        if FileExist(GAME_OFFSETS_DB_DIR "\" SubStr(A_LoopFileName,1,-4) ".ini")
            names.Push(A_LoopFileName)
    if !names.Length
        return
    names:=GameOffsetsSortNames(names)
    refBuild:=SubStr(names[names.Length],1,-4)
    out:=dir "\" build ".static.ini",log:=dir "\" build ".static.log"
    cmd:=A_ComSpec ' /c ' python ' -I "' tool '" --ref-exe "' dir "\" refBuild '.exe" --ref-ini "' GAME_OFFSETS_DB_DIR "\" refBuild '.ini" --exe "' exe '" --out "' out '" > "' log '" 2>&1'
    try Run(cmd,A_ScriptDir,"Hide")
    catch
        return
    EventLog("GLOBAL","GAME_OFFSETS_STATIC","版本 " build "｜用 " refBuild " 的 game.exe 離線比對推算候選位置（不用登入，只當佐證）")
}

; 遊戲推算完成後：和離線候選互相核對，結果寫進日誌。
GameOffsetsCompareStatic(build) {
    global gameOffsets
    cand:=A_ScriptDir "\game_ref\" build ".static.ini"
    if !FileExist(cand)
        return
    c:=GameOffsetsReadMap(cand)
    if c.Get("Status","")!="OK" {
        EventLog("GLOBAL","GAME_OFFSETS_STATIC_CMP","離線候選：" c.Get("Error","沒有結果") "（略過核對）")
        return
    }
    diff:="",n:=0
    for k,v in c {
        if !RegExMatch(k,"Rvas?$")
            continue
        n++
        if !gameOffsets.Has(k) || gameOffsets[k]!=v
            diff.=" " k
    }
    EventLog("GLOBAL","GAME_OFFSETS_STATIC_CMP",diff="" ? "離線候選與遊戲推算的 " n " 項位置完全一致" : "離線候選與遊戲推算不一致：" Trim(diff))
}

; 登入座標 / 開始監控被擋時要顯示的說明：遊戲剛更新、還在等新版位置資料時回傳說明文字，否則空字串。
GameOffsetsWaitingText() {
    global gameOffsetsWaitBuild
    if gameOffsetsWaitBuild=""
        return ""
    return "遊戲剛更新（版本 " gameOffsetsWaitBuild "），正在等待新版的遊戲資料位置。`n`n"
        . "程式會自動到 GitHub 下載，約每 10 分鐘重試一次；也可以按畫面上方的「檢查更新」。`n"
        . "下載到之後就能使用，不需要重新校正座標。"
}

; 下載來的位置資料是否可信：UTF-16（含 BOM）、Status=OK、Build 與要的版本相同、工具版本夠新。
GameOffsetsRemoteValid(text, build) {
    global GAME_OFFSETS_TOOL_VERSION
    if !RegExMatch(text,"m)^Status=OK\s*$") || !RegExMatch(text,"m)^Build=(\S+)\s*$",&mb) || mb[1]!=build
        return false
    return RegExMatch(text,"m)^ToolVersion=(\d+)\s*$",&mt) && Integer(mt[1])>=GAME_OFFSETS_TOOL_VERSION
}

; 非同步下載（不卡住管理程式）；回傳 true = 已經開始或正在下載，呼叫端先不要走 Game.pdb 解析。
GameOffsetsFetchRemote(pid, build) {
    global gameOffsetsRemoteReq,gameOffsetsRemoteBuild,gameOffsetsRemotePid,gameOffsetsRemoteStart
    global gameOffsetsRemoteTried,GAME_OFFSETS_REMOTE_RETRY_MS
    if IsObject(gameOffsetsRemoteReq)
        return gameOffsetsRemoteBuild=build
    if !RegExMatch(build,"^[0-9A-F]+-[0-9A-F]*[1-9A-F][0-9A-F]*\z")
        return false
    last:=gameOffsetsRemoteTried.Get(build,0)
    if last && A_TickCount-last<GAME_OFFSETS_REMOTE_RETRY_MS
        return false
    gameOffsetsRemoteTried[build]:=A_TickCount
    repo:="chingcavaliers-alt/hihiyong"   ; 與 Updater.ahk 的 UPDATE_REPO 相同；測試環境沒有那個變數
    try repo:=%"UPDATE_REPO"%
    try {
        gameOffsetsRemoteReq:=ComObject("WinHttp.WinHttpRequest.5.1")
        gameOffsetsRemoteReq.Open("GET","https://raw.githubusercontent.com/" repo "/main/offsets_db/" build ".ini?t=" A_TickCount,true)
        gameOffsetsRemoteReq.SetRequestHeader("Cache-Control","no-cache")
        gameOffsetsRemoteReq.Send()
    } catch {
        gameOffsetsRemoteReq:=0
        return false
    }
    gameOffsetsRemoteBuild:=build,gameOffsetsRemotePid:=pid,gameOffsetsRemoteStart:=A_TickCount
    EventLog("GLOBAL","GAME_OFFSETS_REMOTE","本機沒有版本 " build " 的位置資料｜向 GitHub 查詢")
    AddRecentEvent("🌐 遊戲版本 " build " 沒有位置資料，正在向 GitHub 下載")
    SetTimer GameOffsetsRemotePoll,300
    return true
}

GameOffsetsRemotePoll() {
    global gameOffsetsRemoteReq,gameOffsetsRemoteBuild,gameOffsetsRemotePid,gameOffsetsRemoteStart
    global gameOffsetsKnownTried,GAME_OFFSETS_DB_DIR,gameOffsets,profiles
    done:=false
    try done:=gameOffsetsRemoteReq.WaitForResponse(0)
    if !done && A_TickCount-gameOffsetsRemoteStart<20000
        return
    SetTimer GameOffsetsRemotePoll,0
    req:=gameOffsetsRemoteReq,build:=gameOffsetsRemoteBuild,pid:=gameOffsetsRemotePid
    gameOffsetsRemoteReq:=0
    ok:=false,code:=0
    try {
        code:=req.Status
        if code=200 {
            body:=req.ResponseBody,size:=body.MaxIndex()+1
            ; SAFEARRAY.pvData（x64 在 +16）；UTF-16 LE 要有 BOM（FF FE），否則 IniRead 讀不到
            p:=NumGet(ComObjValue(body),8+A_PtrSize,"Ptr")
            if size>4 && size<65536 && NumGet(p,0,"UShort")=0xFEFF {
                text:=StrGet(p+2,(size-2)//2,"UTF-16")
                if GameOffsetsRemoteValid(text,build) {
                    DirCreate GAME_OFFSETS_DB_DIR
                    tmp:=GAME_OFFSETS_DB_DIR "\" build ".ini.part"
                    f:=FileOpen(tmp,"w")
                    f.RawWrite(p,size)
                    f.Close()
                    FileMove tmp,GAME_OFFSETS_DB_DIR "\" build ".ini",true
                    ok:=true
                }
            }
        }
    }
    if ok {
        try gameOffsetsKnownTried.Delete(build)
        if GameOffsetsUseKnownBuild(build) {
            EventLog("GLOBAL","GAME_OFFSETS_REMOTE_OK","已從 GitHub 取得版本 " build " 的位置資料")
            AddRecentEvent("✓ 已從 GitHub 取得新版遊戲資料位置，不需要校正")
            for p in profiles {
                if !p.HasOwnProp("memHpStale") || !ProfileGameAlive(p)
                    continue
                p.memHpStale:=0,p.memHpArmed:=0,p.memHpPlausibleStreak:=0
                p.memHpUnarmedSince:=A_TickCount,p.memHpSuspectLogged:=0
            }
            return
        }
    }
    EventLog("GLOBAL","GAME_OFFSETS_REMOTE_MISS","GitHub 還沒有版本 " build " 的位置資料" (code ? "（回應 " code "）" : "（連不到 GitHub）") "｜10 分鐘後再試")
    StartGameOffsetsResolve(pid,build)
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
    global GAME_OFFSETS_TOOL_VERSION,gameOffsetsRemoteTried
    ; 先向 GitHub 要這個版本的位置資料；已經問過（或剛問完沒有）才輪到本機 Game.pdb 解析
    if GameOffsetsFetchRemote(pid,build)
        return
    tryKey:=build "#" GAME_OFFSETS_TOOL_VERSION
    if GameOffsetsResolving()
        return
    if gameOffsetsResolveTried.Has(tryKey) {   ; Game.pdb 那條路已經試過（失敗）：改用遊戲記憶體推算，過一陣子再試
        GameOffsetsStartDerive(pid,build)
        return
    }
    gameOffsetsResolveTried[tryKey]:=A_TickCount
    exe:=""
    try exe:=ProcessGetPath(pid)
    pdb:=RegExReplace(exe,"[^\\]+$","Game.pdb")
    if exe="" || !FileExist(pdb) {
        EventLog("GLOBAL","GAME_OFFSETS_UNAVAILABLE","找不到 Game.pdb，也沒有這個版本（" build "）的已知位置資料（" exe "）｜改由執行中的遊戲推算")
        GameOffsetsStartDerive(pid,build)
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
    gameOffsetsResolveKind:="pdb"
    EventLog("GLOBAL","GAME_OFFSETS_RESOLVE","game.exe 版本 " build "｜由 Game.pdb 解析 HP / 金幣 / 背包位置")
    AddRecentEvent("🔎 偵測到 game.exe 版本 " build "，正在由 Game.pdb 解析資料位置")
    SetTimer GameOffsetsResolveTick,500
}

; 沒有 Game.pdb 時：由執行中的遊戲推算（已知版本的位置資料 + 遊戲記憶體逐項驗證，全部對上才採用）。
; 需要至少一個已登入角色的遊戲視窗；角色還在登入畫面就會失敗，之後每 5 分鐘自動再試。
GameOffsetsStartDerive(pid,build) {
    global gameOffsetsResolvePid,gameOffsetsResolveBuild,gameOffsetsResolveStart,gameOffsetsResolveKind
    global gameOffsetsDeriveTried,GAME_OFFSETS_DERIVE_RETRY_MS,GAME_OFFSETS_INI,GAME_OFFSETS_DB_DIR,profiles
    if GameOffsetsResolving() || !RegExMatch(build,"^[0-9A-F]+-[0-9A-F]*[1-9A-F][0-9A-F]*\z")
        return
    last:=gameOffsetsDeriveTried.Get(build,0)
    if last && A_TickCount-last<GAME_OFFSETS_DERIVE_RETRY_MS
        return
    python:=FindPythonLauncher()
    exe:=""
    try exe:=ProcessGetPath(pid)
    if python="" || exe="" || !FileExist(A_ScriptDir "\tools\derive_game_offsets.py")
        return
    pids:=" --pid " pid
    for p in profiles {
        try {
            if p.pid && p.pid!=pid && ProfileGameAlive(p) && GameBuildOf(p.pid)=build
                pids.=" --pid " p.pid
        }
    }
    gameOffsetsDeriveTried[build]:=A_TickCount
    cmd:=python ' -I "' A_ScriptDir '\tools\derive_game_offsets.py" --exe "' exe '"' pids ' --out "' GAME_OFFSETS_INI '" --db "' GAME_OFFSETS_DB_DIR '"'
    newPid:=0
    try Run(cmd,A_ScriptDir,"Hide",&newPid)
    catch as err {
        EventLog("GLOBAL","GAME_OFFSETS_FAIL","無法執行推算工具：" err.Message)
        return
    }
    gameOffsetsResolvePid:=newPid
    gameOffsetsResolveBuild:=build
    gameOffsetsResolveStart:=A_TickCount
    gameOffsetsResolveKind:="derive"
    EventLog("GLOBAL","GAME_OFFSETS_DERIVE","game.exe 版本 " build "｜沒有 Game.pdb 可用，改由執行中的遊戲推算資料位置")
    AddRecentEvent("🔎 遊戲版本 " build " 沒有 Game.pdb，正在由執行中的遊戲推算資料位置")
    SetTimer GameOffsetsResolveTick,500
}

GameOffsetsResolveTick() {
    global gameOffsets,gameOffsetsResolvePid,gameOffsetsResolveBuild,gameOffsetsResolveStart,GAME_OFFSETS_RESOLVE_TIMEOUT_MS,profiles,gameOffsetsResolveKind
    if GameOffsetsResolving() {
        if A_TickCount-gameOffsetsResolveStart<GAME_OFFSETS_RESOLVE_TIMEOUT_MS
            return
        try ProcessClose gameOffsetsResolvePid
        EventLog("GLOBAL","GAME_OFFSETS_FAIL","解析逾時 " Floor(GAME_OFFSETS_RESOLVE_TIMEOUT_MS/1000) " 秒｜HP 改用動態校正")
    }
    SetTimer GameOffsetsResolveTick,0
    gameOffsetsResolvePid:=0
    if LoadGameOffsets() && gameOffsets["Build"]=gameOffsetsResolveBuild {
        EventLog("GLOBAL",gameOffsetsResolveKind="derive" ? "GAME_OFFSETS_DERIVED" : "GAME_OFFSETS_OK","Build=" gameOffsets["Build"] "｜Gaea=" gameOffsets["GaeaInstanceRva"] "｜HP=Char+" gameOffsets["HpNowOffset"] "｜Money=Char+" gameOffsets["MoneyOffset"]
            . (gameOffsetsResolveKind="derive" ? "｜由 " gameOffsets.Get("DerivedFrom","?") " 推算（沒有 Game.pdb）" : ""))
        AddRecentEvent("✓ 已取得新版遊戲資料位置（HP / 金幣 / 背包），不需要校正")
        if gameOffsetsResolveKind="derive"
            GameOffsetsCompareStatic(gameOffsets["Build"])
        ; 讓目前的 session 改用新位置，並重新走「連續讀到合理 HP 才啟用死亡判定」。
        for p in profiles {
            if !p.HasOwnProp("memHpStale") || !ProfileGameAlive(p)
                continue
            p.memHpStale:=0,p.memHpArmed:=0,p.memHpPlausibleStreak:=0
            p.memHpUnarmedSince:=A_TickCount,p.memHpSuspectLogged:=0
        }
    } else {
        err:=gameOffsets.Has("Error") ? gameOffsets["Error"] : "沒有產生結果"
        EventLog("GLOBAL","GAME_OFFSETS_FAIL",(gameOffsetsResolveKind="derive" ? "推算：" : "") err "｜HP 改用動態校正")
        AddRecentEvent(gameOffsetsResolveKind="derive" ? "⚠ 無法由遊戲推算新版資料位置，HP 改用動態校正（詳見 Log）" : "⚠ Game.pdb 解析失敗，HP 改用動態校正（詳見 Log）")
        ; Game.pdb 那條路失敗：立刻接著用遊戲記憶體推算
        if gameOffsetsResolveKind="pdb" {
            for p in profiles {
                try {
                    if p.pid && ProfileGameAlive(p) && GameBuildOf(p.pid)=gameOffsetsResolveBuild {
                        GameOffsetsStartDerive(p.pid,gameOffsetsResolveBuild)
                        break
                    }
                }
            }
        }
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
    ; 讀到 0 / 不合理的數字 = 這個遊戲版本的位置不對（實測 6AF0283E 四個視窗全部讀到 0）：當作讀不到。
    ; 否則伺服器時間永遠「沒更新」，每個帳號都被判「疑似假在線」，嚴重時還會把正常的遊戲關掉重登。
    if v="" || v<1000000000 || v>4000000000
        return false
    serverTime:=v
    return true
}

; v1.3.51.0 道具冷卻表（GLCharacter.m_mapCoolTimeType：std::map<冷卻類型, ITEM_COOLTIME>）。
; 回傳 [{type, id, use, end}]（id = 最後使用的道具 主ID | 子ID<<16；use / end = 伺服器時間 time_t 秒）；沒有這組位置資料 / 讀不到回傳 ""。
; 起點卡與前點卡共用同一個冷卻類型：按了其中一張，兩張都要等 end 過了才能再用。
ReadGameCoolEntries(pid) {
    if !GameOffsetsReady(pid) || !GameOffset("CoolMapTypeOffset") || !GameOffset("CoolNodeValueOffset") || !GameOffset("CoolEndTimeOffset")
        return ""
    cb:=GameCharBase(pid)
    if !cb
        return ""
    h:=GameProcHandle(pid)
    mapAddr:=cb+GameOffset("CoolMapTypeOffset")
    head:=GameReadNum(h,mapAddr,"Ptr"),size:=GameReadNum(h,mapAddr+8,"Ptr")
    if head="" || !head || size="" || size>256
        return ""
    ; std::map 節點：_Left 0 / _Parent 8 / _Right 0x10（MSVC 固定排列）；從 head 的 _Parent 取根，逐一走訪
    root:=GameReadNum(h,head+8,"Ptr")
    out:=[],stack:=[root],seen:=Map()
    isNil:=GameOffset("CoolNodeIsNilOffset"),keyOff:=GameOffset("CoolNodeKeyOffset"),valOff:=GameOffset("CoolNodeValueOffset")
    idOff:=GameOffset("CoolItemIdOffset"),useOff:=GameOffset("CoolUseTimeOffset"),endOff:=GameOffset("CoolEndTimeOffset")
    need:=Max(valOff+endOff+8,isNil+1,0x18)
    while stack.Length && out.Length<=size+1 {
        n:=stack.Pop()
        if !n || n="" || n=head || seen.Has(n)
            continue
        seen[n]:=1
        nb:=GameReadBuf(h,n,need)
        if !nb
            return ""
        if NumGet(nb,isNil,"UChar")
            continue
        end:=NumGet(nb,valOff+endOff,"Int64")
        if end<0 || end>4102444800    ; 超過 2100 年 = 讀到垃圾
            return ""
        out.Push({type:NumGet(nb,keyOff,"UInt"),id:NumGet(nb,valOff+idOff,"UInt"),use:NumGet(nb,valOff+useOff,"Int64"),end:end})
        stack.Push(NumGet(nb,0,"Ptr"),NumGet(nb,0x10,"Ptr"))
    }
    return out.Length=size ? out : ""      ; 筆數對不上 = 讀到一半被改動，當作讀不到
}

; 道具「主ID-子ID」（快捷欄 DailyQuickInfo 的 id）轉成冷卻表用的 dwID。
GameItemKeyToId(key) {
    p:=StrSplit(key,"-")
    return p.Length=2 && IsInteger(p[1]) && IsInteger(p[2]) ? (Integer(p[1])&0xFFFF)|((Integer(p[2])&0xFFFF)<<16) : ""
}

; 某個冷卻類型現在還要等幾秒（0 = 可以用了）；讀不到冷卻表 / 伺服器時間回傳 -1；表裡沒有這個類型 = 0。
GameCoolRemainByType(pid, type) {
    ents:=ReadGameCoolEntries(pid)
    srv:=0
    if !IsObject(ents) || !ReadGameServerTime(pid,&srv) || srv<=0
        return -1
    for e in ents
        if e.type=type
            return Max(0,e.end-srv)
    return 0
}

; 最後一次用這個道具的冷卻資訊 {type, end, use, remain}；表裡沒有（沒用過）回傳 0；讀不到回傳 ""。
; 注意：同一個冷卻類型的別張卡後來用過，這筆會被改寫成那張卡（所以起點卡 / 前點卡要兩個一起看）。
GameCoolInfoByItem(pid, itemId) {
    ents:=ReadGameCoolEntries(pid)
    srv:=0
    if !IsObject(ents) || !ReadGameServerTime(pid,&srv) || srv<=0
        return ""
    for e in ents
        if e.id=itemId
            return {type:e.type,end:e.end,use:e.use,remain:Max(0,e.end-srv),srv:srv}
    return 0
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
; 手動指定的快捷欄鍵位（角色設定 quickKeys，例如 "q,w,e,a,s,d"）：讀到的鍵位不準時，使用者可以在「寵物 / 雇傭兵 / 魔法娃娃」頁面自己改。
; 回傳陣列（和 ReadGameQuickKeys 一樣的格式）；這個 PID 的角色沒有手動設定回傳 ""。
GameQuickKeyOverride(pid) {
    global profiles
    if !IsSet(profiles) || !IsObject(profiles)
        return ""
    for p in profiles {
        if p.HasOwnProp("pid") && p.pid = pid && p.HasOwnProp("quickKeys") && Trim(p.quickKeys) != "" {
            arr := StrSplit(Trim(p.quickKeys), ",")
            out := []
            for k in arr
                out.Push(Trim(k))
            return out
        }
    }
    return ""
}
; raw = true：不套用手動設定（畫面上要同時顯示「自動讀到的」）
ReadGameQuickKeys(pid, raw := false) {
    if !raw {
        ov := GameQuickKeyOverride(pid)
        if IsObject(ov)
            return ov
    }
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
; 召喚獸（雇傭兵）現在是否在外面：1 = 在外面，0 = 不在，讀不到回傳 -1。和寵物同一種讀法（GLGaeaClient.m_Summon.m_bValid）。
ReadGameSummonOut(pid) {
    if !GameOffsetsReady(pid) || !GameOffset("SummonValidOffset")
        return -1
    inst:=GameGaeaBase(pid)
    v:=inst ? GameReadNum(GameProcHandle(pid),inst+GameOffset("SummonValidOffset"),"UChar") : ""
    return v="" ? -1 : (v ? 1 : 0)
}
; 魔法娃娃現在是否在外面：1 = 在外面，0 = 不在，讀不到回傳 -1。GLCharacter.m_magicDoll：收起時階級 0、座標 0xFFFF，
; 叫出時階級 / 座標有值（實測：收放一次序號加 1）。只有「階級 0 而且座標 0xFFFF」才算不在，其他一律當作在外面，避免誤判後把它收起來。
ReadGameMagicDollOut(pid) {
    if !GameOffsetsReady(pid) || !GameOffset("MagicDollOffset")
        return -1
    cb:=GameCharBase(pid)
    buf:=cb ? GameReadBuf(GameProcHandle(pid),cb+GameOffset("MagicDollOffset"),12) : 0
    if !buf
        return -1
    return (NumGet(buf,0,"UInt")=0 && NumGet(buf,8,"UShort")=0xFFFF) ? 0 : 1
}
; 每日任務（T 視窗）：回傳 {today, rows:[{name, claimed, goals:[{map, name, target, done}]}]}；讀不到回傳 0。
; 資料是遊戲收到伺服器回應後放在固定位置的 DailyTasks::Response，這個遊戲視窗打開過 T 才有；
; 還沒有資料（今日欄位 0 / 沒有任務），或任務是前一天的（row.day 不等於 today），也回傳 0（呼叫端要先開 T 再讀）。
ReadGameDailyTasks(pid) {
    if !GameOffsetsReady(pid) || !GameOffset("DailyStateRva")
        return 0
    hProc:=GameProcHandle(pid)
    base:=hProc ? GetGameModuleBase(pid,hProc) : 0
    if !base
        return 0
    rowBytes:=GameOffset("DailyRowBytes"),rowMax:=GameOffset("DailyRowCount"),objBytes:=GameOffset("DailyObjectiveBytes")
    if !rowBytes || !rowMax || !objBytes || rowMax>8
        return 0
    state:=base+GameOffset("DailyStateRva")
    head:=GameReadBuf(hProc,state,GameOffset("DailyRowsOffset"))
    if !head
        return 0
    today:=NumGet(head,GameOffset("DailyTodayOffset"),"UInt")
    count:=NumGet(head,GameOffset("DailyCountOffset"),"UInt")
    if !today || !count || count>rowMax
        return 0
    res:={today:today,rows:[]}
    Loop count {
        row:=GameReadBuf(hProc,state+GameOffset("DailyRowsOffset")+(A_Index-1)*rowBytes,rowBytes)
        if !row
            return 0
        if NumGet(row,GameOffset("DailyRowDayOffset"),"UInt")!=today
            return 0
        objCount:=NumGet(row,GameOffset("DailyRowObjCountOffset"),"UInt")
        if objCount>4
            return 0
        r:={name:StrGet(row.Ptr+GameOffset("DailyRowDefNameOffset"),"CP950"),claimed:NumGet(row,GameOffset("DailyRowClaimedOffset"),"UInt")?1:0,goals:[]}
        Loop objCount {
            o:=GameOffset("DailyRowObjectivesOffset")+(A_Index-1)*objBytes
            r.goals.Push({map:NumGet(row,o+GameOffset("DailyObjMapOffset"),"UInt")
                ,name:StrGet(row.Ptr+o+GameOffset("DailyObjNameOffset"),"CP950")
                ,target:NumGet(row,o+GameOffset("DailyObjTargetOffset"),"UInt")
                ,done:NumGet(row,GameOffset("DailyRowObjProgressOffset")+(A_Index-1)*4,"UInt")})
        }
        res.rows.Push(r)
    }
    return res
}
; 介面視窗指標：which = "Bus"（公車）/ "Dialogue"（NPC 對話）/ "LargeMap"（大地圖）；讀不到回傳 0。
GameInnerWindow(pid, which) {
    key := "Inner" which "WindowOffset"
    if !GameOffsetsReady(pid) || !GameOffset("InnerInterfaceRva") || !GameOffset(key)
        return 0
    hProc := GameProcHandle(pid)
    base := hProc ? GetGameModuleBase(pid, hProc) : 0
    if !base
        return 0
    w := GameReadNum(hProc, base + GameOffset("InnerInterfaceRva") + GameOffset(key), "Ptr")
    return w ? w : 0
}
; 這個介面視窗現在有沒有開著：1 = 開著，0 = 沒開，讀不到回傳 -1。
ReadGameUiOpen(pid, which) {
    w := GameInnerWindow(pid, which)
    if !w || !GameOffset("UiVisibleOffset")
        return -1
    v := GameReadNum(GameProcHandle(pid), w + GameOffset("UiVisibleOffset"), "UInt")
    return v = "" ? -1 : (v ? 1 : 0)
}
; 公車視窗：{visible, sel（目前選到清單第幾筆，0 起算；沒選 = -1）, maps:[清單每一筆的地圖編號]}；讀不到回傳 0。
; 清單是遊戲自己載入的（GLBusList.m_vecVILLAGE），不用寫死哪張圖在第幾筆。
ReadGameBusWindow(pid) {
    w := GameInnerWindow(pid, "Bus")
    if !w || !GameOffset("BusVillageVecOffset") || !GameOffset("BusVillageBytes")
        return 0
    hProc := GameProcHandle(pid)
    vis := GameReadNum(hProc, w + GameOffset("UiVisibleOffset"), "UInt")
    sel := GameReadNum(hProc, w + GameOffset("BusSelectMapOffset"), "UInt")
    vb := GameReadNum(hProc, w + GameOffset("BusVillageVecOffset"), "Ptr")
    ve := GameReadNum(hProc, w + GameOffset("BusVillageVecOffset") + 8, "Ptr")
    stride := GameOffset("BusVillageBytes")
    if vis = "" || sel = "" || !vb || !ve || ve <= vb || (ve - vb) // stride > 200
        return 0
    count := (ve - vb) // stride
    buf := GameReadBuf(hProc, vb, count * stride)
    if !buf
        return 0
    maps := []
    Loop count
        maps.Push(NumGet(buf, (A_Index - 1) * stride + GameOffset("BusVillageMapIdOffset"), "UInt"))
    return {visible: vis ? 1 : 0, sel: sel < count ? sel : -1, maps: maps}
}
; 公車清單文字框：{cur（目前頁首第幾行，0 起算）, visible（一頁幾行）, total（總共幾行）, over（滑鼠停在第幾行：沒停在任何一行 = -1）, sel, top, height（框在遊戲畫面上的位置）}；讀不到回傳 0。
; 「捲到哪裡」「游標下面是哪一行」遊戲裡直接讀得到，不用靠點擊再讀回去猜。
; 公車視窗下方的「公車站」（入口）清單：選好地圖後要先點它的一行，才能按確定傳送。回傳 {top, height, total, sel}；讀不到回傳 0。
; 這個欄位在遊戲裡就在地圖清單後面一格（+0x10），舊的位置資料沒有這個鍵，所以沒有時用地圖清單位置推。
ReadGameBusGateList(pid) {
    w := GameInnerWindow(pid, "Bus")
    mapOff := GameOffset("BusMapListOffset")
    off := GameOffset("BusGateListOffset") ? GameOffset("BusGateListOffset") : (mapOff ? mapOff + 0x10 : 0)
    if !w || !off || !GameOffset("TextBoxTotalLineOffset")
        return 0
    hProc := GameProcHandle(pid)
    tb := GameReadNum(hProc, w + off, "Ptr")
    if !tb
        return 0
    tot := GameReadNum(hProc, tb + GameOffset("TextBoxTotalLineOffset"), "Int")
    sel := GameReadNum(hProc, tb + GameOffset("TextBoxSelectedOffset"), "Int")
    rc := GameReadBuf(hProc, tb + GameOffset("UiGlobalRectOffset"), 24)
    if tot = "" || sel = "" || !rc || tot < 0 || tot > 50
        return 0
    return {top: NumGet(rc, 8, "Float"), height: NumGet(rc, 20, "Float"), total: tot, sel: sel}
}
ReadGameBusList(pid) {
    w := GameInnerWindow(pid, "Bus")
    if !w || !GameOffset("BusMapListOffset") || !GameOffset("TextBoxCurLineOffset")
        return 0
    hProc := GameProcHandle(pid)
    tb := GameReadNum(hProc, w + GameOffset("BusMapListOffset"), "Ptr")
    if !tb
        return 0
    cur := GameReadNum(hProc, tb + GameOffset("TextBoxCurLineOffset"), "Int")
    vis := GameReadNum(hProc, tb + GameOffset("TextBoxVisibleLineOffset"), "Int")
    tot := GameReadNum(hProc, tb + GameOffset("TextBoxTotalLineOffset"), "Int")
    over := GameReadNum(hProc, tb + GameOffset("TextBoxMouseOverOffset"), "Int")
    sel := GameReadNum(hProc, tb + GameOffset("TextBoxSelectedOffset"), "Int")
    rc := GameReadBuf(hProc, tb + GameOffset("UiGlobalRectOffset"), 24)
    if cur = "" || vis = "" || tot = "" || over = "" || sel = "" || !rc || vis < 1 || vis > 100 || tot < 0 || tot > 500
        return 0
    return {cur: cur, visible: vis, total: tot, over: over, sel: sel, top: NumGet(rc, 8, "Float"), height: NumGet(rc, 20, "Float")}
}
; 大地圖（M）頁面：{visible, left, right, top, bottom（地圖框在遊戲畫面上的位置）, startX, startY, sizeX, sizeY（世界範圍）, texX, texY（地圖貼圖像素）,
;  viewX, viewY（視圖起點）, rpx, rpy（目前顯示的貼圖位置，0~1）, tx, ty（遊戲記的「上次點的目標」地圖像素）, mapMain（這頁顯示哪張圖）}；讀不到回傳 0。
ReadGameNewMap(pid) {
    w := GameInnerWindow(pid, "NewMap")
    if !w || !GameOffset("NewMapMainPageOffset") || !GameOffset("NewMapCtlOffset")
        return 0
    hProc := GameProcHandle(pid)
    vis := GameReadNum(hProc, w + GameOffset("UiVisibleOffset"), "UInt")
    page := GameReadNum(hProc, w + GameOffset("NewMapMainPageOffset"), "Ptr")
    if vis = "" || !page
        return 0
    I(key) => GameReadNum(hProc, page + GameOffset(key), "Int")
    pg := {visible: vis ? 1 : 0, startX: I("NewMapWorldStartXOffset"), startY: I("NewMapWorldStartYOffset"), sizeX: I("NewMapWorldSizeXOffset"), sizeY: I("NewMapWorldSizeYOffset")
        , texX: I("NewMapTexSizeXOffset"), texY: I("NewMapTexSizeYOffset"), viewX: I("NewMapViewStartXOffset"), viewY: I("NewMapViewStartYOffset")
        , tx: I("NewMapTargetXOffset"), ty: I("NewMapTargetYOffset")}
    for k, v in pg.OwnProps()
        if v = ""
            return 0
    if pg.sizeX <= 0 || pg.sizeY <= 0 || pg.texX <= 0 || pg.texY <= 0
        return 0
    rp := GameReadBuf(hProc, page + GameOffset("NewMapRenderPosOffset"), 8)
    ctl := GameReadNum(hProc, page + GameOffset("NewMapCtlOffset"), "Ptr")
    rc := ctl ? GameReadBuf(hProc, ctl + GameOffset("UiGlobalRectOffset"), 24) : 0
    mid := GameReadNum(hProc, page + GameOffset("NewMapMapIdOffset"), "UShort")
    if !rp || !rc || mid = ""
        return 0
    ; 玩家標記（代表人物的小點）在畫面上的中心：地圖開著時每個畫面都會更新，用它對照人物的世界座標就能得到精確的偏移
    pm := GameOffset("NewMapPlayerMarkOffset") ? GameReadNum(hProc, page + GameOffset("NewMapPlayerMarkOffset"), "Ptr") : 0
    prc := pm ? GameReadBuf(hProc, pm + GameOffset("UiGlobalRectOffset"), 24) : 0
    if prc {
        mx := (NumGet(prc, 0, "Float") + NumGet(prc, 4, "Float")) / 2, my := (NumGet(prc, 8, "Float") + NumGet(prc, 12, "Float")) / 2
        if vis && mx > NumGet(rc, 0, "Float") - 60 && mx < NumGet(rc, 4, "Float") + 60 && my > NumGet(rc, 8, "Float") - 60 && my < NumGet(rc, 12, "Float") + 60
            pg.markX := mx, pg.markY := my
    }
    pg.rpx := NumGet(rp, 0, "Float"), pg.rpy := NumGet(rp, 4, "Float")
    pg.left := NumGet(rc, 0, "Float"), pg.right := NumGet(rc, 4, "Float"), pg.top := NumGet(rc, 8, "Float"), pg.bottom := NumGet(rc, 12, "Float")
    pg.mapMain := mid
    return pg
}
; 滑鼠現在指著哪一個怪 / NPC：{kind（1 = NPC，2 = 怪）, id（全域編號，和怪物清單的 glob 一樣；沒指到任何東西 = -1）}；讀不到回傳 0。
ReadGameMouseTarget(pid) {
    if !GameOffsetsReady(pid) || !GameOffset("CharMouseTargetOffset") || !GameOffset("TargetIdOffset")
        return 0
    cb := GameCharBase(pid)
    buf := cb ? GameReadBuf(GameProcHandle(pid), cb + GameOffset("CharMouseTargetOffset"), GameOffset("TargetIdOffset") + 4) : 0
    if !buf
        return 0
    id := NumGet(buf, GameOffset("TargetIdOffset"), "UInt")
    return {kind: NumGet(buf, 0, "UInt"), id: id = 0xFFFFFFFF ? -1 : id}
}
; 遊戲的「自動打怪」（F6）是不是開著：1 = 開著，0 = 沒開，讀不到回傳 -1。
ReadGameAutoHunt(pid) {
    if !GameOffsetsReady(pid) || !GameOffset("AutoHuntOffset")
        return -1
    cb := GameCharBase(pid)
    v := cb ? GameReadNum(GameProcHandle(pid), cb + GameOffset("AutoHuntOffset"), "UInt") : ""
    return v = "" ? -1 : (v ? 1 : 0)
}
; 角色身上記的召喚獸全域 ID（沒有召喚獸通常是 0xFFFFFFFF）；讀不到回傳 ""。
ReadGameSummonGuid(pid) {
    if !GameOffsetsReady(pid) || !GameOffset("CharSummonGuidOffset")
        return ""
    cb:=GameCharBase(pid)
    return cb ? GameReadNum(GameProcHandle(pid),cb+GameOffset("CharSummonGuidOffset"),"UInt") : ""
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
