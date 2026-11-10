; ============================================================================
; DailyHunt：每日討伐（T 視窗任務：指定地圖的怪各打 1000 隻）自動跑圖。
; 按「▶ 啟動」才會動（不存檔：程式重開一定是停止）；「勾選」是選要跑哪幾個角色（可多個，各自獨立進行，
; 同一時間只有一個角色在用前景視窗，其他角色在掛機打怪時不需要視窗）。要跑哪幾張圖也可以另外勾。
; 任務資料：遊戲視窗打開過 T 才有（ReadGameDailyTasks；程式會自己按 T 刷新），每天 00:00 換。
; 設定存在 INI [DailyHunt]：Chars（要跑的角色，| 分隔）、Maps（勾選的地圖編號，逗號分隔）。
; 公車清單：打開公車視窗後先捲到最底，最底那一頁固定 20 格；點完會從遊戲讀回「選到第幾筆」確認。
; ============================================================================

; 地圖編號 → [名稱, 最底那頁的第幾格]。清單裡沒有的地圖（任務換了新地圖）只能顯示、不能自動跑。
global DH_BUS_BOTTOM_ROWS := 20
global DH_MAPS := Map(
    254, ["CDM 電算室2", 0],
    221, ["黑暗後裔集結區", 5],
    222, ["死神修煉場", 7],
    163, ["童話世界", 9],
    164, ["機械區", 10],
    165, ["魔術區", 12],
    166, ["裂變時空", 13],
    167, ["波斯宮", 14],
    233, ["異形空降區", 15],
    235, ["末日禁地島", 16],
    251, ["重力迴廊", 17],
    285, ["零號禁區", 18],
    286, ["冥神禁域", 19])

; 對話框第幾行（1～12）；不合理的值用 4
DhRowOf(v) => IsInteger(v) && Integer(v) >= 1 && Integer(v) <= 12 ? Integer(v) : 4
; NPC / 傳送卡名稱：去掉分隔符號、最長 20 字；空白用預設
DhCleanName(v, def) {
    v := Trim(StrReplace(StrReplace(StrReplace(v, "~", ""), "|", ""), ",", ""))
    return v = "" ? def : SubStr(v, 1, 20)
}
; 每張圖到了之後怎麼選要打的地方：
;   "dense" = 怪平均鋪滿、中間最密（電算室、機械區、黑暗後裔集結區）→ 跑到最密的中心；
;   "near"  = 怪一團一團（其他圖，預設）→ 就近找一群有幾隻的直接開打，不跑遠。
global DH_MAP_MODE := Map(254, "dense", 164, "dense", 221, "dense")
DhModeOf(mapId) => DH_MAP_MODE.Get(mapId, "near")

DhIniGet(key, def := "") {
    global INI
    try return IniRead(INI, "DailyHunt", key, def)
    return def
}
; 勾選的地圖編號（逗號分隔字串 → Map(編號, 執行順序))；字串裡的先後就是執行順序（1 起算）；設定檔被改壞的項目略過
DhParseMaps(text) {
    out := Map()
    for part in StrSplit(text, ",", " `t")
        if IsInteger(part) && Integer(part) > 0 && !out.Has(Integer(part))
            out[Integer(part)] := out.Count + 1
    return out
}
; 勾選的地圖編號，照執行順序排好的陣列（順序值相同的，照編號小到大）
DhOrderedIds(sel) {
    ids := []
    for id, rank in sel {
        pos := ids.Length + 1
        while pos > 1 && (sel[ids[pos - 1]] > rank)
            pos -= 1
        ids.InsertAt(pos, id)
    }
    return ids
}
; 勾選的角色（| 分隔字串 → Map(名字, 1)）
DhParseChars(text) {
    out := Map()
    for part in StrSplit(text, "|")
        if (n := Trim(part)) != ""
            out[n] := 1
    return out
}
global DH_RUNNING := 0                      ; 啟動 / 停止（不存檔）
global DH_START_IDLE_MS := 2000                ; 啟動 / 換下一步之前，鍵盤滑鼠要停多久才算你沒在用電腦
global DH_TEST := 0                         ; 測試流程（不存檔）：只傳送到勾選的圖、走到固定點就算完成、回起點、下一張，不打怪
global DH_CHARS := DhParseChars(DhIniGet("Chars", DhIniGet("Char", "")))   ; 舊版只有單一角色（Char）
global DH_MAPS_ON := DhParseMaps(DhIniGet("Maps", ""))
; 重開管理程式後自動接續（預設關閉）：[DailyHunt] ResumeOnStart=1 且上次是啟動狀態（Running=1）才會自己開始；遊戲被重新登入（管理程式沒關）不需要這個，本來就會接續。
global DH_RESUME := DhIniGet("ResumeOnStart", "0") = "1" ? 1 : 0
if DH_RESUME && DhIniGet("Running", "0") = "1"
    DH_RUNNING := 1
; 還沒設定過（設定檔沒有 Maps 這一項）時，已知清單裡的圖預設全部勾選
if DhIniGet("Maps", "<none>") = "<none>" {
    for id, _ in DH_MAPS
        DH_MAPS_ON[id] := 1
}

; 今日任務裡可以跑的地圖：有勾選、公車清單位置已知、沒被略過的。沒打滿的排前面（依任務順序），打滿的排後面（依任務順序）——
; 打滿 1000 隻的地圖也可以繼續跑（想繼續刷），只是會先跑還沒打滿的。
; tasks 是 ReadGameDailyTasks 的結果（讀不到 = 0 → 空清單）；回傳 [{map, name, done, target, row}]
DhPending(tasks, selected, skip := 0) {
    global DH_MAPS
    open := [], full := []
    if !IsObject(tasks)
        return open
    for r in tasks.rows
        for g in r.goals {
            if !selected.Has(g.map) || !DH_MAPS.Has(g.map) || (IsObject(skip) && skip.Has(g.map))
                continue
            (g.done >= g.target ? full : open).Push({map: g.map, name: g.name, done: g.done, target: g.target, row: DH_MAPS[g.map][2]})
        }
    DhSortByRank(open, selected), DhSortByRank(full, selected)
    for g in full
        open.Push(g)
    return open
}
; 照使用者排的執行順序（selected 的值）穩定排序；順序相同的維持任務原本的順序
DhSortByRank(list, selected) {
    i := 2
    while i <= list.Length {
        cur := list[i], r := selected[cur.map], j := i - 1
        while j >= 1 && selected[list[j].map] > r {
            list[j + 1] := list[j]
            j -= 1
        }
        list[j + 1] := cur
        i += 1
    }
}

; ---------------------------------------------------------------- 固定打怪點
; 怪的重生點是固定的，「怪最密的地方」也是固定的；即時算會隨別的角色打掉哪些怪而一直變。所以每張圖可以記一個固定點，
; 到了之後直接走到那裡開打（不再算密度）。記法：在遊戲的大地圖（M）上左鍵點一下想去的位置（遊戲會記下目標），
; 再按頁面上那張圖的「記錄」，程式從遊戲讀出那個位置存起來；也可以手動輸入座標。存在 INI [DailyHunt] Spots=地圖編號:x,z|…
DhParseSpots(text) {
    out := Map()
    for part in StrSplit(text, "|") {
        kv := StrSplit(part, ":")
        if kv.Length != 2 || !IsInteger(kv[1])
            continue
        xz := StrSplit(kv[2], ",")
        if xz.Length = 2 && IsNumber(xz[1]) && IsNumber(xz[2])
            out[Integer(kv[1])] := {x: xz[1] + 0, z: xz[2] + 0}
    }
    return out
}
; 數字存成最短的寫法（-24.0 → -24，-0.5 → -0.5）
DhNum(v) {
    s := Round(v, 1)
    return InStr(s, ".") ? RTrim(RTrim(s, "0"), ".") : s
}
DhSpotsText() {
    global DH_SPOTS, DH_SPOT_DEFAULTS
    s := ""
    for id, v in DH_SPOTS {
        d := DH_SPOT_DEFAULTS.Get(id, 0)
        if IsObject(d) && DhNum(d.x) = DhNum(v.x) && DhNum(d.z) = DhNum(v.z)
            continue   ; 和預設一樣的不存，以後預設更新才會跟著換
        s .= (s = "" ? "" : "|") id ":" DhNum(v.x) "," DhNum(v.z)
    }
    return s
}
; 內建預設固定點（開發者實測記下來的）。使用者自己按「記錄」存的點（INI Spots）會蓋過預設；「清除」= 回到預設（沒有預設的圖就是沒有固定點）。
global DH_SPOT_DEFAULTS := DhParseSpots("163:-141.6,-317.4|164:710.9,-254.6|165:304,-197.8|166:-6522.4,-4384.3|167:-264.9,286.1|221:-821.7,1748.5|222:542.5,-32.2|233:-12.8,2397.5|235:-176.7,348.3|251:805.4,-1975.4|254:22.9,-2.6|285:-189.1,163.3|286:-17.2,-1031.3")
global DH_SPOTS := DhParseSpots(DhIniGet("Spots", ""))
for id, v in DH_SPOT_DEFAULTS
    if !DH_SPOTS.Has(id)
        DH_SPOTS[id] := v
global dhSpotMsg := ""

; value：地圖編號~teach（從遊戲讀「上次在大地圖點的位置」）／地圖編號~clear／地圖編號~x~z（手動輸入）。回傳給畫面的訊息。
DailyHuntSpot(rawValue) {
    global INI, DH_SPOTS, DH_MAPS, dhSpotMsg
    dhSpotMsg := DhSpotDo(rawValue)
    return dhSpotMsg
}
global dhTeachLast := 0   ; 最近一次「記錄」用的遊戲目標像素（{map, tx, ty}），擋住「沒在這張圖點過、記到上一張圖的點」
DhSpotDo(rawValue) {
    global INI, DH_SPOTS, DH_SPOT_DEFAULTS, DH_MAPS, dhTeachLast
    parts := StrSplit(rawValue, "~")
    if parts.Length < 2 || !IsInteger(parts[1]) || !DH_MAPS.Has(Integer(parts[1]))
        return "（這張圖不支援）"
    id := Integer(parts[1]), msg := ""
    if parts[2] = "clear" {
        if DH_SPOTS.Has(id)
            DH_SPOTS.Delete(id)
        if DH_SPOT_DEFAULTS.Has(id) {
            DH_SPOTS[id] := DH_SPOT_DEFAULTS[id]
            msg := DH_MAPS[id][1] "：已回復內建預設固定點 (" Round(DH_SPOTS[id].x) ", " Round(DH_SPOTS[id].z) ")"
        } else
            msg := DH_MAPS[id][1] "：已清除固定點，改用自動找最密的地方"
    } else if parts[2] = "teach" {
        p := DhProfile()
        pg := p ? ReadGameNewMap(p.pid) : 0
        if !IsObject(pg)
            return "讀不到大地圖資料（要先有遊戲視窗，並在遊戲裡打開過大地圖）"
        here := DhMapMain(p.pid)   ; 以角色真正所在的地圖為準（有些圖的大地圖頁面編號和地圖編號不同，例如異形空降區、冥神禁域）
        if here != id && (here = -1 && pg.mapMain != id)
            return "讀不到角色現在在哪張圖（大地圖顯示的是 " pg.mapMain "）：請先讓角色到「" DH_MAPS[id][1] "」，再按記錄"
        if here != id && here != -1
            return "那個角色現在不在「" DH_MAPS[id][1] "」（在 " here "）：請先讓角色到這張圖，在大地圖上點想去的位置，再按記錄"
        if pg.mapMain != id
            EventLog(p.name, "DH_SPOT", DH_MAPS[id][1] "｜大地圖頁面編號 " pg.mapMain " 和地圖編號 " id " 不同，以角色所在地圖為準")
        ; 記錄的位置有兩種來源，一律以「人物走得到」為準：
        ;  A. 你在大地圖點的目標：目標有效（在這張圖範圍內、不是上一張圖留下的點）而且人物已經走到它旁邊（200 單位內）→ 記目標（最精準）；
        ;  B. 其他情況（沒點過、目標是上一張圖留下的、遊戲找路走不到那個點、人物停在半路）→ 記「人物現在站的位置」。人物站得到的地方，以後一定走得到。
        ; 遊戲換圖時不會清掉「上一次點的目標」，所以 A 要擋掉範圍外 / 和上一張圖同一個點（異形空降區曾被記成 (1049,98)，離這張圖很遠）。
        w := DhMapTargetWorld(pg), why := "", meT := MiningCharState(p.pid)
        if !IsObject(w)
            why := "遊戲還沒記到你點的目標"
        else if w.x < pg.startX - 60 || w.x > pg.startX + pg.sizeX + 60 || w.z < pg.startY - 60 || w.z > pg.startY + pg.sizeY + 60
            why := "遊戲記的目標 (" Round(w.x) "," Round(w.z) ") 不在這張圖的範圍內（是上一張圖點的）"
        else if IsObject(dhTeachLast) && dhTeachLast.map != id && dhTeachLast.tx = pg.tx && dhTeachLast.ty = pg.ty
            why := "遊戲記的目標和「" DH_MAPS[dhTeachLast.map][1] "」記錄的是同一個點（這張圖還沒點過）"
        else if IsObject(meT) && Sqrt((meT.x - w.x) ** 2 + (meT.z - w.z) ** 2) > 200
            why := "人物離你點的位置還有 " Round(Sqrt((meT.x - w.x) ** 2 + (meT.z - w.z) ** 2)) " 單位，沒有走到（那個位置可能走不到）"
        if why = "" {
            dhTeachLast := {map: id, tx: pg.tx, ty: pg.ty}
            DH_SPOTS[id] := {x: w.x, z: w.z}
            EventLog(p.name, "DH_SPOT", DH_MAPS[id][1] "｜記錄目標｜遊戲目標像素 (" pg.tx "," pg.ty ")｜世界座標 (" Round(w.x, 1) "," Round(w.z, 1) ")｜人物現在 (" (IsObject(meT) ? Round(meT.x) "," Round(meT.z) : "?") ")｜地圖範圍 " pg.startX "," pg.startY " 大小 " pg.sizeX "x" pg.sizeY " 貼圖 " pg.texX "x" pg.texY)
            msg := DH_MAPS[id][1] "：已記錄固定點 (" Round(w.x) ", " Round(w.z) ")"
        } else {
            if !IsObject(meT) || meT.x < pg.startX - 60 || meT.x > pg.startX + pg.sizeX + 60 || meT.z < pg.startY - 60 || meT.z > pg.startY + pg.sizeY + 60
                return DH_MAPS[id][1] "：" why "，而且讀不到人物在這張圖裡的位置，沒有記錄。請讓人物站在想打怪的地方（或在大地圖點好、等人物走到），再按記錄"
            DH_SPOTS[id] := {x: meT.x, z: meT.z}
            EventLog(p.name, "DH_SPOT", DH_MAPS[id][1] "｜記錄人物位置｜原因：" why "｜人物 (" Round(meT.x, 1) "," Round(meT.z, 1) ")")
            msg := DH_MAPS[id][1] "：已記錄「人物現在站的位置」(" Round(meT.x) ", " Round(meT.z) ")（原因：" why "）。人物站得到的地方以後一定走得到"
        }
    } else if parts.Length >= 3 && IsNumber(parts[2]) && IsNumber(parts[3]) {
        DH_SPOTS[id] := {x: parts[2] + 0, z: parts[3] + 0}
        msg := DH_MAPS[id][1] "：固定點設為 (" Round(parts[2] + 0) ", " Round(parts[3] + 0) ")"
    } else
        return "座標格式不對（要兩個數字）"
    IniWrite DhSpotsText(), INI, "DailyHunt", "Spots"
    AddRecentEvent("🎯 " msg)
    return msg
}
; 每個角色自己的進行狀態（放在角色物件上，和寵物監測一樣）
DhSt(p) {
    if !p.HasOwnProp("dh")
        p.dh := {next: 0, fails: 0, hunted: 0, refreshedAt: 0, skip: Map(), prog: Map(), stalls: 0, staleN: 0, lock: 0, keepPlace: false, lastDay: 0, text: "", done: false, testDone: Map(), seen: Map(), notified: Map()}
    return p.dh
}

