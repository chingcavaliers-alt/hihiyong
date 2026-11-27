; 自動進場打王（v1.3.90.105）：多開打王頁勾「參加」的角色一隻一隻進場 → 全部進場後游標放到王的血條上、每隻卡右鍵 →
; 王死了會再出現下一隻（游標跟著移到新的王身上），最後一隻「路西法」打完 → 全部放開 → 每隻走回出發點點「確認」回學院廣場。
; 進場（11/24 12:55 欸等示範錄製）：背包右鍵「波斯貓傳送卡」→ 波斯貓集結區（地圖 179）→ 走到地上的法陣 (13,-11) 按空白鍵 →
; 王的地圖（201）出發點 (-169,-160)，王在 (-135,70)。背包沒有波斯貓傳送卡的角色略過。
; 卡右鍵期間其他會切視窗 / 按鍵的自動功能（組隊、寵物 / 雇傭兵、每日討伐、採礦）先暫停（ApBlockerRaw）；命運箱子照常開。
; 設定：[BossRaid] Top = 打完 / 卡右鍵後放在最前面的角色（命運箱子設這隻開）、AimH = 游標對準王離地多高（預設）、Aim|<王的名字> = 學過的高度
global BR_STATE := "idle"      ; idle / entering / fighting / leaving
global BR_TEXT := ""
global brStop := false, brEntered := [], brBoss := 0, brSeen := [], brLastBossAt := 0, brFightStart := 0, brSawLast := false
global brLearnSince := 0, brInv := Map(), brRelockAt := 0
global brAimPt := 0, brUserPt := 0   ; 程式最後一次放游標的位置 / 你手動調過的位置（螢幕座標）
global brYaw := "", brLockTick := 0   ; 鏡頭方向（第一隻對準王後，其他隻照這個轉）/ 最後一次卡右鍵的時間
global BR_BOSS_POS := {x: -135, z: 70}
; 每輪統計（v1.3.90.109）：開始時間、進場花多久、每隻王從出現到打死幾秒、離開花多久、總時間；最近 30 輪存在 [BossRaidRuns]
global brRound := 0, BR_RUNS_KEEP := 30
; 打完自動接下一輪（v1.3.90.120）：[BossRaid] Loop=1；LoopMax = 最多幾輪（0 = 不限）。連續 2 輪沒等到王 / 沒有角色進場 / 按停止就不再接
global brLoopN := 0, brNoBossN := 0
; 王重生時間實測（v1.3.90.122）：記「地圖空了幾秒」（最後一隻離開 → 下一輪第一隻進到王的地圖）和「進去時王在不在」。
; 王在 → 下次少等一點；王不在 → 這個秒數太短，下次改在「太短」和「夠」中間試，差 10 秒以內就固定用「夠」的那個。
; [BossRaid] RespawnGood = 試過夠的最短秒數、RespawnBad = 試過不夠的最長秒數、LoopDelaySec = 下次要等幾秒
global brLastLeaveAt := 0, brEmptySec := -1
; 暫停（v1.3.90.126）：別的角色要更換每日道具（功能優先順序排在冒險小隊 Boss 前面）、或有角色在重新登入 → 放開右鍵讓出視窗；
; 都做完了 → 不在王地圖的角色重新進場（換完道具 / 重登後會在城裡或掛機點）→ 重新卡右鍵接著打（這一輪的統計照算）
global brPauseReq := "", brPauseWhy := "", brPausedAt := 0
global brDhYieldAt := 0   ; 每日討伐請打王暫停的時間（換完圖清掉）
; 施法監看（v1.3.90.134）：打王中每 0.5 秒看每隻的人物動作，記「施法中」的比例（每隻王結束時寫日誌）；
; 某一隻連續 8 秒都沒在施法（卡住的右鍵掉了 / 游標跑掉）→ 自動幫它重卡
global brCast := Map()   ; 角色名 → {n, cast, idleSince}   ; 舊版用的離場時間（現在存設定檔 LastLeaveUTC）/ 這一輪地圖空了幾秒
global BR_LOOT_COUNT := 5   ; 路西法打完地上要撿的道具數（每隻角色）
global BR_CARD := "波斯貓傳送卡"
global BR_MAP_GATHER := 179, BR_MAP_BOSS := 201
; v1.3.90.189：每個冒險小隊的集結區 / 王的地圖代碼不一樣（11/27 另一台「炮兵團」：集結區 174、王的地圖 196），
; 用傳送卡 / 按空白後第一次到的地圖記下來（[BossRaid] GatherMaps / BossMaps），之後 BrMap 都換成 179 / 201 回傳
global brGatherMaps := Map(179, 1), brBossMaps := Map(201, 1)
BrLoadMaps() {
    global brGatherMaps, brBossMaps
    for kv in [["GatherMaps", brGatherMaps], ["BossMaps", brBossMaps]] {
        raw := ""
        try raw := BrIni(kv[1], "")
        for x in StrSplit(raw, ",")
            if IsInteger(Trim(x))
                kv[2][Integer(Trim(x))] := 1
    }
}
BrLearnMap(kind, main, who) {
    global INI, brGatherMaps, brBossMaps
    m := kind = "gather" ? brGatherMaps : brBossMaps
    if m.Has(main)
        return
    m[main] := 1
    out := ""
    for k in m
        out .= (out = "" ? "" : ",") k
    try IniWrite out, INI, "BossRaid", kind = "gather" ? "GatherMaps" : "BossMaps"
    EventLog(who, "BR_LEARN_MAP", "記下" (kind = "gather" ? "集結區" : "王的地圖") "的地圖代碼：" main "（目前認得：" out "）")
}
global BR_CIRCLE := {x: 13.4, z: -11.2}, BR_STAND := {x: -136, z: 60}, BR_EXIT := {x: -169, z: -160}
global BR_EXIT_OK := {x: 507, y: 306}   ; 出發點「學院廣場：移動到該地」的「確認」（1024x768）
global BR_LAST_BOSS := "路西法"
global BR_AIM_H_DEF := 13   ; v1.3.90.119：11/24 13:49 手動對準闇獄蜂后學到 13；30 太高（14:30、14:38 都沒施法）
global brTestDriver := 0

BrStateNow() => BR_STATE
; 這隻角色用的傳送卡名稱：多開打王角色欄位自己填的，沒填就是「波斯貓傳送卡」（卡名跟著冒險小隊名稱變）
BrCardOf(p) {
    global BR_CARD
    c := ""
    try c := BlCfg(p.name).card
    return c != "" ? c : BR_CARD
}
; 這個角色現在在冒險小隊打王（在王的地圖裡、或這一輪有參加）：站著不掉血、不開 F6 都是正常的（假在線判定、重登後檢查要略過）
; 這隻角色由冒險小隊打王管（勾了參加、打完自動接下一輪開著）：每日道具換完不用送去怪區、不用開 F6
BrRaidOwnsChar(name) {
    try return BlCfg(name).on && BrIni("Loop", "0") = "1"
    return false
}
; 這隻角色每日討伐正在跑（還沒打完）
BrInDailyHunt(p) {
    try {
        global DH_RUNNING, DH_CHARS
        if !DH_RUNNING || !DH_CHARS.Has(p.name)
            return false
        ; v1.3.90.165：今天已經做完收尾過（重開管理程式後記憶體裡的「做完」還沒讀回來）：不算在跑
        ; （11/25 10:58 重開後欸等明明 10:29 就做完了，還是被當成「正在跑每日討伐」不帶）
        fdNm := "DhFinishedDay"
        if %fdNm%(p) = DateDiff(A_Now, "19700101", "Days")
            return false
        return !(p.HasOwnProp("dh") && IsObject(p.dh) && p.dh.done)
    }
    return false
}
BrIsRaiding(p) {
    global BR_STATE, brEntered, BR_MAP_BOSS
    try {
        if p.pid && BrMap(p.pid) = BR_MAP_BOSS
            return true
    }
    if BR_STATE != "idle"
        for q in brEntered
            if q.name = p.name
                return true
    return false
}
; 假在線投票要略過：在打王、或勾了參加打王而且沒開自動攻擊（兩輪之間站在學院廣場等王重生，血量本來就不會變）
; 11/24 19:10 打王結束後欸等、小白貓站在廣場不動，又被判假在線重登
BrSoftExempt(p) {
    if BrIsRaiding(p)
        return true
    try {
        if BlCfg(p.name).on && !(p.HasOwnProp("autoAtk") && p.autoAtk = 1)
            return true
    }
    return false
}
BrIni(k, d := "") {
    global INI
    return IniRead(INI, "BossRaid", k, d)
}
BrTopName() => Trim(BrIni("Top", ""))
BrAimH(bossName) {
    v := BrIni("Aim|" bossName, "")
    if IsNumber(v)
        return Number(v)
    v := BrIni("AimH", "")
    return IsNumber(v) ? Number(v) : BR_AIM_H_DEF
}
; 頁面：置頂角色
BossRaidSetTop(name) {
    global INI
    IniWrite Trim(name), INI, "BossRaid", "Top"
    EventLog("GLOBAL", "BR_CFG", "自動進場打王：最前面的角色＝" (Trim(name) = "" ? "最後進場的那隻" : Trim(name)))
}
global brStepAt := 0   ; 最後一次有進度（狀態 / 文字更新）的時間：按停止後很久沒進度就強制回到待命
BrSetState(state, text := "") {
    global BR_STATE, BR_TEXT, brStepAt
    BR_STATE := state, BR_TEXT := text, brStepAt := A_TickCount
    try BossLockPushWeb()
}
BrSay(text) {
    global BR_STATE
    BrSetState(BR_STATE, text)
}

; 地圖代碼：王的地圖回傳 201（BR_MAP_BOSS）；其他地圖回傳主編號；學院廣場回傳 2010。
; 學院廣場和王的地圖主編號都是 201。v1.3.90.143 只認子編號 6，20:41 欸等在王的地圖裡（子編號不是 6）被判成不在、用傳送卡傳出去了。
; v1.3.90.144：主編號 201 時看「是不是安全區」（學院廣場是安全區、王的地圖不是）；讀不到地圖資料時，看附近有沒有王
BrMainMap(pid) {   ; 地圖主編號（讀不到回傳 0）
    id := ""
    try id := ReadGameMapId(pid)
    return id != "" && RegExMatch(id, "^(\d+)-", &m) ? Integer(m[1]) : 0
}
BrMap(pid) {
    id := ""
    try id := ReadGameMapId(pid)
    if id = "" || !RegExMatch(id, "^(\d+)-(\d+)$", &m)
        return 0
    main := Integer(m[1])
    global brGatherMaps, brBossMaps
    static mapsLoaded := false
    if !mapsLoaded {
        mapsLoaded := true
        try BrLoadMaps()
    }
    if brGatherMaps.Has(main)
        return 179
    if !brBossMaps.Has(main)
        return main
    if IsObject(BrFindBoss(pid))   ; 附近有王 = 一定在王的地圖
        return 201
    info := 0
    try info := GameMapInfo(pid, id)
    if IsObject(info)
        return info.peace ? 2010 : 201
    return 201   ; 讀不到：當作在王的地圖（寧可不要用傳送卡把人傳出去）
}
; 王的地圖裡的王（不是 NPC、不是礦；讀得到種類時只算種類 2）。回傳最近的那隻
BrFindBoss(pid) {
    all := 0
    try all := MiningCrows(pid)
    if !IsObject(all)
        return 0
    me := 0
    try me := MiningCharState(pid)
    best := 0, bd := 1e18
    for m in all {
        if m.name = "" || InStr(m.name, "原石") || m.name = "護士"
            continue
        if m.kind != -1 && m.kind != 2
            continue
        d := IsObject(me) ? (m.x - me.x) ** 2 + (m.z - me.z) ** 2 : 0
        if d < bd
            best := m, bd := d
    }
    return best
}
; 王的血條在 p 視窗裡的螢幕座標（讀不到 / 不在畫面內回傳 0）
BrBossScreen(p, b) {
    global AP_DESIGN_W, AP_DESIGN_H
    sp := MnScreenPt(p.pid, b.x, b.y + BrAimH(b.name), b.z)
    if sp.x < 0
        return 0
    r := BlClientRect(p)
    if !IsObject(r)
        return 0
    return {x: r.x + Round(sp.x * r.w / AP_DESIGN_W), y: r.y + Round(sp.y * r.h / AP_DESIGN_H)}
}

