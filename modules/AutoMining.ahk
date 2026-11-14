; ============================================================================
; AutoMining：水晶礦場自動採礦。
; 按「▶ 啟動」才會動（不存檔：程式重開一定是停止）；「勾選」是要採礦的角色，各自獨立，同一時間只有一個角色在用前景視窗。
;
; 玩法（從示範錄製看到的）：
;   - 水晶礦場（地圖 213）的「○能原石」是怪物清單裡的物件（血量 200000、永遠待機），不是採集物清單；
;   - 採集工具是背包裡的「十字鎬」：站到礦石旁（錄到的是離礦石 13 單位），右鍵十字鎬，角色進入「採集」動作站著不動 60 秒，
;     採完礦石從清單消失（遊戲公告：被採完的礦石每 30 分鐘重生一次）。
; 流程：不在水晶礦場且有開「自動進圖」→ 用背包 / 銀行的「水晶礦場傳送卡(2H)禮盒」開出傳送卡、右鍵傳進去；
;       在水晶礦場 → 依顏色挑下一顆（綠 > 紫 > 紅 > 黃 > 藍，同顏色挑最近的）→ 走過去 → 右鍵十字鎬 → 確認進入採集 →
;       採集中（60 秒）不佔前景鎖，其他功能照常；礦都採完了就等重生。
; 採礦中的角色血量不會變，不能被「假在線」誤判：這裡把角色標成 p.mnActive，主程式的血量靜止判斷、變慢自動過圖都會略過它。
; 設定存在 INI [AutoMining]：Chars（要採礦的角色，| 分隔）、AutoEnter（沒在水晶礦場時自動進圖 0/1）、KeepInv（背包一直開著 0/1）。
; 只需要道具視窗（I），不開角色視窗（C）。
; ============================================================================

global MN_MAP_MAIN := 213                 ; 水晶礦場的地圖編號
global MN_ORE_NAME := "能原石"             ; 礦石名稱（○能原石）
global MN_COLORS_ALL := ["綠", "紫", "紅", "黃", "藍"]   ; 水晶礦場有的礦石顏色
global MN_TICK_MS := 3000
global MN_STAND_DIST := 8                 ; 站在離礦石幾單位的旁邊（會依採集成功的結果往小學）；目標點是「礦石旁邊」，不是礦石本身
global MN_USE_MAX := 24                   ; 離礦石在這個距離內就直接右鍵十字鎬，不必走得很精準（起始值；實際值每個角色自己學：在 12 單位以上採不起來就往下調、採起來了就不會低於那個距離）
global MN_STOP_DIST := 4                  ; 走到離「旁邊的站位」幾單位內就停
global MN_CLICK_AVOID := 55                ; 地面點擊的落點離任何怪（礦石也是怪）的畫面距離至少這麼遠（1024x768 的像素）；點到礦石人物會一直普攻
global MN_FINAL_STEPS := 14, MN_FINAL_IDLE_MS := 900, MN_FINAL_SEG_MS := 4000
global MN_LOOT_WAIT_MS := 20000            ; 採完後最多等這麼久看水晶進背包（還沒進就先不算沒收穫）；0 = 不等（舊行為）
global MN_MAP_STOP := 6                  ; 大地圖走到離站位這麼近就算到（離礦石最遠 MN_STAND_DIST + 這個 = 14，在 MN_USE_MAX 內、直接採）
global MN_NEAR_OK := 24                   ; （舊值，實際用每個角色學到的 st.useMax）
global MN_GATHER_CONFIRM_MS := 7000       ; 右鍵十字鎬之後最多等這麼久，角色要進入「採集」動作
global MN_SKIP_MS := 600000               ; 走不到 / 採不了的礦石先略過 10 分鐘
global MN_RESPAWN_CHECK_MS := 30000       ; 礦都採完了，每隔多久再看一次（遊戲每 30 分鐘重生一次）
global MN_START_IDLE_MS := 2000
global MN_RUNNING := 0
global MN_RESUME := 0, MN_RESUMED := false   ; 重開程式後自動接續採礦（設定檔 [AutoMining] ResumeOnStart / Running）
global MN_HANG_MS := Max(2, Integer(MnIniGet("GatherHangMin", "5"))) * 60000   ; 採集動作一直沒結束（正常約 60 秒）累積超過這麼久 = 假在線，走假在線自動重新登入
global MN_STALL_MS := 900000                 ; 15 分鐘沒有任何進展 = 卡住（通知 Discord）
global mnBusy := false
global MN_BOSS_BAR := Min(10, Max(0, Integer(MnIniGet("BossBar", "8"))))   ; 打王要求的技能欄 F1～F10（0 = 不檢查）
global MN_BOSS_SKILL := Trim(MnIniGet("BossSkill", "15-0"))               ; 打王要求的右鍵技能代碼（預設 15-0 群魔亂舞；空白 = 只檢查技能欄）
; 打王技能的規則：除了「固定技能職業」（預設 8 = 欸等，用「打王右鍵技能代碼」，預設 15-0 群魔亂舞）以外，
; 其他職業一律用「技能欄第 1 個」的技能（第 1 排第 1 格，按 F1 選；從記憶體讀那一格現在放的技能）。
; 設定檔 [AutoMining] BossFixedClasses（固定技能的職業代碼，逗號分隔，預設 8）、BossClassSlots（個別職業改用別格，格式「職業代碼:第幾個」）。
MnParseClassSlots(text) {
    out := Map()
    for part in StrSplit(text, ",") {
        f := StrSplit(Trim(part), ":")
        if f.Length = 2 && IsInteger(f[1]) && IsInteger(f[2]) && Integer(f[2]) >= 1 && Integer(f[2]) <= 10
            out[Integer(f[1])] := Integer(f[2])
    }
    return out
}
global MN_BOSS_CLASS_SLOTS := MnParseClassSlots(MnIniGet("BossClassSlots", ""))
MnParseIntSet(text) {
    out := Map()
    for part in StrSplit(text, ",")
        if IsInteger(Trim(part))
            out[Integer(Trim(part))] := 1
    return out
}
global MN_BOSS_FIXED_CLASSES := MnParseIntSet(MnIniGet("BossFixedClasses", "8"))
; 個別角色指定打王技能欄第幾格（優先於職業規則）：頁面每個角色旁邊的「打王技能」選單；設定檔 [AutoMining] BossCharSlots，格式「角色名:第幾格|角色名:第幾格」。
MnParseCharSlots(text) {
    out := Map()
    for part in StrSplit(text, "|") {
        i := InStr(part, ":", , -1)
        if i > 1 && IsInteger(Trim(SubStr(part, i + 1))) {
            n := Integer(Trim(SubStr(part, i + 1)))
            if n >= 1 && n <= 10
                out[Trim(SubStr(part, 1, i - 1))] := n
        }
    }
    return out
}
global MN_BOSS_CHAR_SLOTS := MnParseCharSlots(MnIniGet("BossCharSlots", ""))
global MN_BOSS_NAME := "虹光秘脈礦主"      ; 水晶礦場的王（固定地點，2 小時重生一次）
global MN_BOSS_STAND := 14                ; 站在離王幾單位的旁邊打
global MN_BOSS_AIM_H := 12                ; 游標對準王身上離地多高（錄製時游標在王的身體 / 血條下方）
global MN_BOSS_SPACE_PICK := MnIniGet("BossSpacePick", "1") = "0" ? 0 : 1   ; 等不到秘笈進背包就按兩下空白鍵自己撿（INI [AutoMining] BossSpacePick=0 關閉）
global MN_BOSS_SPACE_AFTER_MS := Min(30, Max(1, Integer(MnIniGet("BossSpaceAfterSec", "5")))) * 1000   ; 王死後幾秒背包還沒有秘笈就先按空白鍵（INI [AutoMining] BossSpaceAfterSec，預設 5）
global MN_BOSS_SPACE_WAIT_MS := 4000   ; 按完空白鍵後最多再等幾毫秒看秘笈進背包
global MN_BOSS_LOOT_WAIT_MS := 20000   ; 王打死後最多等幾毫秒，讓寵物把掉落（秘笈）撿進背包；等不到就記一筆並通知
global MN_BOSS_MAX_MS := Min(60, Max(2, Integer(MnIniGet("BossMaxMin", "15")))) * 60000   ; 一隻王最多打幾分鐘（INI [AutoMining] BossMaxMin，預設 15；欸等欸一隻王約 10 分鐘，10 分鐘上限太緊）；超過就放開右鍵、先離開王
global MN_BOSS_ORE_GAP := 45               ; 游標離礦石的畫面點至少幾像素，太近就換瞄王身上別的點
global MN_BOSS_TICK_MS := 300             ; 每隔多久重新對準游標
global mnTestInput := 0                   ; 測試用：取代真正的游標 / 滑鼠右鍵