; 勾選的角色裡遊戲視窗還在的（依角色列表順序）
DhSelectedAlive() {
    global profiles, DH_CHARS
    out := []
    for p in profiles {
        if !DH_CHARS.Has(p.name)
            continue
        alive := false
        try alive := ProfileGameAlive(p)
        if alive && p.pid
            out.Push(p)
    }
    return out
}
; 畫面上顯示任務進度的角色：第一個還沒做完的，都做完了就第一個
DhProfile() {
    list := DhSelectedAlive()
    for p in list
        if !DhSt(p).done
            return p
    return list.Length ? list[1] : 0
}

; rawValue：啟動(0/1)~角色名|角色名~地圖編號,地圖編號,…[~NPC 名稱~傳送卡名稱~對話框第幾行]
DailyHuntSet(rawValue) {
    global INI, DH_RUNNING, DH_CHARS, DH_MAPS_ON, profiles, DH_NPC_NAME, DH_START_CARD, DH_NPC_ROW, DH_TEST, DH_RESUME
    parts := StrSplit(rawValue, "~")
    if parts.Length < 3 || !IsInteger(parts[1])
        return
    wasRunning := DH_RUNNING, wasTest := DH_TEST
    DH_RUNNING := Integer(parts[1]) ? 1 : 0
    if parts.Length >= 7 && IsInteger(parts[7])
        DH_TEST := Integer(parts[7]) ? 1 : 0
    DH_CHARS := DhParseChars(parts[2])
    DH_MAPS_ON := DhParseMaps(parts[3])
    names := ""
    for n, _ in DH_CHARS
        names .= (names = "" ? "" : "|") n
    ids := ""
    for id in DhOrderedIds(DH_MAPS_ON)
        ids .= (ids = "" ? "" : ",") id
    if parts.Length >= 6 {
        DH_NPC_NAME := DhCleanName(parts[4], "護士"), DH_START_CARD := DhCleanName(parts[5], "起點傳送卡"), DH_NPC_ROW := DhRowOf(parts[6])
        IniWrite DH_NPC_NAME, INI, "DailyHunt", "Npc"
        IniWrite DH_START_CARD, INI, "DailyHunt", "Card"
        IniWrite DH_NPC_ROW, INI, "DailyHunt", "Row"
    }
    if parts.Length >= 8 && IsInteger(parts[8])
        DH_RESUME := Integer(parts[8]) ? 1 : 0
    IniWrite DH_RESUME, INI, "DailyHunt", "ResumeOnStart"
    if DH_RESUME {   ; 只有勾「重開程式後自動接續」才把啟動狀態存檔（原本的設計：程式重開一定是停止）
        IniWrite DH_RUNNING, INI, "DailyHunt", "Running"
    } else {
        try IniDelete INI, "DailyHunt", "Running"
    }
    IniWrite names, INI, "DailyHunt", "Chars"
    IniWrite ids, INI, "DailyHunt", "Maps"
    if DH_RUNNING && (!wasRunning || wasTest != DH_TEST) {   ; 重新啟動 / 切換測試流程：之前的「略過」「做完」「失敗休息」都清掉
        for p in profiles
            if p.HasOwnProp("dh")
                p.DeleteProp("dh")
    }
    AddRecentEvent("🎯 每日討伐：" (DH_RUNNING ? "▶ 啟動" : "■ 停止") (DH_TEST ? "（測試流程）" : "") "｜角色 " (names = "" ? "（沒勾選）" : StrReplace(names, "|", "、")) "｜勾選 " DH_MAPS_ON.Count " 張圖")
}

; 頁面上顯示：目前執行的程式碼是幾點的版本；磁碟上有更新的版本就警告要重開
DhBuildText() {
    global DH_LOADED_STAMP
    loaded := DH_LOADED_STAMP, disk := DhFileStamp()
    if loaded = ""
        return ""
    txt := "目前執行的每日討伐程式碼：" FormatTime(loaded, "MM-dd HH:mm:ss")
    if disk != "" && disk != loaded
        txt .= "｜⚠ 磁碟上有更新的版本（" FormatTime(disk, "MM-dd HH:mm:ss") "），請關掉管理程式重開才會用到"
    return txt
}
DailyHuntPushWeb() {
    global DH_TEST, webReady, WVCore, profiles, DH_RUNNING, DH_CHARS, DH_MAPS_ON, DH_MAPS, DH_NPC_NAME, DH_START_CARD, DH_NPC_ROW, DH_SPOTS, dhSpotMsg, DH_RESUME
    if !webReady || !WVCore
        return
    chars := "", states := ""
    for p in profiles {
        if !p.enabled
            continue
        chars .= (chars = "" ? "" : ",") '{"name":"' JsonEscapeWeb(p.name) '","on":' (DH_CHARS.Has(p.name) ? "true" : "false") '}'
        if DH_CHARS.Has(p.name)
            states .= (states = "" ? "" : ",") '{"name":"' JsonEscapeWeb(p.name) '","text":"' JsonEscapeWeb(DhSt(p).text) '"}'
    }
    p := DhProfile()
    tasks := 0
    if p
        try tasks := ReadGameDailyTasks(p.pid)
    rows := ""
    if IsObject(tasks) {
        for r in tasks.rows
            for g in r.goals {
                rows .= (rows = "" ? "" : ",") '{"map":' g.map ',"name":"' JsonEscapeWeb(g.name) '","done":' g.done ',"target":' g.target
                    . ',"group":"' JsonEscapeWeb(r.name) '","claimed":' (r.claimed ? "true" : "false") ',"runnable":' (DH_MAPS.Has(g.map) ? "true" : "false")
                    . ',"on":' (DH_MAPS_ON.Has(g.map) ? "true" : "false") ',"rank":' DH_MAPS_ON.Get(g.map, 0) ',"spot":"' (DH_SPOTS.Has(g.map) ? Round(DH_SPOTS[g.map].x) "," Round(DH_SPOTS[g.map].z) : "") '"}'
            }
    }
    sel := ""
    for id in DhOrderedIds(DH_MAPS_ON)
        sel .= (sel = "" ? "" : ",") id
    pending := 0   ; 畫面上「勾選且未完成」：打滿的也能跑，但不算在這裡
    for g in DhPending(tasks, DH_MAPS_ON, p ? DhSt(p).skip : 0)
        if g.done < g.target
            pending += 1
    status := DH_CHARS.Count = 0 ? "請勾選要跑的角色" : (!p ? "勾選的角色都沒有遊戲視窗" : (IsObject(tasks) ? "" : "讀不到任務：" (DH_RUNNING ? "啟動後程式會自己按 T 讀取" : "按「▶ 啟動」會自己按 T 讀取，或在「" p.name "」的遊戲裡按 T 打開一次")))
    try WVCore.PostWebMessageAsJson('{"type":"dailyhunt","data":{"running":' (DH_RUNNING ? "true" : "false") ',"test":' (DH_TEST ? "true" : "false") ',"resume":' (DH_RESUME ? "true" : "false")
        . ',"using":"' JsonEscapeWeb(p ? p.name : "") '","chars":[' chars '],"states":[' states '],"status":"' JsonEscapeWeb(status) '","build":"' JsonEscapeWeb(DhBuildText()) '","spotMsg":"' JsonEscapeWeb(dhSpotMsg) '","npc":"' JsonEscapeWeb(DH_NPC_NAME) '","card":"' JsonEscapeWeb(DH_START_CARD) '","row":' DH_NPC_ROW ',"pending":' pending ',"selected":[' sel '],' DhSchedJson() ',"tasks":[' rows ']}}')
}

; ============================================================================
; 自動跑圖。一次只做一小段（每段一個「回合」：切到遊戲視窗 → 做完 → 切回原本的視窗），其餘時間只讀資料。
; 流程（和你示範的一樣）：回起點 → 點 NPC 麗娜 → 選「公車站2號線」→ 公車清單捲到最底 → 點目標地圖 → 確定 →
;   到了新地圖 → 點一下目標怪（人物會跑過去）→ 按 F6 開自動打怪 → 每隔一段時間按 T 看進度 → 打滿 1000 就換下一張。
; 每一步都先讀遊戲資料確認（視窗有沒有開、選到哪一筆、在哪張圖、F6 有沒有開），對不上就停手，不會亂點。
; 沿用組隊 / 寵物監測的守門：你開始操作電腦、緊急停止、其他自動動作中、死亡中、不在遊戲世界時都不動作。
; ============================================================================
; 搭公車的 NPC 名稱、到那張圖用的傳送卡（道具快捷欄裡的名稱）、對話框裡「公車站」是第幾行（可在頁面上改；每個 NPC 的選單不同）
; 這個檔案載入時的修改時間：磁碟上的檔案比它新 = 管理程式還在跑舊版，要重開（AHK 啟動後不會自己載入新檔案）
global DH_FILE := A_LineFile
global DH_LOADED_STAMP := DhFileStamp()
DhFileStamp() {
    try return FileGetTime(DH_FILE, "M")
    return ""
}
global DH_NPC_NAME := DhCleanName(DhIniGet("Npc", "護士"), "護士")
global DH_START_CARD := DhIniGet("Card", "起點傳送卡")
global DH_NPC_ROW := DhRowOf(DhIniGet("Row", 4))
global DH_BUS_OPTION_X := 576, DH_BUS_OPTION_Y0 := 322, DH_BUS_OPTION_PITCH := 20    ; NPC 對話框選項：第 1 行在 y=322，每行 20
global DH_BUS_LIST_X := 131, DH_BUS_ROW0_Y := 149, DH_BUS_ROW_H := 14.05, DH_BUS_OK_X := 188, DH_BUS_OK_Y := 594
global DH_REFRESH_MS := 45000, DH_STALL_MS := 180000, DH_TICK_MS := 3000
global dhBusy := false
; 下一步做什麼（不碰遊戲，方便測試）。
; st：{tasks, selected, skip, curMap, autoHunt, huntedMap, now, refreshedAt}
; 回傳 {action: "refresh"/"travel"/"starthunt"/"monitor"/"done", goal}
DhDecide(st) {
    global DH_REFRESH_MS
    if !IsObject(st.tasks)
        return {action: "refresh", goal: 0}
    pend := DhPending(st.tasks, st.selected, st.skip)
    if !pend.Length
        return {action: "done", goal: 0}   ; 沒有任何勾選的地圖可跑（沒勾、全被略過）
    if st.HasOwnProp("test") && st.test {   ; 測試流程：每張圖只要「到了固定點」就算完成，依序做完所有勾選的圖
        left := []
        for g in pend
            if !st.testDone.Has(g.map)
                left.Push(g)
        if !left.Length
            return {action: "finish", goal: 0}
        goal := left[1]
        return st.curMap != goal.map ? {action: "travel", goal: goal} : {action: "testwalk", goal: goal}
    }
    allDone := true
    for g in pend
        if g.done < g.target
            allDone := false
    if allDone   ; 勾選的全部打滿了：回起點、通報完成（不再留在地圖上繼續打）
        return {action: "finish", goal: 0}
    goal := pend[1]   ; 沒打滿的排在前面
    ; 正在跑的那張圖還沒打滿、也還勾著：跑完它再換。跑到一半才勾選順序在前面的圖（例如電算室），不會被拉回去，排在它後面
    if st.HasOwnProp("lockMap") && st.lockMap
        for g in pend
            if g.map = st.lockMap && g.done < g.target {
                goal := g
                break
            }
    if st.curMap != goal.map
        return {action: "travel", goal: goal}
    if st.huntedMap != goal.map || st.autoHunt = 0
        return {action: "starthunt", goal: goal}
    if st.now - st.refreshedAt >= DH_REFRESH_MS
        return {action: "refresh", goal: goal}
    return {action: "monitor", goal: goal}
}