; 這隻角色自己的視窗裡，王血條的螢幕位置（v1.3.90.116：11/24 14:30 兩個遊戲視窗沒疊在一起，只算一個位置，另一隻卡在畫面中間打不到王）
BrAimChar(p) {
    ; v1.3.90.151：視窗疊在一起共用一個游標 → 大家都用最前面那隻視窗算的位置（大家站同一個站位、鏡頭同方向，王在每個視窗的位置一樣）。
    ; 11/24 23:08 王在 (-148,72)，每隻各自算的位置差一點，重卡 A 游標一移、B C 就碰不到，輪流把對方打斷
    t := BrTop()
    tb := BrFindBoss(t.pid)
    if IsObject(tb) && tb.hp > 0 {
        h := BrAimH(tb.name)
        sp := MnScreenPt(t.pid, tb.x, tb.y + h, tb.z)
        r := BlClientRect(t)
        if sp.x >= 0 && IsObject(r)
            return {x: r.x + Round(sp.x * r.w / 1024), y: r.y + Round(sp.y * r.h / 768)}
    }
    b := BrFindBoss(p.pid)
    if !IsObject(b) || b.hp <= 0
        return 0
    return BrBossScreen(p, b)
}
; 卡右鍵並確認真的在施法（v1.3.90.119：11/24 14:38 卡上了但游標不在王血條上，技能沒放）：
; 每隻：用這隻王記住的高度（沒有就預設）卡右鍵 → 1.5 秒內人物動作有沒有變成「技能」→ 沒有就放開、換下一個高度再卡；
; 成功的高度記在這隻王的名字下（之後直接用）。回傳 Map(角色名 → 成功的高度或 -1)
BrLockAll(list, b) {
    global INI, blLocked
    res := Map(), okNames := [], badNames := []
    first := BrAimH(b.name)
    cands := [first]
    for h in [13, 9, 17, 5, 22, 28, 2, 35]
        if h != first
            cands.Push(h)
    for p in list {
        res[p.name] := -1
        for i, h in cands {
            pb := BrFindBoss(p.pid)
            if !IsObject(pb)
                pb := b
            ; 共用最前面那隻視窗算的位置（v1.3.90.151）
            ap := BrTop(), ab := BrFindBoss(ap.pid)
            if !IsObject(ab)
                ap := p, ab := pb
            sp := MnScreenPt(ap.pid, ab.x, ab.y + h, ab.z), r := BlClientRect(ap)
            if sp.x < 0 || !IsObject(r) {
                sp := MnScreenPt(p.pid, pb.x, pb.y + h, pb.z), r := BlClientRect(p)
                if sp.x < 0 || !IsObject(r)
                    continue
            }
            pt := {x: r.x + Round(sp.x * r.w / 1024), y: r.y + Round(sp.y * r.h / 768)}
            err := BlRelockOne(p, pt)
            if err != "" {
                EventLog(p.name, "BR_AIM_TRY", "卡右鍵失敗｜" err)
                break
            }
            if BrCasting(p, 1500) {
                res[p.name] := h
                if i > 1 || BrIni("Aim|" pb.name, "") = ""
                    IniWrite h, INI, "BossRaid", "Aim|" pb.name
                EventLog(p.name, "BR_AIM_OK", pb.name "｜高度 " h " 有在施法" (i > 1 ? "（試到第 " i " 個高度，已記住）" : ""))
                break
            }
            EventLog(p.name, "BR_AIM_TRY", pb.name "｜高度 " h " 卡了右鍵但沒有施法，換下一個高度")
            try BlReleaseOne(p)
            try blLocked.Delete(p.name)
        }
        if res[p.name] >= 0
            okNames.Push(p.name)
        else
            badNames.Push(p.name)
    }
    BlSetState(blLocked.Count ? "locked" : "idle", (okNames.Length ? "施法中：" BcJoin(okNames) : "") (badNames.Length ? "｜沒對準王：" BcJoin(badNames) : ""))
    return res
}
; 這段時間內人物動作有沒有出現「技能」(3)
BrCasting(p, ms) {
    t0 := A_TickCount
    while A_TickCount - t0 < ms {
        me := 0
        try me := MiningCharState(p.pid)
        if IsObject(me) && me.HasOwnProp("action") && me.action = 3
            return true
        Sleep 60
    }
    return false
}
; 要把游標放哪：這隻王記過血條高度 → 用算的；沒記過但你這一輪調過游標 → 用你調的位置（王都在同一個點出現）；都沒有 → 用預設高度算
BrAimFor(p, b) {
    global brUserPt, INI
    pt := BrBossScreen(p, b)
    return IsObject(pt) || !IsObject(brUserPt) ? pt : brUserPt
}
; 游標在螢幕 c：算出它對應王頭上多高（找不到 / 太遠回傳 -1），記在這隻王的名字下
BrLearnAt(p, b, c) {
    global INI, AP_DESIGN_W, AP_DESIGN_H
    r := BlClientRect(p)
    if !IsObject(r) || r.w < 100
        return -1
    gx := (c.x - r.x) * AP_DESIGN_W / r.w, gy := (c.y - r.y) * AP_DESIGN_H / r.h
    best := -1, bd := 1e18
    Loop 121 {
        h := A_Index - 1
        sp := MnScreenPt(p.pid, b.x, b.y + h, b.z)
        if sp.x < 0
            continue
        d := (sp.x - gx) ** 2 + (sp.y - gy) ** 2
        if d < bd
            bd := d, best := h
    }
    if best < 0 || bd > 60 ** 2
        return -1
    IniWrite best, INI, "BossRaid", "Aim|" b.name
    return best
}
; ---- 進場 ----
BrEnter(p) {
    global dhMapPatient
    dhMapPatient := true   ; 走路點一下就等它走到（不一直補點，走起來比較順）
    try
        return BrEnterCore(p)
    finally
        dhMapPatient := false
}
BrEnterCore(p) {
    global BR_CARD, BR_MAP_GATHER, BR_MAP_BOSS, BR_CIRCLE, BR_STAND, apRunStart, apLastOwn
    pid := p.pid
    apRunStart := A_TickCount
    if BrMap(pid) = BR_MAP_BOSS {
        EventLog(p.name, "BR_ENTER", "已經在王的地圖裡，先放開可能卡住的右鍵，再走到王旁邊")
        if !ApActivate(p)
            throw Error("叫不到前面")
        try BlReleaseOne(p)   ; 重開管理程式前可能還卡著右鍵（程式不記得），卡著會一直施法、走不動
        ; v1.3.90.176：自動攻擊開著（例如重新登入後被按了 F6）會跟卡右鍵打架，一直打不到王：先關掉
        ; （11/26 08:41 重登後欸等等、小白貓自動攻擊開著，08:47～08:55 換高度試了好幾輪都沒施法）
        try DhEnsureAutoHuntOff(p)
        apLastOwn := A_TickCount
        ApWait(() => (ApGuardAny(), false), 500)
    } else {
        if !ApActivate(p)
            throw Error("叫不到前面")
        DhEnsureAutoHuntOff(p)
        if BrMap(pid) != BR_MAP_GATHER {
            ctx := MnCtx(p)
            MnEnsureInventory(p, ctx)
            cardName := BrCardOf(p)
            card := MnFindIn(pid, "InvenOffset", (n) => InStr(n, cardName))
            if !card {
                try MnCloseWindows(p)
                return "skip"
            }
            DailyStep(ctx, "右鍵 " cardName)
            DailyClickCell(ctx, card, "Right")
            MnOwnAct()
            m0 := 0
            try m0 := BrMainMap(pid)
            DailyWaitUntil(ctx, "右鍵" cardName "後 30 秒還沒到波斯貓集結區", () => GameCharacterLoaded(pid) && (BrMap(pid) = BR_MAP_GATHER || (BrMainMap(pid) != m0 && BrMainMap(pid) > 0)), 30000)
            if BrMap(pid) != BR_MAP_GATHER
                BrLearnMap("gather", BrMainMap(pid), p.name)
            MnCloseWindows(p)
            ApWait(() => (ApGuardAny(), false), 1500)
        }
        apRunStart := A_TickCount
        DhMoveTo(p, BR_CIRCLE.x, BR_CIRCLE.z, 4)
        ApWait(() => (ApGuardAny(), false), 500)
        entered := false
        Loop 3 {
            ApKey(p, "Space")
            if ApWait(() => (ApGuardAny(), GameCharacterLoaded(pid) && (BrMap(pid) = BR_MAP_BOSS || (BrMap(pid) != BR_MAP_GATHER && BrMainMap(pid) > 0))), 8000) {
                if BrMap(pid) != BR_MAP_BOSS
                    BrLearnMap("boss", BrMainMap(pid), p.name)
                entered := true
                break
            }
            me := MiningCharState(pid)   ; 沒進去：可能沒站在法陣上，再走一次
            if IsObject(me) && Sqrt((me.x - BR_CIRCLE.x) ** 2 + (me.z - BR_CIRCLE.z) ** 2) > 4
                DhMoveTo(p, BR_CIRCLE.x, BR_CIRCLE.z, 3)
        }
        if !entered
            throw Error("站在法陣上按空白鍵，還是沒進到王的地圖")
        EventLog(p.name, "BR_ENTER", "已進入王的地圖")
        global brEmptySec
        lv := BrIni("LastLeaveUTC", "")   ; 存在設定檔：重開管理程式也算得到
        if brEmptySec < 0 && lv != ""
            try brEmptySec := DateDiff(A_NowUTC, lv, "Seconds")
        ApWait(() => (ApGuardAny(), false), 2000)
    }
    apRunStart := A_TickCount
    if !ApIsActive(p)
        ApActivate(p)
    BrGoNearBoss(p)   ; v1.3.90.142：走到「現在的王」旁邊（離王 14 以內就好），不再硬走固定站位
    try MnEnsurePet(p, "進場打王")
    try BrEnsureMerc(p)
    try BrAlignCamera(p)
    catch as e {
        if e.Extra = "stop"
            throw e
        EventLog(p.name, "BR_CAMERA", "鏡頭對齊失敗：" e.Message)
    }
    return "ok"
}