MnIniGet(key, def := "") {
    global INI
    try return IniRead(INI, "AutoMining", key, def)
    return def
}
MnParseChars(text) {
    out := Map()
    for part in StrSplit(text, "|")
        if (n := Trim(part)) != ""
            out[n] := 1
    return out
}
; 要挖的顏色（照優先順序排）：INI 沒有這一項 = 全部，預設順序綠 > 紫 > 紅 > 黃 > 藍；有這一項但是空的 = 一個都不挖
MnParseColors(text) {
    global MN_COLORS_ALL
    out := []
    for part in StrSplit(text, ",") {
        c := Trim(part)
        known := false
        for k in MN_COLORS_ALL
            if k = c
                known := true
        dup := false
        for o in out
            if o = c
                dup := true
        if known && !dup
            out.Push(c)
    }
    return out
}
global MN_COLORS := MnParseColors(MnIniGet("Colors", "綠,紫,紅,黃,藍"))
global MN_WALK_SPEED := 90                ; 走路速度（單位 / 秒），算挑礦成本用
global MN_RANK_SEC := Max(0, Number(MnIniGet("RankSec", "4")))   ; 顏色順序差一名折合幾秒的走路時間（預設 4；>= 100 = 嚴格依顏色順序，會多跑遠路）
; ---------------------------------------------------------------- 挖礦統計（累積取得的道具）
; 每顆礦開始採集時記下背包，採完後再讀一次，多出來的道具就算這顆礦挖到的（採集中沒有別的來源；王的掉落不在採集的 60 秒內，不會混進來）。
; 存在 INI [MiningStats]，每個角色一行：採集顆數,今天顆數,日期|道具代碼~名稱~累積~今天;…（日期換了今天的數字自動歸零）。
global MN_STATS := Map()
MnToday() => FormatTime(A_Now, "yyyyMMdd")
MnStatsOf(name) {
    global MN_STATS
    if !MN_STATS.Has(name)
        MN_STATS[name] := {gathers: 0, dayGathers: 0, day: MnToday(), items: Map(), runs: []}
    s := MN_STATS[name]
    if s.day != MnToday() {   ; 換日：今天的數字歸零，累積不變
        s.day := MnToday(), s.dayGathers := 0
        for k, it in s.items
            it.day := 0
    }
    return s
}
MnStatsSerialize(s) {
    out := s.gathers "," s.dayGathers "," s.day "|"
    first := true
    for k, it in s.items {
        out .= (first ? "" : ";") k "~" StrReplace(StrReplace(it.name, "~", "-"), ";", "-") "~" it.total "~" it.day
        first := false
    }
    return out
}
MnStatsParse(text) {
    s := {gathers: 0, dayGathers: 0, day: MnToday(), items: Map(), runs: []}
    if Trim(text) = ""
        return s
    parts := StrSplit(text, "|", , 2)
    h := StrSplit(parts[1], ",")
    if h.Length >= 3 && IsInteger(h[1]) && IsInteger(h[2])
        s.gathers := Integer(h[1]), s.dayGathers := Integer(h[2]), s.day := h[3]
    if parts.Length >= 2 && parts[2] != "" {
        for item in StrSplit(parts[2], ";") {
            f := StrSplit(item, "~")
            if f.Length >= 4 && IsInteger(f[3]) && IsInteger(f[4])
                s.items[f[1]] := {name: f[2], total: Integer(f[3]), day: Integer(f[4])}
        }
    }
    return s
}
MnStatsLoad() {
    global INI, MN_STATS
    MN_STATS := Map()
    raw := ""
    try raw := IniRead(INI, "MiningStats")
    for line in StrSplit(raw, "`n", "`r") {
        eq := InStr(line, "=")
        if eq > 1
            MN_STATS[SubStr(line, 1, eq - 1)] := MnStatsParse(SubStr(line, eq + 1))
    }
    raw := ""
    try raw := IniRead(INI, "MiningRuns")
    for line in StrSplit(raw, "`n", "`r") {
        eq := InStr(line, "=")
        if eq > 1 {
            nm := SubStr(line, 1, eq - 1)
            if !MN_STATS.Has(nm)
                MN_STATS[nm] := MnStatsParse("")
            MN_STATS[nm].runs := MnRunsParse(SubStr(line, eq + 1))
        }
    }
}
; ---------------------------------------------------------------- 每輪統計（每次進礦場算一輪：採集顆數、王、取得的道具）
; 存在 INI [MiningRuns]，每個角色一行，最近 MN_RUNS_KEEP 輪：輪號,開始,顆數,王,結束|道具代碼~名稱~數量;…（輪之間用 ^ 分開）
global MN_RUNS_KEEP := 30
MnRunsSerialize(runs) {
    out := ""
    for r in runs {
        it := ""
        for k, d in r.items
            it .= (it = "" ? "" : ";") k "~" StrReplace(StrReplace(StrReplace(d.name, "~", "-"), ";", "-"), "^", "-") "~" d.count
        out .= (out = "" ? "" : "^") r.n "," r.start "," r.gathers "," r.boss "," r.end "|" it
    }
    return out
}
MnRunsParse(text) {
    runs := []
    for one in StrSplit(text, "^") {
        if Trim(one) = ""
            continue
        parts := StrSplit(one, "|", , 2)
        h := StrSplit(parts[1], ",")
        if h.Length < 5 || !IsInteger(h[1]) || !IsInteger(h[3]) || !IsInteger(h[4])
            continue
        r := {n: Integer(h[1]), start: h[2], gathers: Integer(h[3]), boss: Integer(h[4]), end: h[5], items: Map()}
        if parts.Length >= 2 && parts[2] != "" {
            for item in StrSplit(parts[2], ";") {
                f := StrSplit(item, "~")
                if f.Length >= 3 && IsInteger(f[3])
                    r.items[f[1]] := {name: f[2], count: Integer(f[3])}
            }
        }
        runs.Push(r)
    }
    return runs
}
MnRunsSave(name) {
    global INI, MN_STATS
    if MN_STATS.Has(name)
        try IniWrite MnRunsSerialize(MN_STATS[name].runs), INI, "MiningRuns", name
}
; 進礦場：開新的一輪（n = 今天第幾趟）
MnRunBegin(name, n) {
    global MN_RUNS_KEEP
    s := MnStatsOf(name)
    if s.runs.Length && s.runs[s.runs.Length].end = "" && s.runs[s.runs.Length].n = n
        return s.runs[s.runs.Length]
    MnRunEnd(name)
    r := {n: n, start: A_Now, gathers: 0, boss: 0, end: "", items: Map()}
    s.runs.Push(r)
    while s.runs.Length > MN_RUNS_KEEP
        s.runs.RemoveAt(1)
    MnRunsSave(name)
    return r
}
; 離開礦場：結束目前這一輪
MnRunEnd(name) {
    s := MnStatsOf(name)
    if s.runs.Length && s.runs[s.runs.Length].end = "" {
        s.runs[s.runs.Length].end := A_Now
        MnRunsSave(name)
    }
}
; 目前這一輪（沒有進行中的就用角色現在的趟數補開一輪：重開管理程式後接續的情況）
MnRunCurrent(name) {
    global profiles
    s := MnStatsOf(name)
    if s.runs.Length && s.runs[s.runs.Length].end = ""
        return s.runs[s.runs.Length]
    n := 0
    for p in profiles
        if p.name = name && p.HasOwnProp("mn")
            n := p.mn.visits
    return MnRunBegin(name, n)
}
MnRunAdd(name, deltas, gather, boss := 0) {
    r := MnRunCurrent(name)
    if gather
        r.gathers += 1
    r.boss += boss
    for k, d in deltas {
        if !r.items.Has(k)
            r.items[k] := {name: d.name, count: 0}
        r.items[k].count += d.count
        if d.name != ""
            r.items[k].name := d.name
    }
    MnRunsSave(name)
}
MnStatsSave(name) {
    global INI, MN_STATS
    if MN_STATS.Has(name)
        try IniWrite MnStatsSerialize(MN_STATS[name]), INI, "MiningStats", name
}
; 一顆礦採完：deltas = Map(道具代碼 → {name, count})
MnStatsAdd(name, deltas) {
    s := MnStatsOf(name)
    s.gathers += 1, s.dayGathers += 1
    for k, d in deltas {
        if !s.items.Has(k)
            s.items[k] := {name: d.name, total: 0, day: 0}
        it := s.items[k]
        it.total += d.count, it.day += d.count
        if d.name != ""
            it.name := d.name
    }
    MnStatsSave(name)
    MnRunAdd(name, deltas, true)
}
MnStatsAddItems(name, deltas) {
    s := MnStatsOf(name)
    for k, d in deltas {
        if !s.items.Has(k)
            s.items[k] := {name: d.name, total: 0, day: 0}
        it := s.items[k]
        it.total += d.count, it.day += d.count
        if d.name != ""
            it.name := d.name
    }
    MnStatsSave(name)
    MnRunAdd(name, deltas, false)   ; 王的掉落：道具算在這一輪
}
AutoMiningReset() {
    global INI, MN_STATS
    MN_STATS := Map()
    try IniDelete INI, "MiningStats"
    try IniDelete INI, "MiningRuns"
    AddRecentEvent("⛏ 自動採礦：統計已清除")
}
; 背包現在的道具 Map(代碼 → 數量)（讀不到回傳 0）
MnInvSnap(pid) {
    inv := 0
    try inv := ReadGameInventory(pid)
    if !IsObject(inv)
        return 0
    out := Map()
    for k, c in inv
        out[k] := c
    return out
}
; 採集開始前後的背包差：Map(代碼 → {name, count})，只算增加的
MnLootDiff(before, after, pid) {
    out := Map()
    if !IsObject(before) || !IsObject(after)
        return out
    for k, c in after {
        d := c - before.Get(k, 0)
        if d > 0 {
            nm := ""
            try nm := GameItemName(k, pid)
            out[k] := {name: nm != "" ? nm : k, count: d}
        }
    }
    return out
}
; 採完 3 秒後（道具到背包要一下子）結算這一顆的收穫
; force：下一顆開始採集前，上一顆還沒結算的收穫要先算進去（否則新的背包快照會把它蓋掉、這顆的收穫就漏了）
MnLootSettle(p, st, force := false) {
    if !IsObject(st.lootBase) {   ; 沒有「採集前」的背包快照可比（例如管理程式在採集中途重啟）：把結算時間也清掉，否則下一顆開始採集一拍快照後會被這個舊的時間提前結算，每顆都誤判「沒有收穫」
        st.lootAt := 0
        return
    }
    if !force && (!st.lootAt || A_TickCount < st.lootAt)
        return
    base := st.lootBase, now := MnInvSnap(p.pid)
    ; 道具進背包比採完晚約 10～15 秒（11/13 走路改快後，下一顆開始採集時上一顆的水晶還沒到，被誤判「沒有收穫」）：
    ; 採完不到 MN_LOOT_WAIT_MS 還沒看到增加就先不結算。下一顆開始採集時（force）人物正在採集、等一下不耗時間，直接輪詢到出現或逾時；
    ; 一般排程（非 force）就把結算往後排 1.5 秒再看。
    doneAt := st.HasOwnProp("lootDone") ? st.lootDone : 0
    if IsObject(now) && doneAt && MN_LOOT_WAIT_MS > 0 && MnLootDiff(base, now, p.pid).Count = 0 && A_TickCount - doneAt < MN_LOOT_WAIT_MS {
        if !force {
            st.lootAt := A_TickCount + 1500
            return
        }
        while A_TickCount - doneAt < MN_LOOT_WAIT_MS {
            Sleep 500
            ApGuardAny()
            now2 := MnInvSnap(p.pid)
            if IsObject(now2) {
                now := now2
                if MnLootDiff(base, now, p.pid).Count > 0
                    break
            }
        }
    }
    st.lootBase := 0, st.lootAt := 0
    if !IsObject(now) {   ; 結算時背包讀不到：不是「沒有收穫」，不算進沒收穫的警告
        EventLog(p.name, "MN_LOOT", "這顆取得：（結算時讀不到背包，無法統計）｜開始前背包 " base.Count " 種")
        return
    }
    deltas := MnLootDiff(base, now, p.pid)
    MnStatsAdd(p.name, deltas)
    MnNoLootNote(p, st, deltas.Count > 0)
    txt := ""
    for k, d in deltas
        txt .= (txt = "" ? "" : "、") d.name " ×" d.count
    diag := ""
    if txt = "" {   ; 背包沒有增加：附上兩次讀到的內容，之後才查得出是真的沒增加還是讀錯
        n0 := 0, n1 := 0
        for k, c in base
            n0 += c
        for k, c in now
            n1 += c
        diag := "｜背包 " base.Count " 種 " n0 " 個 → " now.Count " 種 " n1 " 個"
    }
    EventLog(p.name, "MN_LOOT", "這顆取得：" (txt = "" ? "（背包沒有增加）" : txt) diag)
}
; ---------------------------------------------------------------- 略過不好走的礦（提升效率）
; 礦石重生後編號會變、位置不變：用「位置」記哪些礦不好走（走不到、一直卡、走太久、右鍵採不起來）。
; 一個位置失敗 2 次、或走得很慢 3 次，就算「不好走」，挑礦時先挑別顆（沒有別顆才回頭挑，不會因此閒著）；
; 之後走得順 / 採起來就把失敗次數減回去；記錄存在 INI [MiningHard]，24 小時沒再遇到就忘掉。
global MN_SKIPHARD := MnIniGet("SkipHard", "1") = "0" ? 0 : 1
global MN_HARD := Map()
global MN_HARD_FAILS := 2, MN_HARD_SLOW := 3, MN_SLOW_MS := 35000, MN_WALK_MAX_MS := 45000, MN_HARD_KEEP_SEC := 86400
MnPosKey(o) => (Round(o.x / 4) * 4) "_" (Round(o.z / 4) * 4)
MnNowUnix() => DateDiff(A_NowUTC, "19700101000000", "Seconds")
MnHardLoad() {
    global INI, MN_HARD, MN_HARD_KEEP_SEC
    MN_HARD := Map()
    raw := ""
    try raw := IniRead(INI, "MiningHard")
    now := MnNowUnix()
    for line in StrSplit(raw, "`n", "`r") {
        eq := InStr(line, "=")
        if eq < 2
            continue
        f := StrSplit(SubStr(line, eq + 1), ",")
        if f.Length >= 3 && IsInteger(f[1]) && IsInteger(f[2]) && IsInteger(f[3]) && now - Integer(f[3]) < MN_HARD_KEEP_SEC
            MN_HARD[SubStr(line, 1, eq - 1)] := {fails: Integer(f[1]), slow: Integer(f[2]), at: Integer(f[3])}
    }
}
MnHardSave(key) {
    global INI, MN_HARD
    if !MN_HARD.Has(key)
        return
    r := MN_HARD[key]
    if r.fails <= 0 && r.slow <= 0 {
        try IniDelete INI, "MiningHard", key
    } else {
        try IniWrite r.fails "," r.slow "," r.at, INI, "MiningHard", key
    }
}
; 這顆礦是不是「不好走」（沒開「自動略過」一律回 false）
MnIsHard(o) {
    global MN_SKIPHARD, MN_HARD, MN_HARD_FAILS, MN_HARD_SLOW, MN_HARD_KEEP_SEC
    if !MN_SKIPHARD
        return false
    r := MN_HARD.Get(MnPosKey(o), 0)
    return IsObject(r) && MnNowUnix() - r.at < MN_HARD_KEEP_SEC && (r.fails >= MN_HARD_FAILS || r.slow >= MN_HARD_SLOW)
}
; 記一次：kind = "fail"（走不到 / 採不起來）、"slow"（走了很久）、"ok"（走得順、採起來了）
MnHardNote(o, kind) {
    global MN_HARD
    key := MnPosKey(o)
    if !MN_HARD.Has(key)
        MN_HARD[key] := {fails: 0, slow: 0, at: MnNowUnix()}
    r := MN_HARD[key]
    r.at := MnNowUnix()
    if kind = "fail"
        r.fails += 1
    else if kind = "slow"
        r.slow += 1
    else {
        r.fails := Max(0, r.fails - 1), r.slow := Max(0, r.slow - 1)
    }
    MnHardSave(key)
}
MnHardCount() {
    global MN_HARD
    n := 0
    for k, r in MN_HARD
        if r.fails >= 2 || r.slow >= 3
            n += 1
    return n
}
AutoMiningHardReset() {
    global INI, MN_HARD
    MN_HARD := Map()
    try IniDelete INI, "MiningHard"
    AddRecentEvent("⛏ 自動採礦：「不好走」的位置紀錄已清除")
}
global MN_CHARS := MnParseChars(MnIniGet("Chars", ""))
MnStatsLoad()
MnHardLoad()
MN_RESUME := MnIniGet("ResumeOnStart", "0") = "1" ? 1 : 0
if MN_RESUME && MnIniGet("Running", "0") = "1" && MN_CHARS.Count {   ; 上次是啟動狀態，重開後接續（趟數也接續）
    MN_RUNNING := 1, MN_RESUMED := true
}
; 趟數存檔（接續用）：[MiningRun] 角色名 = 已經進過幾趟
MnRunVisitsLoad(name) {
    global INI
    v := 0
    try v := IniRead(INI, "MiningRun", name, "0")
    return IsInteger(v) ? Integer(v) : 0
}
MnRunVisitsSave(name, n) {
    global INI
    try IniWrite n, INI, "MiningRun", name
}
global MN_AUTOENTER := MnIniGet("AutoEnter", "1") = "0" ? 0 : 1
global MN_BOSS_ON := MnIniGet("Boss", "0") = "1" ? 1 : 0   ; 王重生時中斷採礦去打王（預設關：這個功能還沒在真正的王身上驗證過）
global MN_LOOPS := Min(99, Max(0, Integer(MnIniGet("Loops", "0"))))   ; 要進礦場幾趟（0 = 一直循環）；每次進去算一趟，跑滿後被踢出就不再進圖
global MN_KEEP_INV := MnIniGet("KeepInv", "1") = "0" ? 0 : 1   ; 背包一直開著（省每顆礦開關一次）；走路時地面點擊會閃開背包區域

