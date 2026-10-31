; 授權（H-042）：這台電腦要有作者簽發的授權檔才能使用。
;   - 授權檔放 license\HIHIYONG.lic，內容＋最後一行 sig=（RSA-SHA256）。程式裡只有公鑰，沒有辦法自己簽。
;   - 綁電腦識別碼；可選限定遊戲帳號（只存雜湊，看不到帳號名稱）或限制同時帳號數。
;   - 沒有授權的帳號只是「不監控、不啟動」，設定不會被洗掉（授權補上後自動恢復）。
; 這支檔案只做判斷與畫面；主程式需要提供 EventLog。測試可先設定 LIC_PS_PATH / LIC_FILE / LIC_PUBKEY。

global LIC_PUBKEY := IsSet(LIC_PUBKEY) ? LIC_PUBKEY : '<RSAKeyValue><Modulus>6p48FlM/jLggZjAaJnHRh9Zi4xsQ4W1/5Fe8Z5t9w8WmEtCUq6LHQhaNWWJjmGW68cvCWys3y3mpEQyox+GFsMlIwbrLEZa1qRDI2NopGsiJI/roN88TyWfU5d9umGlKTzcv9nN8tuhr0AnU1XsnLqroC6voRZeCk5O4lEFhIs/xYCpbfRR1J7gcg2sOFuGel9+U40kjWnbh5Hq0N2ABuzk8j2dnmB7iJprN8BswJlGMIf9ZNqVwh9Ef6Y1HvAg7ErTfrZNviV/re2J1ZEiRN4kVY+0QFZ4ExnG5zGvjnJVJFII0k2tXiALSdsik63SlfPCyyFLZBfY413ziYSTX5Q==</Modulus><Exponent>AQAB</Exponent></RSAKeyValue>'
global LIC_PS_PATH := IsSet(LIC_PS_PATH) ? LIC_PS_PATH : A_ScriptDir "\tools\license_verify.ps1"
global LIC_FILE := IsSet(LIC_FILE) ? LIC_FILE : A_ScriptDir "\license\HIHIYONG.lic"
global LIC_SEEN_FILE := IsSet(LIC_SEEN_FILE) ? LIC_SEEN_FILE : A_ScriptDir "\license\lastseen.txt"
global LIC_NAME_FILE := IsSet(LIC_NAME_FILE) ? LIC_NAME_FILE : A_ScriptDir "\license\name.txt"
global LIC_WARN_DAYS := 7
global licState := 0       ; 目前授權狀態（Lic_Load 的結果）
global licInfoCache := 0   ; 通過驗簽的授權內容（每天重算期限，不用重驗簽）

; ---------- 雜湊 / 識別碼 ----------
Lic_Sha256Hex(text) {
    n := StrPut(text, "UTF-8")
    buf := Buffer(n)
    StrPut(text, buf, "UTF-8")
    hProv := 0, hHash := 0
    if !DllCall("advapi32\CryptAcquireContextW", "Ptr*", &hProv, "Ptr", 0, "Ptr", 0, "UInt", 24, "UInt", 0xF0000000)
        return ""
    hex := ""
    if DllCall("advapi32\CryptCreateHash", "Ptr", hProv, "UInt", 0x800C, "Ptr", 0, "UInt", 0, "Ptr*", &hHash) {
        DllCall("advapi32\CryptHashData", "Ptr", hHash, "Ptr", buf, "UInt", n - 1, "UInt", 0)
        out := Buffer(32), size := 32
        if DllCall("advapi32\CryptGetHashParam", "Ptr", hHash, "UInt", 2, "Ptr", out, "UInt*", &size, "UInt", 0)
            loop 32
                hex .= Format("{:02x}", NumGet(out, A_Index - 1, "UChar"))
        DllCall("advapi32\CryptDestroyHash", "Ptr", hHash)
    }
    DllCall("advapi32\CryptReleaseContext", "Ptr", hProv, "UInt", 0)
    return hex
}

; 識別碼只由「系統 GUID ＋ 主機板 UUID ＋ CPU 編號」算出，不含任何會被改名的東西。
Lic_MachineParts() {
    guid := "", uuid := "", cpu := ""
    try guid := RegRead("HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Cryptography", "MachineGuid")
    loop 2 {
        try {
            wmi := ComObjGet("winmgmts:")
            for o in wmi.ExecQuery("Select UUID from Win32_ComputerSystemProduct")
                uuid := o.UUID
            for o in wmi.ExecQuery("Select ProcessorId from Win32_Processor")
                if cpu = ""
                    cpu := o.ProcessorId
        }
        if uuid != "" && cpu != ""
            break
        Sleep 300
    }
    return guid "|" uuid "|" cpu
}