; 目前所在地圖的主編號（讀不到回傳 -1）
DhMapMain(pid) {
    m := ""
    try m := ReadGameMapId(pid)
    if m = ""
        return -1
    n := StrSplit(m, "-")[1]
    return IsInteger(n) ? Integer(n) : -1
}
; 怪物名稱：任務目標寫成「地圖 / 怪物」
DhMobName(goal) {
    parts := StrSplit(goal.name, " / ")
    return parts.Length >= 2 ? Trim(parts[2]) : ""
}

DailyHuntTick() {
    global DH_RUNNING, DH_CHARS, DH_MAPS_ON, dhBusy, apBusy, cwBusy
    if !DH_RUNNING
        return
    if dhBusy || apBusy || cwBusy
        return
    why := ApBlockerRaw()
    if why != "" {
        for p in DhSelectedAlive()
            DhSt(p).text := "等待中：" why
        return
    }
    if DH_CHARS.Count = 0
        return
    ; 每個勾選的角色各看一次：只讀資料就能判斷的（打怪中 / 做完了）當場處理，需要動手的做第一個
    todo := 0
    for p in DhSelectedAlive() {
        st := DhSt(p)
        if st.done
            continue
        if !ApReady(p) {
            dead := p.HasOwnProp("hpEventOpen") && p.hpEventOpen
            st.text := dead ? "💀 死亡中，用歸魂珠原地復活後自動繼續" : "還沒進遊戲世界（或死亡中）"
            if dead   ; 跑圖期間死亡：馬上用歸魂珠原地復活（不等 60 秒；鍵鼠閒置 3 秒就動手），復活後從頭判斷、重新開地圖走過去
                try ReviveStuckCheck(p, 0, 3)
            continue
        }
        if st.HasOwnProp("deathNoted") && st.deathNoted {   ; 復活了：從頭判斷（可能在復活點，要重新搭車）
            st.deathNoted := false, st.hunted := 0, st.next := 0
            EventLog(p.name, "DH_REVIVED", "復活了，每日討伐繼續")
        }
        if A_TickCount < st.next
            continue
        d := DhPlan(p)
        if d.action = "done" {
            if st.text != "沒有可跑的地圖（沒勾選，或都被略過）" {   ; 只提示一次；不設「做完」旗標，之後勾了地圖馬上就會繼續
            st.text := "沒有可跑的地圖（沒勾選，或都被略過）"
            AddRecentEvent("🎯 " p.name "：沒有可跑的地圖（沒勾選，或都被略過）")
        }
        } else if d.action = "monitor"
            DhMonitor(p, d.goal)
        else if !todo
            todo := {p: p, d: d}
    }
    if todo {
        busy := ApBlocker(DH_START_IDLE_MS)   ; 含「等你停止操作鍵盤滑鼠」：每日討伐只等 2 秒（不跟自動組隊共用 5 秒）
        if busy != "" {
            DhSt(todo.p).text := "等待中：" busy
            return
        }
        fpWhy := "", fpNm := "FpBlocked"   ; 功能優先順序：排在前面的功能忙著就先等
        try {
            fpf := %fpNm%
            fpWhy := fpf("dailyhunt", todo.p)
        }
        if fpWhy != "" {
            DhSt(todo.p).text := "等待中：" fpWhy
            return
        }
        DhRun(todo.p, todo.d)
    }
}

; 現在是「第幾天」（從 1970-01-01 起算，本機日期；遊戲的每日任務也是這種算法，00:00 換日）
global DH_CHECK_STALE_DAY := true
DhRealDay() => DateDiff(A_Now, "19700101", "Days")
; 遊戲裡的任務資料是不是前一天（或更早）的
DhIsStaleDay(gameDay, realDay) {
    global DH_CHECK_STALE_DAY
    return DH_CHECK_STALE_DAY && IsInteger(gameDay) && gameDay > 0 && gameDay < realDay
}
; 這個角色現在該做什麼（讀資料，不動遊戲）
DhPlan(p) {
    global DH_MAPS_ON, DH_TEST
    pid := p.pid, st := DhSt(p)
    tasks := 0
    try tasks := ReadGameDailyTasks(pid)
    ; 00:00 換日後，遊戲裡的任務資料還是前一天的（昨天打滿的進度），要按 T 打開任務視窗遊戲才會更新。
    ; 不處理的話會把昨天的進度當成今天「全部完成」，點啟動後什麼都不做：視為還沒讀到，先去開 T 更新。
    if IsObject(tasks) && DhIsStaleDay(tasks.today, DhRealDay()) {
        st.staleN += 1
        st.text := "遊戲的任務資料還是前一天的，開 T 更新（第 " st.staleN " 次）"
        if st.staleN = 1
            EventLog(p.name, "DH_STALE_DAY", "遊戲的任務資料是第 " tasks.today " 天，現在是第 " DhRealDay() " 天｜開 T 讓遊戲更新")
        else if st.staleN >= 6 {
            st.refreshedAt := 0, st.next := A_TickCount + 60000
            st.text := "遊戲的任務資料一直沒換成今天（試了 " st.staleN " 次），1 分鐘後再試；仍不行請重新登入這個角色"
        }
        tasks := 0
    } else if IsObject(tasks)
        st.staleN := 0
    if IsObject(tasks) && tasks.today != st.lastDay {   ; 新的一天（00:00 換任務）：重新來過
        st.lastDay := tasks.today, st.skip := Map(), st.prog := Map(), st.stalls := 0, st.hunted := 0, st.lock := 0, st.done := false
        if st.HasOwnProp("stat")
            st.DeleteProp("stat")
    }
    if IsObject(tasks) && !DH_TEST
        DhNoteProgress(p, tasks)
    d := DhDecide({test: DH_TEST, testDone: st.testDone, tasks: tasks, selected: DH_MAPS_ON, skip: st.skip, curMap: DhMapMain(pid), autoHunt: ReadGameAutoHunt(pid)
        , huntedMap: st.hunted, now: A_TickCount, refreshedAt: st.refreshedAt, lockMap: st.lock})
    if !DH_TEST && IsObject(d.goal) && d.goal.done < d.goal.target
        st.lock := d.goal.map   ; 記住現在在跑的圖
    if !DH_TEST && d.action != "done"
        DhStatTrack(p, st, d)   ; 統計每張圖花的時間
    return d
}

; 打怪中：只看進度。進度很久沒動（自動打怪開著但沒有在打）→ 重新跑去怪那邊，連續 3 次就略過這張圖。
DhMonitor(p, g) {
    global DH_STALL_MS, DH_SPOTS, DH_AWAY_DIST
    st := DhSt(p)
    if g.done >= g.target {   ; 已打滿：進度不會再增加，不能用「進度沒動」判斷卡住
        st.text := "已打滿，繼續打：" g.name "｜" g.done " / " g.target
        return
    }
    pr := st.prog.Get(g.map, 0)
    if !IsObject(pr) || pr.done != g.done {
        st.prog[g.map] := {done: g.done, since: A_TickCount}
    } else if A_TickCount - pr.since >= DH_STALL_MS {
        st.stalls += 1
        EventLog(p.name, "DH_STALL", g.name "｜進度 " g.done " 已超過 " Round(DH_STALL_MS / 1000) " 秒沒增加｜重新跑去怪那邊（第 " st.stalls " 次）")
        st.prog.Delete(g.map)
        if st.stalls >= 3 {
            st.skip[g.map] := 1, st.stalls := 0
            AddRecentEvent("🎯 " p.name "：" g.name " 一直打不到，先略過這張圖")
        } else {
            st.hunted := 0
            ; 第一次卡住、而且人物不在固定點附近（你手動換了位置）：不要硬拉回固定點（那邊可能有人），就地找怪
            if st.stalls = 1 && DhIsAway(MiningCharState(p.pid), DH_SPOTS.Get(g.map, 0), DH_AWAY_DIST)
                st.keepPlace := true
        }
        return
    }
    st.text := "打怪中：" g.name "｜" g.done " / " g.target
}

; 一個回合：和 CompanionRun 一樣的保護（旗標、切視窗、守門、收尾還原視窗）。
DhRun(p, d) {
    global dhBusy, apBusy, foregroundOwner, apRunStart, apLastOwn, dhCurProfile
    st := DhSt(p), g := d.goal
    prev := 0, cursor := 0, minimized := [], stopped := false, runT0 := A_TickCount
    dhBusy := true, apBusy := true, foregroundOwner := "dailyhunt", apRunStart := A_TickCount, apLastOwn := A_TickCount, dhCurProfile := p
    try {
        prev := ApForeground(), cursor := ApCursor()
        if ApIsMinimized(p)
            minimized.Push(p)
        if !ApActivate(p) {
            st.next := A_TickCount + 30000, st.text := "切不到遊戲視窗，稍後再試"
            return
        }
        if d.action = "refresh" {
            st.text := "讀取任務進度（開 T）"
            DhActRefresh(p)
            st.refreshedAt := A_TickCount, st.next := A_TickCount + 8000   ; 還讀不到資料時不要每 3 秒就開關一次 T
        } else if d.action = "travel" {
            st.text := "前往 " g.name
            DhActTravel(p, g)
        } else if d.action = "starthunt" {
            st.text := "到怪物那邊開始自動打怪：" g.name
            ; 這張圖本來就在打、只是自動打怪被關掉了（你手動走開時遊戲會自己關）：人物不在固定點附近就留在原地繼續，不拉回去
            DhActStartHunt(p, g, st.hunted = g.map || st.keepPlace)
            st.keepPlace := false
            st.hunted := g.map
        } else if d.action = "testwalk" {
            st.text := "（測試）走到固定點：" g.name
            DhActTestWalk(p, g)
        } else if d.action = "finish" {
            st.text := "全部做完，回起點"
            DhActFinish(p)
        }
        st.fails := 0
    } catch as e {
        if e.Extra = "stop" {
            stopped := true
            st.next := A_TickCount + 20000
            if p.HasOwnProp("hpEventOpen") && p.hpEventOpen {   ; 死亡：不算失敗；走到一半的事作廢，復活後從頭判斷（人物會在復活點，不是原本的地圖）
                st.hunted := 0
                if !st.HasOwnProp("deathNoted") || !st.deathNoted {
                    st.deathNoted := true
                    DhNotify("💀 每日討伐｜" p.name "｜跑任務途中死亡（" (IsObject(g) ? g.name : "回起點途中") "），先暫停，復活後自動繼續")
                }
            }
            st.text := "⏸ " e.Message "（稍後再試）"
            EventLog(p.name, "DH_STOP", e.Message "｜距離上次實體鍵鼠輸入 " A_TimeIdlePhysical " 毫秒")   ; 被「使用者在操作」叫停時，這個數字很小 = 剛剛真的有實體輸入
        } else {
            st.fails += 1
            wait := Min(600000, 30000 * (2 ** Min(st.fails - 1, 4)))
            st.next := A_TickCount + wait
            st.text := "⚠ " e.Message "｜" Round(wait / 60000, 1) " 分鐘後再試（連續第 " st.fails " 次）"
            EventLog(p.name, "DH_ERROR", d.action (IsObject(g) ? "｜" g.name : "") "｜" e.Message)
            if st.fails >= 3 {
                if IsObject(g) {
                    st.skip[g.map] := 1
                    AddRecentEvent("🎯 " p.name "：" g.name " 連續失敗，先略過這張圖：" e.Message)
                }
                st.fails := 0
            }
        }
    } finally {
        try DhCloseWindows(p)
        ApCleanup(p, false, minimized, prev, cursor, stopped)
        try DhStatRunEnd(p, A_TickCount - runT0)
        foregroundOwner := "", apBusy := false, apRunStart := 0, dhBusy := false, dhCurProfile := 0
    }
}
; 做完（或中途出錯）時，遊戲裡不要留著對話框 / 公車視窗
DhCloseWindows(p) {
    if ReadGameUiOpen(p.pid, "NewMap") = 1 && ApIsActive(p)
        DhCloseMap(p)
    Loop 3 {
        if ReadGameUiOpen(p.pid, "Bus") != 1 && ReadGameUiOpen(p.pid, "Dialogue") != 1
            return
        if !ApIsActive(p)
            return
        ApKey(p, "Escape")
        Sleep 400
    }
}

; 按 T 打開任務視窗讓遊戲向伺服器要最新進度，等一下再按 T 關起來。
DhActRefresh(p) {
    ApKey(p, "t")
    ApWait(() => (ApGuardAny(), false), 2500)   ; 等伺服器回應（逾時回傳 false 是預期的）；等的時候照樣守門
    ApKey(p, "t")
    Sleep 300
}

; 附近的某個怪 / NPC（名稱包含 name），回傳第一個；找不到回傳 0
DhFindCrow(pid, name) {
    cr := 0
    try cr := MiningCrows(pid, name)
    return IsObject(cr) && cr.Length ? cr[1] : 0
}

