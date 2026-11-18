; 角色卡「現在在做什麼」：每個角色一行文字 + 等級（ok / warn / bad），網頁角色卡最上面顯示，異常的標紅。
; 11/18 豆奶離線 11 小時、小柯基禮盒用完 2 天都只能從日誌看出來：打開首頁就要看得到。
; 依序判斷：沒監控 → 重新登入 → 離線 → 死亡 → 每日討伐 → 採礦 → 打怪。
ProfileActivity(p) {
    global DH_RUNNING, DH_CHARS, MN_RUNNING, MN_CHARS
    if !p.enabled
        return {text: "", lv: ""}
    st := p.state
    if st = "需要人工處理" || st = "恢復失敗" || st = "需要人工確認"
        return {text: "離線：重新登入失敗" (p.HasOwnProp("loginNote") && p.loginNote != "" ? "（" p.loginNote "）" : "") "｜可按「重新登入」", lv: "bad"}
    if st = "排隊中" || st = "恢復中" || st = "載入中"
        return {text: "重新登入中", lv: "warn"}
    if !ProfileGameAlive(p)
        return {text: "離線：沒有遊戲視窗｜可按「重新登入」", lv: "bad"}
    if p.HasOwnProp("hpEventOpen") && p.hpEventOpen
        return {text: "💀 死亡中，等待復活", lv: "warn"}
    if DH_RUNNING && DH_CHARS.Has(p.name) && p.HasOwnProp("dh") && !p.dh.done && p.dh.text != ""
        return {text: "每日討伐：" p.dh.text, lv: ActivityLevel(p.dh.text)}
    if MN_RUNNING && MN_CHARS.Has(p.name) && p.HasOwnProp("mn") {
        if p.mn.HasOwnProp("boxesLeft") && p.mn.boxesLeft = 0 && !p.mn.inMine
            return {text: "採礦停：水晶礦場傳送卡禮盒用完了，請補貨", lv: "bad"}
        if p.mn.text != ""
            return {text: "採礦：" p.mn.text, lv: ActivityLevel(p.mn.text)}
    }
    aa := p.HasOwnProp("autoAtkPid") && p.autoAtkPid = p.pid ? p.autoAtk : -1
    if aa = 1
        return {text: "打怪中", lv: "ok"}
    if aa = 0
        return {text: "自動攻擊關閉", lv: "warn"}
    return {text: "", lv: ""}
}
; 狀態文字裡有警告字眼 → warn
ActivityLevel(text) => RegExMatch(text, "⚠|失敗|卡住|不足|斷線|讀不到|稍後再試|等待中") ? "warn" : "ok"
ActivityJson(p) {
    a := ProfileActivity(p)
    return ',"activity":"' JsonEscapeWeb(a.text) '","activityLv":"' a.lv '"'
}