Lic_MachineIdFrom(parts) {
    h := StrUpper(Lic_Sha256Hex("HIHIYONG|" parts))
    return SubStr(h, 1, 4) "-" SubStr(h, 5, 4) "-" SubStr(h, 9, 4) "-" SubStr(h, 13, 4)
}

Lic_MachineId() => Lic_MachineIdFrom(Lic_MachineParts())

; 帳號雜湊含電腦識別碼當鹽：同一個帳號在不同電腦的授權檔裡長得不一樣。
Lic_AcctHash(machineId, account) => Lic_Sha256Hex("acct|" machineId "|" StrLower(Trim(account)))

; ---------- 授權內容 ----------
; 作者端用：組出要簽的內容。expires = "forever" 或 yyyyMMdd。
Lic_BuildPayload(user, machineId, issued, expires, mode, count := 0, accounts := "") {
    t := "HIHIYONG-LICENSE 1`n"
    ; 授權編號每次簽發都不同（含時間），撤銷名單才能只撤這一份、不影響之後重新簽發的
    t .= "id=" A_Now A_MSec "-" SubStr(StrReplace(machineId, "-"), 1, 6) "`n"
    t .= "user=" RegExReplace(user, "[\r\n=]", " ") "`n"
    t .= "machine=" machineId "`n"
    t .= "issued=" issued "`n"
    t .= "expires=" expires "`n"
    t .= "mode=" mode "`n"
    if mode = "count"
        t .= "count=" Integer(count) "`n"
    if mode = "list" && IsObject(accounts)
        for a in accounts
            if Trim(a) != ""
                t .= "acct=" Lic_AcctHash(machineId, a) "`n"
    return t
}

Lic_Parse(text) {
    text := StrReplace(text, "`r`n", "`n")
    lines := StrSplit(text, "`n")
    if lines.Length < 2 || !RegExMatch(lines[1], "^HIHIYONG-LICENSE 1\s*$")
        return 0
    lic := {user: "", machine: "", issued: "", expires: "", mode: "", count: 0, accts: Map(), id: ""}
    for line in lines {
        p := InStr(line, "=")
        if !p
            continue
        k := SubStr(line, 1, p - 1), v := SubStr(line, p + 1)
        if k = "acct"
            lic.accts[StrLower(Trim(v))] := 1
        else if k = "count"
            lic.count := RegExMatch(v, "^\d+$") ? Integer(v) : 0
        else if lic.HasOwnProp(k)
            lic.%k% := v
    }
    if lic.machine = "" || !RegExMatch(lic.expires, "^(forever|\d{8})$") || !RegExMatch(lic.mode, "^(any|list|count)$")
        return 0
    if lic.expires != "forever" && !Lic_ValidDate(lic.expires)
        return 0
    return lic
}

Lic_ValidDate(ymd) {
    if !RegExMatch(ymd, "^\d{8}$")
        return false
    try {
        DateAdd(ymd "000000", 0, "Days")
        return SubStr(FormatTime(ymd "000000", "yyyyMMdd"), 1, 8) = ymd
    }
    return false
}

; 期限判斷。today / lastSeen 為 yyyyMMdd。daysLeft：-1 = 永久。
Lic_Status(lic, machineId, today, lastSeen := "") {
    if lic.machine != machineId
        return {ok: false, reason: "machine", daysLeft: 0}
    if lastSeen != "" && Lic_ValidDate(lastSeen) && DateDiff(lastSeen "000000", today "000000", "Days") > 1
        return {ok: false, reason: "clock", daysLeft: 0}
    if lic.expires = "forever"
        return {ok: true, reason: "", daysLeft: -1}
    left := DateDiff(lic.expires "000000", today "000000", "Days")
    if left < 0
        return {ok: false, reason: "expired", daysLeft: left}
    return {ok: true, reason: "", daysLeft: left}
}

