# Verify a license file. On success writes the verified payload to -out and exits 0.
#   exit 2 = bad file format   exit 3 = signature mismatch (tampered or signed by another key)
# Keep this file ASCII-only: Windows PowerShell 5.1 misreads UTF-8 without BOM.
param([string]$file, [string]$key, [string]$out)
$ErrorActionPreference = 'Stop'
try {
  $text = [IO.File]::ReadAllText($file, (New-Object Text.UTF8Encoding $false)) -replace "`r`n", "`n"
  $i = $text.LastIndexOf("`nsig=")
  if ($i -lt 0) { exit 2 }
  $payload = $text.Substring(0, $i + 1)
  $sig = [Convert]::FromBase64String($text.Substring($i + 5).Trim())
  $rsa = New-Object Security.Cryptography.RSACryptoServiceProvider
  $rsa.FromXmlString($key)
  $bytes = (New-Object Text.UTF8Encoding $false).GetBytes($payload)
  if (-not $rsa.VerifyData($bytes, 'SHA256', $sig)) { exit 3 }
  [IO.File]::WriteAllBytes($out, $bytes)
  exit 0
} catch { exit 2 }
