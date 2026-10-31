; ============================================================================
; H-033 登入畫面直接讀遊戲記憶體（取代 8 個預設點）
;
; 登入 / 選伺服器 / 選角畫面（COuterInterface）每個按鈕、輸入框的位置、文字與是否顯示都在記憶體裡，
; 所以不用先記「伺服器、分流、連線、帳號欄、密碼欄、確認登入、開始遊戲」這些點，也不用畫面樣板：
;   伺服器 / 分流 = 清單裡的列（預設第一列，可用 [Login] ServerName / ChannelName 指定名稱）
;   連線 / 確認 / 開始遊戲 = 文字剛好是這幾個字的按鈕；帳號 / 密碼 = 兩個輸入框
;   選角 = 讀得到角色清單（名稱、等級），依設定的角色名稱點對應的位置，並用記憶體確認真的選到了
; 讀不到（舊位置檔 / 畫面沒出現）時一律退回原本的預設點與畫面樣板。[Login] MemoryUi=0 可整個關閉。
; ============================================================================

global LOGIN_MEM_UI := 1
try LOGIN_MEM_UI := Integer(IniRead(INI,"Login","MemoryUi","1"))
global LOGIN_SERVER_NAME := Trim(IniRead(INI,"Login","ServerName",""))
global LOGIN_CHANNEL_NAME := Trim(IniRead(INI,"Login","ChannelName",""))
; 選角畫面：第 1 隻角色模型的點擊位置（沒有預設點時用）與每隻之間的間距（實測：第 1 隻 x≈153、第 2 隻 x≈345～400）
global LOGIN_CHAR_X0 := 153, LOGIN_CHAR_Y := 479, LOGIN_CHAR_DX := 222
global loginUiTestDriver := 0
global LOGIN_MEM_WAIT_MAX_MS := 20000   ; 每個遊戲程序等「遊戲資料就緒」的累計上限
global loginMemWaitMs := Map()           ; pid → 已等待毫秒數

; 目前的位置資料有登入畫面欄位（資料就緒才算；沒有 = 照舊用 8 個預設點）
LoginMemoryAvailable() {
    global LOGIN_MEM_UI
    return LOGIN_MEM_UI && GameOffsetsLoadedOk() && GameOffset("OuterInstanceRva") && GameOffset("GlobalStageRva") && GameOffset("LobyCharInfoOffset") ? true : false
}

LoginUiPid(hwnd) {
    pid:=0
    try pid:=WinGetPID("ahk_id " hwnd)
    return pid && GameOffsetsReady(pid) && GameOffset("OuterInstanceRva") ? pid : 0
}

; 這個遊戲視窗的角色是不是已經在遊戲世界裡（記憶體：有角色資料而且有地圖）。
; 是的話登入流程不能再點座標、打帳號密碼（會點到遊戲畫面、或把帳密打進聊天）。
; 同時把本輪恢復標成「已確認」，失敗清理就不會關掉這個正在遊戲中的 game.exe。讀不到記憶體時回傳 false（不擋）。
LoginGuardInWorld(hwnd, profileName, what) {
    global activeRecoveryCommitted
    pid:=0
    try pid:=WinGetPID("ahk_id " hwnd)
    if !pid
        return false
    inWorld:=false
    try inWorld:=GameInWorld(pid)
    if !inWorld
        return false
    activeRecoveryCommitted:=true
    EventLog(profileName,"LOGIN_BLIND_BLOCKED","角色已在遊戲世界中｜停止" what "（不點擊、不打字）")
    return true
}

; 這個帳號原本綁定的遊戲視窗還在、PID 沒變、角色已在遊戲世界，只是被判成「綁定失效」
; （例如視窗標題暫時不同）：回傳 hwnd，呼叫端應直接重新綁定，不能再開一個新的遊戲重新登入
; （同一組帳密重複登入會被拒絕，或把原本好好的角色踢下線）。其他情況回傳 0。
LoginExistingWorldHwnd(pid, hwnd, procName := "game.exe") {
    if !pid || !hwnd || !ProcessExist(pid) || !WinExist("ahk_id " hwnd)
        return 0
    try {
        if WinGetPID("ahk_id " hwnd) != pid || WinGetProcessName("ahk_id " hwnd) != procName
            return 0
        return GameInWorld(pid) ? hwnd : 0
    }
    return 0
}