; 走到王旁邊（v1.3.90.142）：11/24 20:33 王跑到 (-119,62)，固定站位 (-136,60) 一帶被擋住，欸等來回走了 2 分多鐘、欸等等「路被擋住」進場失敗。
; 改成：王在哪就走到王旁邊（王和人物之間、離王 8），離王 14 以內就算到；走不到也不算失敗（照樣卡右鍵，施法監看會再補救）
BrGoNearBoss(p) {
    ; v1.3.90.149：改回 v1.3.90.141 的做法（那版三隻施法 94～100%）：大家走到固定站位 (-136,60)，用大地圖點一下等它走到、
    ; 點不到就改點地面；差 6 以內就好，走不到也不算失敗。v1.3.90.142～148 改成「走到王旁邊 / 站位候選點」反而讓欸等等卡在走不出去的地方
    global BR_STAND
    me := MiningCharState(p.pid)
    if IsObject(me) && Sqrt((me.x - BR_STAND.x) ** 2 + (me.z - BR_STAND.z) ** 2) <= 6
        return
    try DhMoveTo(p, BR_STAND.x, BR_STAND.z, 6)
    catch as e {
        if e.Extra = "stop"
            throw e
        me := MiningCharState(p.pid)
        EventLog(p.name, "BR_MOVE", "走到站位沒走到（" e.Message "）｜離站位 " (IsObject(me) ? Round(Sqrt((me.x - BR_STAND.x) ** 2 + (me.z - BR_STAND.z) ** 2)) : "?") "，照樣開始")
    }
}
; 大家都站的那一點（v1.3.90.148）：先試王的正南邊 10（以前固定站位的相對位置）；走不到（22:11 王在 (-130,77)，南邊被擋住）
; 就依序試西南、西、東南、東、北。第一隻走到哪一點，這一輪其他隻都站同一點（王換位置就重找）
global brStand := 0   ; {dx, dz}：站位相對王的位置
global BR_STAND_CANDS := [[-1, -10], [-8, -7], [-10, 0], [7, -7], [10, 0], [0, 10]]
BrStandFor(bx, bz) {
    global brStand
    o := IsObject(brStand) ? brStand : {dx: -1, dz: -10}
    return {x: bx + o.dx, z: bz + o.dz}
}
; 雇傭兵不在外面就按快捷欄的雇傭兵叫出來
BrEnsureMerc(p) {
    if CwRead(p, "merc") != 0
        return
    info := DailyQuickInfo(p.pid, "雇傭兵")
    if !IsObject(info) || info.key = "" {
        EventLog(p.name, "BR_MERC", "雇傭兵不在外面，但快捷欄找不到雇傭兵（或不知道是哪個鍵）")
        return
    }
    ApKey(p, info.key)
    MnOwnAct()
    ok := ApWait(() => (ApGuardAny(), CwRead(p, "merc") = 1), 3000)
    EventLog(p.name, "BR_MERC", "雇傭兵不在外面，已按 " StrUpper(info.key) " 叫出｜" (ok ? "出來了" : "按了還是沒出來"))
}
BrAtan2(y, x) {
    static PI := 3.141592653589793
    if x > 0
        return ATan(y / x)
    if x < 0
        return ATan(y / x) + (y >= 0 ? PI : -PI)
    return y > 0 ? PI / 2 : y < 0 ? -PI / 2 : 0
}
; 鏡頭方向（水平角度，弧度；讀不到回傳空字串）
BrCamYaw(pid) {
    e := 0
    try e := GameCameraEye(pid)
    return IsObject(e) ? BrAtan2(e.fx, e.fz) : ""
}
BrWrap(a) {
    static PI := 3.141592653589793
    while a > PI
        a -= 2 * PI
    while a < -PI
        a += 2 * PI
    return a
}
; 每隻角色的視角拉成一樣（11/24：視窗疊在一起時，有一隻的王血條位置不一樣就打不到）：
; 鏡頭拉到最遠 → 第一隻：壓中鍵左右轉，讓王在畫面正中間，記住這個鏡頭方向；之後每隻轉到同一個方向（差 2 度以內）。
BrAlignCamera(p) {
    global brYaw, dhOrbitMode, BR_BOSS_POS
    pid := p.pid
    DhSoft(p, "鏡頭拉遠", () => DhCameraZoomOut(p))
    y0 := BrCamYaw(pid)
    if y0 = ""
        throw Error("讀不到鏡頭方向")
    ; 試轉 120 像素，量每像素轉幾弧度（含方向）
    ApOrbit(p, 512, 420, 120, 10, 18, dhOrbitMode)
    ApWait(() => (ApGuardAny(), false), 300)
    y1 := BrCamYaw(pid)
    rate := y1 = "" ? 0 : BrWrap(y1 - y0) / 120
    if Abs(rate) < 0.0004 {   ; 11/24 13:49 兩隻都「沒有轉」：換另一種拖法（移游標 / 相對移動）再試一次，有轉就記住
        other := dhOrbitMode = "abs" ? "rel" : "abs"
        ApOrbit(p, 512, 420, 120, 10, 18, other)
        ApWait(() => (ApGuardAny(), false), 300)
        y2 := BrCamYaw(pid)
        rate := y2 = "" || y1 = "" ? 0 : BrWrap(y2 - y1) / 120
        if Abs(rate) < 0.0004
            throw Error("壓中鍵拖曳鏡頭沒有轉（移游標和相對移動兩種都試過；鏡頭方向 " Round(y0 * 57.2958) " 度）")
        dhOrbitMode := other
    }
    ; v1.3.90.124：固定鏡頭方向（[BossRaid] CamYaw，度；預設 -167 = 11/24 14:41 畫面清楚的那個）。
    ; 以前第一隻「讓王在畫面中間」：角色離王只有 10，轉到哪裡王都在中間，每輪方向都不一樣，有時轉到牆後面（16:32 欸等等整個畫面被牆擋住）
    cy := BrIni("CamYaw", "-167")
    if brYaw = "" && IsNumber(cy)
        brYaw := BrWrap(Number(cy) / 57.2958)
    if brYaw = "" {   ; 第一隻：讓王在畫面正中間
        Loop 6 {
            b := BrFindBoss(pid)
            sp := IsObject(b) ? MnScreenPt(pid, b.x, b.y + 20, b.z) : MnScreenPt(pid, BR_BOSS_POS.x, 20, BR_BOSS_POS.z)
            if sp.x < 0 {   ; 王不在畫面內：轉 90 度再看
                ApOrbit(p, 512, 420, Max(-600, Min(600, Round(1.57 / rate))), 14, 18, dhOrbitMode)
                ApWait(() => (ApGuardAny(), false), 300)
                continue
            }
            off := sp.x - 512
            if Abs(off) <= 20
                break
            ; 畫面上偏右 off 像素 → 鏡頭往右轉約 off/512 × 半個視野（約 0.5 弧度）；方向不對下一圈會再修正
            px := Round(off / 512 * 0.5 / Abs(rate))
            ApOrbit(p, 512, 420, Max(-400, Min(400, px)), 12, 18, dhOrbitMode)
            ApWait(() => (ApGuardAny(), false), 300)
            sp2 := IsObject(b) ? MnScreenPt(pid, b.x, b.y + 20, b.z) : MnScreenPt(pid, BR_BOSS_POS.x, 20, BR_BOSS_POS.z)
            if sp2.x >= 0 && Abs(sp2.x - 512) > Abs(off) {   ; 轉反了：轉回來再往另一邊轉
                ApOrbit(p, 512, 420, Max(-800, Min(800, -2 * px)), 14, 18, dhOrbitMode)
                ApWait(() => (ApGuardAny(), false), 300)
            }
        }
        brYaw := BrCamYaw(pid)
        EventLog(p.name, "BR_CAMERA", "鏡頭拉遠、王轉到畫面中間｜鏡頭方向 " (brYaw = "" ? "?" : Round(brYaw * 57.2958)) " 度（其他角色照這個方向轉）")
        return
    }
    Loop 8 {
        cur := BrCamYaw(pid)
        if cur = ""
            break
        d := BrWrap(brYaw - cur)
        if Abs(d) <= 0.035
            break
        ApOrbit(p, 512, 420, Max(-500, Min(500, Round(d / rate))), 12, 18, dhOrbitMode)
        ApWait(() => (ApGuardAny(), false), 300)
    }
    cur := BrCamYaw(pid)
    EventLog(p.name, "BR_CAMERA", "鏡頭轉到固定方向 " Round(brYaw * 57.2958) " 度｜差 " (cur = "" ? "?" : Round(Abs(BrWrap(brYaw - cur)) * 57.2958, 1)) " 度")
}
; ---- 開始 / 停止 ----
BossRaidStart() {
    global BR_STATE, brStop, brEntered, foregroundOwner, apBusy, apRunStart, apLastOwn, BL_STATE, INI
    if BR_STATE != "idle" || BL_STATE = "running"
        return
    why := ""
    try why := ApBlockerRaw()
    if why != "" || foregroundOwner != "" {
        msg := why != "" ? why : "其他功能正在操作遊戲視窗（" foregroundOwner "）"
        ; v1.3.90.157：11/25 06:12 重開後接續剛好碰上每日討伐在用視窗，打王就沒開始、也沒再試。「打完自動接下一輪」開著就 30 秒後再試
        if BrIni("Loop", "0") = "1" {
            BrSetState("idle", "現在不能開始：" msg "（30 秒後再試）")
            EventLog("GLOBAL", "BR_WAIT", "現在不能開始：" msg "｜30 秒後再試")
            SetTimer BrLoopStart, -30000
        } else
            BrSetState("idle", "現在不能開始：" msg)
        return
    }
    chars := BlChars()
    ; v1.3.90.185：隊伍還沒組好就先不進（王地圖分身是跟著隊伍的，各自進去會被分到不同分身）；「打完自動接下一輪」開著就 30 秒後再試
    if BrIni("Loop", "0") = "1" {
        nmList := []
        for q in chars
            if !BrInDailyHunt(q)
                nmList.Push(q.name)
        pw := BrPartyWait(nmList)
        if pw != "" {
            BrSetState("idle", "現在不能開始：" pw "（30 秒後再試）")
            SetTimer BrLoopStart, -30000
            return
        }
    }
    ; v1.3.90.155：正在跑每日討伐的角色這一輪先不帶（11/25 06:00 欸等的每日討伐定時啟動，剛好在兩輪之間把欸等帶走）；
    ; 每日討伐跑完，下一輪自動把它帶回來
    dhSkip := []
    for i, p in chars.Clone()
        if BrInDailyHunt(p)
            dhSkip.Push(p.name)
    if dhSkip.Length {
        keep := []
        for p in chars {
            skip := false
            for nm in dhSkip
                if nm = p.name
                    skip := true
            if !skip
                keep.Push(p)
        }
        chars := keep
        EventLog("GLOBAL", "BR_SKIP", "正在跑每日討伐，這一輪先不帶：" BcJoin(dhSkip))
        ; v1.3.90.159：不帶的角色視窗搬回它記錄的位置（不要疊在打王的視窗上面）。
        ; 11/25 06:52～07:15 欸等的視窗還疊在一起，每日討伐每次切到欸等、移游標，打王的兩隻就打不到（施法 65～83%，4 隻王 22 分半）
        global profiles
        for i, q in profiles {
            for nm in dhSkip
                if nm = q.name && q.hwnd {
                    fn := "RestoreProfileWindowPosition"
                    try %fn%(i, q.hwnd)
                }
        }
    }
    if !chars.Length {
        BrSetState("idle", "沒有勾選參加的角色（或遊戲視窗沒開 / 都在跑每日討伐）")
        return
    }
    ; 置頂角色最後進場（它的視窗最後在最前面）
    top := BrTopName()
    for i, p in chars
        if p.name = top {
            chars.Push(chars.RemoveAt(i))
            break
        }
    global brYaw, brEmptySec, brStand
    brStop := false, brEntered := [], brYaw := "", brEmptySec := -1, brStand := 0
    ; v1.3.90.129：參加的角色視窗先疊在一起（疊在「最前面的角色」上）
    anchor := chars[chars.Length]
    try BlStackWindows(chars, anchor)
    BrSetState("entering", "進場中（不要動滑鼠鍵盤）")
    EventLog("GLOBAL", "BR_START", "自動進場打王開始｜" BcJoin(BrNames(chars)))
    try IniWrite "1", INI, "BossRaid", "Running"
    global brRound
    brRound := {t0: A_TickCount, when: FormatTime(, "MM/dd HH:mm"), enterMs: 0, fightT0: 0, leaveT0: 0, leaveMs: 0, bosses: [], chars: BcJoin(BrNames(chars))}
    SetTimer BrEnterAll.Bind(chars), -10
}
BrNames(list) {
    out := []
    for p in list
        out.Push(p.name)
    return out
}
BrEnterAll(chars) {
    global brStop, brEntered, foregroundOwner, apBusy, apRunStart, apLastOwn, brRound
    skipped := [], failed := [], cardFail := [], fakeOnline := false
    apBusy := true, foregroundOwner := "bossraid", apRunStart := A_TickCount, apLastOwn := A_TickCount
    try {
        for p in chars {
            if brStop
                break
            BrSay("進場中：" p.name)
            r := "", err := 0
            ; v1.3.90.113：11/24 14:19 走到王旁邊時偵測到鍵鼠輸入就整輪停掉。現在「你在操作」先等你停手 3 秒再繼續這隻（最多 3 次）；按停止才真的停
            Loop 4 {
                err := 0
                try {
                    r := BrEnter(p)
                    break
                } catch as e {
                    err := e
                    ; 可以再試的：你在操作、視窗被別的功能 / 監控切走、中途有其他動作（v1.3.90.118）；按停止才真的停
                    ; v1.3.90.131：11/24 19:18 欸等等「道具視窗被蓋住，無法叫回最上層」就直接略過。現在除了按停止，什麼錯誤都先關掉遊戲裡開著的視窗再試（最多 3 次）
                    if brStop || InStr(e.Message, "已按停止") || A_Index = 4
                        break
                    ; v1.3.90.183：右鍵傳送卡沒反應、到現在還沒有任何一隻傳得過去，連續兩次（可以是不同隻）→ 判定假在線
                    ; （11/27 03:21 四隻都假在線：畫面正常、伺服器時間也在動，但傳送卡右鍵都沒反應，試了 25 分鐘；
                    ;   打王的角色不看血量、又站在安全區，原本的假在線判定都抓不到）
                    if InStr(e.Message, "還沒到波斯貓集結區") && !brEntered.Length {
                        has := false
                        for x in cardFail
                            if x.name = p.name
                                has := true
                        if !has
                            cardFail.Push(p)
                        if cardFail.Length >= 2 || A_Index >= 2 {
                            fakeOnline := true
                            break
                        }
                    }
                    ; v1.3.90.177：有角色在重新登入：等它登入完（最多 5 分鐘）再試，不要 3 秒內就把 3 次用完
                    if InStr(e.Message, "重新登入") {
                        EventLog(p.name, "BR_WAIT", "進場途中有角色在重新登入，等它登入完再繼續這隻")
                        t1 := A_TickCount
                        while !brStop && A_TickCount - t1 < 300000 && BrPauseNeeded() != ""
                            Sleep 1000
                        Sleep 3000
                    }
                    try MnCloseWindows(p)
                    EventLog(p.name, "BR_PAUSE", e.Message "｜等 3 秒再繼續這隻（第 " A_Index " 次）")
                    BrSay("等一下再繼續…（" p.name "：" e.Message "）")
                    t0 := A_TickCount
                    while !brStop && A_TickCount - t0 < 120000 && A_TimeIdlePhysical < 3000
                        Sleep 200
                    apLastOwn := A_TickCount, apRunStart := A_TickCount
                }
            }
            if fakeOnline
                break
            if IsObject(err) {
                failed.Push(p.name)
                EventLog(p.name, "BR_FAIL", "進場失敗｜" err.Message)
                if brStop || InStr(err.Message, "已按停止") {
                    brStop := true
                    break
                }
                continue
            }
            if r = "skip" {
                skipped.Push(p.name)
                EventLog(p.name, "BR_SKIP", "背包找不到「" BrCardOf(p) "」，略過")
            } else
                brEntered.Push(p)
        }
        if fakeOnline {
            BrFakeOnline(chars)
            failed := []
        }
        ; 其他角色都進完了，失敗的再補一次（關掉遊戲裡的視窗再進）
        if !brStop && !fakeOnline && failed.Length {
            retryNames := failed.Clone(), failed := []
            for nm in retryNames {
                p := 0
                for q in chars
                    if q.name = nm
                        p := q
                if !IsObject(p) || brStop
                    continue
                EventLog(p.name, "BR_RETRY", "其他角色進完了，再補進場一次")
                r := ""
                try {
                    try MnCloseWindows(p)
                    apLastOwn := A_TickCount, apRunStart := A_TickCount
                    r := BrEnter(p)
                } catch as e {
                    EventLog(p.name, "BR_FAIL", "補進場也失敗｜" e.Message)
                }
                if r = "ok"
                    brEntered.Push(p)
                else
                    failed.Push(p.name)
            }
        }
    } finally {
        try MnCloseWindows(chars[1])
        foregroundOwner := "", apBusy := false, apRunStart := 0
    }
    note := (skipped.Length ? "｜沒有傳送卡略過：" BcJoin(skipped) : "") (failed.Length ? "｜進場失敗：" BcJoin(failed) : "")
    if brStop || !brEntered.Length {
        if !fakeOnline {
            global INI
            try IniWrite "0", INI, "BossRaid", "Running"
        }
        BrSetState("idle", (brStop ? "已停止" : "沒有角色進場") note)
        EventLog("GLOBAL", "BR_END", (brStop ? "已停止" : "沒有角色進場") note)
        brRound := 0
        return
    }
    EventLog("GLOBAL", "BR_ENTERED", "進場完成：" BcJoin(BrNames(brEntered)) note)
    if IsObject(brRound)
        brRound.enterMs := A_TickCount - brRound.t0, brRound.fightT0 := A_TickCount
    ; v1.3.90.114：11/24 14:14、14:23 兩次進場完成後就停住（沒卡右鍵、按停止沒反應）。這個執行緒在這之前被別的計時器插隊壓在下面、
    ; 一直沒輪回來。開打改成另開一個新的執行緒（不被壓在下面），進場這個執行緒到這裡就結束
    BrSetState("fighting", "準備卡右鍵" note)
    SetTimer BrBeginFightSafe.Bind(note), -10
}
; 置頂角色（有進場的）；沒設定 / 沒進場 = 最後進場的那隻
; 撿掉落物的角色：頁面選的（有進場的）；沒選 = 最前面的角色
BrLooter() {
    global brEntered, brLootFull
    nm := Trim(BrIni("Looter", ""))
    for p in brEntered
        if p.name = nm && !BrLootFullNow(p.name)
            return p
    top := BrTop()
    if IsObject(top) && !BrLootFullNow(top.name)
        return top
    for p in brEntered   ; 設定的 / 最前面的背包都滿了：找一隻背包沒滿的
        if !BrLootFullNow(p.name)
            return p
    return top
}
; v1.3.90.178：撿不到（背包滿了）的角色 1 小時內不再先叫它撿（你清背包後最多 1 小時就會再輪到它）
global brLootFull := Map()
BrLootFullNow(name) {
    global brLootFull
    return brLootFull.Has(name) && A_TickCount - brLootFull[name] < 3600000
}
BossRaidSetLooter(name) {
    global INI
    IniWrite Trim(name), INI, "BossRaid", "Looter"
    EventLog("GLOBAL", "BR_CFG", "自動進場打王：撿掉落物的角色＝" (Trim(name) = "" ? "最前面的角色" : Trim(name)))
}
; 卡右鍵的順序：最前面的角色最後（做完它在最前面）
BrLockOrder() {
    global brEntered
    top := BrTop(), out := []
    for p in brEntered
        if p != top
            out.Push(p)
    out.Push(top)
    return out
}
BrTop() {
    global brEntered
    top := BrTopName()
    for p in brEntered
        if p.name = top
            return p
    return brEntered[brEntered.Length]
}
BrBeginFightSafe(note := "") {
    try BrBeginFight(note)
    catch as e {
        EventLog("GLOBAL", "BR_FAIL", "開始卡右鍵出錯：" e.Message "｜第 " e.Line " 行")
        global foregroundOwner
        if foregroundOwner = "bossraid"
            foregroundOwner := ""
        SetTimer BrFightTick, 500   ; 照樣看王（王出現會再卡）
    }
}
BrBeginFight(note := "") {
    global brBoss, brSeen, brLastBossAt, brFightStart, brSawLast, BR_STATE, brEntered
    global brInv, brRelockAt
    global brCast
    brCast := Map()
    brBoss := 0, brSeen := [], brLastBossAt := A_TickCount, brFightStart := A_TickCount, brSawLast := false, brRelockAt := 0
    global brUserPt
    brUserPt := 0
    brInv := Map()   ; v1.3.90.112：不再在這裡讀背包（撿東西時才讀撿之前的背包）
    EventLog("GLOBAL", "BR_STEP", "開始卡右鍵流程")
    BrSetState("fighting", "等王出現" note)
    ; v1.3.90.185：每隻看到的王不一樣 = 被分到不同的王地圖分身（隊伍還沒組好就各自進場）→ 全部離開，組好隊再重進
    ; （11/27 07:59 重新登入後三隻在組隊前各自進場，欸等等打劫炎魔皇、小白貓闇獄蜂后、嗨朵拉的盒子萬象神裁，欸等等整輪打不到）
    bossNames := Map()
    for q in brEntered {
        bq := 0
        try bq := BrFindBoss(q.pid)
        if IsObject(bq)
            bossNames[bq.name] := (bossNames.Has(bq.name) ? bossNames[bq.name] "、" : "") q.name
    }
    if bossNames.Count > 1 {
        txt := ""
        for nm, who in bossNames
            txt .= (txt = "" ? "" : "｜") who "：" nm
        EventLog("GLOBAL", "BR_INSTANCE", "每隻看到的王不一樣（被分到不同的王地圖分身）：" txt "｜全部離開，組好隊再重進")
        BrFinish("分到不同的王地圖分身")
        return
    }
    ; 置頂角色叫到前面、游標放到王的血條上，再全部卡右鍵（置頂角色最後卡，做完它在最前面）
    ; v1.3.90.112：11/24 14:14 進場完成後命運箱子插進來開箱，之後一直停在「進場中」、按停止也沒反應。
    ; 卡右鍵做完之前先佔著遊戲視窗（命運箱子等這段做完再開）
    global foregroundOwner
    foregroundOwner := "bossraid"
    top := BrTop()
    BlActivate(top)
    b := BrFindBoss(top.pid)
    global brAimPt
    brAimPt := 0
    BrRespawnNote(IsObject(b) && b.hp > 0)
    pt := IsObject(b) && b.hp > 0 ? BrAimFor(top, b) : 0
    if IsObject(pt) {
        BlSetCursor(pt.x, pt.y)
        BrLockAll(BrLockOrder(), b)
        BlSetCursor(pt.x, pt.y)
        brAimPt := BlCursor()
        global brLockTick
        brLockTick := A_TickCount
    } else {   ; 王還沒出現 / 不在畫面上：先不卡（卡在地板上沒用），等王出現再卡
        brRelockAt := 1
        EventLog(top.name, "BR_WAIT_BOSS", "進場完成，王還沒出現（或不在畫面上），等王出現再卡右鍵")
    }
    if foregroundOwner = "bossraid"
        foregroundOwner := ""
    SetTimer BrFightTick, 500
}
; 打王中：王換了 / 移動了就把游標移到新的位置（你 1.5 秒內有動滑鼠就不搶）；最後一隻打完 → 結束
BrFightTick() {
    global BR_STATE, brBoss, brSeen, brLastBossAt, brFightStart, brSawLast, brStop, BR_LAST_BOSS, BR_MAP_BOSS, brRelockAt, brEntered, brAimPt, brUserPt, brLockTick, BL_STATE, blLocked, mboxLastOwn, mboxBusy, foregroundOwner, brCast
    if BR_STATE != "fighting" {
        SetTimer BrFightTick, 0
        return
    }
    global emergencyStop
    if emergencyStop {   ; F10
        SetTimer BrFightTick, 0
        return
    }
    if brStop {
        SetTimer BrFightTick, 0
        BrFinish("已停止")
        return
    }
    ; 要讓路（每日更換道具 / 重新登入）就先暫停
    pw := BrPauseNeeded()
    if pw != "" {
        BrPause(pw)
        return
    }
    top := BrTop()
    if BrMap(top.pid) != BR_MAP_BOSS {   ; 置頂角色不在王的地圖（死了回城 / 斷線）：換一隻還在裡面的看
        for p in brEntered
            if BrMap(p.pid) = BR_MAP_BOSS {
                top := p
                break
            }
    }
    b := BrFindBoss(top.pid)
    now := A_TickCount
    if IsObject(b) && b.hp > 0 {
        brLastBossAt := now
        if BL_STATE = "locked" && !brRelockAt {
            stuck := BrCastSample(now)
            BrCircle(top, b, now)   ; 有角色 2 秒以上沒施法：游標在王周圍繞圈（疊在一起的視窗都吃得到游標位置）
            if IsObject(stuck) {   ; 有一隻 8 秒沒施法：重卡（離站位太遠先走回去）
                ; v1.3.90.152：重卡時游標會拖到視窗外放開，疊在一起的其他隻那一下也碰不到王 → 會被判沒施法、又去重卡，一隻接一隻停不下來
                ; （23:11～23:15 重卡 39 次）。同一隻 25 秒內不重卡第二次；重卡完所有角色都重新計 8 秒
                c := brCast[stuck.name]
                if !c.HasOwnProp("fixAt") || A_TickCount - c.fixAt >= 25000 {
                    c.fixAt := A_TickCount
                    BrCastFix(stuck, b)
                    for nm, cc in brCast
                        cc.idleSince := A_TickCount
                    brLockTick := A_TickCount
                    return
                }
            }
        }
        if !IsObject(brBoss) || brBoss.glob != b.glob {
            BrCastReport(IsObject(brBoss) ? brBoss.name : "")
            seenText := brSeen.Length ? "（第 " (brSeen.Length + 1) " 隻）" : ""
            brSeen.Push(b.name)
            BrBossEnd(now)   ; 上一隻沒等到「不見了」就換成這隻：上一隻算到現在
            try brRound.bosses.Push({name: b.name, t0: now, t1: 0})
            try BossLockPushWeb()
            if InStr(b.name, BR_LAST_BOSS)
                brSawLast := true
            EventLog(top.name, "BR_BOSS", "王出現：" b.name seenText "｜位置 (" Round(b.x) "," Round(b.z) ")｜瞄準高度 " BrAimH(b.name))
            BrSay("打王中：" b.name "（第 " brSeen.Length " 隻）")
            ; 第 2 隻以後：手動是每隻新王都先放開、游標移到新王血條、再卡一次（11/24 13:05～13:20 每次換王都重卡）→ 1.5 秒後照做
            if brSeen.Length > 1 || brRelockAt = 1
                brRelockAt := now + 1500
        }
        brBoss := b
        if brRelockAt && now >= brRelockAt {
            brRelockAt := 0
            EventLog(top.name, "BR_RELOCK", "換王：放開、游標移到 " b.name " 的血條、重新卡右鍵")
            try BossLockStop()
            foregroundOwner := "bossraid"   ; 放開到重卡之間不讓命運箱子插進來
            try {
                BlActivate(top)
                pt := BrAimFor(top, b)
                if IsObject(pt)
                    BlSetCursor(pt.x, pt.y), brAimPt := pt
                BrLockAll(BrLockOrder(), b)
                if IsObject(pt)
                    BlSetCursor(pt.x, pt.y)
            } finally {
                if foregroundOwner = "bossraid"
                    foregroundOwner := ""
            }
            brAimPt := BlCursor(), brLockTick := A_TickCount
            return
        }
        ; 命運箱子開完（開箱子的角色就不再施法）：那隻重新卡右鍵（v1.3.90.108）
        mbl := 0, mbb := false
        try mbl := mboxLastOwn, mbb := mboxBusy
        if mbl > brLockTick && !mbb && now - mbl >= 1500 && BL_STATE = "locked" {
            for p in brEntered {
                on := false
                try on := MBoxOn(p)
                if !on || !blLocked.Has(p.name)
                    continue
                aim := BrAimChar(p)
                if !IsObject(aim)
                    aim := IsObject(brAimPt) ? brAimPt : BlCursor()
                err := BlRelockOne(p, aim)
                EventLog(p.name, "BR_MBOX_RELOCK", "命運箱子開完，重新卡右鍵" (err = "" ? "" : "｜失敗：" err))
            }
            ; v1.3.90.135：11/24 19:29～19:38 每次欸等等開完箱子，疊在最上面的小白貓 5 秒後就停止施法（8 秒後才被自動重卡）。
            ; 開完箱子順便檢查其他隻，沒在施法的馬上重卡
            for p in brEntered {
                if !blLocked.Has(p.name) || BrCasting(p, 1200)
                    continue
                aim := BrAimChar(p)
                if !IsObject(aim)
                    continue
                err := BlRelockOne(p, aim)
                EventLog(p.name, "BR_MBOX_RELOCK", "命運箱子開完後這隻沒在施法，重新卡右鍵" (err = "" ? "" : "｜失敗：" err))
                try brCast[p.name].idleSince := A_TickCount
            }
            brLockTick := A_TickCount
            return
        }
        ; v1.3.90.107：不再一直把游標拉回算出來的位置（11/24 13:34 實測算的位置不準、你調了又被拉回去）。
        ; 你手動把游標移到別的地方、停 2 秒 → 記住這個位置（換王重卡時直接用），也記住這隻王的血條高度
        ; v1.3.90.140：停用（游標會自己繞王畫圈，而且 11/24 18:48、18:59 你移游標時被誤記成高度 11、6）；要記高度請按「🎯 記住瞄準高度」
        c := BlCursor()
        if false && IsObject(brAimPt) && Abs(c.x - brAimPt.x) + Abs(c.y - brAimPt.y) > 6 && BlIdle() >= 2000 {
            brAimPt := c, brUserPt := c
            h := BrLearnAt(top, b, c)
            EventLog(top.name, "BR_AIM_USER", "你調了游標位置｜" b.name (h >= 0 ? "｜血條離地 " h "（已記住），每隻照這個高度重新卡右鍵" : "（算不出高度，換王重卡時用這個位置）"))
            if h >= 0
                brRelockAt := now + 300   ; 用學到的高度，每隻在自己的視窗重新瞄準、重卡
        }
        return
    }
    if IsObject(brBoss) {
        BrCastReport(brBoss.name)
        sec := BrBossEnd(now)
        EventLog(top.name, "BR_BOSS_DOWN", brBoss.name " 不見了（打死了）｜已經打 " brSeen.Length " 隻" (sec > 0 ? "｜這隻打了 " BrDur(sec) : ""))
        try BossLockPushWeb()
        brBoss := 0
    }
    idle := now - brLastBossAt
    if brSawLast && idle >= 15000 {
        SetTimer BrFightTick, 0
        BrFinish("最後一隻「" BR_LAST_BOSS "」打完")
    } else if !brSeen.Length && idle >= 30000 {   ; v1.3.90.122：進去 30 秒都沒王 = 還沒重生（11/24 15:30 待 3 分鐘也沒出來，有人在裡面不會重生）
        SetTimer BrFightTick, 0
        BrFinish("進場 30 秒沒有王出現（還沒重生）")
    } else if idle >= 180000 {
        SetTimer BrFightTick, 0
        BrFinish("3 分鐘沒有王出現")
    } else if now - brFightStart >= 45 * 60000 {
        SetTimer BrFightTick, 0
        BrFinish("打了 45 分鐘，先結束")
    }
}
; 結束：全部放開 → 每隻走回出發點點「確認」回學院廣場
; 進場時王在不在 → 調整下次要等幾秒（只在「從上一輪離場算起」的情況才算數）
BrRespawnNote(present) {
    global brEmptySec, INI
    if brEmptySec < 0
        return
    sec := brEmptySec, brEmptySec := -1
    if sec > 1800   ; 上次離場太久以前（不是連打）：不算
        return
    fx := BrIni("RespawnFixed", "")   ; 固定讓地圖空幾秒（v1.3.90.123：11/24 實測 48 秒不夠、64 秒夠，你決定固定 66）
    if IsInteger(fx) && Integer(fx) > 0 {
        IniWrite Max(5, Integer(fx) - 15), INI, "BossRaid", "LoopDelaySec"
        EventLog("GLOBAL", "BR_RESPAWN", "地圖空了 " sec " 秒，進去時王" (present ? "在" : "不在") "｜固定讓地圖空 " fx " 秒")
        return
    }
    good := BrIni("RespawnGood", ""), bad := BrIni("RespawnBad", "")
    good := IsInteger(good) ? Integer(good) : 0, bad := IsInteger(bad) ? Integer(bad) : 0
    if present {
        if !good || sec < good
            good := sec
    } else if sec > bad
        bad := sec
    if good && bad >= good   ; 互相矛盾（例如同樣秒數一次有一次沒有）：以比較長的為準
        good := bad + 10
    IniWrite good ? good : "", INI, "BossRaid", "RespawnGood"
    IniWrite bad ? bad : "", INI, "BossRaid", "RespawnBad"
    ; 下次要等幾秒：還沒找到不夠的 → 比夠的少 15 秒（最少 10）；找到了 → 兩者中間；差 10 秒以內 → 固定用夠的
    if !good
        nxt := Max(150, bad + 30)
    else if !bad
        nxt := Max(10, good - 15)
    else if good - bad <= 10
        nxt := good
    else
        nxt := Round((good + bad) / 2)
    ; 離場要花時間（最後一隻走出去到下一輪第一隻進場，程式本身大約要 15 秒），等的秒數 = 目標空地圖秒數 - 15
    IniWrite Max(5, nxt - 15), INI, "BossRaid", "LoopDelaySec"
    EventLog("GLOBAL", "BR_RESPAWN", "地圖空了 " sec " 秒，進去時王" (present ? "在" : "不在") "｜目前：夠的最短 " (good ? good " 秒" : "?") "，不夠的最長 " (bad ? bad " 秒" : "?") "｜下一輪讓地圖空 " nxt " 秒" (good && bad && good - bad <= 10 ? "（已找到）" : ""))
}
; 每日更換道具問：要不要等（回傳原因；空字串 = 不用等）
BrYieldForDaily(p := 0) {
    global BR_STATE, brPauseReq, brEntered
    if BR_STATE = "idle"
        return ""
    ; v1.3.90.127：打王的角色自己要換 → 等這一輪打完、回到學院廣場再換（下一輪等它換完才進場）
    if IsObject(p) {
        for q in brEntered
            if q.name = p.name
                return "這隻在打冒險小隊 Boss，等這一輪打完回到廣場再換"
        try {
            if BR_STATE = "entering" && BlCfg(p.name).on
                return "這隻正要進場打冒險小隊 Boss，等這一輪打完回到廣場再換"
        }
    }
    if BR_STATE = "paused"
        return ""
    ; 掛網的其他角色要換：打王先暫停（放開右鍵讓出前景），換完再回來
    rr := 99, rd := 0
    try rr := FpRank("raid"), rd := FpRank("daily")
    if rr < rd
        return "冒險小隊打王中（優先順序較高，等這一輪打完）"
    brPauseReq := "更換每日道具"   ; 打王中 → 下一次檢查就暫停；進場 / 離場中 → 做完那段再暫停
    return "等冒險小隊打王先暫停（放開右鍵）"
}
; 每日討伐（沒在打王的角色）要換圖 / 點 NPC：打王先暫停，每日討伐那一步做完（或 3 分鐘）再回來（v1.3.90.161）
BrDhYield(p) {
    global BR_STATE, brPauseReq, brDhYieldAt
    if BR_STATE = "idle"   ; 不是自動打王（手動多開打王卡右鍵）：照樣等
        return "多開打王卡右鍵中"
    if BR_STATE = "paused"
        return ""
    ; v1.3.90.175：最後一隻（路西法）出現後到撿完掉落物、離開，不暫停（11/26 06:57 路西法剛死就暫停讓每日討伐換圖，
    ; 回來晚了快 1 分鐘才撿，一個都沒撿到）。每日討伐等這一輪打完再換
    global brSawLast
    if brSawLast || BR_STATE = "leaving"
        return "冒險小隊打王在打最後一隻 / 撿掉落物，等這一輪打完"
    if brDhYieldAt = 0 {
        brDhYieldAt := A_TickCount
        brPauseReq := "每日討伐換圖（" p.name "）"
    }
    return "等冒險小隊打王先暫停（放開右鍵）"
}
; v1.3.90.174：打王的角色有設定組隊、但隊伍還沒組好（例如重新登入後被踢出隊伍）→ 回傳原因；組好了 / 沒開自動組隊回傳空字串。
; 暫停後要回去打、或兩輪之間要接下一輪之前，先等自動組隊把人邀回來（最多 5 分鐘）
global brPartyWaitSince := 0
BrPartyPending(names) {
    global profiles
    try {
        global AP_ENABLED
        if !AP_ENABLED
            return ""
    } catch
        return ""
    for L in profiles {
        isLeader := false
        try isLeader := L.enabled && ApIsLeader(L)
        if !isLeader
            continue
        grp := []
        try grp := ApGroupNames(L)
        hit := false
        for nm in names
            if ApHasName(grp, nm) || nm = L.name
                hit := true
        if !hit
            continue
        pl := 0
        try pl := ApPlan(L)
        if !IsObject(pl)
            continue
        if pl.err != "" {
            if InStr(pl.err, "還沒登入完成")
                return "等 " L.name " 登入完成再組隊"
            continue   ; 其他狀況（例如隊長換人）交給自動組隊的邀回 / 交還
        }
        for mp in pl.todo
            for nm in names
                if mp.name = nm
                    return "等自動組隊把 " nm " 邀回 " L.name " 的隊伍"
    }
    return ""
}
BrPartyWait(names) {   ; 要等就回傳原因（等超過 5 分鐘就不等了，回傳空字串）
    global brPartyWaitSince
    why := BrPartyPending(names)
    if why = "" {
        brPartyWaitSince := 0
        return ""
    }
    if !brPartyWaitSince {
        brPartyWaitSince := A_TickCount
        EventLog("GLOBAL", "BR_WAIT", why "（最多等 5 分鐘）")
    }
    if A_TickCount - brPartyWaitSince > 300000 {
        EventLog("GLOBAL", "BR_WAIT", "等組隊超過 5 分鐘（" why "），先繼續打王")
        brPartyWaitSince := 0
        return ""
    }
    return why
}
; 打王中要不要暫停：每日更換道具要做了、或有角色在重新登入 / 載入
BrPauseNeeded() {
    global brPauseReq, processingQueue, activeRecoveryHwnd, fastLoginCritical, recoveryQueue, asyncLoadingEntries, dailyRunning, profiles
    if brPauseReq != ""
        return brPauseReq
    try {
        if dailyRunning != ""
            return "更換每日道具"
    }
    try {
        if processingQueue || activeRecoveryHwnd || fastLoginCritical || recoveryQueue.Length || asyncLoadingEntries.Count
            return "有角色在重新登入"
    }
    return ""
}
BrPause(why) {
    global brPauseReq, brPauseWhy, brPausedAt, BR_STATE
    SetTimer BrFightTick, 0
    brPauseWhy := why, brPausedAt := A_TickCount
    EventLog("GLOBAL", "BR_PAUSE", "冒險小隊打王暫停：" why "｜先放開右鍵讓路，做完再回來")
    try BossLockStop()
    brPauseReq := ""
    BrSetState("paused", "暫停中（" why "），做完會自動回來接著打")
    SetTimer BrPauseTick, 3000
}
; 暫停中：每日更換道具 / 重新登入都做完、沒有東西擋著 → 回來接著打
BrPauseTick() {
    global BR_STATE, brPausedAt, brPauseWhy, brStop, dailyRunQueue, dailyRunning
    if BR_STATE != "paused" {
        SetTimer BrPauseTick, 0
        return
    }
    if brStop {
        SetTimer BrPauseTick, 0
        BrSetState("fighting", "")
        BrFinish("已停止")
        return
    }
    busy := BrPauseNeeded() != ""
    try busy := busy || dailyRunQueue.Length > 0 || dailyRunning != ""
    global brDhYieldAt
    if brDhYieldAt && A_TickCount - brDhYieldAt < 180000   ; 每日討伐還沒做完那一步（最多等 3 分鐘）
        busy := true
    else
        brDhYieldAt := 0
    why := ""
    try why := ApBlockerRaw()
    if !busy && why = "" {   ; 重新登入 / 換道具都做完了：隊伍也要組好才回去打
        global brEntered
        nm := []
        for q in brEntered
            nm.Push(q.name)
        pw := BrPartyWait(nm)
        if pw != "" {
            BrSetState("paused", "暫停中：" pw)
            busy := true
        }
    }
    if busy || why != "" {
        if A_TickCount - brPausedAt > 1800000 {   ; 等了 30 分鐘還不能回來：結束這一輪（角色留在原地）
            SetTimer BrPauseTick, 0
            EventLog("GLOBAL", "BR_PAUSE", "暫停 30 分鐘還不能回來（" (why != "" ? why : brPauseWhy) "），結束這一輪")
            BrSetState("fighting", "")
            BrFinish("暫停太久")
        }
        return
    }
    SetTimer BrPauseTick, 0
    EventLog("GLOBAL", "BR_RESUME", "暫停結束（" brPauseWhy "，" Round((A_TickCount - brPausedAt) / 1000) " 秒），回王的地圖接著打")
    BrSetState("entering", "回王的地圖接著打")
    SetTimer BrResumeFight, -10
}
; 不在王地圖的角色重新進場（在裡面的走回站位），然後重新卡右鍵
BrResumeFight() {
    global brEntered, foregroundOwner, apBusy, apRunStart, apLastOwn, brRelockAt, brStop, brLastBossAt
    ok := []
    ; v1.3.90.177：這一輪有勾參加的角色都帶回來（不只暫停前已經在打的）：11/26 08:41 進場途中碰到重新登入，
    ; 小白貓、嗨朵拉的盒子「進場失敗」被排除，暫停回來只剩欸等等一隻在打
    back := []
    try {
        for q in BlChars()
            if !BrInDailyHunt(q)
                back.Push(q)
    }
    for q in brEntered {
        has := false
        for x in back
            if x.name = q.name
                has := true
        if !has
            back.Push(q)
    }
    brEntered := back
    try BlStackWindows(brEntered, BrTop())   ; 重新登入後視窗可能被搬回記錄的位置：再疊一次
    apBusy := true, foregroundOwner := "bossraid", apRunStart := A_TickCount, apLastOwn := A_TickCount
    try {
        for p in brEntered {
            if brStop
                break
            r := ""
            Loop 3 {
                try {
                    r := BrEnter(p)
                    break
                } catch as e {
                    EventLog(p.name, "BR_FAIL", "回王的地圖失敗（第 " A_Index " 次）｜" e.Message)
                    if InStr(e.Message, "已按停止")
                        break
                    Sleep 3000
                    apLastOwn := A_TickCount, apRunStart := A_TickCount
                }
            }
            if r = "ok"
                ok.Push(p)
        }
    } finally {
        foregroundOwner := "", apBusy := false, apRunStart := 0
    }
    if !ok.Length {
        BrSetState("fighting", "")
        BrFinish("暫停後沒有角色回到王的地圖")
        return
    }
    brEntered := ok
    brRelockAt := 1, brLastBossAt := A_TickCount   ; 看到王就馬上重新卡右鍵
    BrSetState("fighting", "接著打（暫停後回來）")
    SetTimer BrFightTick, 500
}
; v1.3.90.140 游標繞王畫圈：卡著右鍵但游標沒碰到王（王移動 / 盲區）時，游標在王血條周圍繞小圈（橢圓，左右 28、上下 36 像素，
; 每 0.5 秒換一個點），疊在一起的視窗都會碰到王。只在有角色 2 秒以上沒施法、而且你沒在動滑鼠（3 秒）時繞；都在施法了就放回中心
global brCircleIdx := 0, brCircling := false
BrCircle(top, b, now) {
    global brCast, brCircleIdx, brCircling, foregroundOwner, brAimPt
    weak := false
    for nm, c in brCast
        if c.n && now - c.idleSince >= 2000
            weak := true
    center := BrBossScreen(top, b)
    if !IsObject(center)
        return
    if !weak || foregroundOwner != "" || BlIdle() < 3000 {
        if brCircling && !weak {
            brCircling := false
            BlSetCursor(center.x, center.y), brAimPt := center
        }
        return
    }
    static offs := [[0, -36], [20, -25], [28, 0], [20, 25], [0, 36], [-20, 25], [-28, 0], [-20, -25]]
    if !brCircling {
        brCircling := true
        txt := ""
        for nm, c in brCast
            if c.n && now - c.idleSince >= 2000
                txt .= (txt = "" ? "" : "、") nm
        EventLog("GLOBAL", "BR_CIRCLE", "沒在施法：" txt "｜游標在 " b.name " 周圍繞圈")
    }
    brCircleIdx := Mod(brCircleIdx, offs.Length) + 1
    o := offs[brCircleIdx]
    BlSetCursor(center.x + o[1], center.y + o[2])
    brAimPt := {x: center.x + o[1], y: center.y + o[2]}
}
; 取樣一次每隻的動作；回傳「連續 8 秒沒施法」的那隻（沒有回傳 0）
BrCastSample(now) {
    global brCast, brEntered
    stuck := 0
    for p in brEntered {
        if !brCast.Has(p.name)
            brCast[p.name] := {n: 0, cast: 0, idleSince: now, w: 0, wc: 0}
        c := brCast[p.name]
        if !c.HasOwnProp("w")
            c.w := 0, c.wc := 0
        me := 0
        try me := MiningCharState(p.pid)
        if !IsObject(me) || !me.HasOwnProp("action")
            continue
        c.n += 1, c.w += 1
        if me.action = 3
            c.cast += 1, c.wc += 1, c.idleSince := now
        else if now - c.idleSince >= 8000 && !IsObject(stuck)
            stuck := p
        ; v1.3.90.181：斷斷續續有施法（不會連續 8 秒沒施法）但 30 秒內施法不到 40%，也當作沒打到王處理（走回站位、重卡）。
        ; （11/26 15:27 小白貓進場走到離站位 17 被擋住，整輪施法 15%，因為偶爾有施法一直沒被救）
        if c.w >= 60 {
            low := c.wc * 100 < c.w * 40
            c.w := 0, c.wc := 0
            if low && !IsObject(stuck)
                stuck := p
        }
    }
    return stuck
}
; v1.3.90.138：8 秒沒施法的處理。11/24 20:12 王跑到 (-118,62)（平常在 (-135,70)），欸等的技能距離短，站在原位一直重卡、一直打不到（施法 6%）。
; 離王超過 12 → 放開、走到王旁邊（王和人物之間、離王 8）→ 用「換高度試」的方式重卡（BrLockAll）
BrCastFix(p, b) {
    ; v1.3.90.149：離固定站位太遠（> 10，被擠走 / 走偏 / 進場沒走到）才走回站位；其他直接用這隻王的高度重卡（不再每次試 8 個高度，那樣每輪卡 30 秒）
    global foregroundOwner, apBusy, apRunStart, apLastOwn, BR_STAND
    me := 0
    try me := MiningCharState(p.pid)
    ds := IsObject(me) ? Sqrt((me.x - BR_STAND.x) ** 2 + (me.z - BR_STAND.z) ** 2) : 0
    if ds > 10 && foregroundOwner = "" {   ; v1.3.90.150：20 → 10（22:40 欸等等停在離站位 15，整輪施法 14%）
        EventLog(p.name, "BR_CAST_MOVE", "連續 8 秒沒有施法，離站位 " Round(ds) "：走回站位再卡")
        try BlReleaseOne(p)
        apBusy := true, foregroundOwner := "bossraid", apRunStart := A_TickCount, apLastOwn := A_TickCount
        try {
            if ApActivate(p)
                BrGoNearBoss(p)
        } catch as e {
            EventLog(p.name, "BR_CAST_MOVE", "走回站位失敗：" e.Message)
        } finally {
            foregroundOwner := "", apBusy := false, apRunStart := 0
        }
    }
    aim := BrAimChar(p)
    if !IsObject(aim)
        return
    err := BlRelockOne(p, aim)
    EventLog(p.name, "BR_CAST_RELOCK", "連續 8 秒沒有施法，重新卡右鍵" (err = "" ? "" : "｜失敗：" err))
}
; 這隻王的施法比例寫日誌，然後歸零
BrCastReport(bossName) {
    global brCast
    if !brCast.Count
        return
    txt := ""
    for nm, c in brCast
        txt .= (txt = "" ? "" : "｜") nm " " (c.n ? Round(c.cast * 100 / c.n) "%" : "?")
    EventLog("GLOBAL", "BR_CAST_RATE", (bossName != "" ? bossName "：" : "") "施法中比例（每 0.5 秒看一次人物動作）｜" txt)
    for nm, c in brCast
        c.n := 0, c.cast := 0
}
; v1.3.90.183：傳送卡右鍵都沒反應 = 假在線：這一輪參加的角色全部關掉遊戲重新登入（有開「假在線自動恢復」的），
; 重新登入完、隊伍組好再自動接下一輪（BrLoopStart 會等重新登入 / 組隊）
BrFakeOnline(chars) {
    global profiles
    ; v1.3.90.184：這一輪沒帶的參加角色（例如在跑每日討伐）也一起重新登入：同一時間通常一起假在線（11/27 06:00 欸等也是）
    all := chars.Clone()
    try {
        for q in BlChars() {
            has := false
            for x in all
                if x.name = q.name
                    has := true
            if !has
                all.Push(q)
        }
    }
    chars := all
    names := []
    for p in chars
        names.Push(p.name)
    EventLog("GLOBAL", "BR_FAKE_ONLINE", "右鍵傳送卡沒反應（連續兩次、沒有任何一隻傳得過去），判定假在線｜重新登入：" BcJoin(names))
    try SendDiscordMessage("🔌 HIHIYONG 冒險小隊打王：傳送卡右鍵沒反應，判定假在線，重新登入 " BcJoin(names) "，登入完、組好隊後自動接著打")
    fn := "SoftDisconnectConfirmed"
    for i, q in profiles
        for p in chars
            if q.name = p.name {
                q.memSoftAlerted := 1
                try %fn%(i, q, "冒險小隊打王：右鍵傳送卡沒反應（假在線）")
            }
    if BrIni("Loop", "0") = "1"
        SetTimer BrLoopStart, -60000
}
; 一輪結束：要不要接下一輪。回傳給人看的說明（不接回傳空字串）
BrLoopNext(why, failedN) {
    global brStop, brLoopN, brNoBossN
    if BrIni("Loop", "0") != "1"
        return ""
    if brStop || InStr(why, "已停止") {
        brLoopN := 0, brNoBossN := 0
        return ""
    }
    if failedN
        return "有角色沒離開地圖，不接下一輪"
    brLoopN += 1
    mx := BrIni("LoopMax", "0")
    if IsInteger(mx) && Integer(mx) > 0 && brLoopN >= Integer(mx) {
        brLoopN := 0
        return "已經連打 " mx " 輪，停止"
    }
    ; v1.3.90.121：11/24 15:29 離場 5 秒就再進，王沒重生（待 3 分鐘都沒出來）；15:03 離場、15:05 再進（隔 2.5 分鐘）王在。
    ; 王要等地圖沒人一段時間才重生 → 離場後等 LoopDelaySec（預設 150 秒）再進
    d := BrIni("LoopDelaySec", "150")
    delay := (IsInteger(d) ? Max(5, Integer(d)) : 150) * 1000
    if InStr(why, "沒有王出現") {
        brNoBossN += 1
        if brNoBossN >= 3 {
            brLoopN := 0, brNoBossN := 0
            return "連續 3 輪沒等到王，不再接"
        }
    } else
        brNoBossN := 0
    SetTimer BrLoopStart, -delay
    return Round(delay / 1000) " 秒後接第 " (brLoopN + 1) " 輪（等王重生）"
}
BrLoopStart() {
    global BR_STATE, dailyRunQueue, dailyRunning
    if BR_STATE != "idle" || BrIni("Loop", "0") != "1"
        return
    why := ""
    try why := ApBlockerRaw()
    try {
        if why = "" && (dailyRunQueue.Length || dailyRunning != "")
            why := "每日更換道具排隊中"
    }
    if why = "" {
        nm := []
        try {
            for q in BlChars()
                nm.Push(q.name)
        }
        why := BrPartyWait(nm)
    }
    if why != "" {   ; 被擋住（例如有角色在重新登入、要換每日道具、隊伍還沒組好）：30 秒後再看
        SetTimer BrLoopStart, -30000
        return
    }
    EventLog("GLOBAL", "BR_LOOP", "打完自動接下一輪")
    BossRaidStart()
}
BossRaidSetLoop(v) {
    global INI, brLoopN, brNoBossN
    f := StrSplit(v, "~")
    on := f[1] = "1"
    IniWrite on ? "1" : "0", INI, "BossRaid", "Loop"
    if f.Length >= 2 && IsInteger(f[2])
        IniWrite Max(0, Integer(f[2])), INI, "BossRaid", "LoopMax"
    if !on
        SetTimer BrLoopStart, 0
    brLoopN := 0, brNoBossN := 0
    EventLog("GLOBAL", "BR_CFG", "自動進場打王：打完自動接下一輪＝" (on ? "開（最多 " BrIni("LoopMax", "0") " 輪，0 = 不限）" : "關"))
}
; 這隻王結束：記下結束時間，回傳打了幾秒（沒有在計時回傳 0）
BrBossEnd(now) {
    global brRound
    try {
        if brRound.bosses.Length {
            last := brRound.bosses[brRound.bosses.Length]
            if !last.t1 {
                last.t1 := now
                return Round((now - last.t0) / 1000)
            }
        }
    }
    return 0
}
BrDur(sec) => sec >= 60 ? Floor(sec / 60) " 分 " Mod(sec, 60) " 秒" : sec " 秒"
; 一輪結束：寫日誌 / 通知 / 存檔（最近 BR_RUNS_KEEP 輪）
BrRoundSave(why) {
    global brRound, INI, BR_RUNS_KEEP
    if !IsObject(brRound)
        return ""
    BrBossEnd(A_TickCount)
    total := Round((A_TickCount - brRound.t0) / 1000)
    fight := brRound.fightT0 ? Round(((brRound.leaveT0 ? brRound.leaveT0 : A_TickCount) - brRound.fightT0) / 1000) : 0
    parts := "", txt := ""
    for x in brRound.bosses {
        sec := x.t1 ? Round((x.t1 - x.t0) / 1000) : 0
        parts .= (parts = "" ? "" : ",") StrReplace(StrReplace(x.name, "~", ""), ",", "") "~" sec
        txt .= "｜・" x.name "：" BrDur(sec)
    }
    line := brRound.when "|" total "|" Round(brRound.enterMs / 1000) "|" fight "|" Round(brRound.leaveMs / 1000) "|" brRound.chars "|" StrReplace(why, "|", "／") "|" parts
    ; 往後推一格，最新的放 R1
    k := BR_RUNS_KEEP
    while k > 1 {
        v := IniRead(INI, "BossRaidRuns", "R" (k - 1), "")
        if v != ""
            IniWrite v, INI, "BossRaidRuns", "R" k
        k -= 1
    }
    IniWrite line, INI, "BossRaidRuns", "R1"
    stats := "打王統計｜" brRound.when "｜" brRound.chars "｜" why "｜王 " brRound.bosses.Length " 隻" txt "｜進場 " BrDur(Round(brRound.enterMs / 1000)) "｜打王 " BrDur(fight) "｜離開 " BrDur(Round(brRound.leaveMs / 1000)) "｜一輪總時間 " BrDur(total)
    EventLog("GLOBAL", "BR_STATS", stats)
    brRound := 0
    return stats
}
; 背包裡打王掉的道具（帝王披風轉盤）有幾個（v1.3.90.153）；讀不到回傳 -1
global BR_LOOT_ITEM := "帝王披風轉盤"
BrLootHave(p) {
    global BR_LOOT_ITEM
    if !IsObject(p) || !p.pid
        return -1
    slots := 0
    try slots := ReadGameInventorySlots(p.pid, "InvenOffset")
    if !IsObject(slots)
        return -1
    n := 0
    for sl in slots {
        nm := ""
        try nm := GameItemName(sl.key, p.pid)
        if InStr(nm, BR_LOOT_ITEM)
            n += sl.count
    }
    return n
}
; 頁面：清除紀錄（最近幾輪的表格）
BossRaidClearRuns() {
    global INI
    try IniDelete INI, "BossRaidRuns"
    EventLog("GLOBAL", "BR_CFG", "清除自動進場打王的每輪紀錄")
}
; 頁面：最近幾輪
BrRunsJson() {
    global INI, BR_RUNS_KEEP
    out := ""
    Loop BR_RUNS_KEEP {
        v := IniRead(INI, "BossRaidRuns", "R" A_Index, "")
        if v = ""
            break
        f := StrSplit(v, "|")
        if f.Length < 8
            continue
        bs := ""
        for part in StrSplit(f[8], ",") {
            q := StrSplit(part, "~")
            if q.Length >= 2 && q[1] != ""
                bs .= (bs = "" ? "" : ",") '{"name":"' JsonEscapeWeb(q[1]) '","sec":' (IsInteger(q[2]) ? q[2] : 0) '}'
        }
        out .= (out = "" ? "" : ",") '{"when":"' JsonEscapeWeb(f[1]) '","total":' Integer(f[2]) ',"enter":' Integer(f[3]) ',"fight":' Integer(f[4]) ',"leave":' Integer(f[5]) ',"chars":"' JsonEscapeWeb(f[6]) '","why":"' JsonEscapeWeb(f[7]) '","bosses":[' bs ']}'
    }
    return out
}
BrFinish(why) {
    global brLootFull
    global brEntered, brSeen, foregroundOwner, apBusy, apRunStart, apLastOwn, brStop, INI
    BrSetState("leaving", why "｜放開右鍵、離開地圖")
    try brRound.leaveT0 := A_TickCount
    EventLog("GLOBAL", "BR_FINISH", why "｜打了 " brSeen.Length " 隻：" BcJoin(brSeen))
    try BossLockStop()
    left := [], failed := []
    lastDone := InStr(why, "最後一隻")
    ; v1.3.90.110：只讓一隻撿（11/24 14:05 欸等一隻就撿到 5 個，欸等等空按 25 秒）。撿的那隻先做，其他隻直接走
    looter := BrLooter()
    lootGot := -1, lootFull := Map()
    lootBefore := lastDone ? BrLootAll() : ""   ; v1.3.90.180：撿之前 / 離開後每隻背包各有幾個（查掉落物跑到誰身上）
    if lootBefore != ""
        EventLog("GLOBAL", "BR_LOOT_CHECK", "撿之前每隻背包的" BR_LOOT_ITEM "：" lootBefore)
    order := [looter]
    for p in brEntered
        if p != looter
            order.Push(p)
    apBusy := true, foregroundOwner := "bossraid", apLastOwn := A_TickCount
    try {
        for p in order {
            if brStop && why != "已停止"
                break
            ; v1.3.90.167：你動到鍵盤滑鼠被叫停 → 等你停手 5 秒再重做這隻（最多 3 次、每次最多等 5 分鐘），不要整輪放棄
            ; （11/25 20:57 欸等撿掉落物時偵測到操作，四隻都沒離開、也沒接下一輪）
            tries := 0
            loop {
                try {
                    if lastDone && p = looter {
                        lootGot := BrPickLoot(p)
                        if lootGot = 0 {
                            brLootFull[p.name] := A_TickCount
                            try SendDiscordMessage("⚠️ HIHIYONG 冒險小隊打王：" p.name " 撿不到掉落物（背包可能滿了），改由其他角色撿；請有空時清一下 " p.name " 的背包")
                        }
                    }
                    else if lastDone && lootGot = 0 && !lootFull.Has(p.name) && lootFull.Count = 0 {
                        ; v1.3.90.179：只換一隻試（11/26 13:34 四隻輪流各撿 25 秒都 0 個：掉落物多半只有隊長 / 撿的那隻撿得到）
                        ; v1.3.90.178：撿的那隻一個都沒撿到（11/26 13:02 欸等「裝備道具欄已滿」）→ 還沒離開的下一隻接著撿
                        EventLog(p.name, "BR_LOOT", "上一隻沒撿到掉落物（背包可能滿了），改由 " p.name " 撿")
                        lootGot := BrPickLoot(p)
                        if lootGot = 0
                            lootFull[p.name] := 1, brLootFull[p.name] := A_TickCount
                    }
                    BrLeave(p)
                    left.Push(p.name)
                    break
                } catch as e {
                    if e.Extra = "stop" && !brStop && tries < 3 {
                        tries += 1
                        EventLog(p.name, "BR_WAIT", "離開被打斷（" e.Message "）｜等你停手 5 秒再重做（第 " tries " 次）")
                        foregroundOwner := "", apBusy := false
                        t0 := A_TickCount
                        while A_TimeIdlePhysical < 5000 && A_TickCount - t0 < 300000 && !brStop
                            Sleep 500
                        apBusy := true, foregroundOwner := "bossraid", apLastOwn := A_TickCount
                        continue
                    }
                    failed.Push(p.name)
                    EventLog(p.name, "BR_FAIL", "離開失敗｜" e.Message)
                    break
                }
            }
            if brStop && why != "已停止"
                break
        }
    } finally {
        foregroundOwner := "", apBusy := false, apRunStart := 0
    }
    if lastDone {
        lootAfter := BrLootAll()
        EventLog("GLOBAL", "BR_LOOT_CHECK", "離開後每隻背包的" BR_LOOT_ITEM "：" lootAfter "（撿之前：" lootBefore "）")
    }
    msg := why "｜打了 " brSeen.Length " 隻" (left.Length ? "｜回學院廣場：" BcJoin(left) : "") (failed.Length ? "｜沒離開：" BcJoin(failed) : "")
    nextMsg := BrLoopNext(why, failed.Length)
    if nextMsg != ""
        msg .= "｜" nextMsg
    else
        try IniWrite "0", INI, "BossRaid", "Running"   ; 不接下一輪了：重開管理程式也不自動接續
    try brRound.leaveMs := A_TickCount - brRound.leaveT0
    if !failed.Length
        IniWrite A_NowUTC, INI, "BossRaid", "LastLeaveUTC"
    stats := BrRoundSave(why)
    BrSetState("idle", msg)
    EventLog("GLOBAL", "BR_END", msg)
    try SendDiscordMessage("🐉 自動進場打王結束`n" msg (stats != "" ? "`n" StrReplace(stats, "｜", "`n") : ""))
}
; 路西法打完：地上的掉落物寵物不會撿 → 按空白鍵撿，等背包比進場時多出 5 個（最多 25 秒，每 2.5 秒再按一次）
BrPickLoot(p) {
    global brInv, BR_LOOT_COUNT, BR_MAP_BOSS, apRunStart, BR_LOOT_ITEM
    pid := p.pid
    if BrMap(pid) != BR_MAP_BOSS
        return
    apRunStart := A_TickCount
    if !ApIsActive(p) && !ApActivate(p)
        throw Error("叫不到前面")
    DhEnsureAutoHuntOff(p)
    ; v1.3.90.109：從「現在」的背包開始算（以前用進場時的背包：打王中命運箱子開出來的東西也被算進去，可能沒撿完就停）
    base := MnInvSnap(pid)
    if !IsObject(base)
        base := brInv.Get(p.name, 0)
    n := 0, items := Map(), t0 := A_TickCount
    while A_TickCount - t0 < 25000 {
        Loop 2 {
            ApKey(p, "Space")
            MnOwnAct()
            Sleep 300
        }
        ApWait(() => (ApGuardAny(), false), 1800)
        items := MnLootDiff(base, MnInvSnap(pid), pid)
        n := 0
        for k, d in items
            n += d.count
        if n >= BR_LOOT_COUNT
            break
    }
    txt := ""
    for k, d in items
        txt .= (txt = "" ? "" : "、") d.name " ×" d.count
    have := BrLootHave(p)
    EventLog(p.name, "BR_LOOT", "撿掉落物｜背包多了 " n " 個" (n < BR_LOOT_COUNT ? "（不到 " BR_LOOT_COUNT " 個）" : "") (txt != "" ? "：" txt : "") (have >= 0 ? "｜背包現在共 " have " 個" BR_LOOT_ITEM : ""))
    return n
}
BrLootAll() {
    global brEntered, BR_LOOT_ITEM
    out := ""
    for q in brEntered {
        n := -1
        try n := BrLootHave(q)
        out .= (out = "" ? "" : "、") q.name " " (n >= 0 ? n : "?")
    }
    return out
}
BrLeave(p) {
    global dhMapPatient
    dhMapPatient := true
    try
        return BrLeaveCore(p)
    finally
        dhMapPatient := false
}
BrLeaveCore(p) {
    global BR_MAP_BOSS, BR_EXIT, BR_EXIT_OK, apRunStart
    pid := p.pid
    if BrMap(pid) != BR_MAP_BOSS
        return
    apRunStart := A_TickCount
    if !ApActivate(p)
        throw Error("叫不到前面")
    DhEnsureAutoHuntOff(p)
    DhMoveTo(p, BR_EXIT.x, BR_EXIT.z, 5)
    ApWait(() => (ApGuardAny(), false), 1500)
    Loop 3 {
        ApClick(p, BR_EXIT_OK.x, BR_EXIT_OK.y, 150)
        if ApWait(() => (ApGuardAny(), BrMap(pid) != BR_MAP_BOSS && BrMap(pid) != 0 && GameCharacterLoaded(pid)), 10000) {
            EventLog(p.name, "BR_LEAVE", "已回學院廣場")
            return
        }
        DhMoveTo(p, BR_EXIT.x, BR_EXIT.z, 4)   ; 確認框沒出來：再走近出發點一次
        ApWait(() => (ApGuardAny(), false), 1500)
    }
    throw Error("走回出發點點了 3 次確認，還在王的地圖裡")
}
BossRaidStop() {
    global BR_STATE, brStop, brLearnSince, brLoopN, INI
    SetTimer BrLoopStart, 0   ; 等著接下一輪的也取消
    try IniWrite "0", INI, "BossRaid", "Running"   ; 你按停止：重開管理程式也不自動接續
    brLoopN := 0
    if brLearnSince {
        brLearnSince := 0
        SetTimer BrLearnTick, 0
        BrSetState(BR_STATE, "取消記住瞄準高度")
        return
    }
    if BR_STATE = "idle"
        return
    brStop := true
    BrSay("停止中…")
    SetTimer BrForceIdle, -15000
    if BR_STATE = "fighting" || BR_STATE = "paused" {
        SetTimer BrFightTick, 0
        SetTimer BrPauseTick, 0
        if BR_STATE = "paused"
            BrSetState("fighting", "")
        BrFinish("已停止")
    }
}

