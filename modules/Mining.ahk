; ============================================================================
; v1.3.18.11 Mining：自動採礦用的遊戲資料讀取（目前供示範錄製記錄，自動流程之後依錄製內容建立）。
;
; - MiningCharState：角色位置、動作（GLAT_GATHERING = 採集中）、坐騎三個開關、目前技能欄、右鍵技能。
; - MiningMaterials：附近的採集物（礦石）清單（GLLandManClient.m_GlobMaterialList）。
; - GameWorldToScreen：世界座標 → 遊戲畫面座標（DxViewPort 的 view / projection 矩陣）。
; - MiningSkillSlots：技能快捷欄（F1～F10 × 1～0）裡每一格的技能名稱。
; ============================================================================

global GLAT_GATHERING := 6

MiningOffsetsOk(pid) {
    return GameOffsetsReady(pid) && GameOffset("LandMaterialListOffset") && GameOffset("ViewPortInstanceRva")
}

; {x,y,z, action, actState, vehicle, vehicleReq, vehicleActive, skillBar(0～9), runSkill, activeSkill, hp, hpMax, mapId}；讀不到回傳 0。
MiningCharState(pid) {
    if !MiningOffsetsOk(pid)
        return 0
    charBase:=GameCharBase(pid)
    if !charBase
        return 0
    hProc:=GameProcHandle(pid)
    pos:=GameReadBuf(hProc,charBase+GameOffset("CharPosOffset"),12)
    if !pos
        return 0
    st:={x:NumGet(pos,0,"Float"),y:NumGet(pos,4,"Float"),z:NumGet(pos,8,"Float")}
    st.action:=GameReadNum(hProc,charBase+GameOffset("CharActionOffset"),"UInt")
    st.actState:=GameReadNum(hProc,charBase+GameOffset("CharActStateOffset"),"UInt")
    st.vehicle:=GameReadNum(hProc,charBase+GameOffset("VehicleOnOffset"),"UInt")
    st.vehicleReq:=GameReadNum(hProc,charBase+GameOffset("VehicleReqOffset"),"UInt")
    st.vehicleActive:=GameReadNum(hProc,charBase+GameOffset("VehicleActiveOffset"),"UInt")
    st.skillBar:=GameReadNum(hProc,charBase+GameOffset("SkillQuickActOffset"),"UShort")
    st.runSkill:=MiningSkillId(GameReadBuf(hProc,charBase+GameOffset("RunSkillOffset"),4))
    st.activeSkill:=MiningSkillId(GameReadBuf(hProc,charBase+GameOffset("ActiveSkillOffset"),4))
    hpNow:=0,hpMax:=0
    ReadGameHP(pid,&hpNow,&hpMax)
    st.hp:=hpNow,st.hpMax:=hpMax
    st.mapId:=ReadGameMapId(pid)
    return st
}

MiningSkillId(buf) {
    if !buf
        return ""
    mid:=NumGet(buf,0,"UShort"),sid:=NumGet(buf,2,"UShort")
    return mid=0xFFFF ? "" : mid "-" sid
}

; 技能名稱（GLStringTable 技能字串表，key = SN_主ID_子ID）。
MiningSkillName(pid,skillId) {
    static cache:=Map()
    if skillId=""
        return ""
    if cache.Has(skillId)
        return cache[skillId]
    parts:=StrSplit(skillId,"-")
    name:=GameStringLookup(pid,Format("SN_{:03}_{:03}",parts[1],parts[2]),"SkillStringMapOffset")
    if name!=""
        cache[skillId]:=name
    return name!="" ? name : "技能 " skillId
}

