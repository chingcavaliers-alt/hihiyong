; ============================================================================
; v1.3.16.0 Recorder：示範錄製（建立自動流程用）。
;
; 使用者手動操作一次（例如每日道具更換），程式只「旁觀記錄」，不攔截也不改變任何操作：
; - 目標遊戲視窗內的滑鼠按下 / 放開（相對遊戲畫面的座標、拖曳起點）、按鍵。
; - 每次滑鼠按下時的遊戲畫面截圖（PNG）。
; - 每次操作後 0.5 秒的裝備欄 / 背包 / 銀行變化（遊戲記憶體）。
; - v1.3.18.11（自動採礦用）：角色位置 / 動作 / 坐騎 / 技能欄 / 目標、附近礦石與它們在畫面上的位置。
; 結果存在 Logs\Recordings\時間_角色\：events.txt（文字紀錄）＋截圖。
; ============================================================================

global recorder := 0
global RECORDER_DRAG_PX := 5

RecorderStart(idx) {
    global profiles,recorder,autoSwitchRunning,invRunning,processingQueue,foregroundOwner
    if IsObject(recorder)
        return
    if idx<1 || idx>profiles.Length
        return
    p:=profiles[idx]
    reason:=""
    if !p.pid || !ProfileGameAlive(p)
        reason:="角色沒有連接遊戲視窗"
    else if !GameOffsetsReady(p.pid)
        reason:="尚未取得 Game.pdb 資料位置"
    else if autoSwitchRunning
        reason:="請先停止「遊戲視窗自動切換」，避免錄製途中切走視窗"
    else if invRunning
        reason:="背包清理正在執行"
    else if processingQueue || foregroundOwner!=""
        reason:="自動登入 / 恢復正在進行"
    if reason!="" {
        AddRecentEvent("⚠ 無法開始錄製：" reason)
        MsgBox "無法開始錄製：" reason,"示範錄製","Icon! 0x40000"
        return
    }
    dir:=A_ScriptDir "\Logs\Recordings\" FormatTime(,"yyyyMMdd_HHmmss") "_" p.name
    DirCreate dir
    WinGetClientPos(&cx,&cy,&cw,&ch,"ahk_id " p.hwnd)
    recorder:={idx:idx,name:p.name,hwnd:p.hwnd,pid:p.pid,dir:dir,file:dir "\events.txt"
        ,start:A_TickCount,count:0,down:0,snap:RecorderSnapshot(p.pid)}
    RecorderWrite("示範錄製｜角色 " p.name "｜開始 " FormatTime(,"yyyy-MM-dd HH:mm:ss")
        . "｜遊戲畫面 " cw "x" ch "｜座標皆為相對遊戲畫面左上角`r`n`r`n【開始時的資料】`r`n" DailyRoleDumpText(p) "`r`n【操作紀錄】")
    Hotkey "~*LButton",(*)=>RecorderMouse("左鍵",true),"On"
    Hotkey "~*LButton Up",(*)=>RecorderMouse("左鍵",false),"On"
    Hotkey "~*RButton",(*)=>RecorderMouse("右鍵",true),"On"
    Hotkey "~*RButton Up",(*)=>RecorderMouse("右鍵",false),"On"
    ih:=InputHook("V")
    ih.KeyOpt("{All}","N")
    ih.OnKeyDown:=RecorderKey
    ih.Start()
    recorder.ih:=ih
    RecorderWrite(RecorderSkillBarText(p.pid))
    recorder.state:="",recorder.statePos:=0,recorder.stateTick:=0,recorder.mats:=""
    SetTimer RecorderStateTick,300
    EventLog(p.name,"RECORDER_START","開始示範錄製｜" dir)
    AddRecentEvent("⏺ 開始示範錄製：" p.name "（只記錄這個遊戲視窗內的操作）")
    SetTimer RecorderWatch,1000
}

