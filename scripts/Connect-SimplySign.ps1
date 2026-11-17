# Signs in to SimplySign Desktop with a TOTP generated from the otpauth:// URI and waits until the Certum
# code-signing certificate is usable from CurrentUser\My. Secrets come from the environment only:
#   CODESIGN_EMAIL     SimplySign account e-mail
#   CODESIGN_OTPAUTH   the full otpauth://totp/... URI of the activation QR code
#   CODESIGN_THUMBPRINT_EXPECTED (optional) SHA-1 thumbprint the certificate must have
# Nothing secret is printed; every generated code is masked in the log before it is used.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'Totp.ps1')

$trim = [char[]]@([char]0xFEFF, ' ', "`t", "`r", "`n", '"', "'")
$email = "$env:CODESIGN_EMAIL".Trim($trim)
$otpUri = "$env:CODESIGN_OTPAUTH".Trim($trim)
$expected = ("$env:CODESIGN_THUMBPRINT_EXPECTED" -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
$exe = if ($env:CODESIGN_SIMPLYSIGN_EXE) { $env:CODESIGN_SIMPLYSIGN_EXE } else { Join-Path $env:ProgramFiles 'Certum\SimplySign Desktop\SimplySignDesktop.exe' }

if (-not $email -or -not $otpUri) {
    throw 'CERTUM_EMAIL / CERTUM_OTPAUTH are empty. The job needs "environment: codesign" and the secrets set in that environment (see README).'
}
if ($expected -and $expected.Length -ne 40) { throw 'thumbprint must be 40 hexadecimal characters (SHA-1).' }
$otp = ConvertFrom-OtpAuthUri $otpUri
Write-Host "::add-mask::$($otp.Secret)"
$key = ConvertFrom-Base32 $otp.Secret

function Get-Period { [long][Math]::Floor([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() / $otp.Period) }

# A fresh code early in its window, from a period after the last attempt (Certum rejects a second try in a
# period whose code was already refused, and validates a few seconds after submission).
$script:lastPeriod = -1L
function Get-FreshCode {
    while ($true) {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $period = [long][Math]::Floor($now / $otp.Period)
        $left = $otp.Period - ($now % $otp.Period)
        if ($period -gt $script:lastPeriod -and $left -ge 20) { break }
        Start-Sleep -Seconds ($left + 1)
    }
    $script:lastPeriod = $period
    $code = Get-TotpCode -Key $key -Counter $period -Algorithm $otp.Algorithm -Digits $otp.Digits
    Write-Host "::add-mask::$code"
    $code
}

function Find-SigningCertificate {
    $all = @(Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue | Where-Object {
            $_.HasPrivateKey -and ($_.EnhancedKeyUsageList | Where-Object { $_.ObjectId -eq '1.3.6.1.5.5.7.3.3' }) -and
            $_.NotBefore -le (Get-Date) -and $_.NotAfter -gt (Get-Date)
        })
    if ($expected) { return @($all | Where-Object { $_.Thumbprint -eq $expected }) | Select-Object -First 1 }
    $certum = @($all | Where-Object { $_.Issuer -match 'Certum' })
    if ($certum.Count -gt 1) { throw "Several Certum code-signing certificates are available ($($certum.Thumbprint -join ', ')); set the CERTUM_THUMBPRINT variable." }
    $certum | Select-Object -First 1
}

function Wait-Certificate([int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $c = Find-SigningCertificate
        if ($c) { return $c }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    $null
}

function Write-Windows {
    Add-Type -Namespace CodeSign -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, System.IntPtr p);
[DllImport("user32.dll")] public static extern int GetWindowText(System.IntPtr h, System.Text.StringBuilder s, int n);
[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
[DllImport("user32.dll")] public static extern bool IsWindowVisible(System.IntPtr h);
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
public delegate bool EnumProc(System.IntPtr h, System.IntPtr p);
'@ -ErrorAction SilentlyContinue
    $ids = @(Get-Process SimplySignDesktop -ErrorAction SilentlyContinue | ForEach-Object Id)
    $found = [System.Collections.Generic.List[object]]::new()
    [CodeSign.Win+EnumProc]$cb = {
        param($h, $p)
        [uint32]$procId = 0
        [void][CodeSign.Win]::GetWindowThreadProcessId($h, [ref]$procId)
        if ($ids -contains $procId -and [CodeSign.Win]::IsWindowVisible($h)) {
            $sb = [Text.StringBuilder]::new(256); [void][CodeSign.Win]::GetWindowText($h, $sb, 256)
            $found.Add([pscustomobject]@{ Handle = $h; Title = $sb.ToString() })
        }
        $true
    }
    [void][CodeSign.Win]::EnumWindows($cb, [IntPtr]::Zero)
    Write-Host "SimplySign processes: $($ids.Count); visible windows: $(($found | ForEach-Object { "'$($_.Title)'" }) -join ', ')"
    $found
}

$cert = $null
# 1) The client's own unattended login: SimplySignDesktop.exe /autologin <account> <token>.
for ($attempt = 1; $attempt -le 3 -and -not $cert; $attempt++) {
    $code = Get-FreshCode
    Write-Host "Login attempt $attempt (/autologin)..."
    Start-Process -FilePath $exe -ArgumentList @('/autologin', $email, $code) | Out-Null
    $cert = Wait-Certificate 45
    if (-not $cert) { Write-Windows | Out-Null }
}

# 2) Fallback: fill in the login dialog (account, Tab, token, Enter) through the clipboard.
if (-not $cert) {
    Write-Host 'Falling back to the login dialog...'
    & $exe /close 2>$null; Start-Sleep -Seconds 3
    Get-Process SimplySignDesktop -ErrorAction SilentlyContinue | Stop-Process -Force
    New-ItemProperty -Path 'HKCU:\Software\Certum\SimplySign' -Name ShowLoginDialogOnStart -Value 1 -PropertyType DWord -Force | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    for ($attempt = 1; $attempt -le 2 -and -not $cert; $attempt++) {
        if (-not (Get-Process SimplySignDesktop -ErrorAction SilentlyContinue)) { Start-Process -FilePath $exe | Out-Null }
        $dialog = $null
        for ($i = 0; $i -lt 30 -and -not $dialog; $i++) {
            Start-Sleep -Seconds 1
            $dialog = Write-Windows | Where-Object { $_.Title -match 'SimplySign|Log ?in|Sign ?in' } | Select-Object -First 1
        }
        if (-not $dialog) { continue }
        $code = Get-FreshCode
        [void][CodeSign.Win]::SetForegroundWindow($dialog.Handle); Start-Sleep -Milliseconds 500
        Set-Clipboard -Value $email; $shell.SendKeys('^a'); $shell.SendKeys('{DEL}'); $shell.SendKeys('^v'); Start-Sleep -Milliseconds 300
        $shell.SendKeys('{TAB}'); Start-Sleep -Milliseconds 300
        Set-Clipboard -Value $code; $shell.SendKeys('^a'); $shell.SendKeys('{DEL}'); $shell.SendKeys('^v'); Start-Sleep -Milliseconds 300
        $shell.SendKeys('{ENTER}')
        Set-Clipboard -Value ' '
        $cert = Wait-Certificate 45
        if (-not $cert) { $shell.SendKeys('{ENTER}'); Start-Sleep -Seconds 2 }  # dismiss an error box, if any
    }
}

if (-not $cert) { throw 'SimplySign login failed: no Certum code-signing certificate appeared in CurrentUser\My. Check the e-mail/otpauth secrets and that the certificate is active.' }

Write-Host "Connected. Certificate: $($cert.Subject)"
Write-Host "  issuer:     $($cert.Issuer)"
Write-Host "  thumbprint: $($cert.Thumbprint)"
Write-Host "  valid to:   $($cert.NotAfter.ToString('yyyy-MM-dd'))"
if ($cert.NotAfter -lt (Get-Date).AddDays(30)) { Write-Host "::warning::The code-signing certificate expires on $($cert.NotAfter.ToString('yyyy-MM-dd')). Renew it at Certum." }
if (-not $expected) { Write-Host "::notice::Pin this certificate: set the variable CERTUM_THUMBPRINT=$($cert.Thumbprint) in the codesign environment." }

if ($env:GITHUB_ENV) {
    "CODESIGN_THUMBPRINT=$($cert.Thumbprint)" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
    "CODESIGN_TIMESTAMP_URL=http://time.certum.pl" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
    "CODESIGN_SIGN=$(Join-Path $PSScriptRoot 'Sign-Files.ps1')" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
}
if ($env:GITHUB_OUTPUT) { "thumbprint=$($cert.Thumbprint)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append -Encoding utf8 }