; rank = 這個帳號在所有有填帳號的角色中的順序（1 起算），給「限制數量」用
Lic_AccountAllowed(lic, machineId, account, rank) {
    if lic.mode = "any"
        return true
    if lic.mode = "count"
        return rank <= lic.count
    return account != "" && lic.accts.Has(Lic_AcctHash(machineId, account))
}

; ---------- 驗簽 / 載入 ----------
; 回傳 {ok, reason: nofile|format|signature, text}
Lic_VerifyFile(path, pubKey := "") {
    global LIC_PS_PATH, LIC_PUBKEY
    if !FileExist(path)
        return {ok: false, reason: "nofile", text: ""}
    out := A_Temp "\hihiyong_lic_" A_TickCount ".txt"
    try FileDelete out
    rc := 99
    try rc := RunWait('powershell -NoProfile -ExecutionPolicy Bypass -File "' LIC_PS_PATH '" -file "' path '" -key "' (pubKey != "" ? pubKey : LIC_PUBKEY) '" -out "' out '"', , "Hide")
    if rc != 0 || !FileExist(out) {
        try FileDelete out
        return {ok: false, reason: rc = 3 ? "signature" : "format", text: ""}
    }
    text := FileRead(out, "UTF-8")
    try FileDelete out
    return {ok: true, reason: "", text: text}
}

; 讀取並判斷 path（預設 LIC_FILE）。state：ok | none | bad | machine | expired | clock
Lic_Evaluate(path := "", machineId := "", today := "") {
    global LIC_FILE, LIC_SEEN_FILE, licInfoCache
    path := path != "" ? path : LIC_FILE
    machineId := machineId != "" ? machineId : Lic_MachineId()
    today := today != "" ? today : SubStr(A_Now, 1, 8)
    v := Lic_VerifyFile(path)
    if !v.ok
        return {state: v.reason = "nofile" ? "none" : "bad", lic: 0, daysLeft: 0, machineId: machineId}
    lic := Lic_Parse(v.text)
    if !lic
        return {state: "bad", lic: 0, daysLeft: 0, machineId: machineId}
    seen := ""
    try seen := Trim(FileRead(LIC_SEEN_FILE, "UTF-8"))
    st := Lic_Status(lic, machineId, today, seen)
    if st.ok && Lic_IsRevoked(lic.id)
        return {state: "revoked", lic: lic, daysLeft: st.daysLeft, machineId: machineId}
    return {state: st.ok ? "ok" : st.reason, lic: lic, daysLeft: st.daysLeft, machineId: machineId}
}

Lic_Load() {
    global licState, licInfoCache
    licState := Lic_Evaluate()
    licInfoCache := licState.lic
    if licState.state = "ok"
        Lic_TouchSeen()
    return licState
}

; 每天只重算期限與帳號，不重新驗簽（檔案沒變）
Lic_Recheck() {
    global licState, licInfoCache, LIC_SEEN_FILE
    if !IsObject(licState) || !licInfoCache
        return licState
    seen := ""
    try seen := Trim(FileRead(LIC_SEEN_FILE, "UTF-8"))
    st := Lic_Status(licInfoCache, licState.machineId, SubStr(A_Now, 1, 8), seen)
    state := st.ok ? "ok" : st.reason
    if st.ok && Lic_IsRevoked(licInfoCache.id)   ; 名單檔變了才會重驗（看修改時間）
        state := "revoked"
    licState := {state: state, lic: licInfoCache, daysLeft: st.daysLeft, machineId: licState.machineId}
    if licState.state = "ok"
        Lic_TouchSeen()
    return licState
}

Lic_TouchSeen() {
    global LIC_SEEN_FILE
    today := SubStr(A_Now, 1, 8)
    seen := ""
    try seen := Trim(FileRead(LIC_SEEN_FILE, "UTF-8"))
    if seen != "" && seen >= today
        return
    try {
        SplitPath LIC_SEEN_FILE, , &dir
        DirCreate dir
        f := FileOpen(LIC_SEEN_FILE, "w", "UTF-8-RAW")
        f.Write(today)
        f.Close()
    }
}

; 把使用者選的授權檔裝進 license\：先驗簽與電腦，通過才覆蓋
Lic_Install(src) {
    global LIC_FILE
    st := Lic_Evaluate(src)
    if st.state != "ok" && st.state != "expired" && st.state != "clock"
        return st
    if st.state != "ok"
        return st
    try {
        SplitPath LIC_FILE, , &dir
        DirCreate dir
        FileCopy src, LIC_FILE, 1
    } catch {
        st.state := "bad"
    }
    return st
}

