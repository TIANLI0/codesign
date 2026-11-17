# RFC 6238 TOTP for an otpauth:// URI. Certum SimplySign uses SHA256, 6 digits, 30 s; most TOTP libraries default
# to SHA1, which yields wrong codes. Dot-source this file; nothing here prints the secret.

Set-StrictMode -Version Latest

function ConvertFrom-OtpAuthUri {
    param([Parameter(Mandatory)][string]$Uri)

    $parsed = $null
    if (-not [Uri]::TryCreate($Uri.Trim(), [UriKind]::Absolute, [ref]$parsed) -or $parsed.Scheme -ne 'otpauth' -or $parsed.Host -ne 'totp') {
        throw 'CERTUM_OTPAUTH is not an otpauth://totp/ URI (paste the whole line of the activation QR code).'
    }
    $query = @{}
    foreach ($pair in $parsed.Query.TrimStart('?').Split('&', [StringSplitOptions]::RemoveEmptyEntries)) {
        $kv = $pair.Split('=', 2)
        $query[[Uri]::UnescapeDataString($kv[0]).ToLowerInvariant()] = if ($kv.Count -eq 2) { [Uri]::UnescapeDataString($kv[1]) } else { '' }
    }
    $secret = ([string]$query['secret']).Trim().TrimEnd('=').ToUpperInvariant()
    if ($secret -notmatch '^[A-Z2-7]{16,}$') { throw 'The otpauth URI has no valid base32 secret.' }
    $algorithm = if ($query['algorithm']) { ([string]$query['algorithm']).ToUpperInvariant() } else { 'SHA1' }
    if ($algorithm -notin 'SHA1', 'SHA256', 'SHA512') { throw "Unsupported TOTP algorithm $algorithm." }
    $digits = if ($query['digits']) { [int]$query['digits'] } else { 6 }
    $period = if ($query['period']) { [int]$query['period'] } else { 30 }
    if ($digits -notin 6, 7, 8 -or $period -lt 15 -or $period -gt 120) { throw 'Unsupported TOTP digits or period.' }

    [pscustomobject]@{ Secret = $secret; Algorithm = $algorithm; Digits = $digits; Period = $period }
}

function ConvertFrom-Base32 {
    param([Parameter(Mandatory)][string]$Text)
    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
    $bytes = [System.Collections.Generic.List[byte]]::new()
    $buffer = 0; $bits = 0
    foreach ($c in $Text.TrimEnd('=').ToUpperInvariant().ToCharArray()) {
        $v = $alphabet.IndexOf($c)
        if ($v -lt 0) { throw 'Invalid base32 character in the TOTP secret.' }
        $buffer = (($buffer -shl 5) -bor $v) -band 0xFFFF
        $bits += 5
        if ($bits -ge 8) { $bits -= 8; $bytes.Add([byte](($buffer -shr $bits) -band 0xFF)) }
    }
    , $bytes.ToArray()
}

function Get-TotpCode {
    param(
        [Parameter(Mandatory)][byte[]]$Key,
        [Parameter(Mandatory)][long]$Counter,
        [string]$Algorithm = 'SHA256',
        [int]$Digits = 6
    )
    $message = [BitConverter]::GetBytes([long]$Counter)
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($message) }
    $hmac = switch ($Algorithm) {
        'SHA1' { [System.Security.Cryptography.HMACSHA1]::new($Key) }
        'SHA256' { [System.Security.Cryptography.HMACSHA256]::new($Key) }
        'SHA512' { [System.Security.Cryptography.HMACSHA512]::new($Key) }
    }
    try { $hash = $hmac.ComputeHash($message) } finally { $hmac.Dispose() }
    $offset = $hash[$hash.Length - 1] -band 0x0F
    $binary = (([int]$hash[$offset] -band 0x7F) -shl 24) -bor ([int]$hash[$offset + 1] -shl 16) -bor ([int]$hash[$offset + 2] -shl 8) -bor [int]$hash[$offset + 3]
    ($binary % [int][Math]::Pow(10, $Digits)).ToString().PadLeft($Digits, '0')
}
