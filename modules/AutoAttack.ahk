; ============================================================================
; v1.3.18.8 AutoAttack：讀取自動攻擊（F6）開關。
;
; F6 → CInnerInterface::UpdateShortcutAfter → GLCharacter::ReqAutoSystem(0)
;      切換 GLCharacter.m_sAutoSystem.sAutoSkill.bActive（Game.pdb 確認）。
; - 網頁顯示每個角色目前是否在自動攻擊。
; - 監控中的角色自動攻擊關閉超過 AlertMinutes 分鐘 → 提醒並發 Discord（每次關閉只提醒一次）。
; - 每日道具自動更換與登入後按鍵改成依實際狀態按 F6，不會按反。
; ============================================================================

global AUTOATTACK_ALERT_ENABLED := Integer(IniRead(INI,"AutoAttack","AlertEnabled","1"))
global AUTOATTACK_ALERT_MIN := Integer(IniRead(INI,"AutoAttack","AlertMinutes","3"))
global AUTOATTACK_TICK_MS := 3000

; 1 開、0 關；讀不到回傳 -1。
ReadGameAutoAttack(pid) {
    charBase:=GameCharBase(pid)
    if !charBase || !GameOffset("AutoSkillActiveOffset")
        return -1
    v:=GameReadNum(GameProcHandle(pid),charBase+GameOffset("AutoSkillActiveOffset"),"UInt")
    return v="" ? -1 : (v ? 1 : 0)
}

; 每 AUTOATTACK_TICK_MS 執行：記錄開 / 關變化，關閉太久就提醒。
AutoAttackTick() {
    global profiles,fastLoginCritical,dailyRunning,AUTOATTACK_ALERT_ENABLED,AUTOATTACK_ALERT_MIN
    if fastLoginCritical
        return
    for p in profiles {
        if !p.enabled || !p.pid || !ProfileGameAlive(p) || !GameOffsetsReady(p.pid) || !GameCharacterLoaded(p.pid)
            continue
        state:=ReadGameAutoAttack(p.pid)
        if state=-1
            continue
        if !p.HasOwnProp("autoAtkPid") || p.autoAtkPid!=p.pid {
            p.autoAtkPid:=p.pid,p.autoAtk:=state,p.autoAtkSince:=A_TickCount,p.autoAtkAlerted:=0
            continue
        }
        if state!=p.autoAtk {
            p.autoAtk:=state,p.autoAtkSince:=A_TickCount,p.autoAtkAlerted:=0
            EventLog(p.name,state ? "AUTO_ATTACK_ON" : "AUTO_ATTACK_OFF",state ? "自動攻擊開啟" : "自動攻擊關閉")
            continue
        }
        ; 只在「監控中、活著、沒有在換每日道具」時才提醒
        if state || p.autoAtkAlerted || !AUTOATTACK_ALERT_ENABLED || p.state!="監控中" || p.hpEventOpen || dailyRunning=p.name
            continue
        offMin:=(A_TickCount-p.autoAtkSince)/60000
        if offMin<AUTOATTACK_ALERT_MIN
            continue
        p.autoAtkAlerted:=1
        where:=""
        try where:=NotificationLocationText(p)
        EventLog(p.name,"AUTO_ATTACK_IDLE","自動攻擊已關閉 " Floor(offMin) " 分鐘｜" where)
        AddRecentEvent("💤 " p.name " 自動攻擊已關閉 " Floor(offMin) " 分鐘（" where "）")
        ReportEventShot(p,"💤 HIHIYONG 角色沒有在自動打怪`n角色：" p.name "`n所在地圖：" where "`n自動攻擊（F6）已關閉 " Floor(offMin) " 分鐘，請確認。（附上當下畫面）")
    }
}

; 網頁欄位：autoAttack 1 / 0 / -1（讀不到）。
; 使用 AutoAttackTick 最後讀到的值（每 3 秒更新），不在網頁刷新時讀遊戲。
AutoAttackJson(p) {
    state:=(p.HasOwnProp("autoAtkPid") && p.autoAtkPid=p.pid && ProfileGameAlive(p)) ? p.autoAtk : -1
    return ',"autoAttack":' state
}

; 登入後按鍵含 F6 時，確認自動攻擊真的開了；沒開（按鍵沒被遊戲吃到）就再按一次。
AutoAttackVerifyAfterPostKeys(hwnd, name, post) {
    if !RegExMatch(post,"i)(^|,)\s*F6\s*(,|$)")
        return
    pid:=0
    try pid:=WinGetPID("ahk_id " hwnd)
    if !pid
        return
    Sleep 800
    state:=ReadGameAutoAttack(pid)
    if state!=0
        return
    EventLog(name,"AUTO_ATTACK_FIX","登入後按鍵已送出 F6，但自動攻擊仍是關閉｜再按一次 F6")
    try {
        ActivateGame(hwnd)
        SendOneKey("F6")
        Sleep 800
    }
    EventLog(name,ReadGameAutoAttack(pid)=1 ? "AUTO_ATTACK_ON" : "AUTO_ATTACK_FIX_FAIL",ReadGameAutoAttack(pid)=1 ? "補按 F6 後自動攻擊已開啟" : "補按 F6 後自動攻擊仍未開啟")
}