; ---------- 白話說明 ----------
Lic_ReasonText(st) {
    s := st.state
    if s = "none"
        return "這台電腦還沒有取得使用許可。"
    if s = "machine"
        return "🖥️ 這份授權不是給這台電腦的。"
    if s = "expired"
        return "⏰ 授權已在 " Lic_DateText(st.lic.expires) " 到期。請聯絡作者續期。"
    if s = "revoked"
        return "⛔ 這份授權已被作者撤銷，無法繼續使用。請聯絡作者重新申請。"
    if s = "clock"
        return "🕒 這台電腦的日期比上次使用時還早，請先把系統時間調正確。"
    return "📄 授權檔已損毀或被修改過，請向作者重新索取。"
}

Lic_DateText(ymd) => ymd = "forever" ? "永久" : SubStr(ymd, 1, 4) "-" SubStr(ymd, 5, 2) "-" SubStr(ymd, 7, 2)

; 剩 7 天內回傳提醒文字，否則空字串
Lic_WarnText(st) {
    global LIC_WARN_DAYS
    if !IsObject(st) || st.state != "ok" || st.daysLeft < 0 || st.daysLeft > LIC_WARN_DAYS
        return ""
    return "⚠️ 授權將在 " (st.daysLeft = 0 ? "今天" : st.daysLeft " 天後") "到期（" Lic_DateText(st.lic.expires) "），請提早向作者續期。"
}

; ---------- 名稱＋識別碼一起複製 ----------
; 使用者先輸入自己的名稱，複製出「名稱｜識別碼」一行文字貼給作者；簽發工具貼上時會自動拆開。
Lic_CleanName(name) => Trim(RegExReplace(name, "[｜|\r\n=]+", " "))

Lic_ShareText(name, machineId) {
    name := Lic_CleanName(name)
    return name = "" ? machineId : name "｜" machineId
}

; 回傳 {name, id}；找不到識別碼回傳 0
Lic_ParseShare(text) {
    if !RegExMatch(text, "i)([0-9A-F]{4}(?:-[0-9A-F]{4}){3})", &m)
        return 0
    name := Lic_CleanName(SubStr(text, 1, m.Pos(1) - 1))
    return {name: name, id: StrUpper(m[1])}
}

Lic_SavedName() {
    global LIC_NAME_FILE
    try return Lic_CleanName(FileRead(LIC_NAME_FILE, "UTF-8"))
    return ""
}

Lic_SaveName(name) {
    global LIC_NAME_FILE
    try {
        SplitPath LIC_NAME_FILE, , &dir
        DirCreate dir
        f := FileOpen(LIC_NAME_FILE, "w", "UTF-8-RAW")
        f.Write(Lic_CleanName(name))
        f.Close()
    }
}

; 介面「複製」按鈕用：已授權就用授權上的名稱，否則用先前輸入過的名稱
Lic_ShareNow() {
    global licState
    n := (IsObject(licState) && IsObject(licState.lic)) ? licState.lic.user : Lic_SavedName()
    return Lic_ShareText(n, licState.machineId)
}

; ---------- 撤銷名單 ----------
; 作者可以撤銷某一份授權（依授權編號，不影響之後重新簽發的）。名單是用同一把私鑰簽名的文字檔：
;   license\revoked.txt（本機快取）；程式啟動時與每 2 小時從 GitHub 取最新一份，驗簽通過才採用。
; 連不上網路就沿用本機那份（撤銷最慢要等下次連得上網才生效）；名單被竄改驗不過就當沒有。
global LIC_REVOKE_FILE := IsSet(LIC_REVOKE_FILE) ? LIC_REVOKE_FILE : A_ScriptDir "\license\revoked.txt"
global LIC_REVOKE_URL := IsSet(LIC_REVOKE_URL) ? LIC_REVOKE_URL : ""
global LIC_REVOKE_CHECK_MS := 2 * 3600000
global licRevoked := 0, licRevokeStamp := "", licRevReq := 0, licRevReqStart := 0, licRevNext := 0

Lic_RevokeUrl() {
    global LIC_REVOKE_URL
    if LIC_REVOKE_URL != ""
        return LIC_REVOKE_URL
    repo := (IsSet(UPDATE_REPO) && UPDATE_REPO != "") ? UPDATE_REPO : "chingcavaliers-alt/hihiyong"
    return "https://raw.githubusercontent.com/" repo "/main/revoked.txt"
}