RecorderStop(reason:="使用者停止") {
    global recorder,profiles
    if !IsObject(recorder)
        return
    for key in ["~*LButton","~*LButton Up","~*RButton","~*RButton Up"]
        try Hotkey key,"Off"
    try recorder.ih.Stop()
    SetTimer RecorderWatch,0
    SetTimer RecorderStateTick,0
    RecorderSnapshotDiff()
    p:=profiles[recorder.idx]
    tail:="`r`n【結束時的資料】（" reason "｜共 " recorder.count " 次滑鼠操作｜" Floor((A_TickCount-recorder.start)/1000) " 秒）`r`n"
    if p.pid && ProfileGameAlive(p)
        tail.=DailyRoleDumpText(p)
    RecorderWrite(tail)
    dir:=recorder.dir,name:=recorder.name
    recorder:=0
    EventLog(name,"RECORDER_STOP",reason "｜" dir)
    AddRecentEvent("⏹ 示範錄製已結束：" name "｜" dir)
    try Run('explorer.exe "' dir '"')
}

; 遊戲視窗消失就自動結束錄製。
RecorderWatch() {
    global recorder
    if IsObject(recorder) && !WinExist("ahk_id " recorder.hwnd)
        RecorderStop("遊戲視窗已關閉")
}

RecorderWrite(text) {
    global recorder
    try FileAppend text "`r`n",recorder.file,"UTF-8"
}

RecorderElapsed() {
    global recorder
    return Format("{:.2f}",(A_TickCount-recorder.start)/1000) "s"
}