; ---------------------------------------------------------------- 鏡頭：拉到最遠、環繞旋轉，讓 NPC 一定看得到
; 鏡頭離人的距離（讀不到回傳 -1）
DhEyeDist(pid) {
    e := GameCameraEye(pid)
    me := MiningCharState(pid)
    if !IsObject(e) || !IsObject(me)
        return -1
    return Sqrt((e.x - me.x) ** 2 + (e.y - me.y) ** 2 + (e.z - me.z) ** 2)
}
; 滾輪把鏡頭拉到最遠。實測這個遊戲滾輪往上 = 拉遠（往下 = 拉近）：直接往上滾，再讀鏡頭距離確認沒有變近；
; 變近代表方向相反（別的版本 / 設定），改往另一邊滾回去，並記住方向。讀不到鏡頭就不動。
global dhWheelOut := -1
DhCameraZoomOut(p) {
    global dhWheelOut
    pid := p.pid
    d0 := DhEyeDist(pid)
    if d0 < 0
        return
    ApScrollMany(p, 512, 400, dhWheelOut, 25, 40)
    ApWait(() => (ApGuardAny(), false), 300)
    d1 := DhEyeDist(pid)
    flipped := false
    if d1 < d0 - 0.5 {
        dhWheelOut := -dhWheelOut, flipped := true
        ApScrollMany(p, 512, 400, dhWheelOut, 50, 40)
        ApWait(() => (ApGuardAny(), false), 300)
    }
    EventLog(p.name, "DH_CAMERA", "鏡頭拉遠｜距離 " Round(d0, 1) " → " Round(DhEyeDist(pid), 1) (flipped ? "（滾輪方向相反，已改）" : ""))
}
; 左右環繞鏡頭找 NPC：每次壓著中鍵拖 260 像素（左右交替），最多 6 次；轉完還看不到回傳 0。
; 第一次轉完鏡頭方向沒變 = 這個遊戲視窗吃不到中鍵拖曳，丟出錯誤（外面會改用走路）。
global dhOrbitMode := "abs"   ; 壓著中鍵拖曳的方式：abs = 移游標位置，rel = 相對移動（遊戲吃哪種就記住哪種）
DhRevealNpc(p, name) {
    global dhOrbitMode
    pid := p.pid
    Loop 6 {
        npc := DhFindCrow(pid, name)
        if !npc
            return 0
        sp := GameWorldToScreen(pid, npc.x, npc.y, npc.z)
        if IsObject(sp) && sp.visible
            return sp
        e0 := GameCameraEye(pid)
        ApOrbit(p, 512, 420, (A_Index & 1) ? 260 : -260, 14, 18, dhOrbitMode)
        ApWait(() => (ApGuardAny(), false), 300)
        e1 := GameCameraEye(pid)
        if A_Index = 1 && IsObject(e0) && IsObject(e1) && Abs(e1.fx - e0.fx) + Abs(e1.fz - e0.fz) < 0.02 {
            other := dhOrbitMode = "abs" ? "rel" : "abs"   ; 這種拖法沒反應：換另一種再試一次
            ApOrbit(p, 512, 420, -260, 14, 18, other)
            ApWait(() => (ApGuardAny(), false), 300)
            e2 := GameCameraEye(pid)
            if IsObject(e2) && Abs(e2.fx - e1.fx) + Abs(e2.fz - e1.fz) >= 0.02
                dhOrbitMode := other
            else
                throw Error("鏡頭轉不動（壓著中鍵拖曳，移游標和相對移動兩種都沒有反應）")
        }
    }
    return 0
}
; 做一件「不成功也沒關係」的事：出錯只寫日誌、照樣往下做；但「停止」類的錯誤一定要往外丟
DhSoft(p, what, fn) {
    try fn()
    catch as e {
        if e.Extra = "stop"
            throw e
        EventLog(p.name, "DH_CAMERA", what "失敗：" e.Message "｜改用其他方式")
    }
}

; 看不到 NPC：不點地板、不亂走。用大地圖點「NPC 所在的座標」走到她旁邊（起點每次不同，但她的位置從記憶體讀得到，不用靠畫面），
; 到了再投影一次；還是被擋住才壓中鍵環繞鏡頭。大地圖走不過去或讀不到就只寫日誌，由鏡頭環繞接手。
DhApproachNpc(p, name, minDist := 250, stopDist := 18, offset := 25) {
    npc := DhFindCrow(p.pid, name)
    me := MiningCharState(p.pid)
    if !npc || !IsObject(me)
        return
    d := Sqrt((npc.x - me.x) ** 2 + (npc.z - me.z) ** 2)
    if d < minDist
        return
    EventLog(p.name, "DH_CAMERA", "看不到「" name "」，用大地圖走到她旁邊｜人物 (" Round(me.x) "," Round(me.z) ")｜她 (" Round(npc.x) "," Round(npc.z) ")｜距離 " Round(d))
    ; 目標點不是她本人的座標（NPC 站的地方人物走不上去，會一直微調 / 卡住），而是「她旁邊」：人物這一側、離她 offset（預設 25）單位的位置
    ux := d < 1 ? 1 : (me.x - npc.x) / d, uz := d < 1 ? 0 : (me.z - npc.z) / d
    gx := npc.x + ux * Min(offset, d), gz := npc.z + uz * Min(offset, d)
    DhRunTowardMap(p, gx, gz, stopDist)
    ApWait(() => (ApGuardAny(), false), 400)
}
; NPC 現在在畫面上的位置（h = 離地高度：點 NPC 身體而不是腳下，鏡頭拉遠時身體變小也一樣準）。
; 不在畫面內：先用大地圖走到她旁邊；還是看不到再壓中鍵環繞鏡頭；都不行就停手（不點地板亂走）。
DhNpcScreen(p, name, h := 0) {
    pid := p.pid
    Loop 4 {
        npc := DhFindCrow(pid, name)
        if !npc
            throw Error("找不到「" name "」")
        sp := GameWorldToScreen(pid, npc.x, npc.y, npc.z)
        if !IsObject(sp)
            throw Error("讀不到畫面投影（無法算「" name "」的位置）")
        if !sp.visible || !DhScreenFree(sp) {   ; 在畫面外，或投影到聊天視窗 / 技能列等介面後面（點下去點到的是介面，不是她）
            if A_Index = 1
                DhSoft(p, "用大地圖走到「" name "」旁邊", () => DhApproachNpc(p, name, 30, 18, 25))
            else if A_Index = 2   ; 還被擋住：再靠近一點
                DhSoft(p, "再靠近「" name "」", () => DhApproachNpc(p, name, 15, 10, 8))
            else if A_Index = 3
                DhSoft(p, "旋轉鏡頭找「" name "」", () => DhRevealNpc(p, name))
            else
                throw Error("走到旁邊也轉過鏡頭，還是看不到「" name "」")
            continue
        }
        if h > 0 {
            sp2 := GameWorldToScreen(pid, npc.x, npc.y + h, npc.z)
            if IsObject(sp2) && sp2.visible && DhScreenFree(sp2)
                return sp2
        }
        return sp
    }
}
; 畫面上這個點沒有被介面蓋住（1024x768：左上狀態列、左邊技能列、左下聊天視窗、右上羅盤、右下快捷欄）
DhScreenFree(sp) {
    x := sp.x, y := sp.y
    if x < 12 || y < 12 || x > 1012 || y > 756
        return false
    if x < 450 && y < 112   ; 左上：HP / 技能圖示
        return false
    if x < 40 && y < 415    ; 左邊技能列
        return false
    if x < 445 && y > 405   ; 左下：聊天視窗
        return false
    if x > 890 && y < 135   ; 右上：羅盤 / 地圖名稱
        return false
    if x > 665 && y > 655   ; 右下：快捷欄 / 技能
        return false
    return true
}
; 自動打怪（F6）開著就按 F6 關掉，讀回確認；關不掉（按兩次都沒關）就停手。讀不到狀態時不動（不亂按開關）。
DhEnsureAutoHuntOff(p) {
    pid := p.pid
    if ReadGameAutoHunt(pid) != 1
        return
    Loop 2 {
        ApKey(p, "F6")
        if ApWait(() => (ApGuardAny(), ReadGameAutoHunt(pid) = 0), 4000) {
            EventLog(p.name, "DH_F6_OFF", "點 NPC 之前自動打怪還開著，已按 F6 關掉")
            ApWait(() => (ApGuardAny(), false), 500)
            return
        }
    }
    throw Error("自動打怪（F6）關不掉，點 NPC 會沒有反應")
}

; 在公車清單裡選到第 idx 筆（0 起算；count = 清單總筆數）。
; 1. 直接讀文字框的「頁首第幾行」確認捲到最底（捲太快遊戲會漏掉滾輪，沒到就再捲，最多 6 次）；
; 2. 算出那一筆在第幾列，游標移到那一列：讀「滑鼠停在第幾行」，對了才點（不管遊戲怎麼算列的邊界，
;    例如框 283 高 / 20 行 = 每行 14.15 而不是 14.05；上下 ±9 像素內找到對的位置）；
; 3. 點完讀回「選到第幾筆」確認。讀不到文字框資料、或游標怎麼移都對不上，退回「點了再讀回」的做法。
DhBusSelect(p, g, idx, count) {
    global DH_BUS_LIST_X
    pid := p.pid
    L := ReadGameBusList(pid)
    if IsObject(L) && L.total = count {
        Loop 6 {
            if L.cur >= L.total - L.visible
                break
            ApScrollMany(p, DH_BUS_LIST_X, 300, 1, A_Index = 1 ? 14 : 8, 90)
            ApWait(() => (ApGuardAny(), false), 300)
            L := ReadGameBusList(pid)
            if !IsObject(L)
                break
        }
        if IsObject(L) {
            if L.cur < L.total - L.visible
                throw Error("公車清單捲不到最底（頁首第 " (L.cur + 1) " 筆，應該是第 " (L.total - L.visible + 1) " 筆）")
            row := idx - L.cur
            if row < 0 || row >= L.visible
                throw Error(g.name " 不在目前顯示的那一頁（第 " (idx + 1) " 筆，頁首第 " (L.cur + 1) " 筆）")
            if DhBusHoverClick(p, L, row, idx)
                return
            DhBusClickCorrect(p, g, L, row, idx)   ; 頁首已知：直接點算出的那一列，沒中就依「選到第幾筆」補（不用先點最上面一格推頁首，那一下會留下舊的選取）
            return
        }
    }
    DhBusSelectByClick(p, g, idx, count)
}
; 頁首已知時的點擊：點算出的位置，等遊戲更新。
;  - 點完「選到哪筆」完全沒變 = 這一下沒被遊戲收到：不挪位置，加長按住的時間（220 → 350 → 480 毫秒）再點同一個位置；
;  - 變了但選錯 = 位置差幾列：差幾列就往上 / 往下挪幾列（每列 height/visible 像素）再點。最多 4 次。
DhBusClickCorrect(p, g, L, row, idx) {
    global DH_BUS_LIST_X
    pid := p.pid
    pitch := L.height / L.visible
    y := L.top + (row + 0.5) * pitch
    sel := -1, hold := 220
    Loop 4 {
        b0 := ReadGameBusWindow(pid)
        before := IsObject(b0) ? b0.sel : -1
        t0 := A_TickCount
        ApClick(p, DH_BUS_LIST_X, Round(y), hold)
        ApWait(() => (ApGuardAny(), DhBusSelIs(pid, idx)), 1500)
        bus := ReadGameBusWindow(pid)
        sel := IsObject(bus) ? bus.sel : -1
        R := ReadGameBusList(pid)
        EventLog(p.name, "DH_BUS", "補點第 " A_Index " 次｜目標第 " (idx + 1) " 筆｜y=" Round(y) "｜按住 " hold " 毫秒｜滑鼠停在 " (IsObject(R) ? R.over : "?") "｜點之前 " (before + 1) " → 選到 " (sel + 1) "｜等了 " (A_TickCount - t0) " 毫秒")
        if sel = idx
            return
        if sel = before
            hold += 130   ; 完全沒變：這一下沒被收到，按久一點
        else if sel >= 0
            y += (idx - sel) * pitch   ; 選到的列和要的差幾列，就往上 / 往下挪幾列
    }
    throw Error("公車清單沒點到 " g.name "（選到第 " (sel + 1) " 筆，要第 " (idx + 1) " 筆）")
}
; 頁首讀不到時的備援
; 目前選到的是不是第 idx 筆
DhBusSelIs(pid, idx) {
    bus := ReadGameBusWindow(pid)
    return IsObject(bus) && bus.sel = idx
}
; 游標移到第 row 列附近，滑鼠停在對的那一行才點；點完選到第 idx 筆回傳 true
DhBusHoverClick(p, L, row, idx) {
    global DH_BUS_LIST_X
    pid := p.pid
    y0 := L.top + (row + 0.5) * (L.height / L.visible)
    for dy in [0, 3, -3, 6, -6, 9, -9] {
        y := Round(y0 + dy)
        ApHover(p, DH_BUS_LIST_X, y)
        ApWait(() => (ApGuardAny(), false), 90)
        R := ReadGameBusList(pid)
        if IsObject(R) && (R.over = row || R.over = idx) {
            t0 := A_TickCount
            ApClick(p, DH_BUS_LIST_X, y, 220)   ; 按住 220 毫秒（預設 90 會被遊戲漏掉）
            ApWait(() => (ApGuardAny(), DhBusSelIs(pid, idx)), 1500)   ; 遊戲更新「選到哪筆」要一點時間：等它，不要點完馬上讀
            bus := ReadGameBusWindow(pid)
            EventLog(p.name, "DH_BUS", "目標第 " (idx + 1) " 筆（列 " row "）｜y=" y "｜滑鼠停在 " R.over "｜點完選到 " (IsObject(bus) ? bus.sel + 1 : "?") "｜等了 " (A_TickCount - t0) " 毫秒")
            return IsObject(bus) && bus.sel = idx
        }
    }
    return false
}
; 備援（讀不到文字框資料才用）：每捲一次就點最上面一格、讀回「選到第幾筆」算出頁首；到了最底再點目標那一格，讀回確認。
DhBusSelectByClick(p, g, idx, count) {
    global DH_BUS_LIST_X, DH_BUS_ROW0_Y, DH_BUS_ROW_H, DH_BUS_BOTTOM_ROWS
    pid := p.pid
    bottomFirst := count - DH_BUS_BOTTOM_ROWS
    row := idx - bottomFirst
    if row < 0
        throw Error(g.name " 不在公車清單最底那一頁（第 " (idx + 1) " 筆）")    ; 5. 捲到最底：每捲一次就點最上面一格、讀回「選到第幾筆」，算出清單現在從第幾筆開始顯示
    ;    （捲太快遊戲會漏掉滾輪，所以要讀回確認；還沒到最底就再捲，最多 5 次），到了最底再點目標那一格
    offset := -1
    Loop 5 {
        ApScrollMany(p, DH_BUS_LIST_X, 300, 1, A_Index = 1 ? 14 : 8, 90)
        ApWait(() => (ApGuardAny(), false), 300)
        ApClick(p, DH_BUS_LIST_X, DH_BUS_ROW0_Y)
        ApWait(() => (ApGuardAny(), false), 400)
        bus := ReadGameBusWindow(pid)
        if !IsObject(bus)
            throw Error("讀不到公車清單")
        if bus.sel >= 0 {
            offset := bus.sel
            if offset >= bottomFirst
                break
        }
    }
    if offset < bottomFirst
        throw Error("公車清單捲不到最底（" (offset < 0 ? "讀不到頁首" : "頁首是第 " (offset + 1) " 筆，應該是第 " (bottomFirst + 1) " 筆") "）")
    row := idx - offset
    if row < 0 || row >= DH_BUS_BOTTOM_ROWS
        throw Error(g.name " 不在目前顯示的那一頁（第 " (idx + 1) " 筆，頁首第 " (offset + 1) " 筆）")
    ok := false
    Loop 2 {
        ApClick(p, DH_BUS_LIST_X, Round(DH_BUS_ROW0_Y + row * DH_BUS_ROW_H))
        ApWait(() => (ApGuardAny(), DhBusSelIs(pid, idx)), 1500)
        bus := ReadGameBusWindow(pid)
        if IsObject(bus) && bus.sel = idx {
            ok := true
            break
        }
        if IsObject(bus) && bus.sel >= 0
            row += idx - bus.sel   ; 點偏了幾格就補幾格
        if row < 0 || row >= DH_BUS_BOTTOM_ROWS
            break
    }
    if !ok
        throw Error("公車清單沒點到 " g.name "（選到第 " (IsObject(bus) ? bus.sel + 1 : "?") " 筆，要第 " (idx + 1) " 筆）")
}

