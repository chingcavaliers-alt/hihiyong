; 設定檔編碼：Windows 的 IniRead / IniWrite 遇到沒有 BOM 的檔案，一律用系統 ANSI 字碼頁（繁中 Windows = CP950）讀寫。
; 11/17 發現 HIHIYONG_AutoRecovery.ini 不知何時被存成沒有 BOM 的 UTF-8（10/22 的備份還是 UTF-16），之後程式用 CP950 讀到亂碼，
; 每日討伐的「起點傳送卡」讀成「韏琿??喲」又被寫回去，快捷欄一直找不到卡；新寫入的角色名稱則是 CP950，同一個角色在檔案裡有兩種寫法。
; 啟動時（任何 IniRead 之前）檢查：沒有 UTF-16 BOM 就先備份，逐行判斷是 UTF-8 還是 CP950 轉回正確文字，
; 同一區段重複的 key 留最後一筆（後面的是之後才寫入的），存成 UTF-16 LE（有 BOM），之後不管系統字碼頁是什麼都不會再亂。
; 回傳轉換的行數；已經是 UTF-16 / 檔案不存在回傳 0。
IniEnsureUnicode(path) {
    if !FileExist(path)
        return 0
    raw := FileRead(path, "RAW")
    n := raw.Size
    if n >= 2 && NumGet(raw, 0, "UChar") = 0xFF && NumGet(raw, 1, "UChar") = 0xFE
        return 0
    start := (n >= 3 && NumGet(raw, 0, "UChar") = 0xEF && NumGet(raw, 1, "UChar") = 0xBB && NumGet(raw, 2, "UChar") = 0xBF) ? 3 : 0
    lines := [], converted := 0, i := start
    while i < n {
        j := i
        while j < n && NumGet(raw, j, "UChar") != 10
            j += 1
        len := j - i
        if len > 0 && NumGet(raw, i + len - 1, "UChar") = 13
            len -= 1
        enc := IniLineIsUtf8(raw, i, len) ? "UTF-8" : "CP950"
        line := len > 0 ? StrGet(raw.Ptr + i, len, enc) : ""
        if enc = "CP950"
            converted += 1
        lines.Push(line)
        i := j + 1
    }
    ; 同一區段同一個 key 只留最後一筆（舊的 UTF-8 / 新的 CP950 轉完會變成同一個 key）
    last := Map(), sec := ""
    for idx, line in lines {
        t := Trim(line)
        if SubStr(t, 1, 1) = "[" {
            sec := t
            continue
        }
        if (p := InStr(t, "=")) && SubStr(t, 1, 1) != ";"
            last[sec "`n" Trim(SubStr(t, 1, p - 1))] := idx
    }
    out := "", sec := "", dropped := 0
    for idx, line in lines {
        t := Trim(line)
        if SubStr(t, 1, 1) = "[" {
            sec := t
        } else if (p := InStr(t, "=")) && SubStr(t, 1, 1) != ";" && last[sec "`n" Trim(SubStr(t, 1, p - 1))] != idx {
            dropped += 1
            continue
        }
        out .= line "`r`n"
    }
    try FileCopy(path, path ".bak_encoding_" FormatTime(, "yyyyMMdd_HHmmss"), true)
    f := FileOpen(path, "w", "UTF-16")
    f.Write(out)
    f.Close()
    return {cp950: converted, dropped: dropped}
}

; 這一段位元組是不是合法的 UTF-8（純 ASCII 也算）
IniLineIsUtf8(buf, off, len) {
    k := 0
    while k < len {
        b := NumGet(buf, off + k, "UChar")
        if b < 0x80 {
            k += 1
            continue
        }
        need := b >= 0xF0 && b <= 0xF4 ? 3 : b >= 0xE0 ? (b <= 0xEF ? 2 : -1) : b >= 0xC2 && b <= 0xDF ? 1 : -1
        if need < 0 || k + need > len - 1
            return false
        Loop need {
            c := NumGet(buf, off + k + A_Index, "UChar")
            if c < 0x80 || c > 0xBF
                return false
        }
        k += need + 1
    }
    return true
}