; ---------------------------------------------------------------- 純邏輯（不碰遊戲）
; 礦石顏色的優先序：1 = 最優先；沒勾選 / 不認得的顏色回傳 99（不挖）。
MnColorRank(name) {
    global MN_COLORS
    if name = ""
        return 99
    c := SubStr(name, 1, 1)
    for i, k in MN_COLORS
        if k = c
            return i
    return 99
}
; 地圖編號字串（"213-0"）是不是水晶礦場
MnIsMineMap(mapId) {
    global MN_MAP_MAIN
    if mapId = ""
        return false
    n := StrSplit(mapId, "-")[1]
    return IsInteger(n) && Integer(n) = MN_MAP_MAIN
}
; 從清單挑下一顆：顏色優先，同顏色挑最近；略過被標記的（skip：glob → 到期的 A_TickCount）和已經沒血的。沒有回傳 0。
MnPickOre(ores, me, skip, now, isHard := 0, near := 0) {
    global MN_RANK_SEC, MN_WALK_SPEED
    best := 0
    for o in ores {
        if o.hp = 0
            continue
        if skip.Has(o.glob) && skip[o.glob] > now
            continue
        r := MnColorRank(o.name)
        if r = 99   ; 沒勾選的顏色不挖
            continue
        d2 := (o.x - me.x) ** 2 + (o.z - me.z) ** 2
        d := Sqrt(d2)
        ; 成本（秒）= 走過去的時間 + 顏色順序差一名要付的代價（預設 4 秒）：旁邊有選定顏色的礦就挑旁邊的，不會為了顏色多跑幾百單位；
        ; 「嚴格依顏色」把代價設成很大，就變回顏色優先。
        cost := d / MN_WALK_SPEED + (r - 1) * MN_RANK_SEC
        if IsObject(isHard) && isHard(o)
            cost += 100000        ; 不好走：沒有別顆才挑
        else if near > 0 && d <= near
            cost -= 50000         ; 已經在採得到的距離內：不用走，優先（這些之間仍照成本比）
        if !best || cost < best.cost || (cost = best.cost && d2 < best.d2)
            best := {o: o, cost: cost, d2: d2}
    }
    return best ? best.o : 0
}
; 道具名稱：傳送卡（可以右鍵傳送）/ 禮盒（要先打開才有傳送卡）
MnIsCard(name) => InStr(name, "水晶礦場傳送卡") && !InStr(name, "禮盒")
MnIsBox(name) => InStr(name, "水晶礦場傳送卡") && InStr(name, "禮盒")

; ---------------------------------------------------------------- 狀態
MnSt(p) {
    if !p.HasOwnProp("mn")
        p.mn := {next: 0, fails: 0, skip: Map(), text: "", gathering: false, gathers: 0, gatherStart: 0, entered: 0, invAnchor: 0, bossSkip: 0, progressAt: A_TickCount, stallAlerted: false, noLootN: 0, noLootAlerted: false, firstTrack: true, respawnSince: 0, bossKills: 0, stand: MN_STAND_DIST, lootBase: 0, lootAt: 0, notSince: 0, useMax: MN_USE_MAX, okMax: 0, fastOff: false, fastFails: 0, inMine: false, inSince: 0, visits: MN_RESUMED ? MnRunVisitsLoad(p.name) : 0, lastStay: 0, enterAlert: false, boxWarned: false, loopDone: false}
    return p.mn
}
MnSelectedAlive() {
    global profiles, MN_CHARS
    out := []
    for p in profiles {
        if !MN_CHARS.Has(p.name)
            continue
        alive := false
        try alive := ProfileGameAlive(p)
        if alive && p.pid
            out.Push(p)
    }
    return out
}

; ---------------------------------------------------------------- 排程
; 這台電腦的授權有沒有「自動採礦」功能（授權檔 features=mining，有簽章）。沒有 License 模組（測試環境）視為有。
MnFeatureOK() {
    ok := true, fnm := "Lic_HasFeature"
    try {
        f := %fnm%
        ok := f("mining")
    }
    return ok
}
global mnLicNoted := false
MnTick() {
    global MN_RUNNING, MN_CHARS, apBusy, cwBusy, MN_START_IDLE_MS, profiles, mnLicNoted
    if !MnFeatureOK() {
        for p in profiles
            p.mnActive := false
        if MN_RUNNING && !mnLicNoted {
            mnLicNoted := true
            EventLog("GLOBAL", "MN_NO_LICENSE", "這台電腦的授權沒有「自動採礦」功能，自動採礦不會啟動（請向作者取得含自動採礦的授權檔）")
            AddRecentEvent("🔒 這台電腦的授權沒有「自動採礦」功能")
        }
        return
    }
    ; 採礦中的角色標記：血量靜止判斷、變慢自動過圖看這個旗標
    for p in profiles
        p.mnActive := MN_RUNNING && MN_CHARS.Has(p.name) ? true : false
    if !MN_RUNNING
        return
    if apBusy || cwBusy
        return
    why := ApBlockerRaw()
    if why != "" {
        for p in MnSelectedAlive()
            MnSt(p).text := "等待中：" why
        return
    }
    todo := 0
    for p in MnSelectedAlive() {
        st := MnSt(p)
        if !ApReady(p) {
            st.text := (p.HasOwnProp("hpEventOpen") && p.hpEventOpen) ? "💀 死亡中，等復活" : "還沒進遊戲世界"
            continue
        }
        MnWatchdog(p, st)
        if A_TickCount < st.next
            continue
        d := MnPlan(p)
        if d.action = "wait" {
            st.text := d.text, st.next := A_TickCount + d.wait
            continue
        }
        if !todo
            todo := {p: p, d: d}
    }
    if todo {
        busy := ApBlocker(MN_START_IDLE_MS)
        if busy != "" {
            MnSt(todo.p).text := "等待中：" busy
            return
        }
        MnRun(todo.p, todo.d)
    }
}

; 進出水晶礦場的紀錄：道具讓角色在礦場待約 2 小時，時間到會被踢出去（有時會延遲），這裡以「實際被踢出（地圖變了）」為準：
; 被踢出後 MnPlan 看到不在礦場就走進圖流程，進去後繼續挖，一直循環。mapId 讀不到（換圖載入中）時不判斷。
MnTrackVisit(p, st, mapId) {
    if mapId = ""
        return
    inMine := MnIsMineMap(mapId)
    first := st.firstTrack, st.firstTrack := false
    if inMine && !st.inMine {
        st.inMine := true, st.inSince := A_TickCount, st.progressAt := A_TickCount
        if first && MN_RESUMED && st.visits > 0 {   ; 重開管理程式（遊戲沒關）接續：角色本來就在礦場裡，這一趟已經算過了
            EventLog(p.name, "MN_IN", "接續：角色還在水晶礦場裡（第 " st.visits " 趟）")
        } else {
            st.visits += 1
            MnRunVisitsSave(p.name, st.visits)
            MnRunBegin(p.name, st.visits)
            EventLog(p.name, "MN_IN", "進入水晶礦場（今天第 " st.visits " 趟）")
        }
    } else if !inMine && st.inMine {
        st.progressAt := A_TickCount
        st.inMine := false, st.lastStay := Round((A_TickCount - st.inSince) / 60000, 1), st.gathering := false
        st.next := 0
        MnRunEnd(p.name)
        EventLog(p.name, "MN_KICKED", "離開水晶礦場（到 " mapId "）｜這趟待了 " st.lastStay " 分鐘｜自動重新進圖")
        AddRecentEvent("⛏ " p.name " 離開水晶礦場（待了 " st.lastStay " 分鐘），自動重新進圖")
    }
}
; 這個角色背包 + 銀行裡還有幾個水晶礦場傳送卡禮盒（銀行沒載入過 = 讀不到，算 0）
MnCountBoxes(pid) {
    n := 0
    for key in ["InvenOffset", "BankOffset"] {
        try {
            for s in DailyInventory(pid, key)
                if MnIsBox(GameItemName(s.key, pid))
                    n += s.count
        }
    }
    return n
}

; 這個角色是不是在排隊等更換每日道具（DailyRunEnqueue 排進 dailyRunQueue，輪到時 DailyRunNext 會等採集中的這一顆採完）
MnDailyQueued(p) {
    global dailyRunQueue, profiles
    for q in dailyRunQueue
        if profiles[q] = p
            return true
    return false
}

; 採集假在線：採集動作正常約 60 秒結束；伺服器不回應（假在線）時角色會一直停在「採集中」。
; 只累計「採礦計時器連續在跑」的時間（遠端暫停 / 等待期間不算），避免暫停回來就誤判；同一顆礦累計超過 MN_HANG_MS 就當作假在線處理。
MnHangCheck(p, st) {
    global MN_HANG_MS, profiles
    now := A_TickCount
    dt := st.HasOwnProp("hangLast") && st.hangLast ? now - st.hangLast : 0
    st.hangLast := now
    if !st.gathering || !st.gatherStart {
        st.hangAcc := 0, st.hangFired := false, st.hangKey := 0
        return
    }
    if !st.HasOwnProp("hangKey") || st.hangKey != st.gatherStart
        st.hangKey := st.gatherStart, st.hangAcc := 0, st.hangFired := false
    if dt > 0 && dt < 15000
        st.hangAcc += dt
    if st.hangAcc < MN_HANG_MS || st.hangFired
        return
    st.hangFired := true
    mins := Round(st.hangAcc / 60000, 1)
    EventLog(p.name, "MN_HANG", "採集動作 " mins " 分鐘還沒結束（正常約 60 秒）｜判定假在線")
    idx := 0
    for i, q in profiles
        if q = p
            idx := i
    fn := "SoftDisconnectConfirmed"
    if idx
        try %fn%(idx, p, "自動採礦：採集動作 " mins " 分鐘還沒結束（正常約 60 秒），伺服器沒有回應")
}

; 卡住偵測：進展 = 開始採集、進出礦場、進圖成功、打完王。15 分鐘都沒有進展就記日誌並通知 Discord（只通知一次，有進展再重新算）；
; 正常的等待（礦都採完等重生最久 40 分鐘、已跑完趟數、沒開自動進圖、沒勾顏色）不算卡住。
MnWatchdog(p, st) {
    global MN_STALL_MS
    MnHangCheck(p, st)
    if st.progressAt && A_TickCount - st.progressAt > MN_STALL_MS {
        if !st.stallAlerted {
            st.stallAlerted := true
            mins := Round((A_TickCount - st.progressAt) / 60000)
            EventLog(p.name, "MN_STALL", "超過 " mins " 分鐘沒有進展｜狀態：" st.text)
            AddRecentEvent("⚠ " p.name " 自動採礦疑似卡住 " mins " 分鐘：" st.text)
            try SendDiscordMessage("⚠️ HIHIYONG 自動採礦疑似卡住`n角色：" p.name "`n已經 " mins " 分鐘沒有進展。`n目前狀態：" st.text)
        }
    } else
        st.stallAlerted := false
}
; 連續幾顆都沒有收穫：疑似假在線 / 斷線 / 背包滿了（採集看起來在跑，其實沒有收穫）
MnNoLootNote(p, st, got) {
    if got {
        st.noLootN := 0, st.noLootAlerted := false
        return
    }
    st.noLootN += 1
    if st.noLootN >= 5 && !st.noLootAlerted {
        st.noLootAlerted := true
        EventLog(p.name, "MN_NOLOOT", "連續 " st.noLootN " 顆採集都沒有收穫（背包滿了？假在線？）")
        AddRecentEvent("⚠ " p.name " 連續 " st.noLootN " 顆採集都沒有收穫")
        try SendDiscordMessage("⚠️ HIHIYONG 自動採礦連續 " st.noLootN " 顆沒有收穫`n角色：" p.name "`n可能是背包滿了，或遊戲假在線 / 斷線但畫面還在跑，請確認。")
    }
}