; 用起點傳送卡回起點（人物的出生 / 復活點）。換圖，或人物位置跳了 400 單位以上，就算到了；再等人物能動。
DhReturnStart(p) {
    global DH_START_CARD
    pid := p.pid
    info := DailyQuickInfo(pid, DH_START_CARD)
    if !IsObject(info) || info.key = ""
        throw Error("道具快捷欄找不到「" DH_START_CARD "」")
    DhEnsureAutoHuntOff(p)
    old := DhMapMain(pid), m0 := MiningCharState(pid)
    ApKey(p, info.key)
    jumped := () => (DhMapMain(pid) != old && DhMapMain(pid) != -1) || (IsObject(m1 := MiningCharState(pid)) && IsObject(m0) && Sqrt((m1.x - m0.x) ** 2 + (m1.z - m0.z) ** 2) > 400)
    if !ApWait(() => (ApGuardAny(), jumped()), 25000)
        throw Error("按了「" DH_START_CARD "」但人物沒有回到起點")
    ApWait(() => (ApGuardAny(), ApReady(p)), 15000)
    ApWait(() => (ApGuardAny(), false), 1500)
    EventLog(p.name, "DH_RETURN", "已用「" DH_START_CARD "」回起點｜地圖 " DhMapMain(pid))
}

; 發 Discord 通知（沒設定 Discord 或送不出去就算了，只留日誌）
DhNotify(text) {
    EventLog("GLOBAL", "DH_NOTIFY", text)
    try SendDiscordMessage(text)
}

; 真正跑任務時：某張勾選的圖從「沒打滿」變成「打滿」，通知一次（啟動時就已經打滿的不通知）
DhNoteProgress(p, tasks) {
    global DH_MAPS_ON
    st := DhSt(p)
    for r in tasks.rows
        for g in r.goals {
            if !DH_MAPS_ON.Has(g.map)
                continue
            if g.done < g.target
                st.seen[g.map] := 1
            else if st.seen.Has(g.map) && !st.notified.Has(g.map) {
                st.notified[g.map] := 1
                DhNotify("✅ 每日討伐｜" p.name "｜" g.name "｜" g.done " / " g.target " 完成")
            }
        }
}

; 測試流程：走到這張圖的固定點就算完成（沒有固定點：略過並通知），然後回起點，下一張。
DhActTestWalk(p, g) {
    global DH_SPOTS, DH_SPOT_STOP
    st := DhSt(p)
    pid := p.pid
    spot := DH_SPOTS.Get(g.map, 0)
    if !IsObject(spot) {
        st.testDone[g.map] := 1
        DhNotify("🧪 每日討伐測試｜" p.name "｜" g.name "｜沒有設定固定點，略過")
        DhReturnStart(p)
        return
    }
    me := MiningCharState(pid)
    if !IsObject(me)
        throw Error("讀不到人物位置")
    t0 := A_TickCount
    EventLog(p.name, "DH_TEST", g.name "｜走到固定點 (" Round(spot.x) "," Round(spot.z) ")｜距離 " Round(Sqrt((spot.x - me.x) ** 2 + (spot.z - me.z) ** 2)))
    try DhMoveTo(p, spot.x, spot.z, DH_SPOT_STOP)
    catch as e {
        if e.Extra = "stop"
            throw e
        throw Error(e.Message "｜這個固定點可能走不到（牆 / 圍欄 / 不能走的格子），請讓人物在遊戲裡真的走到想去的位置，再按「記錄」重存")
    }
    me := MiningCharState(pid)
    d := IsObject(me) ? Sqrt((spot.x - me.x) ** 2 + (spot.z - me.z) ** 2) : 99999
    if d > DH_SPOT_STOP * 3
        throw Error("沒有走到固定點（還差 " Round(d) "）｜這個固定點可能走不到，請讓人物在遊戲裡真的走到想去的位置，再按「記錄」重存")
    st.testDone[g.map] := 1
    DhNotify("🧪 每日討伐測試｜" p.name "｜" g.name "｜已走到固定點 (" Round(spot.x) "," Round(spot.z) ")，差 " Round(d) "，用了 " Round((A_TickCount - t0) / 1000) " 秒")
    DhReturnStart(p)
}

; 全部做完：關自動打怪、用起點傳送卡回起點（復活點）、通報 Discord；這個角色之後不再動作（隔天 00:00 任務換了才重來）。
DhActFinish(p) {
    global DH_NPC_NAME
    st := DhSt(p)
    finT0 := A_TickCount
    npc := DhFindCrow(p.pid, DH_NPC_NAME), me := MiningCharState(p.pid)
    if IsObject(npc) && IsObject(me) && Sqrt((npc.x - me.x) ** 2 + (npc.z - me.z) ** 2) <= 400
        EventLog(p.name, "DH_RETURN", "人物已經在起點（「" DH_NPC_NAME "」就在附近），不用再按傳送卡")
    else
        DhReturnStart(p)
    st.done := true
    st.text := "✅ 指定任務全部完成，已回起點"
    DhNotify("🎉 每日討伐｜" p.name "｜指定任務全部完成，已用起點傳送卡回到復活點")
    AddRecentEvent("🎯 " p.name "：指定任務全部完成，已回起點")
    try DhStatFinish(p, A_TickCount - finT0)   ; 每張圖花的時間 + 總時長
    try DhSchedFinish(p)                       ; 定時啟動的：跑完自動停止
}
; 選好地圖後，下方「公車站」清單會出現入口：要先點第一行（入口）再按確定，不點的話確定沒有反應。
DhBusPickGate(p) {
    global DH_BUS_LIST_X
    pid := p.pid
    gl := 0
    ApWait(() => (ApGuardAny(), (gl := ReadGameBusGateList(pid)) != 0 && gl.total > 0), 2500)   ; 入口清單跟著地圖選取才長出來
    if !IsObject(gl) || gl.total < 1 {
        EventLog(p.name, "DH_BUS_GATE", "讀不到入口清單，照舊直接按確定")
        return
    }
    y := Round(gl.top) + 9
    for hold in [200, 300, 450] {
        ApClick(p, DH_BUS_LIST_X, y, hold)
        ApWait(() => (ApGuardAny(), false), 500)
        gl := ReadGameBusGateList(pid)
        if !IsObject(gl) || gl.sel >= 0
            return
    }
    EventLog(p.name, "DH_BUS_GATE", "點了入口三次，清單仍沒有選取，照舊按確定")
}
; 搭公車這一段（點 NPC、選地圖、點入口、確定）游標用平順移動，不是瞬間跳過去。
DhActTravel(p, g) {
    global apSmooth
    apSmooth := true
    try
        DhActTravelCore(p, g)
    finally
        apSmooth := false
}
; 回起點 → 點麗娜 → 公車站2號線 → 捲到最底 → 點地圖 → 點入口 → 確定 → 等換圖
DhActTravelCore(p, g) {
    global DH_NPC_NAME, DH_START_CARD, DH_BUS_OPTION_X, DH_BUS_LIST_X, DH_BUS_ROW0_Y, DH_BUS_ROW_H, DH_BUS_OK_X, DH_BUS_OK_Y, DH_BUS_BOTTOM_ROWS, DH_NPC_ROW, DH_BUS_OPTION_Y0, DH_BUS_OPTION_PITCH
    pid := p.pid
    DhSt(p).hunted := 0
    ; 1. 麗娜不在附近 → 先用起點傳送卡回起點
    if !DhFindCrow(pid, DH_NPC_NAME) {
        DhReturnStart(p)
        if !ApWait(() => (ApGuardAny(), ApReady(p) && DhFindCrow(pid, DH_NPC_NAME) != 0), 30000)
            throw Error("按了起點傳送卡但附近還是看不到「" DH_NPC_NAME "」")
        ApWait(() => (ApGuardAny(), false), 1500)
    }
    ; 2. 點 NPC（人物會自己跑過去）→ 對話框出現。自動打怪（F6）開著的話人物會一直去找怪，點 NPC 沒有反應：點之前一定先確認它是關的
    opened := false
    DhSoft(p, "鏡頭拉遠", () => DhCameraZoomOut(p))   ; 每次回來視角都不一樣：先拉到最遠
    for h in [10, 16, 5] {
        DhEnsureAutoHuntOff(p)
        if A_Index = 2   ; 第一下沒開：可能離太遠 / 被別人擋住。用大地圖走到她身邊（約 90 單位）再點
            DhSoft(p, "走到「" DH_NPC_NAME "」身邊", () => DhApproachNpc(p, DH_NPC_NAME, 40, 18, 20))
        else if A_Index = 3   ; 還不行：轉鏡頭換個角度
            DhSoft(p, "旋轉鏡頭找「" DH_NPC_NAME "」", () => DhRevealNpc(p, DH_NPC_NAME))
        sp := DhNpcScreen(p, DH_NPC_NAME, h)
        npcD := DhFindCrow(pid, DH_NPC_NAME), meD := MiningCharState(pid)
        EventLog(p.name, "DH_CAMERA", "點「" DH_NPC_NAME "」第 " A_Index " 次｜畫面 (" Round(sp.x) "," Round(sp.y) ")｜高度 " h "｜距離 " (IsObject(npcD) && IsObject(meD) ? Round(Sqrt((npcD.x - meD.x) ** 2 + (npcD.z - meD.z) ** 2)) : "?"))
        ApClick(p, sp.x, sp.y, 160)
        if ApWait(() => (ApGuardAny(), ReadGameUiOpen(pid, "Dialogue") = 1), 9000) {
            opened := true
            break
        }
    }
    if !opened
        throw Error("點了「" DH_NPC_NAME "」但對話框沒有出現")
    ; 3. 「公車站2號線」→ 公車視窗
    ApWait(() => (ApGuardAny(), false), 600)   ; 對話框剛出現，選項還在長出來：多等一下再點
    busOpen := false
    for hold in [200, 300, 400] {   ; 沒開就換更長的按住時間再點一次
        ApClick(p, DH_BUS_OPTION_X, DH_BUS_OPTION_Y0 + (DH_NPC_ROW - 1) * DH_BUS_OPTION_PITCH, hold)
        if ApWait(() => (ApGuardAny(), ReadGameUiOpen(pid, "Bus") = 1), 3500) {
            busOpen := true
            break
        }
        if ReadGameUiOpen(pid, "Dialogue") != 1
            break
    }
    if !busOpen
        throw Error("點了公車站但公車視窗沒有出現")
    ApWait(() => (ApGuardAny(), (b0 := ReadGameBusWindow(pid)) != 0 && b0.maps.Length > 0), 3000)   ; 公車清單載入要時間：讀到清單就往下，不死等
    ApWait(() => (ApGuardAny(), false), 250)
    ; 4. 從遊戲讀公車清單，算出目標地圖在最底那頁的第幾格
    bus := ReadGameBusWindow(pid)
    if !IsObject(bus) || !bus.maps.Length
        throw Error("讀不到公車清單")
    idx := -1
    for i, m in bus.maps
        if m = g.map {
            idx := i - 1
            break
        }
    if idx < 0
        throw Error("公車清單裡沒有 " g.name)
    DhBusSelect(p, g, idx, bus.maps.Length)
    ApWait(() => (ApGuardAny(), false), 400)   ; 選好之後停一下再按確定
    DhBusPickGate(p)
    arrivedMap := false
    for hold in [220, 320, 450] {   ; 確定沒按到（公車視窗還開著、地圖也沒換）就換更長的按住時間再按
        if ReadGameUiOpen(pid, "Bus") = 1 {
            bs := ReadGameBusWindow(pid)
            if IsObject(bs) && bs.HasOwnProp("sel") && bs.sel != idx
                DhBusSelect(p, g, idx, bus.maps.Length)   ; 選取跑掉了：重選
            ApClick(p, DH_BUS_OK_X, DH_BUS_OK_Y, hold)
        }
        if ApWait(() => (ApGuardAny(), DhMapMain(pid) = g.map), hold = 450 ? 30000 : 6000) {
            arrivedMap := true
            break
        }
    }
    if !arrivedMap
        throw Error("按了確定但沒有到 " g.name)
    EventLog(p.name, "DH_ARRIVE", "已搭公車到 " g.name)
    ApWait(() => (ApGuardAny(), false), 3000)   ; 新地圖載入
}

