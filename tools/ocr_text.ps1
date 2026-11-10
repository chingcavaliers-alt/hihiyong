# 用 Windows 內建文字辨識（OCR）讀一張圖，結果以 UTF-8 寫到 -Out（一行一行）。
# -Crop "x,y,w,h"：先裁切；-Scale：放大倍數（遊戲字很小，放大 3 倍辨識比較準）。必須用 Windows PowerShell（powershell.exe）執行。
param([string]$Path, [string]$Out, [string]$Crop = "", [int]$Scale = 3, [string]$Lang = "zh-Hant-TW")
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Runtime.WindowsRuntime
Add-Type -AssemblyName System.Drawing
$null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Storage.StorageFile, Windows.Foundation, ContentType = WindowsRuntime]
$null = [Windows.Globalization.Language, Windows.Foundation, ContentType = WindowsRuntime]
function Await($op, $type) {
    $m = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0].MakeGenericMethod($type)
    $t = $m.Invoke($null, @($op)); $t.Wait(); $t.Result
}
$src = (Resolve-Path $Path).Path
$tmp = Join-Path $env:TEMP ("hihiyong_ocr_" + [guid]::NewGuid().ToString("N") + ".png")
try {
    $img = [System.Drawing.Image]::FromFile($src)
    $x = 0; $y = 0; $w = $img.Width; $h = $img.Height
    if ($Crop) { $c = $Crop.Split(",") | ForEach-Object { [int]$_ }; $x = $c[0]; $y = $c[1]; $w = $c[2]; $h = $c[3] }
    $bmp = New-Object System.Drawing.Bitmap ($w * $Scale), ($h * $Scale)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.DrawImage($img, (New-Object System.Drawing.Rectangle 0, 0, ($w * $Scale), ($h * $Scale)), $x, $y, $w, $h, [System.Drawing.GraphicsUnit]::Pixel)
    $g.Dispose(); $img.Dispose()
    $bmp.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    $file = Await ([Windows.Storage.StorageFile]::GetFileFromPathAsync($tmp)) ([Windows.Storage.StorageFile])
    $stream = Await ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    $dec = Await ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $sb = Await ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $eng = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage([Windows.Globalization.Language]::new($Lang))
    if (-not $eng) { $eng = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages() }
    $res = Await ($eng.RecognizeAsync($sb)) ([Windows.Media.Ocr.OcrResult])
    $lines = @(); foreach ($l in $res.Lines) { $lines += $l.Text }
    [System.IO.File]::WriteAllText($Out, ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding($true)))
} finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
}