; 現在該做什麼：{action: "wait", text, wait} / {action: "enter"} / {action: "mine", ore}
MnPlan(p) {
    global MN_AUTOENTER, MN_ORE_NAME, MN_RESPAWN_CHECK_MS, GLAT_GATHERING, MN_COLORS, MN_BOSS_ON, MN_LOOPS, INI
    st := MnSt(p), pid := p.pid
    MnLootSettle(p, st)
    mapId := ""
    try mapId := ReadGameMapId(pid)
    MnTrackVisit(p, st, mapId)
    if !MnIsMineMap(mapId) && MnLoopsDone(st) {
        st.gathering := false
        MnLoopsNotify(p, st)
        st.progressAt := A_TickCount
        return {action: "wait", text: "已跑完 " st.visits " 趟（設定 " MN_LOOPS " 趟），不再進圖", wait: 30000}
    }
    if !MnIsMineMap(mapId) {
        st.gathering := false
        if !MN_AUTOENTER {
            st.progressAt := A_TickCount
            return {action: "wait", text: "不在水晶礦場（沒有開「自動進圖」）", wait: 10000}
        }
        ; 設定檔 [AutoMining] PauseEnter=1：不再進礦場（入場券不夠 / 想先停手時用；不用關程式，改回 0 就繼續）。角色在礦場裡的採集不受影響，只擋「進圖」
        pe := 0
        try pe := IniRead(INI, "AutoMining", "PauseEnter", "0")
        if pe = "1" {
            st.progressAt := A_TickCount
            return {action: "wait", text: "已暫停進礦場（設定檔 [AutoMining] PauseEnter=1）", wait: 15000}
        }
        return {action: "enter"}
    }
    me := MiningCharState(pid)
    if !IsObject(me)
        return {action: "wait", text: "讀不到人物位置", wait: 3000}
    if me.action = GLAT_GATHERING {
        st.notSince := 0
        if !st.gathering
            st.gathering := true, st.gatherStart := st.gatherStart ? st.gatherStart : A_TickCount
        left := Max(0, 60 - Round((A_TickCount - st.gatherStart) / 1000))
        return {action: "wait", text: "採集中（約剩 " left " 秒）", wait: 2000}
    }
    if st.gathering {   ; 剛採完？採集要 60 秒；不到 50 秒動作就不是採集，可能只是一瞬間（視窗焦點被搶、讀取雜訊）：隔 1.2 秒以上再確認一次才算結束
        if A_TickCount - st.gatherStart < 50000 {
            if !st.notSince {
                st.notSince := A_TickCount
                return {action: "wait", text: "確認採集是否結束…", wait: 1300}
            }
            if A_TickCount - st.notSince < 1200
                return {action: "wait", text: "確認採集是否結束…", wait: 400}
            EventLog(p.name, "MN_GATHER_EARLY", "採集只持續 " Round((A_TickCount - st.gatherStart) / 1000) " 秒就結束了（被打斷？）")
        }
        st.notSince := 0
        st.gathering := false, st.gathers += 1, st.gatherStart := 0, st.lootAt := A_TickCount + 3000, st.lootDone := A_TickCount
        EventLog(p.name, "MN_GATHER_DONE", "採集完成｜今天第 " st.gathers " 顆")
    }
    if MnBossTimerDue(p, st, false)   ; 按了「現在讀王重生時間」：不在採集中的空檔去讀
        return {action: "bosstimer"}
    ; 功能優先順序：排在「自動採礦」前面的功能忙著（預設：每日更換道具排隊中 / 進行中）→ 採完這一顆就讓出（不開始下一顆、不去打王），
    ; 等它做完（每日道具原地換，不離開礦場）再繼續
    fpWhy := FpBlocked("mining", p)
    if fpWhy != ""
        return {action: "wait", text: "等待：" fpWhy, wait: 2000}
    if MN_BOSS_ON {   ; 王活著（在怪物清單裡）就先去打；採集中的那一顆已經在上面先等它採完
        boss := MnFindBoss(pid)
        if IsObject(boss) && A_TickCount >= st.bossSkip
            return {action: "boss", boss: boss}
    }
    if !MN_COLORS.Length {
        st.progressAt := A_TickCount
        return {action: "wait", text: "沒有勾選要挖的礦石顏色", wait: 10000}
    }
    crows := 0
    try crows := MiningCrows(pid, MN_ORE_NAME)
    if !IsObject(crows)
        return {action: "wait", text: "讀不到礦石清單", wait: 3000}
    ore := MnPickOre(crows, me, st.skip, A_TickCount, MnIsHard, st.useMax - 2)
    if !ore {   ; 礦都採完了等重生（遊戲 30 分鐘一次）：最久算 40 分鐘的正常等待，超過才當成卡住
        if MnBossTimerDue(p, st, true)   ; 空檔順便讀王的重生時間（BossTimerAuto=1 才會自動）
            return {action: "bosstimer"}
        if !st.respawnSince
            st.respawnSince := A_TickCount
        if A_TickCount - st.respawnSince < 2400000
            st.progressAt := A_TickCount
        return {action: "wait", text: "這一輪的礦都採完了，等重生（遊戲每 30 分鐘重生一次）｜清單 " crows.Length " 顆", wait: MN_RESPAWN_CHECK_MS}
    }
    st.respawnSince := 0
    return {action: "mine", ore: ore}
}

; ---------------------------------------------------------------- 執行一個回合（持有前景鎖）
MnRun(p, d) {
    global mnBusy, apBusy, foregroundOwner, apRunStart, apLastOwn, MN_KEEP_INV, DH_UI_BLOCK
    st := MnSt(p)
    prev := 0, cursor := 0, minimized := [], stopped := false, failed := false
    DH_UI_BLOCK := MN_KEEP_INV ? MnUiBlock(st) : 0
    mnBusy := true, apBusy := true, foregroundOwner := "mining", apRunStart := A_TickCount, apLastOwn := A_TickCount
    try {
        prev := ApForeground(), cursor := ApCursor()
        if ApIsMinimized(p)
            minimized.Push(p)
        if !ApActivate(p) {
            st.next := A_TickCount + 30000, st.text := "切不到遊戲視窗，稍後再試"
            return
        }
        if d.action = "enter" {
            st.text := "進水晶礦場"
            MnEnter(p)
        } else if d.action = "bosstimer" {
            MnBossTimer(p)
        } else if d.action = "boss" {
            MnFightBoss(p, d.boss)
        } else {
            MnMine(p, d.ore)
        }
        st.fails := 0
        if d.action = "enter"
            st.enterAlert := false
    } catch as e {
        failed := true
        if e.Extra = "stop" {
            stopped := true
            st.next := A_TickCount + 20000
            st.text := "⏸ " e.Message "（稍後再試）"
            EventLog(p.name, "MN_STOP", e.Message "｜距離上次實體鍵鼠輸入 " A_TimeIdlePhysical " 毫秒")
        } else {
            st.fails += 1
            wait := Min(600000, 30000 * (2 ** Min(st.fails - 1, 4)))
            st.next := A_TickCount + wait
            st.text := "⚠ " e.Message "｜" Round(wait / 60000, 1) " 分鐘後再試（連續第 " st.fails " 次）"
            EventLog(p.name, "MN_ERROR", d.action "｜" e.Message)
            if st.fails = 3
                AddRecentEvent("⛏ " p.name " 採礦連續失敗：" e.Message)
            if d.action = "enter" && st.fails >= 3 && !st.enterAlert {   ; 進圖一直失敗（禮盒用完、銀行沒載入、被別的視窗擋住…）：通知一次，之後照退避繼續試
                st.enterAlert := true
                try SendDiscordMessage("⚠️ HIHIYONG 自動進水晶礦場失敗`n角色：" p.name "`n連續 " st.fails " 次：" e.Message "`n程式會繼續重試（間隔最多 10 分鐘）。若是禮盒用完了，請補貨。")
            }
        }
    } finally {
        DH_UI_BLOCK := 0
        if !MN_KEEP_INV || failed || d.action = "enter"   ; 背包一直開著時，成功的一回合不關；出錯或進圖後關掉，避免留著擋東西
            try MnCloseWindows(p)
        ApCleanup(p, false, minimized, prev, cursor, stopped)
        foregroundOwner := "", apBusy := false, apRunStart := 0, mnBusy := false
    }
}

; 走到礦石旁 → 右鍵十字鎬 → 確認進入採集。走不到 / 採不起來：這顆先略過 10 分鐘，換下一顆。
MnMine(p, ore) {
    global MN_SKIP_MS, MN_GATHER_CONFIRM_MS, GLAT_GATHERING, MN_WALK_MAX_MS, MN_SLOW_MS
    st := MnSt(p), pid := p.pid
    t0 := A_TickCount, deadline := t0 + MN_WALK_MAX_MS
    um := st.useMax
    ; 自動打怪（F6）開著，人物會去打礦石（礦石是怪、打了沒有傷害），而且打著的時候用不了十字鎬：先關掉
    DhEnsureAutoHuntOff(p)
    me := MiningCharState(pid)
    if !IsObject(me)
        throw Error("讀不到人物位置")
    dist := Sqrt((ore.x - me.x) ** 2 + (ore.z - me.z) ** 2)
    st.text := "走向 " ore.name "（距離 " Round(dist) "）"
    EventLog(p.name, "MN_GOTO", ore.name "#" ore.glob "｜(" Round(ore.x) "," Round(ore.z) ")｜人物 (" Round(me.x) "," Round(me.z) ")｜距離 " Round(dist))
    ; 防呆（遊戲說「距離太遠」）：站位從 st.stand 開始、每次沒採起來就站更近（再縮到 3、1.5）；每次按十字鎬之前都重新量一次離礦石多遠，
    ; 超過 MN_USE_MAX 就先再靠近、不按；哪一次採起來了，就把那個站位記起來（之後的礦直接站那麼近）；走不到就繞到礦石另一側。
    stands := st.stand <= 3 ? [st.stand, 1.5] : [st.stand, 3, 1.5]
    for k, sd in stands {
        if k > 1 || dist > um {
            try {
                MnWalkAround(p, ore, sd, deadline, um)
            } catch as e {
                if e.Extra = "stop"
                    throw e
                MnHardNote(ore, "fail")
                st.skip[ore.glob] := A_TickCount + MN_SKIP_MS
                ; 走不到這顆：看看角色現在周圍有沒有別顆採得到的（離得近就不必精準、直接採）
                alt := MnNearbyOre(p, ore, um - 1)
                if IsObject(alt) {
                    EventLog(p.name, "MN_ALT", ore.name "#" ore.glob " 走不到（" e.Message "），改採旁邊的 " alt.name "#" alt.glob "（離 " Round(Sqrt((alt.x - MiningCharState(pid).x) ** 2 + (alt.z - MiningCharState(pid).z) ** 2), 1) " 單位）")
                    return MnMine(p, alt)
                }
                EventLog(p.name, "MN_SKIP", ore.name "#" ore.glob " 走不過去：" e.Message "｜略過 10 分鐘")
                st.text := "走不過去，換下一顆：" e.Message
                return
            }
        }
        cur := MiningCharState(pid)
        if !IsObject(cur)
            throw Error("讀不到人物位置")
        d := Sqrt((ore.x - cur.x) ** 2 + (ore.z - cur.z) ** 2)
        if d > um {
            EventLog(p.name, "MN_FAR", "走完離礦石還有 " Round(d, 1) "（上限 " Round(um, 1) "），先再靠近一次、不按十字鎬")
            try {
                MnWalkAround(p, ore, sd, 0, um)
            } catch as e {
                if e.Extra = "stop"
                    throw e
            }
            cur := MiningCharState(pid)
            d := IsObject(cur) ? Sqrt((ore.x - cur.x) ** 2 + (ore.z - cur.z) ** 2) : 9999
            if d > um
                continue
        }
        if IsObject(cur) && (cur.action = 2 || cur.action = 3)   ; 攻擊 / 技能：人物在普攻礦石，這時用不了十字鎬
            MnBreakAttack(p, ore)
        ; 十字鎬「再次使用可停止」：重試之前先確認沒有已經在採集（採集晚幾秒才開始的話，再右鍵一次反而會把它停掉）
        if k > 1 {
            cur := MiningCharState(pid)
            if IsObject(cur) && cur.action = GLAT_GATHERING {
                MnLootSettle(p, st, true)
                st.gathering := true, st.gatherStart := A_TickCount, st.lootBase := MnInvSnap(pid), st.lootAt := 0, st.progressAt := A_TickCount
                st.text := "採集中（約 60 秒）"
                MnHardNote(ore, A_TickCount - t0 > MN_SLOW_MS ? "slow" : "ok")
                EventLog(p.name, "MN_GATHER_START", ore.name "#" ore.glob "｜晚幾秒才開始，不重複右鍵")
                return
            }
        }
        EventLog(p.name, "MN_USE", "第 " k " 次右鍵十字鎬｜離礦石 " Round(d, 1) "｜站位 " Round(sd, 1))
        tUse := A_TickCount
        how := MnUsePickaxe(p)
        EventLog(p.name, "MN_USE_TIME", "右鍵十字鎬花了 " Round((A_TickCount - tUse) / 1000, 1) " 秒（" (how = "fast" ? "快速" : "一般") "路徑）")
        start := A_TickCount
        while A_TickCount - start < MN_GATHER_CONFIRM_MS {
            ApGuardAny()
            cur := MiningCharState(pid)
            if IsObject(cur) && cur.action = GLAT_GATHERING {
                MnLootSettle(p, st, true)
                st.gathering := true, st.gatherStart := A_TickCount, st.lootBase := MnInvSnap(pid), st.lootAt := 0, st.progressAt := A_TickCount
                st.text := "採集中（約 60 秒）"
                if d > st.okMax {   ; 採得起來的最遠距離（距離上限不會低於它）
                    st.okMax := d
                    if d > st.useMax
                        st.useMax := d, um := d
                }
                ; 只在「實際離礦石距離」真的接近這個站位時才學：大地圖點不動、停在離礦石 18 單位也採得起來時，不能把「規劃的站位 3」當成採得起來的距離
                ; （學壞了之後每顆都走去站位 3，更容易點不動、被略過）
                if sd < st.stand && d <= sd + 6 {
                    EventLog(p.name, "MN_STAND_LEARN", "站位 " Round(sd, 1) " 採得起來，之後的礦直接站這麼近（原本 " Round(st.stand, 1) "）")
                    st.stand := sd
                }
                walkMs := A_TickCount - t0
                if how = "fast"
                    st.fastFails := 0
                MnHardNote(ore, walkMs > MN_SLOW_MS ? "slow" : "ok")
                EventLog(p.name, "MN_GATHER_START", ore.name "#" ore.glob "｜離礦石 " Round(d, 1) "｜從出發到開始採集 " Round(walkMs / 1000) " 秒" (MnIsHard(ore) ? "｜（這個位置不好走）" : ""))
                return
            }
            Sleep 200
        }
        EventLog(p.name, "MN_RETRY", "右鍵十字鎬後沒有進入採集（離礦石 " Round(d, 1) "），站更近再試")
        if how = "fast" {   ; 快速路徑沒點對（視窗被移動 / 換了版面）：忘掉記住的位置，下次走一般路徑重新抓
            st.invAnchor := 0, st.fastFails += 1
            if st.fastFails >= 3
                st.fastOff := true
            EventLog(p.name, "MN_USE_FASTFAIL", "快速路徑沒進入採集，下次改走一般路徑（連續 " st.fastFails " 次" (st.fastOff ? "，不再用快速路徑" : "") "）")
        }
        if d > 12 && d > st.okMax {   ; 離得遠採不起來：把距離上限往下調（但不低於採起來過的距離）
            st.useMax := Max(10, st.okMax, d - 3), um := st.useMax
            EventLog(p.name, "MN_USEMAX_LEARN", "離 " Round(d, 1) " 單位採不起來，距離上限調成 " Round(um, 1))
        }
    }
    MnHardNote(ore, "fail")
    st.skip[ore.glob] := A_TickCount + MN_SKIP_MS
    EventLog(p.name, "MN_SKIP", ore.name "#" ore.glob " 靠近到 " Round(stands[stands.Length], 1) " 單位也採不起來｜略過 10 分鐘")
    st.text := "這顆採不起來，換下一顆"
}