; 作者端用：組出要簽的名單內容。updated 為 yyyyMMddHHmmss（越新越優先，舊名單不能蓋掉新名單）
Lic_RevokeBuild(updated, ids) {
    t := "HIHIYONG-REVOKE 1`nupdated=" updated "`n"
    for id in ids
        if RegExMatch(id, "^[0-9A-Za-z-]+$")
            t .= "id=" id "`n"
    return t
}

Lic_RevokeParse(text) {
    lines := StrSplit(StrReplace(text, "`r`n", "`n"), "`n")
    if !lines.Length || !RegExMatch(lines[1], "^HIHIYONG-REVOKE 1\s*$")
        return 0
    r := {updated: "", ids: Map()}
    for line in lines {
        p := InStr(line, "=")
        if !p
            continue
        k := SubStr(line, 1, p - 1), v := Trim(SubStr(line, p + 1))
        if k = "id"
            r.ids[v] := 1
        else if k = "updated"
            r.updated := v
    }
    return RegExMatch(r.updated, "^\d{14}$") ? r : 0
}

; 讀本機名單（驗簽）。檔案沒變就用記憶體裡的，不重驗
Lic_RevokeLoad() {
    global LIC_REVOKE_FILE, licRevoked, licRevokeStamp
    stamp := ""
    try stamp := FileGetTime(LIC_REVOKE_FILE, "M") "|" FileGetSize(LIC_REVOKE_FILE)
    if stamp = licRevokeStamp
        return licRevoked
    licRevokeStamp := stamp, licRevoked := 0
    if stamp = ""
        return 0
    v := Lic_VerifyFile(LIC_REVOKE_FILE)
    if v.ok {
        r := Lic_RevokeParse(v.text)
        if r
            licRevoked := r
    }
    return licRevoked
}

Lic_RevokeForget() {
    global licRevokeStamp
    licRevokeStamp := "?"
}

Lic_IsRevoked(id) {
    r := Lic_RevokeLoad()
    return IsObject(r) && id != "" && r.ids.Has(id)
}

; 收到一份名單檔（tmp）：簽章對、而且不比本機的舊才採用。回傳 new | same | old | bad
Lic_RevokeAccept(tmp) {
    global LIC_REVOKE_FILE
    v := Lic_VerifyFile(tmp)
    n := v.ok ? Lic_RevokeParse(v.text) : 0
    if !n
        return "bad"
    cur := Lic_RevokeLoad()
    if IsObject(cur) && n.updated < cur.updated
        return "old"
    if IsObject(cur) && n.updated = cur.updated
        return "same"
    try {
        SplitPath LIC_REVOKE_FILE, , &dir
        DirCreate dir
        FileCopy tmp, LIC_REVOKE_FILE, 1
    } catch
        return "bad"
    Lic_RevokeForget()
    return "new"
}

Lic_RevokeHandleText(text) {
    tmp := A_Temp "\hihiyong_revoke_" A_TickCount ".txt"
    try FileDelete tmp
    f := FileOpen(tmp, "w", "UTF-8-RAW"), f.Write(text), f.Close()
    r := Lic_RevokeAccept(tmp)
    try FileDelete tmp
    if r = "new"
        try EventLog("GLOBAL", "LICENSE", "收到新的撤銷名單")
    return r
}

; 啟動時用：最多等 ms 毫秒。連不上就算了（沿用本機名單）
Lic_RevokeFetchSync(ms := 3000) {
    try {
        req := ComObject("WinHttp.WinHttpRequest.5.1")
        req.SetTimeouts(ms, ms, ms, ms)
        req.Open("GET", Lic_RevokeUrl() "?t=" A_TickCount, false)
        req.SetRequestHeader("Cache-Control", "no-cache")
        req.Send()
        if req.Status = 200
            return Lic_RevokeHandleText(req.ResponseText)
        return "http" req.Status
    }
    return "offline"
}