; ---------------------------------------------------------------- 找怪最多的地方 → 走過去 → 開自動打怪
; 遊戲記憶體裡有整張圖的怪（讀得到幾百隻），不用開地圖找紅點：找出目標怪最密集的一群，用地面點擊一段一段走過去。
global DH_HUNT_STOP_NEAR := 150, DH_SEG_MAX_MS := 9000, DH_IDLE_MS := 1200
global DH_MAP_SHORT := [[0.4, 0], [0.2, 0], [0.4, 40], [0.4, -40], [0.4, 90], [0.4, -90], [0.2, 140], [0.2, -140], [0.1, 0]]   ; 走不動時依序試的路徑點（框半徑的幾成, 偏離目標方向幾度）
global DH_SPOT_STOP := 30   ; 固定點：走到離它 30 單位內（地圖小的時候 80 看起來像沒走到）
global DH_CLUSTER_R := 400, DH_HUNT_STOP := 80   ; 走到離目標點 80 單位內才按 F6（太大會停在入口附近）

; 目標怪（活的）最密集的地方。有些圖（電算室、機械區、黑暗後裔集結區）怪不是一坨一坨，而是平均鋪滿、中間最密，
; 所以不從怪身上算，而是在整張圖掃描格點，找「周圍 radius 內怪最多」的中心（數量多優先，距離每 500 單位抵掉一隻打破平手），
; 再走到離那個中心最近的那隻怪旁邊（怪站的地方一定走得到，不會選到牆裡）。
; cr：[{x,y,z,hp}]；me：{x,z}；回傳 {x,y,z,count,dist}（count = 中心周圍的怪數）；沒有活的回傳 0。
DhBestCluster(cr, me, radius := 400) {
    xs := [], zs := [], alive := []
    for c in cr
        if c.hp > 0
            alive.Push(c), xs.Push(c.x), zs.Push(c.z)
    if !alive.Length
        return 0
    minx := maxx := xs[1], minz := maxz := zs[1]
    for v in xs
        minx := Min(minx, v), maxx := Max(maxx, v)
    for v in zs
        minz := Min(minz, v), maxz := Max(maxz, v)
    step := 60
    while ((maxx - minx) / step + 1) * ((maxz - minz) / step + 1) > 2500   ; 地圖很大時放大格距，掃描不超過約 2500 格
        step += 30
    r2 := radius ** 2
    bestS := -1e18, bx := minx, bz := minz, bn := 0
    x := minx
    while x <= maxx + 0.01 {
        z := minz
        while z <= maxz + 0.01 {
            n := 0
            for i, ox in xs
                if (ox - x) ** 2 + (zs[i] - z) ** 2 <= r2
                    n += 1
            s := n - Sqrt((x - me.x) ** 2 + (z - me.z) ** 2) / 500
            if s > bestS
                bestS := s, bx := x, bz := z, bn := n
            z += step
        }
        x += step
    }
    best := alive[1], bd := 1e18
    for c in alive {
        d := (c.x - bx) ** 2 + (c.z - bz) ** 2
        if d < bd
            best := c, bd := d
    }
    return {x: best.x, y: best.y, z: best.z, count: bn, dist: Sqrt((best.x - me.x) ** 2 + (best.z - me.z) ** 2)}
}
; 就近的一群：周圍 radius 內至少有 minN 隻（怪少於 minN 隻就以怪的總數為準）的怪裡，離人最近的那一隻。
; 沒有任何一群夠大就退而求其次選離人最近的一隻。回傳格式和 DhBestCluster 一樣。
DhNearestCluster(cr, me, radius := 300, minN := 4) {
    alive := []
    for c in cr
        if c.hp > 0
            alive.Push(c)
    if !alive.Length
        return 0
    need := Min(minN, alive.Length)
    best := 0, bd := 1e18, near := 0, nd := 1e18
    r2 := radius ** 2
    for c in alive {
        d := Sqrt((c.x - me.x) ** 2 + (c.z - me.z) ** 2)
        if d < nd
            near := {x: c.x, y: c.y, z: c.z, count: 1, dist: d}, nd := d
        n := 0
        for o in alive
            if (o.x - c.x) ** 2 + (o.z - c.z) ** 2 <= r2
                n += 1
        if n >= need && d < bd
            best := {x: c.x, y: c.y, z: c.z, count: n, dist: d}, bd := d
    }
    return best ? best : near
}

; 點擊位置限制在畫面中間（避開左邊技能列、上方狀態列、左下聊天框、右下快捷欄）
; 畫面上不能點的區塊 {l, t, r, b}（遊戲畫面座標）：自動採礦讓背包一直開著時，地面點擊會閃開背包視窗（點在視窗上不會走路）。0 = 沒有。
global DH_UI_BLOCK := 0
DhSafeClick(sx, sy) {
    global DH_UI_BLOCK
    c := {x: Round(Min(950, Max(70, sx))), y: Round(Min(560, Max(90, sy)))}
    if IsObject(DH_UI_BLOCK) && c.x >= DH_UI_BLOCK.l && c.x <= DH_UI_BLOCK.r && c.y >= DH_UI_BLOCK.t && c.y <= DH_UI_BLOCK.b
        c.x := Max(70, DH_UI_BLOCK.l - 12)
    return c
}

; ---------------------------------------------------------------- 用大地圖（M）走路：開地圖 → 一直左鍵點目的地 → 到了關地圖
; 遊戲自己的「點地圖自動走過去」會自己繞路；被怪打到會取消移動，所以一直點（每次點完等不到 1 秒就再點）。
;
; 世界座標 → 地圖像素是確定的（遊戲的 CONVERT_WORLD2MAP：x 照比例，z 要翻轉，北在上）：
;   地圖像素 mx = (x − 世界起點x) × 貼圖寬 ÷ 世界寬；my = (世界起點y + 世界高 − z) × 貼圖高 ÷ 世界高。
; 地圖像素 → 螢幕則隨地圖捲動而變：螢幕 sx = mx − K.x + 地圖框左；sy = my − K.y + 地圖框上，K 是目前的捲動偏移。
; 不去猜遊戲欄位（VIEW_START、renderPos、scrollGap）各自是什麼意思——實測它們有時已經包含捲動、有時沒有，公式一重複就偏到方向相反——
; 而是直接量 K：
;   ① 玩家標記（代表人物的小點）每個畫面都會更新：它畫在螢幕哪裡 + 人物的世界座標 → K（不用點擊）；
;   ② 每點一下，遊戲會記下「目標」的地圖像素：點的螢幕位置 + 它記的像素 → K，並學到標記的中心偏差，之後用「目前的標記 + 偏差」。
DhMapPx(pg, wx, wz) => {x: (wx - pg.startX) * pg.texX / pg.sizeX, y: (pg.startY + pg.sizeY - wz) * pg.texY / pg.sizeY}
; 地圖像素 → 世界座標（CONVERT_MAP2WORLD）
DhMapPixToWorld(pg, mx, my) => {x: pg.startX + mx * pg.sizeX / pg.texX, z: pg.startY + pg.sizeY - my * pg.sizeY / pg.texY}
; 遊戲現在記的「目標」（地圖像素）換成世界座標；還沒點過 / 讀不到回傳 0
DhMapTargetWorld(pg) => (pg.tx = -2147483648 || pg.ty = -2147483648) ? 0 : DhMapPixToWorld(pg, pg.tx, pg.ty)
; K ①：玩家標記 + 人物世界座標；沒有標記資料回傳 0
DhMapKFromMark(pg, me) {
    if !pg.HasOwnProp("markX") || !IsObject(me)
        return 0
    c := DhMapPx(pg, me.x, me.z)
    return {x: c.x - (pg.markX - pg.left), y: c.y - (pg.markY - pg.top)}
}
; K ②：點了螢幕 (sx,sy) 之後，遊戲記的目標地圖像素
DhMapKFromClick(pg, sx, sy) => {x: pg.tx - (sx - pg.left), y: pg.ty - (sy - pg.top)}
; 世界座標 → 螢幕座標
DhMapScreenPoint(pg, K, wx, wz) {
    p := DhMapPx(pg, wx, wz)
    return {x: p.x - K.x + pg.left, y: p.y - K.y + pg.top}
}

; 要點的畫面位置：目的地在地圖框內就直接點它；不在框內（大地圖只顯示一部分）就點「人物到目的地連線和框邊的交點」，
; 人物走過去之後地圖會跟著移動，下一輪再算。回傳 {x, y, inside}
DhMapAim(pg, K, me, tx, tz) {
    m := 14
    xl := pg.left + m, xr := pg.right - m, yt := pg.top + m, yb := pg.bottom - m
    dst := DhMapScreenPoint(pg, K, tx, tz)
    if dst.x >= xl && dst.x <= xr && dst.y >= yt && dst.y <= yb
        return {x: dst.x, y: dst.y, inside: true, wx: tx, wz: tz}
    cur := DhMapScreenPoint(pg, K, me.x, me.z)
    if cur.x < xl || cur.x > xr || cur.y < yt || cur.y > yb {   ; 人物自己也不在框內：直接把目的地夾進框裡
        cx2 := Min(xr, Max(xl, dst.x)), cy2 := Min(yb, Max(yt, dst.y))
        w2 := DhMapPixToWorld(pg, cx2 - pg.left + K.x, cy2 - pg.top + K.y)
        return {x: cx2, y: cy2, inside: false, wx: w2.x, wz: w2.z}
    }
    dx := dst.x - cur.x, dy := dst.y - cur.y, kk := 1
    if dx > 0
        kk := Min(kk, (xr - cur.x) / dx)
    else if dx < 0
        kk := Min(kk, (xl - cur.x) / dx)
    if dy > 0
        kk := Min(kk, (yb - cur.y) / dy)
    else if dy < 0
        kk := Min(kk, (yt - cur.y) / dy)
    kk := Max(0, kk) * 0.7   ; 不點框邊：往目標方向走框邊的 70%（框邊可能是地圖圖片以外、按鈕或空白）
    ax := cur.x + dx * kk, ay := cur.y + dy * kk
    w := DhMapPixToWorld(pg, ax - pg.left + K.x, ay - pg.top + K.y)
    wx := Min(pg.startX + pg.sizeX - 40, Max(pg.startX + 40, w.x)), wz := Min(pg.startY + pg.sizeY - 40, Max(pg.startY + 40, w.z))   ; 路徑點不能落在地圖範圍外
    s := DhMapScreenPoint(pg, K, wx, wz)
    return {x: s.x, y: s.y, inside: false, wx: wx, wz: wz}
}

; 讀到的大地圖資料合理嗎？（遊戲換圖 / 剛開地圖時偶爾讀到亂的數字，例如世界大小幾十億，拿去算會點到完全錯的地方）
DhMapPageOk(pg) {
    if pg.sizeX < 500 || pg.sizeY < 500 || pg.sizeX > 30000 || pg.sizeY > 30000 || pg.texX < 128 || pg.texY < 128 || pg.texX > 8192 || pg.texY > 8192
        return false
    if pg.right - pg.left < 150 || pg.bottom - pg.top < 150
        return false
    if pg.HasOwnProp("markX") && (pg.markX < pg.left - 5 || pg.markX > pg.right + 5 || pg.markY < pg.top - 5 || pg.markY > pg.bottom + 5)   ; 玩家標記一定畫在框裡
        return false
    return true
}

; 走不動時的短路徑點：遊戲自己的找路有距離限制 / 起點被圍住時，遠處的點會被拒絕（不走、也不記目標）。
; 改點「離人物近一點、換個角度」的點：frac = 框半徑的幾成，ang = 偏離目標方向幾度。回傳同 DhMapAim。
DhMapAimShort(pg, K, me, tx, tz, frac, ang) {
    cur := DhMapScreenPoint(pg, K, me.x, me.z)
    dst := DhMapScreenPoint(pg, K, tx, tz)
    dx := dst.x - cur.x, dy := dst.y - cur.y
    len := Max(1, Sqrt(dx * dx + dy * dy))
    r := Min(len, frac * 0.5 * Min(pg.right - pg.left, pg.bottom - pg.top))
    a := ang * 3.14159265 / 180
    ux := (dx * Cos(a) - dy * Sin(a)) / len, uy := (dx * Sin(a) + dy * Cos(a)) / len
    w := DhMapPixToWorld(pg, cur.x + ux * r - pg.left + K.x, cur.y + uy * r - pg.top + K.y)
    wx := Min(pg.startX + pg.sizeX - 40, Max(pg.startX + 40, w.x)), wz := Min(pg.startY + pg.sizeY - 40, Max(pg.startY + 40, w.z))
    s := DhMapScreenPoint(pg, K, wx, wz)
    return {x: s.x, y: s.y, inside: false, wx: wx, wz: wz}
}