; ---------------------------------------------------------------- 打王
; 王在怪物清單裡（名稱 = MN_BOSS_NAME）：活著就在、死了就消失。血量欄位讀到的不是 2 億，所以不拿它判斷。
MnFindBoss(pid) {
    global MN_BOSS_NAME
    cr := 0
    try cr := MiningCrows(pid, MN_BOSS_NAME)
    return IsObject(cr) && cr.Length ? cr[1] : 0
}
; 游標移到遊戲畫面（1024x768 座標）(x,y)；和 ApClick 一樣先確認視窗在前面、畫面大小對
MnAim(p, x, y) {
    global apLastOwn, AP_DESIGN_W, AP_DESIGN_H, mnTestInput
    if IsObject(mnTestInput)
        return mnTestInput.Aim(x, y)
    ApGuard(p)
    WinGetClientPos(&cx, &cy, &cw, &ch, "ahk_id " p.hwnd)
    dpi := A_ScreenDPI / 96
    if Abs(cw - AP_DESIGN_W * dpi) > 4 || Abs(ch - AP_DESIGN_H * dpi) > 4
        ApStop(p.name " 的遊戲畫面不是 1024x768（" cw "x" ch "），不能打王")
    if x < 0 || x >= AP_DESIGN_W || y < 0 || y >= AP_DESIGN_H
        return false
    DllCall("SetCursorPos", "Int", cx + Round(x * cw / AP_DESIGN_W), "Int", cy + Round(y * ch / AP_DESIGN_H))
    apLastOwn := A_TickCount
    return true
}
; 滑鼠右鍵按下 / 放開（按住打王用；放開一定要做到，所以呼叫端放在 finally）
MnRightButton(down) {
    global apLastOwn, mnTestInput
    if IsObject(mnTestInput)
        return mnTestInput.Right(down)
    DllCall("mouse_event", "UInt", down ? 0x0008 : 0x0010, "Int", 0, "Int", 0, "UInt", 0, "UPtr", 0)   ; RIGHTDOWN / RIGHTUP
    apLastOwn := A_TickCount
}

; 打王前確認技能：技能欄要在 F<MN_BOSS_BAR>（例如 F8；第二頁的 F18 也算），不對就按那個 F 鍵切過去、讀回確認；
; 設定了「右鍵技能代碼」就要完全一樣（固定技能）。確認不了就不開打（寧可不打，也不要用錯技能壓著右鍵）。
; 技能的顯示文字：「名稱（代碼）」
MnSkillText(pid, id) {
    nm := ""
    try nm := MiningSkillName(pid, id)
    return (nm != "" ? nm : "未知技能") "（" (id = "" ? "無" : id) "）"
}
; 這個角色打王要按哪個鍵、右鍵技能要變成哪個代碼：職業在 MN_BOSS_CLASS_SLOTS 裡（例如超能部）→ 技能欄第 N 個（從記憶體讀那一格現在放的技能）；
; 其他職業 → 設定的技能欄鍵 + 右鍵技能代碼。
MnBossSkillPlan(p) {
    global MN_BOSS_BAR, MN_BOSS_SKILL, MN_BOSS_CLASS_SLOTS, MN_BOSS_FIXED_CLASSES, MN_BOSS_CHAR_SLOTS
    cls := 0
    try cls := ReadGameCharClass(p.pid)
    charSlot := MN_BOSS_CHAR_SLOTS.Get(p.name, 0)   ; 這個角色自己指定了第幾格：最優先
    if charSlot > 0 || (cls != 0 && !MN_BOSS_FIXED_CLASSES.Has(cls)) {   ; 其餘（固定技能職業以外）：技能欄第 N 個（預設第 1 個）
        n := charSlot > 0 ? charSlot : MN_BOSS_CLASS_SLOTS.Get(cls, 1), code := ""
        for s in MiningSkillSlots(p.pid) {
            if s.bar = 1 && s.key = n {
                code := s.id
                break
            }
        }
        return {key: "F" n, code: code, byClass: true, cls: cls, slot: n}
    }
    return {key: MN_BOSS_BAR > 0 ? "F" MN_BOSS_BAR : "", code: MN_BOSS_SKILL, byClass: false, cls: cls, slot: MN_BOSS_BAR}
}
MnEnsureBossSkill(p) {
    global MN_BOSS_BAR
    pid := p.pid
    me := MiningCharState(pid)
    if !IsObject(me)
        throw Error("讀不到技能欄")
    plan := MnBossSkillPlan(p)
    if plan.byClass {
        EventLog(p.name, "MN_BOSS_CLASS", "職業 " plan.cls " 打王用技能欄第 " plan.slot " 個（按 " plan.key "）：" (plan.code = "" ? "（這一格沒有技能）" : MnSkillText(pid, plan.code)))
        if plan.code = ""
            throw Error("職業 " plan.cls " 要用技能欄第 " plan.slot " 個技能打王，但那一格是空的，不開打")
    }
    if plan.code != "" {
        ; 以「右鍵技能代碼」為準（最可靠：壓著右鍵放的就是它）。不對就按 F<技能欄> 選，讀回確認；
        ; 11/09 00:07 實際發生：技能欄顯示 F18（算 F8）通過了，但右鍵技能是 13-10 氣化符（輔助技能），壓著右鍵打不到王。
        if me.runSkill != plan.code {
            if plan.key = ""
                throw Error("右鍵技能是 " MnSkillText(pid, me.runSkill) "，要的是 " plan.code "，又沒有設定技能欄可以切，不開打")
            Loop 2 {
                EventLog(p.name, "MN_BOSS_SKILLBAR", "右鍵技能是 " MnSkillText(pid, me.runSkill) "，要的是 " plan.code "，按 " plan.key " 選技能（第 " A_Index " 次）")
                ApKey(p, plan.key)
                Sleep 600
                me := MiningCharState(pid)
                if IsObject(me) && me.runSkill = plan.code
                    break
            }
            if !IsObject(me) || me.runSkill != plan.code
                throw Error("右鍵技能是 " (IsObject(me) ? MnSkillText(pid, me.runSkill) : "?") "，要的是 " MnSkillText(pid, plan.code) "，按 " plan.key " 也切不過去（技能欄不在第 1 排？），不開打；請手動把右鍵技能選好" (plan.byClass ? "" : "，或到頁面改技能代碼"))
        }
    } else if MN_BOSS_BAR > 0 && Mod(me.skillBar, 10) + 1 != MN_BOSS_BAR {
        EventLog(p.name, "MN_BOSS_SKILLBAR", "技能欄是 F" (me.skillBar + 1) "，要求 F" MN_BOSS_BAR "，按 F" MN_BOSS_BAR " 切過去")
        ApKey(p, "F" MN_BOSS_BAR)
        Sleep 500
        me := MiningCharState(pid)
        if !IsObject(me) || Mod(me.skillBar, 10) + 1 != MN_BOSS_BAR
            throw Error("技能欄不是 F" MN_BOSS_BAR "（現在 F" (IsObject(me) ? me.skillBar + 1 : "?") "），不開打")
    }
    EventLog(p.name, "MN_BOSS_SKILL", "技能欄 F" (me.skillBar + 1) "｜右鍵技能 " MnSkillText(pid, me.runSkill))
}

; ---------------------------------------------------------------- 王的掉落（秘笈）靠寵物撿
; 王打死一定會掉秘笈，掉在地上由「寵物」撿進背包；寵物不在外面就撿不到。打王前先確認寵物在外面（不在就叫），王死後不馬上走開：
; 留在原地最多 MN_BOSS_LOOT_WAIT_MS 等背包多出秘笈，等不到就記 MN_BOSS_LOOT 並通知（附寵物在不在外面），之後才有線索查。
; ReadGamePetOut / DailyQuickInfo 用名稱呼叫（測試環境沒有這兩個函式時不會在載入時報錯）。
MnPetOut(pid) {
    v := -1, fnm := "ReadGamePetOut"
    try {
        f := %fnm%
        v := f(pid)
    }
    return IsInteger(v) ? Integer(v) : -1
}
; 寵物不在外面就按寵物卡的鍵叫出來。回傳寵物現在是不是在外面。
MnEnsurePet(p, why) {
    pid := p.pid
    pet := MnPetOut(pid)
    if pet != 0
        return pet = 1
    info := "", fnm := "DailyQuickInfo"
    try {
        f := %fnm%
        info := f(pid, "寵物卡")
    }
    if !IsObject(info) || info.key = "" {
        EventLog(p.name, "MN_PET", why "｜寵物不在外面，但快捷欄找不到寵物卡（或不知道是哪個鍵）｜沒有叫")
        return false
    }
    ApKey(p, info.key)
    MnOwnAct()
    Sleep 1500
    ok := MnPetOut(pid) = 1
    EventLog(p.name, "MN_PET", why "｜寵物不在外面，已按 " StrUpper(info.key) " 叫出｜" (ok ? "寵物出來了" : "按了但寵物還是沒出來"))
    return ok
}
; 按兩下空白鍵撿地上的秘笈，再等一下看秘笈進背包沒有。回傳有沒有撿到；items 換成最新的背包差。start = 王死亡的時間（日誌寫第幾秒）
MnBossSpacePick(p, base, &items, start) {
    global MN_BOSS_SPACE_WAIT_MS
    pid := p.pid
    at := Round((A_TickCount - start) / 1000)
    Loop 2 {
        ApGuardAny()
        ApKey(p, "Space")
        MnOwnAct()
        Sleep 400
    }
    got := false, t0 := A_TickCount
    Loop {
        ApGuardAny()
        items := MnLootDiff(base, MnInvSnap(pid), pid)
        for k, d in items
            if InStr(d.name, "秘笈")
                got := true
        if got || A_TickCount - t0 >= MN_BOSS_SPACE_WAIT_MS
            break
        Sleep 500
    }
    EventLog(p.name, "MN_BOSS_SPACE", "王死後 " at " 秒背包沒有多出秘笈，按了兩下空白鍵撿地上的｜" (got ? "撿到了" : "還是沒有秘笈"))
    return got
}
MnBossLootWait(p, st, base) {
    global MN_BOSS_LOOT_WAIT_MS, MN_BOSS_SPACE_PICK, MN_BOSS_SPACE_AFTER_MS
    pid := p.pid
    if MnPetOut(pid) = 0
        MnEnsurePet(p, "王死後")
    start := A_TickCount, items := Map(), got := false, spaceTried := false, spaceEarly := false
    Loop {
        ApGuardAny()
        items := MnLootDiff(base, MnInvSnap(pid), pid)
        for k, d in items
            if InStr(d.name, "秘笈")
                got := true
        if got || A_TickCount - start >= MN_BOSS_LOOT_WAIT_MS
            break
        if MN_BOSS_SPACE_PICK && !spaceEarly && A_TickCount - start >= MN_BOSS_SPACE_AFTER_MS {   ; 寵物站太遠撿不到：不等到掉落物消失，早一點自己按空白鍵撿
            spaceEarly := spaceTried := true
            got := MnBossSpacePick(p, base, &items, start)
            if got
                break
        }
        Sleep 500
    }
    if !got && MN_BOSS_SPACE_PICK {   ; 時間到還是沒有：最後再按一次
        spaceTried := true
        got := MnBossSpacePick(p, base, &items, start)
    }
    txt := ""
    for k, d in items
        txt .= (txt = "" ? "" : "、") d.name " ×" d.count
    pet := MnPetOut(pid)
    petTxt := pet = 1 ? "寵物在外面" : (pet = 0 ? "寵物不在外面" : "讀不到寵物狀態")
    EventLog(p.name, "MN_BOSS_LOOT", (got ? (spaceTried ? "王的掉落已進背包（按空白鍵撿的）：" : "王的掉落已進背包：") txt : "等了 " Round((A_TickCount - start) / 1000) " 秒背包沒有多出秘笈" (txt = "" ? "" : "（只多出：" txt "）")) "｜" petTxt)
    if items.Count
        MnStatsAddItems(p.name, items)
    if !got
        try SendDiscordMessage("⚠️ HIHIYONG 王打死了，但背包沒有多出秘笈`n角色：" p.name "`n" petTxt "。請看一下地上有沒有掉落物、背包是不是滿了。")
}