; 目前登入畫面的快照：{pages, labels:[{page,text,l,r,t,b}], edits:Map("id"/"pw"), servers:[{text,x,y}], channels:[…]}；讀不到回傳 ""。
LoginUiSnap(pid) {
    global loginUiTestDriver
    if IsObject(loginUiTestDriver)
        return loginUiTestDriver.Snap(pid)
    ui:=ReadGameLoginUi(pid,3)
    if !IsObject(ui)
        return ""
    h:=GameProcHandle(pid)
    snap:={pages:ui.pages,labels:[],edits:Map(),servers:[],channels:[]}
    for c in ui.ctrls {
        if !c.shown
            continue
        if c.name="LOGIN_EDIT_ID" || c.name="LOGIN_EDIT_PW" {
            snap.edits[c.name="LOGIN_EDIT_ID" ? "id" : "pw"]:=c
            continue
        }
        isList:=c.name="SELECT_SERVER_LIST"
        if !isList && !InStr(c.name,"TEXTBOX")
            continue
        tb:=0
        try tb:=ApReadTextBox(h,c.ptr,12)
        if !IsObject(tb) || !tb.parts.Length
            continue
        if isList {
            for part in tb.parts {
                r:=part.rect
                if !IsObject(r) || part.text="" || r.t<c.t-1 || r.b>c.b+1
                    continue
                row:={text:part.text,x:Round((r.l+r.r)/2),y:Round((r.t+r.b)/2)}
                (c.l<600 ? snap.servers : snap.channels).Push(row)
            }
        } else {
            r:=tb.parts[1].rect
            if IsObject(r)
                snap.labels.Push({page:c.page,text:Trim(tb.parts[1].text),l:r.l,r:r.r,t:r.t,b:r.b})
        }
    }
    return snap
}

LoginUiLabel(snap, page, text) {
    for lb in snap.labels
        if lb.page=page && lb.text=text
            return {x:Round((lb.l+lb.r)/2),y:Round((lb.t+lb.b)/2)}
    return ""
}

LoginUiPickRow(rows, wanted) {
    if !rows.Length
        return ""
    if wanted!="" {
        for row in rows
            if row.text=wanted
                return {x:row.x,y:row.y}
        for row in rows
            if InStr(row.text,wanted)
                return {x:row.x,y:row.y}
        return ""   ; 指定的名稱找不到：不亂選別的（呼叫端退回預設點或逾時）
    }
    return {x:rows[1].x,y:rows[1].y}
}

; 某個登入步驟要點的位置 {x,y}（遊戲畫面座標）；現在沒有這個控制項 / 還沒出現回傳 ""。
LoginUiPoint(snap, key) {
    global LOGIN_SERVER_NAME,LOGIN_CHANNEL_NAME
    if !IsObject(snap)
        return ""
    switch key {
        case "server":
            return LoginUiPickRow(snap.servers,LOGIN_SERVER_NAME)
        case "channel":
            return LoginUiPickRow(snap.channels,LOGIN_CHANNEL_NAME)
        case "connect":
            return LoginUiLabel(snap,"Server","連線")
        case "login":
            return LoginUiLabel(snap,"Login","確認")
        case "startgame":
            return LoginUiLabel(snap,"CharLeft","開始遊戲")
        case "account", "password":
            e:=snap.edits.Has(key="account" ? "id" : "pw") ? snap.edits[key="account" ? "id" : "pw"] : 0
            return IsObject(e) ? {x:Round((e.l+e.r)/2),y:Round((e.t+e.b)/2)} : ""
    }
    return ""
}

; ClickPoint 用：這個登入步驟目前能從記憶體找到位置就回傳 {x,y}，否則 ""（呼叫端用預設點）。
LoginUiClickPoint(hwnd, key) {
    global LOGIN_MEM_UI
    if !LOGIN_MEM_UI || !(pid:=LoginUiPid(hwnd))
        return ""
    try return LoginUiPoint(LoginUiSnap(pid),key)
    return ""
}

LoginUiLoby(pid) {
    global loginUiTestDriver
    if IsObject(loginUiTestDriver)
        return loginUiTestDriver.Loby(pid)
    try return ReadGameLobyChars(pid)
    return ""
}

