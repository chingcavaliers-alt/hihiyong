# 擷取遊戲視窗畫面存成 PNG（看聊天欄訊息、有沒有視窗擋住）。
#   預設：每個遊戲視窗用 PrintWindow 擷取（不切換視窗；有些遊戲畫面會擷取成全黑）
#   -Activate：先把指定視窗（-Hwnd）叫到前面再擷取螢幕上的那一塊（會短暫搶前景，打王中盡量少用）
param([string]$OutDir = $env:TEMP, [switch]$Activate, [int64]$Hwnd = 0)
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices; using System.Text;
public class HihiWin {
  public delegate bool EP(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EP f, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out R r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  public struct R { public int L, T, Ri, B; }
}
'@
$wins = New-Object System.Collections.ArrayList
[HihiWin]::EnumWindows({ param($h, $l)
    $sb = New-Object Text.StringBuilder 64; [HihiWin]::GetWindowText($h, $sb, 64) | Out-Null
    $r = New-Object HihiWin+R; [HihiWin]::GetWindowRect($h, [ref]$r) | Out-Null
    if ([HihiWin]::IsWindowVisible($h) -and $sb.ToString() -like 'HIHIYong*' -and ($r.Ri - $r.L) -gt 300) {
        $procId = 0; [HihiWin]::GetWindowThreadProcessId($h, [ref]$procId) | Out-Null
        [void]$wins.Add([pscustomobject]@{ H = $h; R = $r; Pid = $procId })
    }
    $true }, [IntPtr]::Zero) | Out-Null
foreach ($w in $wins) {
    if ($Hwnd -and [int64]$w.H -ne $Hwnd) { continue }
    $wd = $w.R.Ri - $w.R.L; $ht = $w.R.B - $w.R.T
    $b = New-Object Drawing.Bitmap $wd, $ht; $g = [Drawing.Graphics]::FromImage($b)
    if ($Activate) {
        [HihiWin]::SetForegroundWindow($w.H) | Out-Null; Start-Sleep -Milliseconds 600
        $g.CopyFromScreen($w.R.L, $w.R.T, 0, 0, $b.Size)
    } else {
        $dc = $g.GetHdc(); [HihiWin]::PrintWindow($w.H, $dc, 2) | Out-Null; $g.ReleaseHdc($dc)
    }
    $f = Join-Path $OutDir ("hihi_shot_{0}_{1}.png" -f $w.Pid, (Get-Date -Format HHmmss))
    $b.Save($f); "PID $($w.Pid) HWND $([int64]$w.H) → $f"
}
