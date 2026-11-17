# RFC 6238 appendix B test vectors plus otpauth parsing. Run: pwsh -NoProfile -File tests/Totp.Tests.ps1
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\Totp.ps1')

$ascii = [Text.Encoding]::ASCII
$keys = @{
    SHA1   = $ascii.GetBytes('12345678901234567890')
    SHA256 = $ascii.GetBytes('12345678901234567890123456789012')
    SHA512 = $ascii.GetBytes('1234567890123456789012345678901234567890123456789012345678901234')
}
$vectors = @(
    @(59, 'SHA1', '94287082'), @(59, 'SHA256', '46119246'), @(59, 'SHA512', '90693936'),
    @(1111111109, 'SHA1', '07081804'), @(1111111109, 'SHA256', '68084774'), @(1111111109, 'SHA512', '25091201'),
    @(1234567890, 'SHA1', '89005924'), @(1234567890, 'SHA256', '91819424'), @(1234567890, 'SHA512', '93441116'),
    @(20000000000, 'SHA1', '65353130'), @(20000000000, 'SHA256', '77737706'), @(20000000000, 'SHA512', '47863826')
)
$failed = 0
foreach ($v in $vectors) {
    $code = Get-TotpCode -Key $keys[$v[1]] -Counter ([long][Math]::Floor([long]$v[0] / 30)) -Algorithm $v[1] -Digits 8
    if ($code -ne $v[2]) { Write-Host "FAIL t=$($v[0]) $($v[1]): $code, expected $($v[2])"; $failed++ }
}

# Base32 round trip: "12345678901234567890" = GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ
$decoded = ConvertFrom-Base32 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'
if ($ascii.GetString($decoded) -ne '12345678901234567890') { Write-Host 'FAIL base32'; $failed++ }

$p = ConvertFrom-OtpAuthUri 'otpauth://totp/Certum%3Auser%40example.com?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ====&issuer=Certum&algorithm=SHA256&digits=6&period=30'
if ($p.Algorithm -ne 'SHA256' -or $p.Digits -ne 6 -or $p.Period -ne 30 -or $p.Secret -ne 'GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ') { Write-Host 'FAIL otpauth parse'; $failed++ }
try { ConvertFrom-OtpAuthUri 'https://example.com' | Out-Null; Write-Host 'FAIL accepted a non-otpauth URI'; $failed++ } catch { }

if ($failed) { throw "$failed TOTP test(s) failed" }
Write-Host "All $($vectors.Count + 3) TOTP tests passed."