; 走到王旁邊 → 游標對準王的身體、壓住右鍵（右鍵技能是你設好的那個）→ 每 0.3 秒重新對準 → 王從清單消失（被打死）就放開。
; 角色死亡 / 你動鍵鼠 / 超時 / 視窗不在前面 / 出錯：一定放開右鍵。
MnFightBoss(p, boss) {
    global MN_BOSS_STAND, MN_BOSS_AIM_H, MN_BOSS_MAX_MS, MN_BOSS_TICK_MS, apRunStart, mnBossFight
    st := MnSt(p), pid := p.pid
    mnBossFight := true   ; 打王優先：排隊重新登入 / 載入中的角色、要切視窗的功能都先等打完（ApBlockerRaw 看這個旗標）
    try {
        MnFightBossCore(p, boss)
    } finally {
        mnBossFight := false
    }
}
; 游標要瞄王身上哪一點：預設是王身體（離地 MN_BOSS_AIM_H）；王的位置和礦石重疊時，游標剛好落在礦上會點到礦、一直對礦送無效攻擊。
; 所以把附近礦石投影到畫面，預設點離任何礦太近（< MN_BOSS_ORE_GAP 像素）就換成王身上較高 / 較低的其他點，挑離礦最遠的。
; 回傳 {x, y, overlap（有換點）, gap（離最近礦的像素，沒有礦 = 9999）}；王不在畫面內 x = -1。
MnBossAimPoint(pid, b) {
    global MN_BOSS_AIM_H, MN_BOSS_ORE_GAP, MN_ORE_NAME
    ores := []
    try {
        cr := MiningCrows(pid, MN_ORE_NAME)
        if IsObject(cr)
            for o in cr
                if Abs(o.x - b.x) < 60 && Abs(o.z - b.z) < 60   ; 離王遠的礦不可能疊在王身上
                    ores.Push(o)
    }
    ; 礦石投影成畫面點（取礦身體中間高度）
    oreSp := []
    for o in ores {
        sp := MnScreenPt(pid, o.x, o.y + 6, o.z)
        if sp.x >= 0
            oreSp.Push(sp)
    }
    best := 0, first := 0
    for dy in [0, 6, 12, 18, -4, -8] {
        sp := MnScreenPt(pid, b.x, b.y + MN_BOSS_AIM_H + dy, b.z)
        if sp.x < 0
            continue
        gap := 9999
        for q in oreSp
            gap := Min(gap, Sqrt((q.x - sp.x) ** 2 + (q.y - sp.y) ** 2))
        c := {x: sp.x, y: sp.y, gap: gap, overlap: false}
        if !IsObject(first)
            first := c
        if gap >= MN_BOSS_ORE_GAP {
            c.overlap := c.y != first.y
            return c
        }
        if !IsObject(best) || gap > best.gap
            best := c
    }
    if !IsObject(best)
        return {x: -1, y: -1, overlap: false, gap: 9999}
    best.overlap := best.y != first.y
    return best
}
; 世界座標 → 遊戲畫面（1024x768）座標；不在畫面內 x = -1
MnScreenPt(pid, x, y, z) {
    sp := GameWorldToScreen(pid, x, y, z)
    if !IsObject(sp) || !sp.visible
        return {x: -1, y: -1}
    return {x: sp.vpw ? Round(sp.x * 1024 / sp.vpw) : sp.x, y: sp.vph ? Round(sp.y * 768 / sp.vph) : sp.y}
}
MnFightBossCore(p, boss) {
    global MN_BOSS_STAND, MN_BOSS_AIM_H, MN_BOSS_MAX_MS, MN_BOSS_TICK_MS, MN_BOSS_ORE_GAP, apRunStart
    st := MnSt(p), pid := p.pid
    DhEnsureAutoHuntOff(p)
    try {
        MnEnsureBossSkill(p)
    } catch as e {
        st.bossSkip := A_TickCount + (e.Extra = "stop" ? 20000 : 120000)
        throw e
    }
    EventLog(p.name, "MN_BOSS_START", boss.name "#" boss.glob "｜(" Round(boss.x) "," Round(boss.z) ")｜HP 欄位 " boss.hp)
    AddRecentEvent("⚔ " p.name " 開始打王：" boss.name)
    st.text := "打王：走到 " boss.name " 旁邊"
    start := A_TickCount, held := false, hidden := 0, overlapLogged := false
    try {
        try MnLootSettle(p, st, true)   ; 上一顆還沒結算的收穫先算掉，免得和王的掉落混在一起
        bossBase := MnInvSnap(pid)
        try {
            MnEnsurePet(p, "打王前")
        } catch as e {
            if e.Extra = "stop"
                throw e
        }
        Loop {
            ApGuardAny()
            apRunStart := A_TickCount   ; 打王要很久，不能被「一個回合最多 120 秒」叫停
            if p.HasOwnProp("hpEventOpen") && p.hpEventOpen
                ApStop("角色死亡了，先放開右鍵等復活")
            b := MnFindBoss(pid)
            if !IsObject(b) {
                EventLog(p.name, "MN_BOSS_DONE", "王從清單消失（被打死 / 離開範圍）｜打了 " Round((A_TickCount - start) / 1000) " 秒")
                AddRecentEvent("✓ " p.name " 打王結束（" Round((A_TickCount - start) / 60000, 1) " 分鐘）")
                st.bossKills += 1, st.progressAt := A_TickCount, MnRunAdd(p.name, Map(), false, 1)
                if held
                    MnRightButton(false), held := false
                st.text := "王打完了，等寵物撿掉落"
                try {
                    MnBossLootWait(p, st, bossBase)
                } catch as e {
                    if e.Extra = "stop"
                        throw e
                }
                st.progressAt := A_TickCount
                st.text := "王打完了，回去採礦"
                return
            }
            if A_TickCount - start > MN_BOSS_MAX_MS
                throw Error("打王超過 " Round(MN_BOSS_MAX_MS / 60000) " 分鐘，先停手")
            me := MiningCharState(pid)
            if !IsObject(me)
                throw Error("讀不到人物位置")
            d := Sqrt((b.x - me.x) ** 2 + (b.z - me.z) ** 2)
            if d > MN_BOSS_STAND + 12 {   ; 太遠（或王被拉走了）：放開右鍵、走到王旁邊再繼續
                if held
                    MnRightButton(false), held := false
                st.text := "打王：走到 " b.name " 旁邊（距離 " Round(d) "）"
                MnWalkBeside(p, b, MN_BOSS_STAND, 0, MN_BOSS_STAND + 12)
                continue
            }
            aim := MnBossAimPoint(pid, b)
            ax := aim.x, ay := aim.y
            if aim.overlap && !overlapLogged {
                overlapLogged := true
                EventLog(p.name, "MN_BOSS_OVERLAP", "王身上有礦石重疊，游標改瞄 (" ax "," ay ")｜離最近的礦 " aim.gap " 像素" (aim.gap < MN_BOSS_ORE_GAP ? "（已經是能找到最遠的點了）" : ""))
            }
            if ax < 0 || !MnAim(p, ax, ay) {
                hidden += 1
                if held
                    MnRightButton(false), held := false
                if hidden * MN_BOSS_TICK_MS > 15000
                    throw Error("看不到王的位置（不在畫面內）")
                Sleep MN_BOSS_TICK_MS
                continue
            }
            hidden := 0
            if !held {
                MnRightButton(true), held := true
                EventLog(p.name, "MN_BOSS_HOLD", "游標對準王 (" ax "," ay ")，壓住右鍵｜距離 " Round(d))
            }
            st.text := "打王中（已 " Round((A_TickCount - start) / 1000) " 秒）"
            Sleep MN_BOSS_TICK_MS
        }
    } catch as e {
        st.bossSkip := A_TickCount + (e.Extra = "stop" ? 20000 : 120000)   ; 出錯先離開王一陣子，免得一直卡在打王
        throw e
    } finally {
        if held
            MnRightButton(false)
    }
}

; 設了趟數（MN_LOOPS > 0）、已經進過那麼多趟、而且現在不在礦場 = 跑完了
MnLoopsDone(st) {
    global MN_LOOPS
    return MN_LOOPS > 0 && st.visits >= MN_LOOPS && !st.inMine
}
MnLoopsNotify(p, st) {
    global MN_LOOPS
    st.progressAt := A_TickCount
    if st.loopDone
        return
    st.loopDone := true
    EventLog(p.name, "MN_LOOPS_DONE", "已跑完 " st.visits " 趟（設定 " MN_LOOPS " 趟），不再進圖")
    AddRecentEvent("⛏ " p.name " 已跑完 " st.visits " 趟自動採礦，停止進圖")
    try SendDiscordMessage("✅ HIHIYONG 自動採礦已跑完設定的趟數`n角色：" p.name "`n共 " st.visits " 趟（設定 " MN_LOOPS " 趟）。")
}
MnVisitText(st) {
    global MN_LOOPS
    if !st.visits
        return ""
    t := "第 " st.visits (MN_LOOPS > 0 ? " / " MN_LOOPS : "") " 趟"
    if st.inMine
        t .= "｜已待 " Round((A_TickCount - st.inSince) / 60000) " 分"
    if st.lastStay
        t .= "｜上趟待了 " st.lastStay " 分"
    return t
}

; 角色現在周圍 maxDist 單位內、選定顏色、沒被略過、不是 exclude 的礦：顏色優先、同顏色挑最近；沒有回傳 0
MnNearbyOre(p, exclude, maxDist) {
    global MN_ORE_NAME
    st := MnSt(p), pid := p.pid
    me := MiningCharState(pid)
    if !IsObject(me)
        return 0
    crows := 0
    try crows := MiningCrows(pid, MN_ORE_NAME)
    if !IsObject(crows)
        return 0
    list := []
    for o in crows
        if o.glob != exclude.glob && Sqrt((o.x - me.x) ** 2 + (o.z - me.z) ** 2) <= maxDist
            list.Push(o)
    return MnPickOre(list, me, st.skip, A_TickCount)
}

