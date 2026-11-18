; 背包清理（多視窗清背包）：快捷鍵、綁定的遊戲視窗、設定與執行流程，以及網頁用的清單 JSON。
; 從主程式搬出來（v1.3.90.52），內容沒有改；只有函式。

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
        for hwnd in WinGetList(GAME_TITLE " ahk_exe game.exe") {
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