; 執行中用：非同步，不卡住管理程式
Lic_RevokeFetchStart() {
    global licRevReq, licRevReqStart
    if IsObject(licRevReq)
        return
    try {
        licRevReq := ComObject("WinHttp.WinHttpRequest.5.1")
        licRevReq.SetTimeouts(5000, 5000, 8000, 8000)
        licRevReq.Open("GET", Lic_RevokeUrl() "?t=" A_TickCount, true)
        licRevReq.SetRequestHeader("Cache-Control", "no-cache")
        licRevReq.Send()
        licRevReqStart := A_TickCount
        SetTimer Lic_RevokePoll, 300
    } catch
        licRevReq := 0
}

Lic_RevokePoll() {
    global licRevReq, licRevReqStart
    done := false
    try done := licRevReq.WaitForResponse(0)
    if !done && A_TickCount - licRevReqStart < 20000
        return
    SetTimer Lic_RevokePoll, 0
    code := 0, text := ""
    try code := licRevReq.Status, text := licRevReq.ResponseText
    licRevReq := 0
    if code = 200
        Lic_RevokeHandleText(text)
}

; ---------- 套用到帳號 ----------
; 沒授權的帳號：不監控、不啟動（記憶體內），原本的設定另外記著，授權補上就恢復，也不會被 SaveProfiles 洗掉。
; 回傳沒授權的帳號數。
Lic_ApplyToProfiles(profs, st) {
    rank := 0, blocked := 0
    for p in profs {
        acct := Trim(p.account)
        if acct != ""
            rank += 1
        ok := IsObject(st) && st.state = "ok" && acct != "" && Lic_AccountAllowed(st.lic, st.machineId, acct, rank)
        p.licensed := ok
        if ok {
            if p.HasOwnProp("licEnabled0") {
                p.enabled := p.licEnabled0, p.launchEnabled := p.licLaunch0
                p.DeleteProp("licEnabled0"), p.DeleteProp("licLaunch0")
            }
        } else {
            blocked += 1
            if !p.HasOwnProp("licEnabled0")
                p.licEnabled0 := p.enabled, p.licLaunch0 := p.launchEnabled
            else {
                if p.enabled
                    p.licEnabled0 := 1
                if p.launchEnabled
                    p.licLaunch0 := 1
            }
            p.enabled := 0, p.launchEnabled := 0
        }
    }
    return blocked
}

; SaveProfiles 用：寫入使用者原本的設定，不要寫成被強制關掉的值
Lic_EnabledToSave(p) => p.HasOwnProp("licEnabled0") ? p.licEnabled0 : p.enabled
Lic_LaunchToSave(p) => p.HasOwnProp("licLaunch0") ? p.licLaunch0 : p.launchEnabled

; ---------- 畫面 ----------
; 啟動時呼叫：有授權就直接回傳；沒有就顯示授權視窗，直到成功或離開（離開 = 結束程式）
Lic_Gate() {
    Lic_RevokeFetchSync(3000)   ; 先看有沒有新的撤銷名單（連不上就沿用本機的）
    st := Lic_Load()
    if st.state = "ok"
        return st
    g := Gui("+AlwaysOnTop -MinimizeBox", "🔒 HIHIYONG 需要授權")
    g.SetFont("s10", "Microsoft JhengHei")
    g.AddText("w420", "🔒 需要授權才能使用")
    msg := g.AddText("w420 h40 cC0392B", Lic_ReasonText(st))
    g.AddText("w420", "👤 你的名稱（讓作者知道是誰）：")
    edName := g.AddEdit("w420", Lic_SavedName())
    g.AddText("w420", "🖥️ 這台電腦的識別碼：")
    g.SetFont("s14 Bold", "Consolas")
    g.AddEdit("w420 ReadOnly Center", st.machineId)
    g.SetFont("s10 norm", "Microsoft JhengHei")
    g.AddText("w420", "1️⃣ 填好名稱，按「複製名稱和識別碼」，貼給作者`n2️⃣ 收到授權檔後，按「選擇授權檔」")
    b1 := g.AddButton("w170 h32", "📋 複製名稱和識別碼")
    b2 := g.AddButton("x+8 w120 h32", "📂 選擇授權檔")
    b3 := g.AddButton("x+8 w100 h32", "❌ 離開")
    state := {done: false, ok: false}
    b1.OnEvent("Click", CopyShare)
    CopyShare(*) {
        if Lic_CleanName(edName.Value) = "" {
            msg.Text := "👤 請先填上你的名稱，再複製。"
            edName.Focus()
            return
        }
        Lic_SaveName(edName.Value)
        A_Clipboard := Lic_ShareText(edName.Value, st.machineId)
        msg.Text := "📋 已複製「名稱＋識別碼」，直接貼給作者就好。"
    }
    b2.OnEvent("Click", Pick)
    b3.OnEvent("Click", (*) => state.done := true)
    g.OnEvent("Close", (*) => state.done := true)
    Pick(*) {
        f := FileSelect(1, A_ScriptDir, "選擇授權檔", "授權檔 (*.lic)")
        if f = ""
            return
        r := Lic_Install(f)
        if r.state = "ok" {
            state.ok := true, state.done := true
        } else
            msg.Text := Lic_ReasonText(r)
    }
    g.Show()
    while !state.done
        Sleep 100
    g.Destroy()
    if !state.ok
        ExitApp
    return Lic_Load()
}

