; ============================================================================
; 自動採礦排班接力（v1.3.90.71）：每個角色設一個「幾點進礦場」，照時間排成順序，一次只有一隻在礦場。
;
;   - 第一隻：時間到了才開始（程式晚開超過 60 分鐘 → 今天不跑，通知 Discord）。
;   - 換人以實際為準：上一隻「結束」了，下一隻馬上接著進場，不管它設定的時間（設定時間只用來排順序和估算）。
;     結束 = 跑滿這個角色的「進礦場趟數」後被踢出，或背包和銀行都沒有入場卷（傳送卡 / 禮盒）。
;     結束的角色不動作（不回怪區），Discord 通報「這隻結束」；全部跑完再通報一次。
;   - 下一隻 5 分鐘內都不能開始（不在監控中、沒有視窗、正在跑每日討伐、沒開自動進圖）→ 略過它，換下一隻，通知 Discord。
;   - 上一隻王打到一半被踢出 → 下一隻進場後接著打（AutoMining.ahk 的 MN_RELAY_BOSS）。
;   - 每次進場先讀一次王的重生時間（AutoMining.ahk 的 MN_ENTRY_BOSSTIMER）。
;   - 頁面顯示每隻的預估開始時間：一趟約 MN_RELAY_TRIP_MIN 分鐘 × 趟數；設定時間和預估差 30 分鐘以上就顯示警語。
;   - 你在頁面按「■ 停止」自動採礦 → 今天的排班也停止，不會再換下一隻。
; 手動接力（v1.3.90.75）：沒有排班、勾了 2 隻以上按「▶ 啟動」→ 照帳號清單順序接力，第一隻馬上開始，規則同上；
;   全部跑完（或按停止）就停止自動採礦，勾選恢復成原本勾的角色。記在 [AutoMiningRelay] Manual（| 分隔）/ ManualStart。
; 設定檔：[AutoMiningSchedule] 角色名=HH:MM；當天狀態 [AutoMiningRelay] Day / Active / Done / Stopped / Note_角色名。
; ============================================================================
global MN_SCHED_SEC := "AutoMiningSchedule"
global MN_SCHED_GRACE_MS := 300000
global MN_SCHED_LATE_MAX_MS := 3600000
global MN_RELAY_TRIP_MIN := Integer(MnIniGet("RelayTripMin", "150"))   ; 一趟大約幾分鐘（11/22 實際 124～150 分鐘）
global MN_SCHED := Map(), MN_SCHED_LOADED := false   ; Map(角色名稱 → "06:00")
global MN_RELAY_BOOT := true, MN_RELAY_WAIT := Map()  ; 重開程式後第一次檢查；角色等不能開始的起點（A_TickCount）

MnSchedEnsure() {
    global INI, MN_SCHED, MN_SCHED_LOADED, MN_SCHED_SEC, profiles
    if MN_SCHED_LOADED
        return
    if !IsSet(profiles) || !IsObject(profiles) || !profiles.Length
        return
    MN_SCHED_LOADED := true
    MN_SCHED := Map()
    for p in profiles {
        txt := ""
        try txt := IniRead(INI, MN_SCHED_SEC, p.name, "")
        arr := DhSchedParse(txt)
        if arr.Length
            MN_SCHED[p.name] := arr[1]
    }
}

; rawValue：角色名稱~HH:MM（空白 = 不排班）
AutoMiningSchedSet(rawValue) {
    global INI, MN_SCHED, MN_SCHED_SEC
    MnSchedEnsure()
    cut := InStr(rawValue, "~", , -1)
    if !cut
        return
    name := Trim(SubStr(rawValue, 1, cut - 1)), text := SubStr(rawValue, cut + 1)
    if name = ""
        return
    arr := DhSchedParse(text)
    if arr.Length {
        MN_SCHED[name] := arr[1]
        IniWrite arr[1], INI, MN_SCHED_SEC, name
        EventLog(name, "MN_SCHED_SET", "採礦排班：" arr[1] " 進礦場" (arr.Length > 1 ? "（排班只用第一個時間）" : ""))
    } else {
        if MN_SCHED.Has(name)
            MN_SCHED.Delete(name)
        try IniDelete INI, MN_SCHED_SEC, name
        EventLog(name, "MN_SCHED_SET", "採礦排班：已取消")
    }
    for w in MnRelayPlan()
        if w.warn != ""
            EventLog(w.name, "MN_RELAY_WARN", w.warn)
}