; 這個步驟的畫面準備好了嗎（記憶體判斷）
LoginUiKeyReady(snap, pid, key) {
    if !IsObject(snap)
        return false
    ; 有訊息 / 對話框蓋在畫面上（連線失敗、帳號已在線上…）時，下面的按鈕點不到：不算到位
    for pg in ["Message","Modal"]
        if snap.pages.Has(pg) && snap.pages[pg].shown
            return false
    if key="char" {
        lc:=LoginUiLoby(pid)
        return IsObject(lc) && lc.inLoby && lc.count>=1 && snap.pages.Has("CharLeft") && snap.pages["CharLeft"].shown
    }
    return IsObject(LoginUiPoint(snap,key))
}

; 以記憶體確認登入畫面已經到這個步驟。回傳 true = 已確認；false = 記憶體讀不到（呼叫端改用畫面樣板 / 固定等待）；
; 逾時（畫面讀得到卻一直沒到這一步）丟錯，和畫面樣板逾時一樣。連續 2 次都到才算（避免畫面轉場中途誤判）。
LoginMemoryGate(hwnd, key, profileName, timeoutSec:=60) {
    global abortRequested,Status,LOGIN_MEM_UI
    if !LOGIN_MEM_UI
        return false
    ; 剛啟動的 game.exe 模組還沒載完（讀不到版本）或位置資料正在解析時，等它就緒再用記憶體，
    ; 不要馬上放棄、退回要多等十幾秒的畫面樣板。每個遊戲程序累計最多等 20 秒（之後的關卡不再等）；
    ; 版本讀得到卻沒有位置資料（也不在解析）就照舊立刻退回。
    pid:=LoginUiPid(hwnd)
    gpid:=0
    try gpid:=WinGetPID("ahk_id " hwnd)
    waited:=loginMemWaitMs.Get(gpid,0)
    waitStart:=A_TickCount
    while !pid && gpid && waited+(A_TickCount-waitStart)<LOGIN_MEM_WAIT_MAX_MS {
        if abortRequested
            throw Error("使用者停止測試。")
        ; 解析工具結束後還要等 GameOffsetsResolveTick 載入結果（gameOffsetsResolvePid 歸零）才算處理完
        if GameBuildOf(gpid)!="" && !GameOffsetsResolving() && !gameOffsetsResolvePid {
            pid:=LoginUiPid(hwnd)
            break
        }
        Sleep 250
        pid:=LoginUiPid(hwnd)
    }
    if gpid
        loginMemWaitMs[gpid]:=waited+(A_TickCount-waitStart)
    if !pid
        return false
    if A_TickCount-waitStart>=500
        EventLog(profileName,"LOGIN_MEMORY_WAIT","遊戲資料就緒才開始用記憶體判斷畫面｜" Round((A_TickCount-waitStart)/1000,1) " 秒")
    stageNames:=Map("server","等待伺服器畫面","channel","等待分流畫面","connect","等待連線畫面","account","等待登入畫面","password","等待密碼欄","login","等待登入按鈕","char","等待角色畫面","startgame","等待開始遊戲")
    stage:=stageNames.Has(key) ? stageNames[key] : "等待畫面 " key
    start:=A_TickCount, stable:=0, sawPage:=false, unreadable:=0
    ; 剛啟動的遊戲登入物件還沒建立時讀不到畫面：在剩餘的等待額度內繼續讀，額度用完才退回畫面樣板
    graceMs:=Min(timeoutSec*1000,Max(0,LOGIN_MEM_WAIT_MAX_MS-loginMemWaitMs.Get(gpid,0)))
    while A_TickCount-start < timeoutSec*1000 {
        if abortRequested
            throw Error("使用者停止測試。")
        if !hwnd || !WinExist("ahk_id " hwnd)
            throw Error(stage "期間遊戲視窗已消失。")
        snap:=LoginUiSnap(pid)
        if !IsObject(snap) {
            if A_TickCount-start >= graceMs {
                loginMemWaitMs[gpid]:=loginMemWaitMs.Get(gpid,0)+(A_TickCount-start)
                return false
            }
            unreadable:=A_TickCount-start, stable:=0
            Sleep 250
            continue
        }
        if unreadable>=500 {
            EventLog(profileName,"LOGIN_MEMORY_WAIT","遊戲畫面資料就緒才開始用記憶體判斷畫面｜" Round(unreadable/1000,1) " 秒")
            loginMemWaitMs[gpid]:=loginMemWaitMs.Get(gpid,0)+unreadable
        }
        unreadable:=0
        if snap.pages.Count
            sawPage:=true
        if LoginUiKeyReady(snap,pid,key) {
            stable+=1
            if stable>=2 {
                EventLog(profileName,"LOGIN_MEMORY_READY",stage " Ready（記憶體）｜" Round((A_TickCount-start)/1000,1) " 秒")
                return true
            }
        } else
            stable:=0
        Status.Text:="狀態：" profileName "｜" stage "｜讀取遊戲畫面 " Round((A_TickCount-start)/1000,1) "s"
        Sleep 250
    }
    ; 一直讀不到任何登入畫面頁面（例如剛啟動還在載入、或這版遊戲的畫面結構不同）→ 退回畫面樣板；有頁面卻沒到這一步 → 逾時
    if !sawPage
        return false
    EventLog(profileName,"LOGIN_MEMORY_TIMEOUT",stage "｜" timeoutSec " 秒內記憶體沒有確認到這個畫面")
    throw Error(stage " Timeout：" timeoutSec " 秒內未確認畫面 Ready（記憶體）。")
}