; 走到礦石「旁邊」：站位在人物這一側、離礦石 standDist 單位的地方。礦石是怪物清單裡的物件，點到它會變成選取 / 攻擊它，
; 所以不拿礦石本身的座標當點擊目標；優先用大地圖點站位走過去（完全不點地面物件），大地圖走不了才退回地面點擊。
MnStandPoint(me, ore, standDist, angle := 0) {
    d := Sqrt((me.x - ore.x) ** 2 + (me.z - ore.z) ** 2)
    ux := d < 1 ? 1 : (me.x - ore.x) / d, uz := d < 1 ? 0 : (me.z - ore.z) / d
    if angle != 0 {   ; 繞到礦石的另一側（原本那一側被擋住 / 走不到時用）
        rad := angle * 3.14159265 / 180
        ux2 := ux * Cos(rad) - uz * Sin(rad), uz2 := ux * Sin(rad) + uz * Cos(rad)
        ux := ux2, uz := uz2
    }
    s := angle != 0 ? standDist : Min(standDist, d)
    return {x: ore.x + ux * s, z: ore.z + uz * s}
}
MnWalkBeside(p, ore, standDist, angle := 0, useMax := 0) {
    global MN_STOP_DIST, MN_MAP_STOP, MN_USE_MAX
    if !useMax
        useMax := MN_USE_MAX
    me := MiningCharState(p.pid)
    if !IsObject(me)
        throw Error("讀不到人物位置")
    g := MnStandPoint(me, ore, standDist, angle)
    EventLog(p.name, "MN_WALK", "走到 " ore.name "#" ore.glob " 旁邊｜站位 (" Round(g.x) "," Round(g.z) ")｜離礦石 " Round(standDist, 1) (angle != 0 ? "｜繞到 " angle " 度" : ""))
    ; 大地圖只點地圖視窗、不會點到遊戲裡的東西；大地圖失敗也不退回一般的地面點擊（那會點到礦石）
    mapFailed := false
    try {
        ; 到站位的容許距離：只要離礦石在 useMax 內就能直接採，不必走到離站位 MN_MAP_STOP 內
        ; （11/13 實測大地圖常停在離站位 ~11 單位，之後要白點 3 次「人物沒動」才放棄，每顆多花 ~7 秒）
        DhRunTowardMap(p, g.x, g.z, Min(20, Max(MN_MAP_STOP, useMax - standDist - 1.5)), 3, 35)   ; 連續 3 次點了地圖人物沒動就放棄，交給避開礦石的地面點擊（目的地在地圖框外時點框邊常常不被收到）
    } catch as e {
        if e.Extra = "stop"
            throw e
        mapFailed := true
        EventLog(p.name, "MN_WALK_MAPFAIL", "大地圖走路失敗：" e.Message)
    }
    ; 大地圖點完離礦石在 useMax 內就直接採，不再補走（地圖點的位置夠近了）；真的太遠（大地圖在地圖邊緣點不準）才補最後一段：
    ; 地面點擊，但落點一定避開所有怪
    cur := MiningCharState(p.pid)
    if !IsObject(cur)
        return
    if mapFailed && Sqrt((g.x - cur.x) ** 2 + (g.z - cur.z) ** 2) > 60
        throw Error("大地圖點不動，離站位還有 " Round(Sqrt((g.x - cur.x) ** 2 + (g.z - cur.z) ** 2)) " 單位，太遠不用地面點擊補走", , "mapfar")
    dOre := Sqrt((ore.x - cur.x) ** 2 + (ore.z - cur.z) ** 2)
    if dOre <= useMax {
        EventLog(p.name, "MN_WALK_OK", "大地圖走完離 " ore.name "#" ore.glob " " Round(dOre, 1) " 單位，夠近，直接採")
        return
    }
    EventLog(p.name, "MN_WALK_FINAL", "大地圖走完離礦石還有 " Round(dOre, 1) " 單位（上限 " useMax "），補走最後一段（落點避開所有礦石）")
    MnFinalApproach(p, g.x, g.z)
}

; 候選落點裡第一個「離所有要避開的點都至少 minDist」的；沒有回傳 0。cands / avoid 是 {x, y}（畫面座標）。
MnPickSafe(cands, avoid, minDist) {
    for c in cands {
        ok := true
        for a in avoid {
            if (c.x - a.x) ** 2 + (c.y - a.y) ** 2 < minDist ** 2 {
                ok := false
                break
            }
        }
        if ok
            return c
    }
    return 0
}
; 用地面點擊走到 (gx,gz)，每一下的落點都避開畫面上所有怪（礦石、王…：身體和頭頂各一點）。
; 候選落點：朝目標方向的一段（整段 / 30 / 18 / 10 單位）× 偏角（0、±25、±50 度）；找不到安全的落點就丟錯誤，不亂點。
MnFinalApproach(p, gx, gz) {
    global MN_STOP_DIST, MN_CLICK_AVOID, MN_FINAL_STEPS, MN_FINAL_IDLE_MS, MN_FINAL_SEG_MS, apRunStart
    pid := p.pid
    badPts := []
    Loop MN_FINAL_STEPS {
        ApGuardAny()
        me := MiningCharState(pid)
        if !IsObject(me)
            throw Error("讀不到人物位置")
        dist := Sqrt((gx - me.x) ** 2 + (gz - me.z) ** 2)
        if dist <= MN_STOP_DIST
            return
        ux := (gx - me.x) / dist, uz := (gz - me.z) / dist
        avoid := []
        for b in badPts
            avoid.Push(b)
        crows := 0
        try crows := MiningCrows(pid)
        if IsObject(crows) {
            for c in crows {
                for h in [0, 15] {
                    sp := GameWorldToScreen(pid, c.x, c.y + h, c.z)
                    if IsObject(sp) && sp.visible
                        avoid.Push({x: sp.x, y: sp.y})
                }
            }
        }
        cands := []
        for s in [dist, 30, 18, 10] {
            step := Min(s, dist)
            for ang in [0, 25, -25, 50, -50] {
                rad := ang * 3.14159265 / 180
                tx := me.x + (ux * Cos(rad) - uz * Sin(rad)) * step, tz := me.z + (ux * Sin(rad) + uz * Cos(rad)) * step
                sp := GameWorldToScreen(pid, tx, me.y, tz)
                if !IsObject(sp) || !sp.visible
                    continue
                c := DhSafeClick(sp.x, sp.y)
                if DhScreenFree(c)
                    cands.Push({x: c.x, y: c.y, tx: tx, tz: tz})
            }
        }
        pick := MnPickSafe(cands, avoid, MN_CLICK_AVOID)
        if !IsObject(pick)
            throw Error("周圍都是礦石，找不到不會點到礦石的落點（還差 " Round(dist) "）")
        try {
            ApClick(p, pick.x, pick.y)
        } catch as e {
            ; 這個落點上面蓋著別的視窗（游標下面不是遊戲視窗）：把它當成要避開的點，換下一個落點，不要整輪停手
            if InStr(e.Message, "游標不在預期位置") && badPts.Length < 4 {
                badPts.Push({x: pick.x, y: pick.y})
                continue
            }
            throw e
        }
        t1 := A_TickCount, last := me, lastMove := t1
        Loop {
            ApGuardAny()
            Sleep 150
            cur := MiningCharState(pid)
            if !IsObject(cur)
                break
            if (cur.x - gx) ** 2 + (cur.z - gz) ** 2 <= MN_STOP_DIST ** 2 || (cur.x - pick.tx) ** 2 + (cur.z - pick.tz) ** 2 <= 6 ** 2
                break
            if (cur.x - last.x) ** 2 + (cur.z - last.z) ** 2 >= 3 ** 2
                last := cur, lastMove := A_TickCount
            if A_TickCount - lastMove >= MN_FINAL_IDLE_MS || A_TickCount - t1 >= MN_FINAL_SEG_MS
                break
        }
        apRunStart := A_TickCount
    }
    me := MiningCharState(pid)
    left := IsObject(me) ? Sqrt((gx - me.x) ** 2 + (gz - me.z) ** 2) : 9999
    if left > MN_STOP_DIST * 2.2
        throw Error("最後一段走不到（還差 " Round(left) "）")
}
; 走到礦石旁邊：這一側走不到（路被擋住）就依序繞到另外三側（+90 / -90 / 180 度）再試，全部都不行才丟錯誤
MnWalkAround(p, ore, standDist, deadline := 0, useMax := 0) {
    last := 0
    for ang in [0, 90, -90, 180] {
        if deadline && A_TickCount > deadline
            throw Error("走了太久還沒到（超過 " Round(MN_WALK_MAX_MS / 1000) " 秒），這顆不好走", , "mapfar")
        try {
            MnWalkBeside(p, ore, standDist, ang, useMax)
            return
        } catch as e {
            if e.Extra = "stop" || e.Extra = "mapfar"   ; 大地圖點不動：換角度也一樣點不動，不要再試
                throw e
            last := e
            EventLog(p.name, "MN_WALK_RETRY", ore.name "#" ore.glob " 從 " ang " 度這一側走不到：" e.Message)
        }
    }
    throw last
}

; 人物正在攻擊礦石（點到礦石 / 自動打怪造成的，礦石是怪物、打了沒有傷害，而且攻擊中用不了十字鎬）：
; 往礦石的反方向點一下地面讓人物停手（移動指令會取消攻擊），等動作回到待機。停不下來就丟錯誤，這顆先略過。
MnBreakAttack(p, ore) {
    pid := p.pid
    me := MiningCharState(pid)
    if !IsObject(me)
        return
    d := Sqrt((me.x - ore.x) ** 2 + (me.z - ore.z) ** 2)
    ux := d < 1 ? 1 : (me.x - ore.x) / d, uz := d < 1 ? 0 : (me.z - ore.z) / d
    EventLog(p.name, "MN_BREAK_ATTACK", "人物正在攻擊 " ore.name "#" ore.glob "（動作 " me.action "），往反方向走一小段讓它停手")
    try DhRunToward(p, me.x + ux * 25, me.z + uz * 25, 8)
    catch as e {
        if e.Extra = "stop"
            throw e
    }
    start := A_TickCount
    while A_TickCount - start < 3000 {
        ApGuardAny()
        cur := MiningCharState(pid)
        if IsObject(cur) && cur.action != 2 && cur.action != 3
            return
        Sleep 150
    }
    throw Error("人物一直在攻擊礦石，停不下來")
}

; ---------------------------------------------------------------- 遊戲操作（沿用每日道具的背包操作）
MnCtx(p) => {idx: 0, name: p.name, hwnd: p.hwnd, pid: p.pid, start: A_TickCount, invAnchor: 0, charAnchor: 0, p: p}

MnFindIn(pid, invenKey, pred) {
    for s in DailyInventory(pid, invenKey)
        if pred(GameItemName(s.key, pid))
            return s
    return 0
}

; 打開背包、右鍵十字鎬
; 回傳用哪條路：fast（快速：背包有沒有開直接讀記憶體、用記住的視窗位置直接右鍵那一格）/ slow（一般：搜圖確認視窗、點背包分頁、確認頁數）。
; 快速路徑只在「之前用一般路徑成功過、記住了視窗位置」、背包格子在目前這一頁時用；有一點對不上就退回一般路徑。
MnUsePickaxe(p) {
    global MN_KEEP_INV
    st := MnSt(p)
    if !st.fastOff && IsObject(st.invAnchor) && MnUsePickaxeFast(p)
        return "fast"
    ctx := MnCtx(p), pid := p.pid
    MnEnsureInventory(p, ctx)
    slot := DailyFindItem(pid, "十字鎬")
    if !slot
        throw Error("背包裡找不到十字鎬")
    DailyStep(ctx, "右鍵十字鎬（背包格子 " slot.x "," slot.y "）")
    DailyClickCell(ctx, slot, "Right")
    if !MN_KEEP_INV
        DailyCloseWindows(ctx)
    MnOwnAct()
    return "slow"
}
; 快速右鍵十字鎬：不搜圖、不點背包分頁、不重複確認頁數。成功送出右鍵回傳 true；對不上（讀不到背包狀態、換頁、背包打不開）回傳 false。
MnUsePickaxeFast(p) {
    global DAILY_INV_CELL0, DAILY_INV_STEP, DAILY_INV_ROWS_PER_PAGE
    st := MnSt(p), pid := p.pid
    slot := 0
    try slot := DailyFindItem(pid, "十字鎬")
    if !IsObject(slot)
        return false
    ui := DailyInvUi(pid)
    if !IsObject(ui)
        return false
    if ui.page > 0 && ui.page != DailyInvPageOf(slot.y)   ; 十字鎬不在目前這一頁：要換頁，交給一般路徑
        return false
    ctx := MnCtx(p)
    ctx.invAnchor := st.invAnchor
    if !ui.open {   ; 沒開：按 I 開，從記憶體等到真的開了（比搜圖快）
        DailyKey(ctx, "i")
        t := A_TickCount
        while A_TickCount - t < 1500 {
            ui := DailyInvUi(pid)
            if IsObject(ui) && ui.open
                break
            Sleep 60
        }
        if !IsObject(ui) || !ui.open
            return false
    }
    DailyClickClient(ctx, st.invAnchor[1] + DAILY_INV_CELL0[1] + slot.x * DAILY_INV_STEP
        , st.invAnchor[2] + DAILY_INV_CELL0[2] + Mod(slot.y, DAILY_INV_ROWS_PER_PAGE) * DAILY_INV_STEP, "Right", true, 120)
    MnOwnAct()
    return true
}
; 每日道具的背包操作（DailyClickCell / DailyKey…）送出的滑鼠和按鍵不會登記成「自己的動作」，
; 守門（ApUserActive）就會把它當成「你開始操作電腦」而叫停（實測：每次右鍵十字鎬 3～5 秒後都被叫停、背包也被關掉）。做完要自己登記。
MnOwnAct() {
    global apLastOwn
    apLastOwn := A_TickCount
}

; 只開道具視窗（I）：已經開著就沿用（找得到標題圖），沒開才按 I；再點「背包」分頁。不開角色視窗（C）。
MnEnsureInventory(p, ctx) {
    global DAILY_INV_TAB_BAG
    DailyEnsureInventoryVisible(ctx)
    DailyClickRel(ctx, ctx.invAnchor, DAILY_INV_TAB_BAG, "Left")
    MnSt(p).invAnchor := ctx.invAnchor
    MnOwnAct()
}
; 背包一直開著時地面點擊要閃開的區塊：道具視窗標題左上角 (x, y)，視窗約 240 寬、500 高；還沒開過就用預設位置（畫面右側）。
MnUiBlock(st) {
    a := st.HasOwnProp("invAnchor") && IsObject(st.invAnchor) ? st.invAnchor : [752, 140]
    return {l: a[1] - 12, t: a[2] - 12, r: a[1] + 250, b: a[2] + 510}
}

MnCloseWindows(p) {
    try DailyCloseWindows(MnCtx(p))
    MnOwnAct()
}