; ---- 當天狀態 ----
MnRelayGet(k, def := "") {
    global INI
    v := def
    try v := IniRead(INI, "AutoMiningRelay", k, def)
    return v
}
MnRelaySetKey(k, v) {
    global INI
    try IniWrite v, INI, "AutoMiningRelay", k
}
MnRelayDoneList() {
    d := MnRelayGet("Done")
    return d = "" ? [] : StrSplit(d, "|")
}
MnRelayIsDone(name) {
    for n in MnRelayDoneList()
        if n = name
            return true
    return false
}
MnRelayNewDay() {
    global INI
    try IniDelete INI, "AutoMiningRelay"
    MnRelaySetKey("Day", SubStr(A_Now, 1, 8))
}

; 手動接力：按「▶ 啟動」時勾的角色（照帳號清單順序）
MnRelayManualBegin() {
    global INI, MN_CHARS, profiles
    names := ""
    for p in profiles
        if MN_CHARS.Has(p.name)
            names .= (names = "" ? "" : "|") p.name
    try IniDelete INI, "AutoMiningRelay"
    MnRelaySetKey("Day", SubStr(A_Now, 1, 8))
    MnRelaySetKey("Manual", names)
    MnRelaySetKey("ManualStart", FormatTime(, "HH:mm"))
    MN_CHARS := Map()   ; 先清空，接力每次只放一隻進去（10 秒內第一隻開始）
    MnSchedPersist()
    EventLog("GLOBAL", "MN_RELAY_MANUAL", "手動啟動自動採礦，勾了 " StrSplit(names, "|").Length " 隻 → 接力（一次一隻）：" StrReplace(names, "|", " → "))
    AddRecentEvent("⛏ 自動採礦接力：" StrReplace(names, "|", " → "))
}
MnRelayManualList() {
    m := MnRelayGet("Manual")
    return m = "" ? [] : StrSplit(m, "|")
}
; 手動接力結束（跑完 / 停止）：停止自動採礦，勾選恢復成原本勾的角色
MnRelayManualEnd(why) {
    global MN_RUNNING, MN_CHARS
    list := MnRelayManualList()
    if !list.Length
        return
    MN_CHARS := Map()
    for n in list
        MN_CHARS[n] := 1
    MN_RUNNING := 0
    MnSchedPersist()
    MnRelaySetKey("Manual", "")
    EventLog("GLOBAL", "MN_RELAY_MANUAL", "手動接力結束（" why "）｜自動採礦已停止，勾選恢復成原本的角色")
}