; 設定值轉成第幾隻（從 0 算）：「#2」= 依順序第 2 隻；其他 = 依角色名稱。找不到回傳 -1。
LoginTargetOf(lc, want) {
    if RegExMatch(want,"^#(\d{1,2})$",&m)
        return Integer(m[1])>=1 && Integer(m[1])<=lc.count ? Integer(m[1])-1 : -1
    for i,c in lc.chars
        if c.name=want
            return i-1
    return -1
}
LoginWantText(want) => RegExMatch(want,"^#(\d{1,2})$",&m) ? "第 " m[1] " 隻" : "「" want "」"

; 選角：要登入哪一隻。profile.loginChar = 角色名稱。回傳 true = 已用記憶體選好並確認；
; false = 交給呼叫端照舊點「角色」預設點（讀不到角色清單，或沒指定角色而且使用者自己校正過預設點——
; 那個點可能是故意校在第 2 隻上，不能擅自改成第 1 隻）。
; 指定的角色名稱找不到時一律停止（寧可不登入，也不要在無人看管時進到別隻角色）。
LoginPickChar(hwnd, p) {
    global LOGIN_MEM_UI,points,abortRequested
    if !LOGIN_MEM_UI || !(pid:=LoginUiPid(hwnd))
        return false
    want:=p.HasOwnProp("loginChar") ? Trim(p.loginChar) : ""
    if want="" && points.Has("char")
        return false
    lc:=LoginUiLoby(pid)
    if !IsObject(lc) || !lc.inLoby || lc.count<1
        return false
    target:=0
    if want!="" {
        target:=-1
        Loop 3 {
            target:=LoginTargetOf(lc,want)
            if target>=0
                break
            Sleep 700   ; 角色清單剛載入時可能還沒讀完整：重讀幾次再下結論
            lc:=LoginUiLoby(pid)
            if !IsObject(lc)
                return false
        }
        if target<0 {
            names:=""
            for c in lc.chars
                names.=(names="" ? "" : "、") c.name
            EventLog(p.name,"LOGIN_CHAR_MISSING","設定要選" LoginWantText(want) "，但選角畫面的角色是：" names)
            throw Error("選角畫面找不到設定的角色" LoginWantText(want) "（現有：" names "）；為避免進錯角色，已停止並保留遊戲視窗。")
        }
    }
    return LoginSelectIndex(hwnd,p,pid,target)
}