; 技能快捷欄 100 格：[{bar:1～10（F1～F10）, key:1～10（數字 1～0）, id, name}]，只列有技能的格子。
MiningSkillSlots(pid) {
    charBase:=GameCharBase(pid)
    if !charBase || !GameOffset("SkillQuickOffset")
        return []
    buf:=GameReadBuf(GameProcHandle(pid),charBase+GameOffset("SkillQuickOffset"),400)
    slots:=[]
    if !buf
        return slots
    Loop 100 {
        mid:=NumGet(buf,(A_Index-1)*4,"UShort"),sid:=NumGet(buf,(A_Index-1)*4+2,"UShort")
        if mid=0xFFFF || (mid=0 && sid=0)
            continue
        id:=mid "-" sid
        slots.Push({bar:(A_Index-1)//10+1,key:Mod(A_Index-1,10)+1,id:id,name:MiningSkillName(pid,id)})
    }
    return slots
}

; 附近的怪物（礦石「○能原石」也是怪物，挖礦 = 用採礦技能把它的 HP 打到 0）：
; [{glob, nid, name, x, y, z, hp, action}]；只要名稱含 nameFilter 的（空字串 = 全部）；讀不到回傳 0。
MiningCrows(pid, nameFilter:="") {
    if !MiningOffsetsOk(pid)
        return 0
    inst:=GameGaeaBase(pid)
    if !inst
        return 0
    hProc:=GameProcHandle(pid)
    land:=GameReadNum(hProc,inst+GameOffset("LandPtrOffset"),"Ptr")
    if !land
        return 0
    list:=land+GameOffset("LandCrowListOffset")
    amount:=GameReadNum(hProc,list,"UInt")
    node:=GameReadNum(hProc,list+GameOffset("CrowListHeadOffset"),"Ptr")
    if amount="" || node="" || amount>KILL_MAX_CROWS
        return 0
    base:=GetGameModuleBase(pid,hProc)
    span:=Max(GameOffset("CrowActionOffset"),GameOffset("CrowGlobIdOffset"),GameOffset("CrowHpNowOffset"),GameOffset("CrowPosOffset")+8)+4
    out:=[]
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
        if !cb || !GameRvaInList("CrowVftableRvas",NumGet(cb,0,"Ptr")-base)
            continue
        nid:=NumGet(cb,GameOffset("CrowNativeIdOffset"),"UShort") "-" NumGet(cb,GameOffset("CrowNativeIdOffset")+2,"UShort")
        name:=KillCrowName(pid,hProc,NumGet(cb,GameOffset("CrowDataPtrOffset"),"Ptr"),nid)
        if nameFilter!="" && !InStr(name,nameFilter)
            continue
        po:=GameOffset("CrowPosOffset")
        out.Push({glob:NumGet(cb,GameOffset("CrowGlobIdOffset"),"UInt"),nid:nid,name:name
            ,x:NumGet(cb,po,"Float"),y:NumGet(cb,po+4,"Float"),z:NumGet(cb,po+8,"Float")
            ,hp:NumGet(cb,GameOffset("CrowHpNowOffset"),"UInt"),action:NumGet(cb,GameOffset("CrowActionOffset"),"UInt")})
    }
    return out
}

; 附近的採集物：[{glob, nid, name, x, y, z, action}]；讀不到回傳 0。
MiningMaterials(pid) {
    if !MiningOffsetsOk(pid)
        return 0
    inst:=GameGaeaBase(pid)
    if !inst
        return 0
    hProc:=GameProcHandle(pid)
    land:=GameReadNum(hProc,inst+GameOffset("LandPtrOffset"),"Ptr")
    if !land
        return 0
    list:=land+GameOffset("LandMaterialListOffset")
    amount:=GameReadNum(hProc,list,"UInt")
    node:=GameReadNum(hProc,list+GameOffset("CrowListHeadOffset"),"Ptr")
    if amount="" || node="" || amount>500
        return 0
    base:=GetGameModuleBase(pid,hProc)
    span:=Max(GameOffset("MaterialActionOffset"),GameOffset("MaterialGlobIdOffset"),GameOffset("MaterialPosOffset")+8)+4
    out:=[]
    Loop amount {
        if !node
            break
        nb:=GameReadBuf(hProc,node,GameOffset("CrowNodeNextOffset")+8)
        if !nb
            break
        node:=NumGet(nb,GameOffset("CrowNodeNextOffset"),"Ptr")
        m:=NumGet(nb,GameOffset("CrowNodeDataOffset"),"Ptr")
        if !m
            continue
        b:=GameReadBuf(hProc,m,span)
        if !b || !GameRvaInList("MaterialVftableRvas",NumGet(b,0,"Ptr")-base)
            continue
        nid:=NumGet(b,GameOffset("MaterialNativeIdOffset"),"UShort") "-" NumGet(b,GameOffset("MaterialNativeIdOffset")+2,"UShort")
        po:=GameOffset("MaterialPosOffset")
        out.Push({glob:NumGet(b,GameOffset("MaterialGlobIdOffset"),"UInt"),nid:nid
            ,name:KillCrowName(pid,hProc,NumGet(b,GameOffset("MaterialDataPtrOffset"),"Ptr"),nid)
            ,x:NumGet(b,po,"Float"),y:NumGet(b,po+4,"Float"),z:NumGet(b,po+8,"Float")
            ,action:NumGet(b,GameOffset("MaterialActionOffset"),"UInt")})
    }
    return out
}

GameRvaInList(key,rva) {
    global gameOffsets
    if !gameOffsets.Has(key)
        return false
    for s in StrSplit(gameOffsets[key],"|")
        if s!="" && Integer(s)=rva
            return true
    return false
}

; 世界座標 → 遊戲畫面（client 區）座標：{x, y, visible}；讀不到回傳 0。
; D3D 列向量：clip = [x y z 1] × View × Proj；畫面 = ViewPort.X + (ndc.x+1)/2 × W，ViewPort.Y + (1-ndc.y)/2 × H。
GameWorldToScreen(pid,wx,wy,wz) {
    if !GameOffset("ViewPortInstanceRva")
        return 0
    hProc:=GameProcHandle(pid)
    base:=hProc ? GetGameModuleBase(pid,hProc) : 0
    if !base
        return 0
    vp:=base+GameOffset("ViewPortInstanceRva")
    b:=GameReadBuf(hProc,vp,GameOffset("ViewPortRectOffset")+24)
    if !b || !GameRvaInList("ViewPortVftableRvas",NumGet(b,0,"Ptr")-base)
        return 0
    v:=GameOffset("ViewMatrixOffset"),p:=GameOffset("ProjMatrixOffset"),r:=GameOffset("ViewPortRectOffset")
    M(o,row,col) => NumGet(b,o+(row*4+col)*4,"Float")
    ; view
    vx:=wx*M(v,0,0)+wy*M(v,1,0)+wz*M(v,2,0)+M(v,3,0)
    vy:=wx*M(v,0,1)+wy*M(v,1,1)+wz*M(v,2,1)+M(v,3,1)
    vz:=wx*M(v,0,2)+wy*M(v,1,2)+wz*M(v,2,2)+M(v,3,2)
    ; projection
    cx:=vx*M(p,0,0)+vy*M(p,1,0)+vz*M(p,2,0)+M(p,3,0)
    cy:=vx*M(p,0,1)+vy*M(p,1,1)+vz*M(p,2,1)+M(p,3,1)
    cw:=vx*M(p,0,3)+vy*M(p,1,3)+vz*M(p,2,3)+M(p,3,3)
    vpx:=NumGet(b,r,"UInt"),vpy:=NumGet(b,r+4,"UInt"),vpw:=NumGet(b,r+8,"UInt"),vph:=NumGet(b,r+12,"UInt")
    ; 在鏡頭後方：沒有畫面座標（仍回傳畫面大小，呼叫端不必另外判斷）
    if cw<=0.0001
        return {x:-1,y:-1,visible:false,vpw:vpw,vph:vph}
    nx:=cx/cw,ny:=cy/cw
    sx:=vpx+(nx+1)/2*vpw,sy:=vpy+(1-ny)/2*vph
    return {x:Round(sx),y:Round(sy),visible:Abs(nx)<=1 && Abs(ny)<=1,vpw:vpw,vph:vph}
}