; 照時間排好的順序：[{name, time}]；手動接力中 = 按啟動時勾的角色（time 空白）
MnRelayOrder() {
    global MN_SCHED, profiles
    MnSchedEnsure()
    out := []
    for n in MnRelayManualList()
        out.Push({name: n, time: ""})
    if out.Length
        return out
    for p in profiles
        if MN_SCHED.Has(p.name)
            out.Push({name: p.name, time: MN_SCHED[p.name]})
    n := out.Length
    Loop n - 1 {
        i := A_Index
        Loop n - i {
            j := A_Index
            if StrCompare(out[j].time, out[j + 1].time) > 0
                tmp := out[j], out[j] := out[j + 1], out[j + 1] := tmp
        }
    }
    return out
}
MnRelayProfile(name) {
    global profiles
    for p in profiles
        if p.name = name
            return p
    return 0
}
MnHmToMin(t) => Integer(SubStr(t, 1, 2)) * 60 + Integer(SubStr(t, 4, 2))
MnMinToHm(m) => Format("{:02d}:{:02d}", Mod(m // 60, 24), Mod(m, 60)) (m >= 1440 ? "（隔天）" : "")

; 預估：[{name, time, loops, est, warn, tickets}]。第一隻用設定時間，之後每隻 = 上一隻開始 + 趟數 × 一趟分鐘
MnRelayPlan() {
    global MN_RELAY_TRIP_MIN
    out := [], est := -1, endless := ""
    for i, r in MnRelayOrder() {
        p := MnRelayProfile(r.name)
        loops := IsObject(p) ? MnLoopsOf(p) : 0
        tickets := IsObject(p) && p.HasOwnProp("mn") && IsObject(p.mn) && p.mn.HasOwnProp("boxesLeft") ? p.mn.boxesLeft : -1
        warn := ""
        if i = 1 {
            est := MnHmToMin(r.time != "" ? r.time : MnRelayGet("ManualStart", FormatTime(, "HH:mm")))
        } else if endless != "" {
            warn := "上一隻「" endless "」趟數是 0：入場卷用完才換下一隻，現在預估不了時間（進過礦場、讀到禮盒數之後就能預估）"
        } else if r.time != "" && Abs(MnHmToMin(r.time) - est) >= 30 {
            warn := "設定 " r.time "，照上一隻的趟數預估 " MnMinToHm(est) " 才會輪到；實際以上一隻結束的時間為準（可能提早或延後）"
        }
        ; 入場卷比趟數少：實際只跑得了入場卷那麼多趟（禮盒數讀過才知道；背包裡已經開好的傳送卡不算在內）
        eff := loops
        if tickets >= 0 && loops > 0 && tickets < loops {
            eff := Max(1, tickets)
            warn .= (warn = "" ? "" : "｜") "入場卷（禮盒）只剩 " tickets " 個，少於趟數 " loops "，大概只跑得了 " eff " 趟，下一隻會提早接續"
        } else if loops = 0 && tickets >= 0 {
            loops := -1, eff := Max(1, tickets + 1)   ; 趟數 0：跑到入場卷用完（禮盒數 + 背包裡已開好的傳送卡，約 +1）
        }
        out.Push({name: r.name, time: r.time != "" ? r.time : "接力", loops: loops < 0 ? 0 : loops, est: endless != "" ? "—" : MnMinToHm(est), warn: warn, tickets: tickets})
        if loops = 0 && endless = ""
            endless := r.name
        else if endless = ""
            est += eff * MN_RELAY_TRIP_MIN
    }
    return out
}

; 不能開始的原因（"" = 可以）
MnSchedWhyNot(p) {
    global MN_AUTOENTER, DH_RUNNING, DH_CHARS
    if !MnFeatureOK()
        return "這台電腦沒有有效的使用授權"
    if !p.enabled
        return "這個帳號沒有勾選"
    if p.state != "監控中"
        return "帳號狀態是「" p.state "」，不是監控中"
    alive := false
    try alive := p.pid && ProfileGameAlive(p)
    if !alive
        return "找不到遊戲視窗"
    if IsSet(DH_RUNNING) && DH_RUNNING && IsSet(DH_CHARS) && DH_CHARS.Has(p.name) && p.HasOwnProp("dh") && IsObject(p.dh) && !p.dh.done
        return "這個角色正在跑每日討伐"
    if !MN_AUTOENTER
        return "「沒在水晶礦場時自動進圖」沒有開"
    return ""
}

MnSchedPersist() {
    global INI, MN_CHARS, MN_RUNNING
    names := ""
    for n, _ in MN_CHARS
        names .= (names = "" ? "" : "|") n
    IniWrite names, INI, "AutoMining", "Chars"
    IniWrite MN_RUNNING, INI, "AutoMining", "Running"
}

MnRelayStart(p, idx, total, resume := false) {
    global MN_RUNNING, MN_CHARS, MN_RESUMED, profiles
    ; 排班裡的其他角色不在採礦清單（一次只有一隻）；不在排班裡、你手動勾的角色不動
    for r in MnRelayOrder()
        if r.name != p.name && MN_CHARS.Has(r.name)
            MN_CHARS.Delete(r.name)
    MN_CHARS[p.name] := 1
    if !resume {
        MnRunVisitsSave(p.name, 0)   ; 這隻從第 1 趟算
        if p.HasOwnProp("mn")
            p.DeleteProp("mn")
    } else {
        MN_RESUMED := true           ; 重開程式接續：趟數照設定檔記的
    }
    MN_RUNNING := 1
    p.mnActive := true
    MnSchedPersist()
    MnRelaySetKey("Active", p.name), MnRelaySetKey("ActiveSince", A_Now)
    loops := MnLoopsOf(p)
    msg := "採礦排班｜第 " idx " / " total " 隻開始" (resume ? "（重開程式接續）" : "") "｜趟數 " (loops ? loops " 趟" : "0（一直循環）")
    EventLog(p.name, "MN_RELAY_START", msg)
    AddRecentEvent("⏰ " p.name " " msg)
    if !resume
        try SendDiscordMessage("⏰ HIHIYONG 採礦排班`n" p.name " 開始進礦場（第 " idx " / " total " 隻）`n趟數：" (loops ? loops " 趟" : "0（一直循環）"))
}

MnRelayFinish(p, why, nextName) {
    global MN_RUNNING, MN_CHARS
    if MN_CHARS.Has(p.name)
        MN_CHARS.Delete(p.name)
    if !MN_CHARS.Count
        MN_RUNNING := 0
    p.mnActive := MN_RUNNING && MN_CHARS.Has(p.name)
    MnSchedPersist()
    d := MnRelayGet("Done")
    MnRelaySetKey("Done", (d = "" ? "" : d "|") p.name)
    MnRelaySetKey("Note_" p.name, why)
    MnRelaySetKey("Active", "")
    st := p.HasOwnProp("mn") && IsObject(p.mn) ? p.mn : 0
    sum := IsObject(st) ? "共 " st.visits " 趟、" st.gathers " 顆" : ""
    EventLog(p.name, "MN_RELAY_DONE", "採礦排班：這隻結束（" why "）" (sum != "" ? "｜" sum : "") "｜角色留在原地不動作" (nextName != "" ? "｜下一隻：" nextName : "｜排班全部結束"))
    AddRecentEvent("⏰ " p.name " 採礦排班結束（" why "）" (nextName != "" ? "，換 " nextName : ""))
    try SendDiscordMessage("✅ HIHIYONG 採礦排班`n" p.name " 結束：" why (sum != "" ? "`n" sum : "") "`n角色留在原地不動作。" (nextName != "" ? "`n下一隻：" nextName " 接著進場" : "`n今天的排班全部結束。"))
}

; 現在這隻是不是結束了："" = 還沒
MnRelayFinishedWhy(p) {
    global MN_RUNNING, MN_CHARS
    if !MN_RUNNING || !MN_CHARS.Has(p.name)
        return "stopped"
    st := p.HasOwnProp("mn") && IsObject(p.mn) ? p.mn : 0
    if !IsObject(st)
        return ""
    if st.loopDone
        return "跑滿 " st.visits " 趟"
    if st.HasOwnProp("noTickets") && st.noTickets && !st.inMine
        return "入場卷用完（跑了 " st.visits " 趟）"
    return ""
}

MnRelayNext(name) {
    order := MnRelayOrder(), hit := false
    for r in order {
        if hit && !MnRelayIsDone(r.name)
            return r.name
        if r.name = name
            hit := true
    }
    return ""
}

; 每 10 秒看一次
AutoMiningSchedTick() {
    global MN_RELAY_BOOT, MN_RELAY_WAIT, MN_SCHED_GRACE_MS, MN_SCHED_LATE_MAX_MS, MN_RUNNING, MN_CHARS
    order := MnRelayOrder()
    boot := MN_RELAY_BOOT, MN_RELAY_BOOT := false
    if !order.Length
        return
    active := MnRelayGet("Active")
    if active = "" && MnRelayGet("Day") != SubStr(A_Now, 1, 8) && !MnRelayManualList().Length
        MnRelayNewDay()
    if active != "" {
        p := MnRelayProfile(active)
        if !IsObject(p) {
            MnRelaySetKey("Active", "")
            return
        }
        idx := 0
        for i, r in order
            if r.name = active
                idx := i
        if boot && (!MN_RUNNING || !MN_CHARS.Has(active)) {   ; 重開程式：接著跑同一隻
            if MnSchedWhyNot(p) = ""
                MnRelayStart(p, idx, order.Length, true)
            return
        }
        why := MnRelayFinishedWhy(p)
        if why = "stopped" {   ; 你按了停止 / 取消勾選：今天的排班停止
            MnRelaySetKey("Active", ""), MnRelaySetKey("Stopped", "1")
            d := MnRelayGet("Done")
            MnRelaySetKey("Done", (d = "" ? "" : d "|") active), MnRelaySetKey("Note_" active, "手動停止")
            EventLog(active, "MN_RELAY_DONE", "自動採礦被停止 / 取消勾選，今天的採礦排班停止（不會再換下一隻）")
            MnRelayManualEnd("按了停止")
            return
        }
        if why != ""
            MnRelayFinish(p, why, MnRelayNext(active))
        return
    }
    if MnRelayGet("Stopped") = "1"
        return
    next := 0, idx := 0
    for i, r in order
        if !MnRelayIsDone(r.name) {
            next := r, idx := i
            break
        }
    if !IsObject(next) {
        if MnRelayGet("AllDone") != "1" && MnRelayDoneList().Length {
            MnRelaySetKey("AllDone", "1")
            EventLog("GLOBAL", "MN_RELAY_ALLDONE", "今天的採礦排班全部結束")
            MnRelayManualEnd("全部跑完")
        }
        return
    }
    p := MnRelayProfile(next.name)
    if idx = 1 && !MnRelayDoneList().Length && next.time != "" {   ; 排班的第一隻：等它的時間（手動接力馬上開始）
        due := SubStr(A_Now, 1, 8) StrReplace(next.time, ":") "00"
        if A_Now < due
            return
        lateSec := DateDiff(A_Now, due, "Seconds")
        if lateSec * 1000 > MN_SCHED_LATE_MAX_MS {
            MnRelaySetKey("Stopped", "1"), MnRelaySetKey("Note_" next.name, "程式晚開，今天沒跑")
            msg := "採礦排班今天沒有開始｜" next.name " 設定 " next.time "，管理程式到點時沒有在跑（已晚 " Round(lateSec / 60) " 分鐘）；需要的話請手動啟動自動採礦"
            EventLog(next.name, "MN_SCHED_MISSED", msg)
            try SendDiscordMessage("⚠️ HIHIYONG " msg)
            return
        }
    }
    why := MnSchedWhyNot(p)
    if why = "" {
        if MN_RELAY_WAIT.Has(p.name)
            MN_RELAY_WAIT.Delete(p.name)
        MnRelayStart(p, idx, order.Length)
        return
    }
    if !MN_RELAY_WAIT.Has(p.name)
        MN_RELAY_WAIT[p.name] := A_TickCount
    if A_TickCount - MN_RELAY_WAIT[p.name] >= MN_SCHED_GRACE_MS {   ; 等了 5 分鐘還是不行：略過這隻
        MN_RELAY_WAIT.Delete(p.name)
        d := MnRelayGet("Done")
        MnRelaySetKey("Done", (d = "" ? "" : d "|") p.name), MnRelaySetKey("Note_" p.name, "略過：" why)
        nx := MnRelayNext(p.name)
        msg := "採礦排班略過 " p.name "：等了 5 分鐘還是不能開始（" why "）" (nx != "" ? "，換 " nx : "")
        EventLog(p.name, "MN_SCHED_MISSED", msg)
        try SendDiscordMessage("⚠️ HIHIYONG " msg)
    }
}

; ---- 頁面 ----
MnSchedTimes(name) {
    global MN_SCHED
    MnSchedEnsure()
    return MN_SCHED.Has(name) ? MN_SCHED[name] : ""
}
MnSchedStatusText(name) {
    global MN_SCHED, MN_RELAY_WAIT
    MnSchedEnsure()
    inManual := false
    for n in MnRelayManualList()
        inManual := inManual || n = name
    if !MN_SCHED.Has(name) && !inManual
        return ""
    today := MnRelayGet("Day") = SubStr(A_Now, 1, 8) || MnRelayGet("Active") != "" || inManual
    if today && MnRelayGet("Active") = name
        return "採礦中（排班）"
    if today && MnRelayIsDone(name)
        return "已結束：" MnRelayGet("Note_" name)
    if today && MnRelayGet("Stopped") = "1"
        return "今天的排班已停止"
    if MN_RELAY_WAIT.Has(name)
        return "等待開始（" Round((A_TickCount - MN_RELAY_WAIT[name]) / 1000) " 秒）"
    return "等待輪到"
}
; 排班表：[{name,time,loops,est,warn,tickets,status}]
MnRelayJson() {
    s := ""
    for w in MnRelayPlan()
        s .= (s = "" ? "" : ",") '{"name":"' JsonEscapeWeb(w.name) '","time":"' w.time '","loops":' w.loops ',"est":"' JsonEscapeWeb(w.est) '","warn":"' JsonEscapeWeb(w.warn) '","tickets":' w.tickets ',"status":"' JsonEscapeWeb(MnSchedStatusText(w.name)) '"}'
    return "[" s "]"
}