; 點選第 target 隻（從 0 算）並用記憶體確認。
LoginSelectIndex(hwnd, p, pid, target) {
    global LOGIN_CHAR_X0,LOGIN_CHAR_Y,LOGIN_CHAR_DX,points,abortRequested
    lc:=LoginUiLoby(pid)
    if !IsObject(lc) || target>=lc.count
        return false
    if lc.selected=target {
        EventLog(p.name,"LOGIN_CHAR","已選到「" lc.chars[target+1].name "」（第 " target+1 " 隻）")
        return true
    }
    if target>3
        throw Error("第 " target+1 " 隻角色的選角位置還不支援（目前只支援前 4 隻）；已停止並保留遊戲視窗。")
    x0:=LOGIN_CHAR_X0,y:=LOGIN_CHAR_Y
    if points.Has("char") && points["char"].nx!="" {
        x0:=Round(points["char"].nx*1024),y:=Round(points["char"].ny*768)
    }
    for off in (target=0 ? [0,-20,20] : [0,-25,25,-50,50,-75,75]) {
        if abortRequested
            throw Error("使用者停止測試。")
        ClickPoint(hwnd,"charslot",{x:x0+target*LOGIN_CHAR_DX+off,y:y})
        Loop 8 {
            Sleep 150
            lc:=LoginUiLoby(pid)
            if IsObject(lc) && lc.selected=target {
                EventLog(p.name,"LOGIN_CHAR","已選到「" lc.chars[target+1].name "」（第 " target+1 " 隻）｜位置偏移 " off)
                return true
            }
        }
    }
    throw Error("選角失敗：點了第 " target+1 " 隻角色的位置，但遊戲沒有選到它（已保留遊戲視窗）。")
}

; 沒指定角色、照預設點點選之後：用記憶體確認真的選到了（選角畫面剛出現時模型還沒準備好，點了沒反應，
; 結果「開始遊戲」按鈕一直不出現）。沒選到就再點，最多 4 次；連 3 次重點都沒選到就多等幾秒再點（最多 LOGIN_CHAR_EXTRA_ROUNDS 輪），
; 仍然選不到才存一張畫面（LOGIN_CHAR_SHOT）供事後查原因；讀不到角色清單就不處理（維持舊行為）。
global LOGIN_CHAR_EXTRA_WAIT_MS := 8000
global LOGIN_CHAR_EXTRA_ROUNDS := 2

LoginEnsureSelected(hwnd, p) {
    global LOGIN_MEM_UI,abortRequested,LOGIN_CHAR_EXTRA_WAIT_MS,LOGIN_CHAR_EXTRA_ROUNDS
    if !LOGIN_MEM_UI || !(pid:=LoginUiPid(hwnd))
        return true
    Loop 4 {
        Loop 12 {
            lc:=LoginUiLoby(pid)
            if !IsObject(lc) || !lc.inLoby
                return true
            if lc.selected>=0
                return true
            if abortRequested
                throw Error("使用者停止測試。")
            Sleep 150
        }
        if A_Index<4 {
            EventLog(p.name,"LOGIN_CHAR_RETRY","點了角色位置但還沒選到，重新點一次（第 " A_Index+1 " 次）")
            ClickPoint(hwnd,"char")
        }
    }
    ; 前面連續重點都沒反應：伺服器可能還在釋放上一次的連線 / 角色模型還在載入，多等幾秒再點，不要直接當失敗
    Loop LOGIN_CHAR_EXTRA_ROUNDS {
        EventLog(p.name,"LOGIN_CHAR_EXTRA_WAIT","連續重點都沒選到｜多等 " Round(LOGIN_CHAR_EXTRA_WAIT_MS/1000,1) " 秒再點（第 " A_Index "/" LOGIN_CHAR_EXTRA_ROUNDS " 輪）")
        waitStart:=A_TickCount
        while A_TickCount-waitStart<LOGIN_CHAR_EXTRA_WAIT_MS {
            lc:=LoginUiLoby(pid)
            if !IsObject(lc) || !lc.inLoby || lc.selected>=0
                return true
            if abortRequested
                throw Error("使用者停止測試。")
            Sleep 150
        }
        ClickPoint(hwnd,"char")
        Loop 12 {
            lc:=LoginUiLoby(pid)
            if !IsObject(lc) || !lc.inLoby || lc.selected>=0
                return true
            Sleep 150
        }
    }
    LoginFailShot(hwnd,p,"LOGIN_CHAR_SHOT","選角畫面一直選不到角色")
    return false
}