; 進水晶礦場：背包有傳送卡就右鍵傳送；只有禮盒就先打開；禮盒在銀行就先拿出來。
MnEnter(p) {
    ctx := MnCtx(p), pid := p.pid
    if MnIsMineMap(ReadGameMapId(pid))
        return
    MnEnsureInventory(p, ctx)
    card := MnFindIn(pid, "InvenOffset", MnIsCard)
    if !card {
        left := MnCountBoxes(pid)
        EventLog(p.name, "MN_BOXES", "傳送卡禮盒剩 " left " 個（背包 + 銀行）")
        if left <= 2 && left >= 1 && !MnSt(p).boxWarned {   ; 快用完了：提醒一次（用完就進不了圖、挖不了礦）
            MnSt(p).boxWarned := true
            AddRecentEvent("⚠ " p.name "：水晶礦場傳送卡禮盒只剩 " left " 個")
            try SendDiscordMessage("⚠️ HIHIYONG 水晶礦場傳送卡禮盒快用完了`n角色：" p.name "`n背包 + 銀行只剩 " left " 個，用完就無法再自動進圖。")
        }
        box := MnFindIn(pid, "InvenOffset", MnIsBox)
        if !box {
            DailyStep(ctx, "從銀行取出水晶礦場傳送卡禮盒")
            MnTakeBoxFromBank(ctx)
            box := MnFindIn(pid, "InvenOffset", MnIsBox)
        }
        if !box
            throw Error("背包和銀行都沒有水晶礦場傳送卡（或禮盒）")
        DailyStep(ctx, "打開 " GameItemName(box.key, pid))
        DailyClickCell(ctx, box, "Right")
        DailyWaitUntil(ctx, "禮盒打開後沒有出現水晶礦場傳送卡", () => MnFindIn(pid, "InvenOffset", MnIsCard))
        card := MnFindIn(pid, "InvenOffset", MnIsCard)
    }
    DailyStep(ctx, "右鍵 " GameItemName(card.key, pid) " 傳送")
    DailyClickCell(ctx, card, "Right")
    DailyWaitUntil(ctx, "右鍵傳送卡後 30 秒還沒到水晶礦場", () => MnIsMineMap(ReadGameMapId(pid)) && GameCharacterLoaded(pid), 30000)
    Sleep 2500
    MnSt(p).entered += 1, MnSt(p).progressAt := A_TickCount
    EventLog(p.name, "MN_ENTERED", "已進入水晶礦場")
}

MnTakeBoxFromBank(ctx) {
    global DAILY_INV_TAB_BAG, DAILY_INV_TAB_BANK
    pid := ctx.pid
    DailyClickRel(ctx, ctx.invAnchor, DAILY_INV_TAB_BANK, "Left")
    bank := 0
    try DailyWaitUntil(ctx, "", () => (bank := MnFindIn(pid, "BankOffset", MnIsBox)), 8000)
    if !bank {
        DailyClickRel(ctx, ctx.invAnchor, DAILY_INV_TAB_BAG, "Left")
        throw Error("銀行裡沒有水晶礦場傳送卡禮盒（銀行要先打開過一次分頁才會載入，可手動打開一次再試）")
    }
    Sleep 300
    DailyClickCell(ctx, bank, "Left", true, true)
    Sleep 500
    DailyClickRel(ctx, ctx.invAnchor, DAILY_INV_TAB_BAG, "Left")
    if DailyHeldName(pid) != ""
        DailyReleaseHeld(ctx)
    DailyWaitUntil(ctx, "禮盒沒有移到背包", () => MnFindIn(pid, "InvenOffset", MnIsBox))
}

; ---------------------------------------------------------------- 頁面
; rawValue：啟動(0/1)~角色名|角色名~自動進圖(0/1)~背包一直開著(0/1)~礦石顏色（照優先順序，逗號分隔，可以是空的）~打王(0/1)~打王技能欄(0～10)~打王右鍵技能代碼~自動略過不好走的礦(0/1)~進礦場趟數(0 = 一直循環)~嚴格依顏色順序(0/1)~各角色打王技能格（角色名:第幾格|…）~重開程式後自動接續採礦(0/1)
AutoMiningSet(rawValue) {
    global INI, MN_RUNNING, MN_CHARS, MN_AUTOENTER, MN_KEEP_INV, MN_COLORS, MN_BOSS_ON, MN_BOSS_BAR, MN_BOSS_SKILL, MN_SKIPHARD, MN_LOOPS, MN_RANK_SEC, MN_BOSS_CHAR_SLOTS, MN_RESUME, MN_RESUMED, profiles
    parts := StrSplit(rawValue, "~")
    if parts.Length < 2 || !IsInteger(parts[1])
        return
    wasRunning := MN_RUNNING
    MN_RUNNING := Integer(parts[1]) ? 1 : 0
    if MN_RUNNING && !MnFeatureOK() {
        MN_RUNNING := 0
        AddRecentEvent("🔒 這台電腦的授權沒有「自動採礦」功能，無法啟動")
    }
    MN_CHARS := MnParseChars(parts[2])
    if parts.Length >= 3 && IsInteger(parts[3])
        MN_AUTOENTER := Integer(parts[3]) ? 1 : 0
    if parts.Length >= 4 && IsInteger(parts[4])
        MN_KEEP_INV := Integer(parts[4]) ? 1 : 0
    if parts.Length >= 5
        MN_COLORS := MnParseColors(parts[5])
    if parts.Length >= 6 && IsInteger(parts[6])
        MN_BOSS_ON := Integer(parts[6]) ? 1 : 0
    if parts.Length >= 7 && IsInteger(parts[7])
        MN_BOSS_BAR := Min(10, Max(0, Integer(parts[7])))
    if parts.Length >= 8
        MN_BOSS_SKILL := RegExMatch(Trim(parts[8]), "^\d+-\d+$") ? Trim(parts[8]) : ""
    if parts.Length >= 9 && IsInteger(parts[9])
        MN_SKIPHARD := Integer(parts[9]) ? 1 : 0
    if parts.Length >= 10 && IsInteger(parts[10])
        MN_LOOPS := Min(99, Max(0, Integer(parts[10])))
    if parts.Length >= 11 && IsInteger(parts[11])
        MN_RANK_SEC := Integer(parts[11]) ? 1000 : 4
    if parts.Length >= 12
        MN_BOSS_CHAR_SLOTS := MnParseCharSlots(parts[12])
    if parts.Length >= 13 && IsInteger(parts[13])
        MN_RESUME := Integer(parts[13]) ? 1 : 0
    names := ""
    for n, _ in MN_CHARS
        names .= (names = "" ? "" : "|") n
    IniWrite names, INI, "AutoMining", "Chars"
    IniWrite MN_AUTOENTER, INI, "AutoMining", "AutoEnter"
    IniWrite MN_KEEP_INV, INI, "AutoMining", "KeepInv"
    IniWrite MN_BOSS_ON, INI, "AutoMining", "Boss"
    IniWrite MN_BOSS_BAR, INI, "AutoMining", "BossBar"
    IniWrite MN_SKIPHARD, INI, "AutoMining", "SkipHard"
    IniWrite MN_LOOPS, INI, "AutoMining", "Loops"
    IniWrite MN_RANK_SEC, INI, "AutoMining", "RankSec"
    IniWrite MN_RESUME, INI, "AutoMining", "ResumeOnStart"
    IniWrite MN_RUNNING, INI, "AutoMining", "Running"
    cs := ""
    for nm, sl in MN_BOSS_CHAR_SLOTS
        cs .= (cs = "" ? "" : "|") nm ":" sl
    IniWrite cs, INI, "AutoMining", "BossCharSlots"
    IniWrite MN_BOSS_SKILL, INI, "AutoMining", "BossSkill"
    colorText := ""
    for c in MN_COLORS
        colorText .= (colorText = "" ? "" : ",") c
    IniWrite colorText, INI, "AutoMining", "Colors"
    if MN_RUNNING && !wasRunning {   ; 使用者重新按「▶ 啟動」：從頭算（趟數歸零，不是接續）
        MN_RESUMED := false
        try IniDelete INI, "MiningRun"
        for p in profiles
            if p.HasOwnProp("mn")
                p.DeleteProp("mn")
    }
    for p in profiles
        p.mnActive := MN_RUNNING && MN_CHARS.Has(p.name) ? true : false
    AddRecentEvent("⛏ 自動採礦：" (MN_RUNNING ? "▶ 啟動" : "■ 停止") "｜角色 " (names = "" ? "（沒勾選）" : StrReplace(names, "|", "、")) "｜自動進圖 " (MN_AUTOENTER ? "開" : "關") "｜背包 " (MN_KEEP_INV ? "一直開著" : "每次開關") "｜礦石 " (colorText = "" ? "（沒勾選）" : StrReplace(colorText, ",", " > ")) "｜打王 " (MN_BOSS_ON ? "開（技能欄 " (MN_BOSS_BAR ? "F" MN_BOSS_BAR : "不檢查") (MN_BOSS_SKILL != "" ? "、右鍵技能 " MN_BOSS_SKILL : "") "）" : "關"))
}

AutoMiningPushWeb() {
    global webReady, WVCore, profiles, MN_RUNNING, MN_CHARS, MN_AUTOENTER, MN_KEEP_INV, MN_COLORS, MN_BOSS_ON, MN_BOSS_BAR, MN_BOSS_SKILL, MN_SKIPHARD, MN_LOOPS, MN_RANK_SEC, MN_BOSS_CHAR_SLOTS, MN_RESUME, MN_RESUMED
    if !webReady || !WVCore
        return
    chars := "", states := ""
    for p in profiles {
        if !p.enabled
            continue
        chars .= (chars = "" ? "" : ",") '{"name":"' JsonEscapeWeb(p.name) '","on":' (MN_CHARS.Has(p.name) ? "true" : "false") ',"slot":' MN_BOSS_CHAR_SLOTS.Get(p.name, 0) '}'
        if MN_CHARS.Has(p.name)
            states .= (states = "" ? "" : ",") '{"name":"' JsonEscapeWeb(p.name) '","text":"' JsonEscapeWeb(MnSt(p).text) '","visit":"' JsonEscapeWeb(MnVisitText(MnSt(p))) '","eta":"' JsonEscapeWeb(MnBossEtaText(MnSt(p))) '"}'
    }
    cur := ""   ; 第一個勾選且在遊戲裡的角色現在的右鍵技能（頁面上「記下目前的」用）
    for p in MnSelectedAlive() {
        me := 0
        try me := MiningCharState(p.pid)
        if IsObject(me) {
            nm := ""
            try nm := MiningSkillName(p.pid, me.runSkill)
            cur := '{"id":"' JsonEscapeWeb(me.runSkill) '","name":"' JsonEscapeWeb(nm) '","bar":' (me.skillBar + 1) '}'
            break
        }
    }
    stats := ""
    for nm, s0 in MN_STATS {
        s := MnStatsOf(nm)
        items := ""
        for k, it in s.items
            items .= (items = "" ? "" : ",") '{"n":"' JsonEscapeWeb(it.name) '","t":' it.total ',"d":' it.day '}'
        runs := ""
        Loop Min(10, s.runs.Length) {
            r := s.runs[s.runs.Length - A_Index + 1]
            ri := ""
            for k, d in r.items
                ri .= (ri = "" ? "" : ",") '{"n":"' JsonEscapeWeb(d.name) '","c":' d.count '}'
            mins := ""
            try mins := Round(DateDiff(r.end != "" ? r.end : A_Now, r.start, "Seconds") / 60, 1)
            runs .= (runs = "" ? "" : ",") '{"n":' r.n ',"start":"' FormatTime(r.start, "MM-dd HH:mm") '","mins":' (mins = "" ? 0 : mins) ',"open":' (r.end = "" ? "true" : "false") ',"gathers":' r.gathers ',"boss":' r.boss ',"items":[' ri ']}'
        }
        stats .= (stats = "" ? "" : ",") '{"name":"' JsonEscapeWeb(nm) '","gathers":' s.gathers ',"dayGathers":' s.dayGathers ',"items":[' items '],"runs":[' runs ']}'
    }
    colors := ""
    for c in MN_COLORS
        colors .= (colors = "" ? "" : ",") '"' c '"'
    try WVCore.PostWebMessageAsJson('{"type":"automining","data":{"running":' (MN_RUNNING ? "true" : "false") ',"autoEnter":' (MN_AUTOENTER ? "true" : "false") ',"keepInv":' (MN_KEEP_INV ? "true" : "false") ',"colors":[' colors '],"boss":' (MN_BOSS_ON ? "true" : "false") ',"bossBar":' MN_BOSS_BAR ',"bossSkill":"' JsonEscapeWeb(MN_BOSS_SKILL) '","loops":' MN_LOOPS ',"resume":' (MN_RESUME ? "true" : "false") ',"resumed":' (MN_RESUMED ? "true" : "false") ',"strictColor":' (MN_RANK_SEC >= 100 ? "true" : "false") ',"skipHard":' (MN_SKIPHARD ? "true" : "false") ',"hardCount":' MnHardCount() ',"curSkill":' (cur = "" ? "null" : cur) ',"stats":[' stats ']'
        . ',"licensed":' (MnFeatureOK() ? "true" : "false") ',"chars":[' chars '],"states":[' states ']}}')
}

#Include %A_LineFile%\..\BossTimer.ahk