; 按了停止 15 秒還停不下來（流程卡住）：強制回到待命，放開右鍵，讓你可以重新開始（角色留在原地，要離開請手動或重按開始）
BrForceIdle() {
    global BR_STATE, brStepAt, foregroundOwner, apBusy
    if BR_STATE = "idle" || A_TickCount - brStepAt < 14000
        return
    EventLog("GLOBAL", "BR_FORCE_IDLE", "按了停止 15 秒還沒停下來（狀態：" BR_STATE "），強制回到待命")
    SetTimer BrFightTick, 0
    if foregroundOwner = "bossraid"
        foregroundOwner := "", apBusy := false
    try BossLockStop()
    BrSetState("idle", "已強制停止（流程卡住）；角色留在原地，要離開請手動，或重按「自動進場打王」")
}
; 重開管理程式後自動接續（部署前寫 [BossRaid] ResumeOnStart=1，只用一次）：啟動 25 秒後（角色綁定好、監控接上）按「自動進場打王」
; v1.3.90.118：11/24 14:36 啟動 25 秒就接續，剛好碰上監控啟動掃描綁定視窗（會切視窗）→「視窗不在前面」停掉。
; 改成每 5 秒看一次：參加的角色都「監控中」、沒有其他東西擋著、啟動後至少 40 秒，才開始（最多等 5 分鐘）
global brResumeT0 := A_TickCount
BrResumeCheck() {
    global INI, BR_STATE, brResumeT0, profiles
    ; v1.3.90.188：打王在跑（Running=1，包含兩輪之間等王重生）時管理程式被重開（例如自動更新），也自動接續。
    ; （11/27 11:59 另一台在兩輪之間按了立即更新，重開後沒接續，閒置 18 分鐘）
    if IniRead(INI, "BossRaid", "Running", "0") = "1" && IniRead(INI, "BossRaid", "ResumeOnStart", "0") != "1"
        IniWrite "1", INI, "BossRaid", "ResumeOnStart"
    if IniRead(INI, "BossRaid", "ResumeOnStart", "0") != "1" {
        SetTimer BrResumeCheck, 0
        return
    }
    el := A_TickCount - brResumeT0
    if el > 300000 {
        IniWrite "0", INI, "BossRaid", "ResumeOnStart"
        SetTimer BrResumeCheck, 0
        EventLog("GLOBAL", "BR_RESUME", "重開後等了 5 分鐘還不能開始（角色還沒監控中或被擋住），沒有自動接續")
        return
    }
    if el < 40000 || BR_STATE != "idle"
        return
    ready := true
    for p in BlChars()
        if !p.HasOwnProp("state") || p.state != "監控中"
            ready := false
    why := ""
    try why := ApBlockerRaw()
    if !ready || why != "" || !BlChars().Length
        return
    IniWrite "0", INI, "BossRaid", "ResumeOnStart"
    SetTimer BrResumeCheck, 0
    EventLog("GLOBAL", "BR_RESUME", "重開管理程式後自動接續自動進場打王")
    BossRaidStart()
}
SetTimer BrResumeCheck, 5000
; ---- 記住瞄準高度：游標放在王的血條上停 2 秒，算出血條離地多高（記在這隻王的名字下）----
BossRaidLearnAim() {
    global brLearnSince
    brLearnSince := A_TickCount
    BrSay("把游標放在王的血條上，滑鼠停 2 秒（30 秒內）")
    SetTimer BrLearnTick, 100
}
BrLearnTick() {
    global brLearnSince, profiles, INI, BR_MAP_BOSS, AP_DESIGN_W, AP_DESIGN_H
    if !brLearnSince {
        SetTimer BrLearnTick, 0
        return
    }
    if A_TickCount - brLearnSince > 30000 {
        brLearnSince := 0
        SetTimer BrLearnTick, 0
        BrSay("30 秒內沒停在王身上，沒有記住")
        return
    }
    if A_TickCount - brLearnSince < 500 || BlIdle() < 2000
        return
    brLearnSince := 0
    SetTimer BrLearnTick, 0
    c := BlCursor()
    hw := BlWindowAt(c.x, c.y)
    p := hw ? BcProfileOf(hw) : 0
    if !IsObject(p) {
        BrSay("游標底下不是遊戲視窗，沒有記住")
        return
    }
    b := BrFindBoss(p.pid)
    r := BlClientRect(p)
    if !IsObject(b) || !IsObject(r) {
        BrSay(p.name "：附近找不到王，沒有記住")
        return
    }
    gx := (c.x - r.x) * AP_DESIGN_W / r.w, gy := (c.y - r.y) * AP_DESIGN_H / r.h
    best := -1, bd := 1e18
    Loop 121 {
        h := A_Index - 1
        sp := MnScreenPt(p.pid, b.x, b.y + h, b.z)
        if sp.x < 0
            continue
        d := (sp.x - gx) ** 2 + (sp.y - gy) ** 2
        if d < bd
            bd := d, best := h
    }
    if best < 0 || bd > 60 ** 2 {
        BrSay(p.name "：游標離 " b.name " 太遠（不在王的正上方），沒有記住")
        return
    }
    IniWrite best, INI, "BossRaid", "Aim|" b.name
    EventLog(p.name, "BR_AIM", "記住瞄準高度｜" b.name "｜離地 " best "｜偏差 " Round(Sqrt(bd)) " 像素")
    BrSay("已記住：" b.name " 的血條離地 " best)
}
; 頁面資料（接在多開打王的資料後面）
BrWebJson() {
    global BR_STATE, BR_TEXT, INI, brLoopN
    aims := "", sec := ""
    try sec := IniRead(INI, "BossRaid")
    for line in StrSplit(sec, "`n", "`r")
        if RegExMatch(line, "^Aim\|(.+?)=(\d+)$", &m)
            aims .= (aims = "" ? "" : ",") '{"boss":"' JsonEscapeWeb(m[1]) '","h":' m[2] '}'
    global brRound
    cur := ""
    try {
        if IsObject(brRound) {
            now := A_TickCount, bl := ""
            for x in brRound.bosses
                bl .= (bl = "" ? "" : ",") '{"name":"' JsonEscapeWeb(x.name) '","sec":' Round(((x.t1 ? x.t1 : now) - x.t0) / 1000) ',"live":' (x.t1 ? "false" : "true") '}'
            cur := ',"cur":{"elapsed":' Round((now - brRound.t0) / 1000) ',"bosses":[' bl ']}'
        }
    }
    lootTxt := ""
    try {
        for p in BlChars() {
            n := BrLootHave(p)
            if n > 0
                lootTxt .= (lootTxt = "" ? "" : "、") p.name " " n
        }
    }
    return ',"br":{"loot":"' JsonEscapeWeb(lootTxt) '","state":"' BR_STATE '","text":"' JsonEscapeWeb(BR_TEXT) '","top":"' JsonEscapeWeb(BrTopName()) '","looter":"' JsonEscapeWeb(Trim(BrIni("Looter", ""))) '","loop":' (BrIni("Loop", "0") = "1" ? "true" : "false") ',"loopMax":' (IsInteger(BrIni("LoopMax", "0")) ? BrIni("LoopMax", "0") : 0) ',"loopN":' brLoopN ',"aims":[' aims ']' cur ',"runs":[' BrRunsJson() ']}'
}
; F10 緊急停止：打王相關的計時器全部停掉，不再送任何鍵鼠（卡著的右鍵不動它，你手動處理；要放開按「■ 全部放開」）
BossRaidEmergency() {
    global brStop, BL_STATE, brLearnSince, brLoopN
    brStop := true, brLearnSince := 0, brLoopN := 0
    for f in [BrFightTick, BrPauseTick, BrLoopStart, BrResumeCheck, BrLearnTick, BlWaitTick]
        try SetTimer f, 0
    try {
        global INI
        IniWrite "0", INI, "BossRaid", "ResumeOnStart"
        IniWrite "0", INI, "BossRaid", "Running"
    }
    if BL_STATE = "waiting" || BL_STATE = "running"
        try BlSetState("locked", "")
    EventLog("GLOBAL", "BR_EMERGENCY", "F10 緊急停止：自動進場打王 / 多開打王全部停止（卡著的右鍵沒有放開，要放開按「■ 全部放開」）")
    BrSetState("idle", "F10 緊急停止（卡著的右鍵沒有放開）")
}
; 卡右鍵期間暫停其他會切視窗 / 按鍵的自動功能（ApBlockerRaw 用）
BlPauseReason() {
    global blLocked, BR_STATE
    try {
        if blLocked.Count
            return "多開打王卡右鍵中"
    }
    return ""
}