; 做完（或出錯）把大地圖關掉（M 是開關：先看是不是開著）
DhCloseMap(p) {
    pid := p.pid
    Loop 2 {
        if ReadGameUiOpen(pid, "NewMap") != 1
            return
        try {
            ApKey(p, "m")
            ApWait(() => (ApGuardAny(), ReadGameUiOpen(pid, "NewMap") != 1), 1500)
        }
    }
}

; 遊戲「目標」有更新（和點之前不一樣）就回傳新的頁面資料，否則 0
DhMapTargetChanged(pid, before) {
    g := ReadGameNewMap(pid)
    return IsObject(g) && (g.tx != before.tx || g.ty != before.ty) ? g : 0
}

; 開地圖，一直左鍵點 (tx,tz) 讓人物自己走過去，到離目標 stopDist 內為止。
; 每次點完讀回遊戲記的目標（等它真的更新），校正 K / 標記偏差；目的地在框內而且遊戲認為的位置和想的差太多（> 60 單位）就立刻重點；
; 連續 8 次點了都沒走動、15 次都沒更靠近、或點了很久還沒到，丟出錯誤（外面會退回地面點擊的走法）；
; 走不動但離目標只差 stopDist 的 2.2 倍內，當作到了。
; maxStill：連續幾次點了地圖人物沒動就放棄（預設 12；自動採礦用 3：目的地在地圖框外時點框邊常常不被收到，不要白等 40 秒）
DhRunTowardMap(p, tx, tz, stopDist, maxStill := 12) {
    global apRunStart, DH_MAP_SHORT
    pid := p.pid
    if ReadGameUiOpen(pid, "NewMap") != 1 {
        Loop 2 {
            ApKey(p, "m")
            if ApWait(() => (ApGuardAny(), ReadGameUiOpen(pid, "NewMap") = 1), 2500)
                break
        }
        if ReadGameUiOpen(pid, "NewMap") != 1
            throw Error("按 M 大地圖沒有打開")
        ApWait(() => (ApGuardAny(), false), 500)
    }
    bias := {x: 0, y: 0}, kLast := 0, kLastRp := 0, fixes := 0, clicks := 0, still := 0, arrived := false, lvl := 0, badPage := 0, mapDiff := 0
    bestDist := 1e18, bestAt := 0
    try {
        Loop 150 {
            ApGuardAny()
            me := MiningCharState(pid)
            if !IsObject(me)
                throw Error("讀不到人物位置")
            dist := Sqrt((tx - me.x) ** 2 + (tz - me.z) ** 2)
            if dist <= stopDist {
                arrived := true
                break
            }
            pg := ReadGameNewMap(pid)
            if !IsObject(pg) || !pg.visible
                throw Error("讀不到大地圖資料")
            if pg.mapMain != DhMapMain(pid) {   ; 剛換圖時頁面還是舊的；有些圖頁面編號本來就不同：連續 4 輪都不同就照用（資料合理性另外檢查）
                mapDiff += 1
                if mapDiff = 1
                    EventLog(p.name, "DH_MAPMOVE", "大地圖頁面編號 " pg.mapMain " 和角色所在地圖 " DhMapMain(pid) " 不同，等一下再確認")
                if mapDiff <= 4 {
                    ApWait(() => (ApGuardAny(), false), 300)
                    continue
                }
            } else
                mapDiff := 0
            if !DhMapPageOk(pg) {   ; 這一輪讀到的資料不合理：不要拿去算，等一下重讀
                badPage += 1
                if badPage = 1 || Mod(badPage, 10) = 0
                    EventLog(p.name, "DH_MAPMOVE", "大地圖資料不合理（第 " badPage " 次），先不點｜世界 " pg.startX "," pg.startY " 大小 " pg.sizeX "x" pg.sizeY " 貼圖 " pg.texX "x" pg.texY " 標記 " (pg.HasOwnProp("markX") ? Round(pg.markX) "," Round(pg.markY) : "?") " 框 " Round(pg.left) "," Round(pg.top) "-" Round(pg.right) "," Round(pg.bottom))
                if badPage > 25
                    throw Error("大地圖資料一直不合理")
                ApWait(() => (ApGuardAny(), false), 250)
                continue
            }
            kMark := DhMapKFromMark(pg, me)
            if IsObject(kMark)
                K := {x: kMark.x + bias.x, y: kMark.y + bias.y}   ; 目前的標記 + 學到的標記中心偏差（地圖捲動了也跟著變）
            else if IsObject(kLast)   ; 沒有標記資料：上次點擊學到的 K，加上這段時間地圖捲動了多少
                K := {x: kLast.x + (pg.rpx - kLastRp.x) * pg.texX, y: kLast.y + (pg.rpy - kLastRp.y) * pg.texY}
            else
                K := {x: pg.viewX, y: pg.viewY}
            if lvl > 0 {
                lv := DH_MAP_SHORT[Min(lvl, DH_MAP_SHORT.Length)]
                aim := DhMapAimShort(pg, K, me, tx, tz, lv[1], lv[2])
            } else
                aim := DhMapAim(pg, K, me, tx, tz)
            cx := Min(pg.right - 6, Max(pg.left + 6, aim.x)), cy := Min(pg.bottom - 6, Max(pg.top + 6, aim.y))
            if clicks < 3 {   ; 剛開地圖的前幾下常沒被收到：先把游標移到那裡停一下再點
                ApHover(p, Round(cx), Round(cy))
                ApWait(() => (ApGuardAny(), false), 120)
            }
            ApClick(p, Round(cx), Round(cy), 120)
            clicks += 1
            ; 讀回遊戲記的目標（等它真的更新，太早讀會讀到上一次的）→ 學到標記偏差 / K
            ApWait(() => (ApGuardAny(), IsObject(DhMapTargetChanged(pid, pg))), 600)
            pg2 := DhMapTargetChanged(pid, pg)
            if IsObject(pg2) {
                kc := DhMapKFromClick(pg2, Round(cx), Round(cy))
                kLast := kc, kLastRp := {x: pg.rpx, y: pg.rpy}   ; 點的那一刻的捲動位置（用點擊前讀到的）
                if IsObject(kMark) {   ; 偏差實測多在 ±10 以內；差到 45 以上多半是讀到上一下點擊的延遲回報，不採用
                    nb := {x: kc.x - kMark.x, y: kc.y - kMark.y}
                    if Abs(nb.x) <= 45 && Abs(nb.y) <= 45
                        bias := nb
                }
                gw := DhMapTargetWorld(pg2)
                if clicks <= 3 && IsObject(gw)   ; 前幾下把細節都寫下來：想點哪、遊戲認為點哪、K、框和地圖範圍
                    EventLog(p.name, "DH_MAPMOVE", "點擊細節 #" clicks "｜想點 (" Round(aim.wx) "," Round(aim.wz) ")｜遊戲認為 (" Round(gw.x) "," Round(gw.z) ")｜畫面 (" Round(cx) "," Round(cy) ")｜K=(" Round(kc.x) "," Round(kc.y) ")｜標記偏差=(" Round(bias.x, 1) "," Round(bias.y, 1) ")｜框 " Round(pg.left) "," Round(pg.top) "-" Round(pg.right) "," Round(pg.bottom) "｜世界 " pg.startX "," pg.startY " 大小 " pg.sizeX "x" pg.sizeY "｜人物 (" Round(me.x) "," Round(me.z) ")")
                if fixes < 6 && IsObject(gw) && (Abs(aim.wx - gw.x) > 60 || Abs(aim.wz - gw.z) > 60) {
                    fixes += 1
                    EventLog(p.name, "DH_MAPMOVE", "校正點擊位置（第 " fixes " 次）｜遊戲認為點的是 (" Round(gw.x) "," Round(gw.z) ")，想點 (" Round(aim.wx) "," Round(aim.wz) ")｜K=(" Round(kc.x) "," Round(kc.y) ")")
                    continue
                }
            }
            from := me
            ApWait(() => (ApGuardAny(), DhMoved(pid, from, 25)), 900)
            now := MiningCharState(pid)
            moved := IsObject(now) ? Sqrt((now.x - from.x) ** 2 + (now.z - from.z) ** 2) : 0
            if dist < bestDist - 60
                bestDist := dist, bestAt := clicks
            else if clicks - bestAt >= 30   ; 點了 15 次都沒有更靠近（路被擋住 / 目的地在地圖框外一直繞）：不要再耗，交給地面點擊
                throw Error("點了 " clicks " 次地圖，離目標還差 " Round(dist) "，沒有更靠近")
            if moved < 4 {
                still += 1, lvl := still
                if still <= DH_MAP_SHORT.Length
                    EventLog(p.name, "DH_MAPMOVE", "點了但人物沒動（第 " still " 次）｜改點離人物較近 / 換角度的點：" DH_MAP_SHORT[still][1] " 倍、偏 " DH_MAP_SHORT[still][2] "°｜目標讀回" (IsObject(pg2) ? "有更新" : "沒更新（遊戲沒記到這一下）"))
                if still >= maxStill {
                    if dist <= stopDist * 2.2 {   ; 差一點點：當作到了
                        arrived := true
                        break
                    }
                    throw Error("點了地圖但人物沒有走動（連續 " still " 次）")
                }
            } else {
                still := 0, lvl := 0
                apRunStart := A_TickCount   ; 還在往前走就重新計時（守門「一個回合最多 120 秒」是防卡死用的）
            }
            if Mod(clicks, 5) = 0
                EventLog(p.name, "DH_MAPMOVE", "第 " clicks " 次點擊｜人物 (" Round(me.x) "," Round(me.z) ")｜還差 " Round(dist) "｜點畫面 (" Round(cx) "," Round(cy) ")" (aim.inside ? "" : "（目的地在地圖框外，點框邊）"))
        }
        if !arrived
            throw Error("點地圖點了很久還沒到（點了 " clicks " 次）")
        mEnd := MiningCharState(pid)
        EventLog(p.name, "DH_MAPMOVE", "已走到目標附近｜點了 " clicks " 次｜校正 " fixes " 次｜目標 (" Round(tx) "," Round(tz) ")｜人物現在 (" (IsObject(mEnd) ? Round(mEnd.x) "," Round(mEnd.z) : "?") ")")
    } finally {
        DhCloseMap(p)
    }
}
; 走到 (tx,tz)：先用大地圖點擊（會自己繞路），失敗就退回地面點擊的走法
DhMoveTo(p, tx, tz, stopDist) {
    try {
        DhRunTowardMap(p, tx, tz, stopDist)
        return true
    } catch as e {
        if e.Extra = "stop"
            throw e
        EventLog(p.name, "DH_MAPMOVE", "大地圖走路失敗：" e.Message "｜改用地面點擊")
    }
    return DhRunToward(p, tx, tz, stopDist)
}
; 從目前位置走到離 (tx,tz) 不超過 stopDist：每一段取「朝目標方向最遠 400 單位」的落點（畫面上看不到就縮短），用畫面投影算成畫面座標、點地面。
; 一段的結束：人物走到落點附近、或停下來超過 DH_IDLE_MS、或超過 DH_SEG_MAX_MS（人物跑得慢，不要太快重點把它打斷）。
; 一段完全沒走動算「卡住」：第 2 次起改點「朝目標方向、有怪站著的位置」（怪站的地方一定走得到，用來繞開牆），連續 5 次放棄。
; 每一段都寫日誌 DH_MOVE（位置、移動量、用時、方式），方便看是哪裡慢。
DhRunToward(p, tx, tz, stopDist) {
    global DH_SEG_MAX_MS, DH_IDLE_MS, apRunStart
    pid := p.pid
    stuck := 0, off := 0, seg := 0
    Loop 60 {
        ApGuardAny()
        me := MiningCharState(pid)
        if !IsObject(me)
            throw Error("讀不到人物位置")
        dx := tx - me.x, dz := tz - me.z
        dist := Sqrt(dx * dx + dz * dz)
        if dist <= stopDist
            return true
        ux := dx / dist, uz := dz / dist
        if off != 0 {   ; 直走被擋住時先繞一下
            rad := off * 3.14159265 / 180
            ux2 := ux * Cos(rad) - uz * Sin(rad), uz2 := ux * Sin(rad) + uz * Cos(rad)
            ux := ux2, uz := uz2
        }
        sp := 0, used := 0, wx := me.x, wz := me.z, how := "直走"
        if stuck >= 2 {
            st := DhStone(pid, me, tx, tz)
            if IsObject(st) {
                sp := GameWorldToScreen(pid, st.x, st.y, st.z)
                if IsObject(sp) && sp.visible
                    used := st.step, wx := st.x, wz := st.z, how := "踏腳石"
                else
                    sp := 0
            }
        }
        if !sp {
            for step in [400, 300, 200, 120, 60, 35] {
                s := Min(step, dist)
                wx := me.x + ux * s, wz := me.z + uz * s
                sp := GameWorldToScreen(pid, wx, me.y, wz)
                if IsObject(sp) && sp.visible {
                    used := s
                    break
                }
                sp := 0
            }
        }
        if !sp
            throw Error("目標在鏡頭後面，走不過去（距離 " Round(dist) "）")
        c := DhSafeClick(sp.x, sp.y)
        ApClick(p, c.x, c.y)
        t1 := A_TickCount, last := me, lastMoveAt := t1, cur := me
        Loop {
            ApGuardAny()
            Sleep 150
            cur := MiningCharState(pid)
            if !IsObject(cur)
                break
            if (cur.x - wx) ** 2 + (cur.z - wz) ** 2 <= 40 ** 2 || (cur.x - tx) ** 2 + (cur.z - tz) ** 2 <= stopDist ** 2
                break
            if (cur.x - last.x) ** 2 + (cur.z - last.z) ** 2 >= 3 ** 2
                last := cur, lastMoveAt := A_TickCount
            if A_TickCount - lastMoveAt >= DH_IDLE_MS || A_TickCount - t1 >= DH_SEG_MAX_MS
                break
        }
        seg += 1
        moved := IsObject(cur) ? Sqrt((cur.x - me.x) ** 2 + (cur.z - me.z) ** 2) : 0
        EventLog(p.name, "DH_MOVE", "第 " seg " 段｜" how "｜(" Round(me.x) "," Round(me.z) ") → (" (IsObject(cur) ? Round(cur.x) "," Round(cur.z) : "?") ")｜移動 " Round(moved) "｜用 " Round((A_TickCount - t1) / 1000, 1) " 秒｜落點距離 " Round(used) "｜點 (" c.x "," c.y ")｜還差 " Round(dist))
        if moved < 12 {
            stuck += 1
            if stuck >= 5 {
                if dist <= stopDist * 2.2 {   ; 差一點點：自動打怪自己會去找旁邊的怪，不必為了差幾單位放棄
                    EventLog(p.name, "DH_MOVE", "走不動了，但離目標只差 " Round(dist) "（停止距離 " stopDist "），當作到了")
                    return true
                }
                throw Error("路被擋住，走不過去（還差 " Round(dist) "）")
            }
            off := (stuck & 1) ? 40 : -40
        } else {
            stuck := 0, off := 0
            apRunStart := A_TickCount   ; 還在往前走就重新計時：守門「一個回合最多 120 秒」是防卡死用的，人物跑得慢、目標很遠（黑暗後裔集結區）時不能被它中途叫停
        }
    }
    throw Error("走了很久還沒到（還差 " Round(dist) "）")
}
; 朝目標方向、離人 60～400、而且比現在更接近目標至少 60 的怪（任何種類，站的地方一定走得到）裡，最接近目標的一隻；沒有回傳 0
DhStone(pid, me, tx, tz) {
    cr := 0
    try cr := MiningCrows(pid, "")
    if !IsObject(cr)
        return 0
    cur := Sqrt((tx - me.x) ** 2 + (tz - me.z) ** 2)
    best := 0, bd := 1e18
    for c in cr {
        if c.hp <= 0
            continue
        d := Sqrt((c.x - me.x) ** 2 + (c.z - me.z) ** 2)
        if d < 60 || d > 400
            continue
        dt := Sqrt((tx - c.x) ** 2 + (tz - c.z) ** 2)
        if dt > cur - 60 || dt >= bd
            continue
        best := {x: c.x, y: c.y, z: c.z, step: d}, bd := dt
    }
    return best
}
; 要打的怪：每日討伐是「這張圖任何怪都算 1 隻」，所以不分種類全部算進去，只排除 NPC（遊戲資料 kind=1：公車站、指導老師、管理員…）
; 和礦（能原石也是 kind=2，用名字排除）。讀不到種類（舊的位置資料）才退回只看任務寫的那種怪（名稱含 mob）。
DhTargets(pid, mob) {
    all := 0
    try all := MiningCrows(pid, "")
    if !IsObject(all) || !all.Length
        return []
    anyKind := false   ; 清單裡有沒有任何一隻讀得到種類（舊的位置資料整份都沒有）
    for c in all
        if c.HasOwnProp("kind") && c.kind >= 0 {
            anyKind := true
            break
        }
    if !anyKind {
        named := 0
        try named := MiningCrows(pid, mob)
        return IsObject(named) ? named : []
    }
    out := []
    for c in all {
        kind := c.HasOwnProp("kind") ? c.kind : -1
        if kind != 2 || InStr(c.name, "原石")   ; 讀不到種類（剛生出來還沒資料）的單隻也跳過，不影響其他
            continue
        out.Push(c)
    }
    return out
}
; 到站後先走一小段（約 200 單位）：遊戲要角色動了才會把這張圖的怪物清單送過來。
; 第 1 次朝地圖中心走（讀得到大地圖資料時），之後每次轉 90°；讀不到地圖範圍就依序往四個方向走。失敗不影響後面（只寫日誌）。
DhWakeMove(p, k) {
    pid := p.pid
    me := MiningCharState(pid)
    if !IsObject(me)
        return
    ux := 1, uz := 0
    pg := ReadGameNewMap(pid)
    if IsObject(pg) {
        dx := pg.startX + pg.sizeX / 2 - me.x, dz := pg.startY + pg.sizeY / 2 - me.z
        len := Sqrt(dx * dx + dz * dz)
        if len > 50
            ux := dx / len, uz := dz / len
    }
    ang := (k - 1) * 90 * 3.14159265 / 180
    wx := me.x + (ux * Cos(ang) - uz * Sin(ang)) * 200, wz := me.z + (ux * Sin(ang) + uz * Cos(ang)) * 200
    EventLog(p.name, "DH_WAKE", "到站先走一小段讓遊戲送怪物清單｜第 " k " 次｜(" Round(me.x) "," Round(me.z) ") → (" Round(wx) "," Round(wz) ")")
    DhSoft(p, "到站先走一小段", () => DhRunToward(p, wx, wz, 40))
}
; 讀不到怪時寫進錯誤訊息的診斷：清單總共幾隻、可打的幾隻
DhCrowDiag(pid, mob) {
    all := 0
    try all := MiningCrows(pid, "")
    return "清單 " (IsObject(all) ? all.Length : "讀不到") " 隻，可打的 " DhTargets(pid, mob).Length " 隻"
}
; 這張圖現在有沒有怪可打（不管死活，用來等剛換圖的怪物載入）
DhHasCrow(pid, mob) => DhTargets(pid, mob).Length > 0
DhMoved(pid, from, dist) {
    me := MiningCharState(pid)
    return IsObject(me) && (me.x - from.x) ** 2 + (me.z - from.z) ** 2 >= dist ** 2
}