; ---------- 主程式串接（需要主程式的 profiles / webReady / WVCore / EventLog / INI / JsonEscapeWeb）----------
global licLastKey := ""
global licWarnedDate := ""

; 每 5 秒：重算期限、把沒授權的帳號關掉（含使用者在介面硬開的）、狀態變了就記錄並通知介面
Lic_Tick() {
    global licState, profiles, licLastKey, licWarnedDate, INI, licRevNext, LIC_REVOKE_CHECK_MS
    if A_TickCount >= licRevNext {
        licRevNext := A_TickCount + LIC_REVOKE_CHECK_MS
        Lic_RevokeFetchStart()
    }
    st := Lic_Recheck()
    blocked := Lic_ApplyToProfiles(profiles, st)
    key := st.state "|" blocked "|" st.daysLeft
    if key != licLastKey {
        first := licLastKey = ""
        licLastKey := key
        if !first || st.state != "ok" || blocked
            EventLog("GLOBAL", "LICENSE", "狀態=" st.state "｜剩 " st.daysLeft " 天｜未授權帳號 " blocked " 個")
        Lic_PushWeb()
    }
    warn := Lic_WarnText(st)
    today := SubStr(A_Now, 1, 8)
    if warn != "" {
        if licWarnedDate = ""
            licWarnedDate := IniRead(INI, "License", "WarnedDate", "")
        if licWarnedDate != today {
            licWarnedDate := today
            try IniWrite(today, INI, "License", "WarnedDate")
            SetTimer(() => MsgBox(warn, "HIHIYONG 授權提醒", "Iconi T120"), -1)
        }
    }
}

Lic_PushWeb() {
    global webReady, WVCore, licState, profiles
    if !webReady || !WVCore || !IsObject(licState)
        return
    names := ""
    for p in profiles
        if p.HasOwnProp("licensed") && !p.licensed
            names .= (names = "" ? "" : ",") '"' JsonEscapeWeb(p.name) '"'
    lic := licState.lic
    try WVCore.PostWebMessageAsJson('{"type":"license","data":{"state":"' licState.state '"'
        . ',"reason":"' JsonEscapeWeb(licState.state = "ok" ? "" : Lic_ReasonText(licState)) '"'
        . ',"user":"' JsonEscapeWeb(IsObject(lic) ? lic.user : "") '"'
        . ',"machine":"' licState.machineId '"'
        . ',"expires":"' (IsObject(lic) ? Lic_DateText(lic.expires) : "") '"'
        . ',"daysLeft":' licState.daysLeft
        . ',"mode":"' (IsObject(lic) ? lic.mode : "") '","count":' (IsObject(lic) ? lic.count : 0)
        . ',"blocked":[' names '],"warn":"' JsonEscapeWeb(Lic_WarnText(licState)) '"}}')
}

; 介面「更換授權檔」：選檔 → 驗簽 → 裝進 license\ → 立刻套用
Lic_PickAndInstall() {
    global licState, profiles
    f := FileSelect(1, A_ScriptDir, "選擇授權檔", "授權檔 (*.lic)")
    if f = ""
        return
    r := Lic_Install(f)
    if r.state != "ok" {
        MsgBox Lic_ReasonText(r), "授權檔無法使用", "Icon!"
        return
    }
    Lic_Load()
    Lic_ApplyToProfiles(profiles, licState)
    try SaveProfiles()
    EventLog("GLOBAL", "LICENSE", "已安裝新的授權檔｜使用者 " licState.lic.user "｜到 " Lic_DateText(licState.lic.expires))
    Lic_PushWeb()
}