; 登入畫面失敗時存一張遊戲畫面到 Logs\Shots，並在日誌留下路徑（只存檔，不上傳）。回傳路徑，存不到回傳空字串。
LoginFailShot(hwnd, p, type, why) {
    path:=""
    try {
        if hwnd && WinExist("ahk_id " hwnd) {
            path:=ReportShotPath(p.name "_" type)
            if !CaptureWindowPng(hwnd,path)
                path:=""
        }
    } catch
        path:=""
    EventLog(p.name,type,why "｜" (path!="" ? "已保存畫面：" path : "畫面存不下來"))
    ; 同時傳到 Discord；每一批重新登入最多傳一張，連續失敗不洗版（整批結束還會再傳一張全部視窗的畫面）
    if path!="" && RecoveryBatchTakeFailShot()
        try SendDiscordImage("⚠️ HIHIYONG 重新登入失敗畫面`n角色：" p.name "`n" why,path)
    return path
}

; 按「開始遊戲」前再確認一次：遊戲有時在角色清單載入後才自己預選「上次玩的角色」，不能只信先前那一次的確認。
LoginConfirmChar(hwnd, p) {
    global LOGIN_MEM_UI
    if !LOGIN_MEM_UI || !(pid:=LoginUiPid(hwnd))
        return
    lc:=LoginUiLoby(pid)
    if !IsObject(lc) || !lc.inLoby || lc.count<1
        return
    want:=p.HasOwnProp("loginChar") ? Trim(p.loginChar) : ""
    target:=0
    if want!="" {
        target:=LoginTargetOf(lc,want)
        if target<0
            throw Error("按開始遊戲前找不到設定的角色" LoginWantText(want) "；已停止。")
    }
    if lc.selected!=target {
        EventLog(p.name,"LOGIN_CHAR_RECHECK","按開始遊戲前發現選到的是第 " lc.selected+1 " 隻，重新選第 " target+1 " 隻")
        LoginSelectIndex(hwnd,p,pid,target)
    }
}

; ---------------------------------------------------------------- 設定畫面：登入後要選哪一隻角色（每個帳號一個下拉選單）

; 這個帳號的遊戲現在開著的話，記下選角清單裡的角色名稱（遊戲進入後清單還在記憶體裡）；回傳名稱陣列（讀不到 = 上次記下的）。
LoginCharsOf(p) {
    names:=[]
    if p.pid && p.hwnd {
        lc:=LoginUiLoby(p.pid)
        if IsObject(lc) && lc.count>=1 {
            for c in lc.chars
                names.Push(c.name)
            list:=""
            for n in names
                list.=(list="" ? "" : "|") n
            if !p.HasOwnProp("loginCharList") || p.loginCharList!=list {
                p.loginCharList:=list
                SaveProfiles()
            }
            return names
        }
    }
    if p.HasOwnProp("loginCharList") && p.loginCharList!="" {
        for n in StrSplit(p.loginCharList,"|")
            if n!=""
                names.Push(n)
    }
    return names
}

LoginCharsPushWeb() {
    global webReady,WVCore,profiles
    if !webReady || !WVCore
        return
    rows:=""
    for i,p in profiles {
        names:=LoginCharsOf(p)
        opts:=""
        for n in names
            opts.=(opts="" ? "" : ",") '"' JsonEscapeWeb(n) '"'
        sel:=p.HasOwnProp("loginChar") ? p.loginChar : ""
        rows.=(rows="" ? "" : ",") '{"index":' i ',"name":"' JsonEscapeWeb(p.name) '","chars":[' opts '],"selected":"' JsonEscapeWeb(sel) '"}'
    }
    try WVCore.PostWebMessageAsJson('{"type":"loginchars","data":{"roles":[' rows ']}}')
}

; 「編號~角色名稱~帳號名稱」（角色名稱空白 = 第 1 隻）
LoginCharSet(rawValue) {
    global profiles
    parts:=StrSplit(WebUrlDecode(rawValue),"~")
    if parts.Length<2 || !IsInteger(parts[1]) || parts[1]<1 || parts[1]>profiles.Length
        return
    p:=profiles[Integer(parts[1])]
    if parts.Length>=3 && parts[3]!=p.name {
        AddRecentEvent("⚠ 登入角色設定沒有儲存：帳號清單已變動，請重新整理畫面再設定")
        return
    }
    name:=Trim(RegExReplace(parts[2],"[\r\n~|]"))
    if RegExMatch(name,"^#\d+$") && (Integer(SubStr(name,2))<1 || Integer(SubStr(name,2))>4)
        return
    p.loginChar:=name
    SaveProfiles()
    AddRecentEvent(p.name " → 登入後選擇：" (name="" ? "預設" : LoginWantText(name)))
}