; 到了目標地圖：先關掉自動打怪（它開著再按 F6 會變成關掉）→ 走到要打的地方 → 按 F6 → 確認真的開了。
;  - 這張圖有固定點：先走到那個位置，**到了再偵測怪**（周圍沒有怪才改去最近的一群）；
;  - 沒有固定點：先走一小段讓遊戲送怪物清單，再讀怪，算出要去的地方（密集中心 / 就近一群）。
; 人物離固定點超過 lim（沒有固定點也算）= 你自己走到別的地方了
DhIsAway(me, spot, lim) => IsObject(me) && (!IsObject(spot) || (spot.x - me.x) ** 2 + (spot.z - me.z) ** 2 > lim ** 2)
global DH_AWAY_DIST := 150

; keepPlace：這次是「接著打」（不是剛到這張圖）。此時人物若不在固定點附近，就留在現在的位置繼續（不走回固定點）。
DhActStartHunt(p, g, keepPlace := false) {
    global DH_SPOTS, DH_AWAY_DIST
    pid := p.pid
    mob := DhMobName(g)   ; 只在讀不到怪物種類（舊的位置資料）時才用來過濾
    if ReadGameAutoHunt(pid) = 1 {
        ApKey(p, "F6")
        if !ApWait(() => (ApGuardAny(), ReadGameAutoHunt(pid) = 0), 5000)
            throw Error("按 F6 想先關掉自動打怪，但它還是開著")
    }
    spot := DH_SPOTS.Get(g.map, 0)
    if keepPlace && DhIsAway(MiningCharState(pid), spot, DH_AWAY_DIST)
        DhStartInPlace(p, g, mob)
    else if IsObject(spot)
        DhStartAtSpot(p, g, spot, mob)
    else
        DhStartByCluster(p, g, mob)
    ApKey(p, "F6")
    if !ApWait(() => (ApGuardAny(), ReadGameAutoHunt(pid) = 1), 6000)
        throw Error("按了 F6 但自動打怪沒有開起來")
    EventLog(p.name, "DH_HUNT", "開始自動打怪：" g.name "｜" g.done " / " g.target)
    AddRecentEvent("🎯 " p.name "：開始打 " g.name)
}

; 留在現在的位置接著打：程式完全不走路（怪物座標可能隔著牆 / 圍欄，程式的點擊尋路走不到），直接開遊戲自己的自動打怪，
; 由遊戲自己找怪、走過去。這裡打不到（3 分鐘進度沒動）的話，第二次卡住會照原本流程走回固定點。
DhStartInPlace(p, g, mob) {
    me := MiningCharState(p.pid)
    if IsObject(me)
        EventLog(p.name, "DH_INPLACE", g.name "｜人物不在固定點附近，留在現在的位置 (" Round(me.x) "," Round(me.z) ") 直接開自動打怪，不走回固定點、也不另外尋路")
}

; 固定點：先走到那個位置（大地圖點擊），到了再偵測怪；周圍 400 單位內沒有怪、但這張圖別處有，才改去最近的一群。
DhStartAtSpot(p, g, spot, mob) {
    global DH_HUNT_STOP, DH_HUNT_STOP_NEAR, DH_SPOT_STOP
    pid := p.pid
    me := MiningCharState(pid)
    if !IsObject(me)
        throw Error("讀不到人物位置")
    dist := Sqrt((spot.x - me.x) ** 2 + (spot.z - me.z) ** 2)
    EventLog(p.name, "DH_CLUSTER", g.name "｜模式 固定點｜先走到 (" Round(spot.x) "," Round(spot.z) ")，到了再偵測怪｜距離 " Round(dist))
    if dist > DH_SPOT_STOP {
        try DhMoveTo(p, spot.x, spot.z, DH_SPOT_STOP)
        catch as e {
            if e.Extra = "stop"
                throw e
            throw Error(e.Message "｜這個固定點可能走不到（牆 / 圍欄 / 不能走的格子），請讓人物在遊戲裡真的走到想去的位置，再按「記錄」重存")
        }
    }
    ; 到了位置，現在才偵測怪（剛動過，遊戲才有送清單；讀不到就等一下）
    ApWait(() => (ApGuardAny(), DhHasCrow(pid, mob)), 5000)
    cr := DhTargets(pid, mob)
    me := MiningCharState(pid)
    alive := 0, near := 0
    for c in cr
        if c.hp > 0 {
            alive += 1
            if IsObject(me) && (c.x - spot.x) ** 2 + (c.z - spot.z) ** 2 <= 400 ** 2
                near += 1
        }
    EventLog(p.name, "DH_CLUSTER", g.name "｜到了固定點再偵測｜周圍 400 內 " near " 隻｜這張圖共 " alive " 隻")
    if near = 0 && alive > 0 && IsObject(me) {   ; 固定點附近一隻都沒有（重生點變了 / 被別人清光）：改去最近的一群
        best := DhNearestCluster(cr, me, 300, 4)
        if IsObject(best) && best.dist > DH_HUNT_STOP_NEAR {
            EventLog(p.name, "DH_CLUSTER", g.name "｜固定點附近沒有怪，改去最近的一群（" best.count " 隻，距離 " Round(best.dist) "）")
            DhMoveTo(p, best.x, best.z, DH_HUNT_STOP_NEAR)
        }
    }
}

; 沒有固定點：怪物清單要角色先動一下遊戲才會送過來，先走一小段再讀；還是空的就換方向再走（最多再 2 次）；
; 然後依模式算要去的地方（密集中心 / 就近一群）走過去。
DhStartByCluster(p, g, mob) {
    global DH_CLUSTER_R, DH_HUNT_STOP, DH_HUNT_STOP_NEAR
    pid := p.pid
    mode := DhModeOf(g.map)
    DhWakeMove(p, 1)
    ApWait(() => (ApGuardAny(), DhHasCrow(pid, mob)), 6000)
    Loop 2 {
        if DhHasCrow(pid, mob)
            break
        DhWakeMove(p, A_Index + 1)
        ApWait(() => (ApGuardAny(), DhHasCrow(pid, mob)), 4000)
    }
    cr := DhTargets(pid, mob)
    me := MiningCharState(pid)
    if !IsObject(me) || !IsObject(cr) || !cr.Length
        throw Error("這張圖讀不到怪物（" DhCrowDiag(pid, mob) "）")
    best := mode = "dense" ? DhBestCluster(cr, me, DH_CLUSTER_R) : DhNearestCluster(cr, me, 300, 4)
    if !IsObject(best)
        throw Error("這張圖的怪都已經被打倒（等重生）")
    aliveN := 0, minx := maxx := best.x, minz := maxz := best.z
    for c in cr
        if c.hp > 0
            aliveN += 1, minx := Min(minx, c.x), maxx := Max(maxx, c.x), minz := Min(minz, c.z), maxz := Max(maxz, c.z)
    ; 分佈資料寫進日誌：之後可以據此判斷哪些圖是「平均鋪滿」、哪些是「一坨一坨」
    EventLog(p.name, "DH_CLUSTER", g.name "｜模式 " (mode = "dense" ? "密集中心" : "就近一群") "｜所有怪（任務寫「" mob "」）活 " aliveN " 隻｜範圍 " Round(maxx - minx) "x" Round(maxz - minz) "｜選的地方周圍 " (mode = "dense" ? DH_CLUSTER_R : 300) " 內 " best.count " 隻（" Round(100 * best.count / Max(1, aliveN)) "%）｜目標點距離 " Round(best.dist))
    stopAt := mode = "dense" ? DH_HUNT_STOP : DH_HUNT_STOP_NEAR
    if best.dist > stopAt
        DhMoveTo(p, best.x, best.z, stopAt)
}

#Include %A_LineFile%\..\DailyHuntSchedule.ahk