RecorderMouse(button,down) {
    global recorder,RECORDER_DRAG_PX
    if !IsObject(recorder)
        return
    MouseGetPos(&mx,&my,&win)
    if win!=recorder.hwnd
        return
    WinGetClientPos(&cx,&cy,&cw,&ch,"ahk_id " recorder.hwnd)
    rx:=mx-cx,ry:=my-cy
    if down {
        recorder.count+=1
        n:=Format("{:03}",recorder.count)
        shot:=n ".png"
        CaptureScreenPng(cx,cy,cw,ch,recorder.dir "\" shot)
        recorder.down:={button:button,x:rx,y:ry,n:n}
        RecorderWrite("[" n "] " RecorderElapsed() " " button "按下 (" rx "," ry ")｜截圖 " shot)
        RecorderMaterialScreens(cw,ch)
        return
    }
    d:=recorder.down
    drag:=(IsObject(d) && (Abs(rx-d.x)>RECORDER_DRAG_PX || Abs(ry-d.y)>RECORDER_DRAG_PX)) ? "｜拖曳：(" d.x "," d.y ") → (" rx "," ry ")" : ""
    RecorderWrite("[" (IsObject(d) ? d.n : "---") "] " RecorderElapsed() " " button "放開 (" rx "," ry ")" drag)
    recorder.down:=0
    SetTimer RecorderSnapshotDiff,-500
}

RecorderKey(ih,vk,sc) {
    global recorder
    if !IsObject(recorder) || !WinActive("ahk_id " recorder.hwnd)
        return
    RecorderWrite("[鍵] " RecorderElapsed() " 按鍵 " GetKeyName(Format("vk{:x}sc{:x}",vk,sc)))
    SetTimer RecorderSnapshotDiff,-600
}

; 裝備欄 / 背包 / 銀行的快照：Map(位置 → 道具描述)。讀取失敗的部分不放入。
RecorderSnapshot(pid) {
    global GAME_EQUIP_SLOT_NAMES
    snap:=Map()
    equip:=ReadGameEquipment(pid)
    if IsObject(equip)
        for i,s in equip
            snap["裝備 " Format("{:02}",i-1) " " GAME_EQUIP_SLOT_NAMES[i]]:=s ? RecorderItemText(pid,s) : "（空）"
    for part in [["背包","InvenOffset"],["銀行","BankOffset"]] {
        slots:=ReadGameInventorySlots(pid,part[2])
        if IsObject(slots) {
            snap[part[1] " *"]:="ok"
            for s in slots
                snap[part[1] " (" s.x "," s.y ")"]:=RecorderItemText(pid,s)
        }
    }
    return snap
}

RecorderItemText(pid,s) {
    text:=s.key " " GameItemName(s.key,pid)
    if s.count>1
        text.=" ×" s.count
    if s.disguiseKey!=""
        text.="｜造型 " s.disguiseKey " " GameItemName(s.disguiseKey,pid)
    return text
}

RecorderSnapshotDiff() {
    global recorder
    if !IsObject(recorder)
        return
    now:=RecorderSnapshot(recorder.pid)
    old:=recorder.snap
    lines:=""
    for key,val in now {
        if SubStr(key,-1)="*"
            continue
        prev:=old.Has(key) ? old[key] : "（空）"
        if prev!=val
            lines.="    變化｜" key "：" prev " → " val "`r`n"
    }
    for key,val in old {
        if SubStr(key,-1)="*" || now.Has(key)
            continue
        ; 背包 / 銀行的那一部分這次讀取失敗時不算「消失」
        part:=SubStr(key,1,2)
        if !now.Has(part " *") && part!="裝備"
            continue
        lines.="    變化｜" key "：" val " → （空）`r`n"
    }
    if lines!=""
        RecorderWrite(RTrim(lines,"`r`n"))
    recorder.snap:=now
}

; 擷取螢幕區域存成 PNG（遊戲視窗需在最上層；示範時本來就在最上層）。
CaptureScreenPng(x,y,w,h,path) {
    static token:=0
    if !token {
        DllCall("LoadLibrary","Str","gdiplus","Ptr")
        si:=Buffer(24,0),NumPut("UInt",1,si)
        DllCall("gdiplus\GdiplusStartup","Ptr*",&token,"Ptr",si,"Ptr",0)
    }
    hdcScreen:=DllCall("GetDC","Ptr",0,"Ptr")
    hdc:=DllCall("CreateCompatibleDC","Ptr",hdcScreen,"Ptr")
    hbm:=DllCall("CreateCompatibleBitmap","Ptr",hdcScreen,"Int",w,"Int",h,"Ptr")
    obm:=DllCall("SelectObject","Ptr",hdc,"Ptr",hbm,"Ptr")
    DllCall("BitBlt","Ptr",hdc,"Int",0,"Int",0,"Int",w,"Int",h,"Ptr",hdcScreen,"Int",x,"Int",y,"UInt",0x40CC0020)
    DllCall("SelectObject","Ptr",hdc,"Ptr",obm)
    bitmap:=0
    DllCall("gdiplus\GdipCreateBitmapFromHBITMAP","Ptr",hbm,"Ptr",0,"Ptr*",&bitmap)
    pngClsid:=Buffer(16)
    DllCall("ole32\CLSIDFromString","Str","{557CF406-1A04-11D3-9A73-0000F81EF32E}","Ptr",pngClsid)
    DllCall("gdiplus\GdipSaveImageToFile","Ptr",bitmap,"WStr",path,"Ptr",pngClsid,"Ptr",0)
    DllCall("gdiplus\GdipDisposeImage","Ptr",bitmap)
    DllCall("DeleteObject","Ptr",hbm)
    DllCall("DeleteDC","Ptr",hdc)
    DllCall("ReleaseDC","Ptr",0,"Ptr",hdcScreen)
}

; ---- v1.3.18.11 自動採礦用的狀態紀錄 ----

global GLAT_NAMES := Map(0,"待機",1,"移動",2,"攻擊",3,"技能",4,"受擊",5,"推拉",6,"採集",7,"對話",8,"對決結束",9,"倒下",10,"死亡")

RecorderSkillBarText(pid) {
    text:="【技能快捷欄】（F1～F10 × 數字 1～0）"
    try {
        for s in MiningSkillSlots(pid)
            text.="`r`n    F" s.bar "-" (s.key=10 ? 0 : s.key) "：" s.name "（" s.id "）"
    }
    return text
}

; 每 0.3 秒：狀態有變化、移動超過 8 單位或移動中每 3 秒寫一行；附近礦石有變化時列出。
RecorderStateTick() {
    global recorder,GLAT_NAMES
    if !IsObject(recorder)
        return
    pid:=recorder.pid
    st:=0
    try st:=MiningCharState(pid)
    if IsObject(st) {
        act:=GLAT_NAMES.Has(st.action) ? GLAT_NAMES[st.action] : st.action
        key:=st.mapId "|" act "|" st.actState "|" st.vehicle "|" st.vehicleReq "|" st.vehicleActive "|" st.skillBar "|" st.runSkill "|" st.activeSkill "|" (st.hp>0)
        moved:=!IsObject(recorder.statePos) ? 999 : Sqrt((st.x-recorder.statePos.x)**2+(st.z-recorder.statePos.z)**2)
        if key!=recorder.state || moved>8 && A_TickCount-recorder.stateTick>=3000 || moved>40 {
            RecorderWrite("[狀態] " RecorderElapsed() " 地圖 " st.mapId "｜位置 (" Round(st.x,1) "," Round(st.y,1) "," Round(st.z,1) ")"
                . "｜動作 " act "/" Format("0x{:X}",st.actState)
                . "｜坐騎 騎乘=" st.vehicle " 請求中=" st.vehicleReq " 啟用=" st.vehicleActive
                . "｜技能欄 F" (st.skillBar+1) "｜右鍵技能 " MiningSkillName(pid,st.runSkill) "（" st.runSkill "）"
                . "｜使用中技能 " MiningSkillName(pid,st.activeSkill) "（" st.activeSkill "）"
                . "｜HP " st.hp "/" st.hpMax)
            recorder.state:=key,recorder.statePos:={x:st.x,z:st.z},recorder.stateTick:=A_TickCount
        }
    }
    ; 礦石（○能原石，屬於怪物）：出現 / 消失 / HP 變化時列出；距離 = 與角色的平面距離
    ores:=0
    try ores:=MiningCrows(pid,"原石")
    if IsObject(ores) {
        sig:=""
        for m in ores
            sig.=m.glob ":" m.hp ":" m.action ";"
        if sig!=recorder.mats {
            text:="[礦] " RecorderElapsed() " 附近礦石 " ores.Length " 顆"
            for m in ores {
                dist:=IsObject(st) ? Round(Sqrt((m.x-st.x)**2+(m.z-st.z)**2)) : "?"
                text.="`r`n    " m.name "#" m.glob "（" m.nid "）位置 (" Round(m.x,1) "," Round(m.y,1) "," Round(m.z,1) ")｜距離 " dist "｜HP " m.hp "｜動作 " (GLAT_NAMES.Has(m.action) ? GLAT_NAMES[m.action] : m.action)
            }
            RecorderWrite(text)
            recorder.mats:=sig
        }
    }
    ; 附近怪物總數與最遠距離（了解記憶體裡看得到多遠）：每 10 秒一次
    if A_TickCount-(recorder.HasOwnProp("crowTick") ? recorder.crowTick : 0)>=10000 && IsObject(st) {
        all:=0
        try all:=MiningCrows(pid)
        if IsObject(all) {
            far:=0
            for m in all
                far:=Max(far,Sqrt((m.x-st.x)**2+(m.z-st.z)**2))
            RecorderWrite("[範圍] " RecorderElapsed() " 記憶體裡的怪物 " all.Length " 隻｜最遠 " Round(far))
        }
        recorder.crowTick:=A_TickCount
    }
}

; 滑鼠按下時：附近礦石（○能原石）換算成畫面座標（用來驗證點礦的位置換算是否正確）。
RecorderMaterialScreens(cw,ch) {
    global recorder
    mats:=0
    try mats:=MiningCrows(recorder.pid,"原石")
    if !IsObject(mats) || !mats.Length
        return
    text:=""
    for m in mats {
        sc:=GameWorldToScreen(recorder.pid,m.x,m.y,m.z)
        if !IsObject(sc)
            continue
        ; 遊戲內部畫面大小和視窗大小不同時等比換算
        sx:=sc.HasOwnProp("vpw") && sc.vpw ? Round(sc.x*cw/sc.vpw) : sc.x,sy:=sc.HasOwnProp("vph") && sc.vph ? Round(sc.y*ch/sc.vph) : sc.y
        text.="`r`n    礦畫面位置｜" m.name "#" m.glob " → (" sx "," sy ")" (sc.visible ? "" : "（不在畫面內）") "｜遊戲畫面 " (sc.HasOwnProp("vpw") ? sc.vpw "x" sc.vph : "?")
    }
    if text!=""
        RecorderWrite(LTrim(text,"`r`n"))
}
