# Authenticode-signs files with the Certum certificate that Connect-SimplySign.ps1 made available, then verifies
# signer, chain and RFC 3161 timestamp of every file. Usable as the `sign` action or directly from build scripts:
#   & $env:CODESIGN_SIGN -Root out/app -Path 'MyApp.exe', 'MyApp*.dll' -Description 'MyApp'
# Patterns are relative to -Root; '*' matches within a folder, '**/' any number of folders. Every pattern must match
# at least one file (unless -AllowMissing), so a renamed binary cannot silently ship unsigned.
# Files that already carry a valid signature by another publisher (Microsoft runtime, vendor installers) are never
# re-signed; files already signed by our certificate are left as they are.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string[]]$Path,
    [string]$Root = '.',
    [string]$Description = '',
    [string]$DescriptionUrl = '',
    [switch]$AllowMissing
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$thumbprint = "$env:CODESIGN_THUMBPRINT"
$signtool = "$env:CODESIGN_SIGNTOOL"
$timestamp = if ($env:CODESIGN_TIMESTAMP_URL) { $env:CODESIGN_TIMESTAMP_URL } else { 'http://time.certum.pl' }
if ($thumbprint -notmatch '^[0-9A-F]{40}$') { throw 'CODESIGN_THUMBPRINT is not set: run the TIANLI0/codesign login action first.' }
if (-not (Test-Path -LiteralPath $signtool)) { throw 'CODESIGN_SIGNTOOL is not set: run the TIANLI0/codesign login action first.' }

$rootFull = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\', '/')
$signable = '.exe', '.dll', '.sys', '.msi', '.cat', '.ocx', '.ps1', '.psm1'

function ConvertTo-Regex([string]$glob) {
    $g = $glob.Trim().Replace('\', '/').TrimStart('/')
    $sb = [Text.StringBuilder]::new('^')
    for ($i = 0; $i -lt $g.Length; $i++) {
        $c = $g[$i]
        if ($c -eq '*' -and $g.Substring($i).StartsWith('**/')) { [void]$sb.Append('(?:.*/)?'); $i += 2 }
        elseif ($c -eq '*' -and $g.Substring($i).StartsWith('**')) { [void]$sb.Append('.*'); $i += 1 }
        elseif ($c -eq '*') { [void]$sb.Append('[^/]*') }
        elseif ($c -eq '?') { [void]$sb.Append('[^/]') }
        else { [void]$sb.Append([Regex]::Escape([string]$c)) }
    }
    [void]$sb.Append('$')
    [Regex]::new($sb.ToString(), 'IgnoreCase')
}

$all = @(Get-ChildItem -LiteralPath $rootFull -Recurse -File | ForEach-Object {
        [pscustomobject]@{ Full = $_.FullName; Rel = $_.FullName.Substring($rootFull.Length + 1).Replace('\', '/') }
    })
$selected = [ordered]@{}
foreach ($pattern in ($Path | ForEach-Object { $_ -split "`r?`n" } | ForEach-Object Trim | Where-Object { $_ -and -not $_.StartsWith('#') })) {
    $rx = ConvertTo-Regex $pattern
    $hits = @($all | Where-Object { $rx.IsMatch($_.Rel) })
    if (-not $hits -and -not $AllowMissing) { throw "No file under $rootFull matches '$pattern'." }
    foreach ($h in $hits) {
        if ([IO.Path]::GetExtension($h.Full).ToLowerInvariant() -notin $signable) { throw "Not an Authenticode-signable file: $($h.Rel)" }
        $selected[$h.Full] = $h.Rel
    }
}

$toSign = [System.Collections.Generic.List[string]]::new()
foreach ($file in $selected.Keys) {
    $sig = Get-AuthenticodeSignature -LiteralPath $file
    if ($sig.Status -eq 'Valid' -and $sig.SignerCertificate.Thumbprint -eq $thumbprint) { Write-Host "already signed: $($selected[$file])"; continue }
    if ($sig.Status -eq 'Valid') { Write-Host "::warning::Skipping $($selected[$file]): already signed by $($sig.SignerCertificate.Subject)"; continue }
    if ($sig.Status -ne 'NotSigned') { throw "$($selected[$file]) has a broken signature ($($sig.Status)); rebuild it instead of signing over it." }
    $toSign.Add($file)
}

$common = @('sign', '/fd', 'SHA256', '/tr', $timestamp, '/td', 'SHA256', '/sha1', $thumbprint)
if ($Description) { $common += @('/d', $Description) }
if ($DescriptionUrl) { $common += @('/du', $DescriptionUrl) }
for ($start = 0; $start -lt $toSign.Count; $start += 16) {
    $batch = $toSign.GetRange($start, [Math]::Min(16, $toSign.Count - $start)).ToArray()
    for ($try = 1; ; $try++) {
        & $signtool @common @batch
        if ($LASTEXITCODE -eq 0) { break }
        if ($try -ge 4) { throw "signtool failed (exit code $LASTEXITCODE) after $try attempts." }
        Write-Host "signtool exit code $LASTEXITCODE (timestamp server or cloud HSM hiccup); retrying in $(10 * $try) s..."
        Start-Sleep -Seconds (10 * $try)
    }
}

$summary = [System.Collections.Generic.List[string]]::new()
foreach ($file in $selected.Keys) {
    $sig = Get-AuthenticodeSignature -LiteralPath $file
    if ($sig.Status -ne 'Valid') { throw "Verification failed for $($selected[$file]): $($sig.Status) $($sig.StatusMessage)" }
    $ours = $sig.SignerCertificate.Thumbprint -eq $thumbprint
    if ($ours -and -not $sig.TimeStamperCertificate) { throw "$($selected[$file]) has no timestamp." }
    $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
    $who = if ($ours) { 'signed' } else { 'third-party, kept' }
    Write-Host ("{0,-18} {1}  {2}" -f $who, $hash, $selected[$file])
    $summary.Add("| ``$($selected[$file])`` | $who | ``$hash`` |")
}
if ($env:GITHUB_STEP_SUMMARY -and $summary.Count) {
    @("### Code signing ($($toSign.Count) signed now)", '', '| File | Status | SHA-256 |', '|---|---|---|') + $summary + '' |
        Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}
