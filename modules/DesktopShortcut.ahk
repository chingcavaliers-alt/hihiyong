; ============================================================================
; v1.3.22.0 桌面捷徑與自訂圖示。
;
; 發佈包最上層的啟動檔（HiHiyong帳號管理.bat）每次啟動時會在桌面建立同名捷徑，
; 圖示用 app\HiHiyong.ico（沒有就用 app\HiHiyong_default.ico）。
; 這裡提供設定頁的三個按鈕：重新建立捷徑、更換圖示（png / jpg / bmp / ico 都可以，
; 自動轉成 256/48/32/16 的 ico）、還原預設圖示。
; 開發資料夾沒有上一層的啟動檔，只會提示「找不到啟動檔」。
; ============================================================================

DesktopShortcutIcon() => A_ScriptDir "\HiHiyong.ico"

; 上一層資料夾裡內容有「HIHIYONG launcher」的 .bat 就是啟動檔（檔名就是捷徑名稱）
DesktopShortcutLauncher() {
    SplitPath A_ScriptDir,,&root
    loop files root "\*.bat" {
        try {
            if InStr(FileRead(A_LoopFileFullPath),"HIHIYONG launcher")
                return A_LoopFileFullPath
        }
    }
    return ""
}

DesktopShortcutCreate(quiet:=false) {
    bat:=DesktopShortcutLauncher()
    if bat="" {
        if !quiet
            AddRecentEvent("⚠ 找不到啟動檔（HiHiyong帳號管理.bat），只有從發佈包執行時才能建立桌面捷徑")
        return false
    }
    SplitPath bat,,&dir,,&name
    ico:=FileExist(DesktopShortcutIcon()) ? DesktopShortcutIcon() : A_ScriptDir "\HiHiyong_default.ico"
    lnk:=A_Desktop "\" name ".lnk"
    try {
        try FileDelete lnk
        FileCreateShortcut bat,lnk,dir,,"HiHiyong 多帳號管理器",FileExist(ico) ? ico : "",,,7
    } catch as e {
        AddRecentEvent("⚠ 建立桌面捷徑失敗：" e.Message)
        return false
    }
    ; 通知檔案總管重新讀圖示（同一個檔名換了內容，不通知會一直顯示舊圖示）
    DllCall("shell32\SHChangeNotify","Int",0x08000000,"UInt",0,"Ptr",0,"Ptr",0)
    if !quiet
        AddRecentEvent("🖥️ 已建立桌面捷徑「" name "」")
    return true
}

DesktopShortcutChooseIcon() {
    src:=FileSelect(1,,"選擇桌面捷徑的圖示","圖片 (*.png; *.jpg; *.jpeg; *.bmp; *.ico)")
    if src=""
        return
    dst:=DesktopShortcutIcon(), tmp:=dst ".tmp"
    DesktopShortcutConvert(src,tmp)
    if !FileExist(tmp) {
        AddRecentEvent("⚠ 這張圖片無法轉成圖示，請換一張 png / jpg 試試")
        return
    }
    try {
        FileMove tmp,dst,true
    } catch as e {
        AddRecentEvent("⚠ 更換圖示失敗：" e.Message)
        return
    }
    AppApplyIcon()
    if DesktopShortcutCreate(true)
        AddRecentEvent("🖼️ 已更換桌面捷徑圖示")
    else
        AddRecentEvent("🖼️ 圖示已儲存（從發佈包啟動後會套用到桌面捷徑）")
}

; 圖片轉成 ico 存到 tmp；.ico 直接複製。失敗時 tmp 不會存在。
DesktopShortcutConvert(src, tmp) {
    try FileDelete tmp
    SplitPath src,,,&ext
    if ext="ico" {
        try FileCopy src,tmp,true
    } else {
        ; 等比例縮進正方形（不足的地方透明），每個尺寸存成 PNG 再包成 ico
        q:=(t)=>"'" StrReplace(t,"'","''") "'"
        ps:="$ErrorActionPreference='Stop';Add-Type -AssemblyName System.Drawing;$img=[Drawing.Image]::FromFile(" q(src) ");$sizes=256,48,32,16;$pngs=@();"
          . "foreach($s in $sizes){$b=New-Object Drawing.Bitmap $s,$s;$g=[Drawing.Graphics]::FromImage($b);$g.InterpolationMode='HighQualityBicubic';$g.SmoothingMode='HighQuality';$g.Clear([Drawing.Color]::Transparent);"
          . "$r=[Math]::Min($s/$img.Width,$s/$img.Height);$w=[int]($img.Width*$r);$h=[int]($img.Height*$r);$g.DrawImage($img,[int](($s-$w)/2),[int](($s-$h)/2),$w,$h);"
          . "$m=New-Object IO.MemoryStream;$b.Save($m,[Drawing.Imaging.ImageFormat]::Png);$pngs+=,($m.ToArray());$g.Dispose();$b.Dispose()};$img.Dispose();"
          . "$bw=New-Object IO.BinaryWriter([IO.File]::Create(" q(tmp) "));$bw.Write([uint16]0);$bw.Write([uint16]1);$bw.Write([uint16]$sizes.Count);$off=6+16*$sizes.Count;"
          . "for($i=0;$i -lt $sizes.Count;$i++){$s=$sizes[$i];$bw.Write([byte]($s%256));$bw.Write([byte]($s%256));$bw.Write([byte]0);$bw.Write([byte]0);$bw.Write([uint16]1);$bw.Write([uint16]32);$bw.Write([uint32]$pngs[$i].Length);$bw.Write([uint32]$off);$off+=$pngs[$i].Length};"
          . "foreach($p in $pngs){$bw.Write($p)};$bw.Close()"
        try RunWait("powershell -NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand " PowerShellEncodedCommand(ps),,"Hide")
    }
}

DesktopShortcutResetIcon() {
    try FileDelete DesktopShortcutIcon()
    AppApplyIcon()
    if DesktopShortcutCreate(true)
        AddRecentEvent("↺ 桌面捷徑已換回預設圖示")
}

; 管理程式自己的圖示（工作列、視窗標題列、系統匣、介面左上角）跟桌面捷徑用同一個檔案
AppIconFile() => FileExist(DesktopShortcutIcon()) ? DesktopShortcutIcon() : A_ScriptDir "\HiHiyong_default.ico"

AppApplyIcon() {
    global WebGui,WVCore
    ico:=AppIconFile()
    if !FileExist(ico)
        return
    try TraySetIcon(ico)
    if WebGui {
        try {
            big:=LoadPicture(ico,"Icon1 w" SysGet(11) " h" SysGet(12),&t1)
            small:=LoadPicture(ico,"Icon1 w" SysGet(49) " h" SysGet(50),&t2)
            SendMessage(0x80,1,big,WebGui.Hwnd)   ; WM_SETICON ICON_BIG
            SendMessage(0x80,0,small,WebGui.Hwnd) ; WM_SETICON ICON_SMALL
        }
    }
    if WVCore
        try WVCore.ExecuteScriptAsync("window.refreshLogo&&refreshLogo()")
}
