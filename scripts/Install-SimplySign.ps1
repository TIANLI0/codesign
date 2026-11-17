# Installs the pinned SimplySign Desktop build on a disposable Windows runner and configures it for unattended use.
# The installer is checked twice before it runs: its SHA-256 against the pin below and its Authenticode publisher.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$version = '9.4.3.90'
$url = "https://files.certum.eu/software/SimplySignDesktop/Windows/$version/SimplySignDesktop-$version-64-bit-en.msi"
$sha256 = 'CE2B38EF0124A574BC08E5558726099CAAC79A7C58B8D3D712F629371FE1BCB7'
$installDir = Join-Path $env:ProgramFiles 'Certum\SimplySign Desktop'
$exe = Join-Path $installDir 'SimplySignDesktop.exe'

if (-not $IsWindows -and $PSVersionTable.PSEdition -eq 'Core') { throw 'Certum SimplySign signing needs a Windows runner.' }
if ([Environment]::Is64BitOperatingSystem -eq $false) { throw 'SimplySign Desktop needs 64-bit Windows.' }

if (-not (Test-Path -LiteralPath $exe)) {
    $msi = Join-Path ([IO.Path]::GetTempPath()) "SimplySignDesktop-$version.msi"
    for ($i = 1; ; $i++) {
        try { Invoke-WebRequest -Uri $url -OutFile $msi -TimeoutSec 180 -UseBasicParsing; break }
        catch { if ($i -ge 3) { throw }; Write-Host "Download attempt $i failed: $($_.Exception.Message)"; Start-Sleep -Seconds (5 * $i) }
    }
    $actual = (Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash
    if ($actual -ne $sha256) { throw "SimplySign installer hash $actual does not match the pinned $version build ($sha256)." }
    $signature = Get-AuthenticodeSignature -LiteralPath $msi
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Asseco|Certum') {
        throw "SimplySign installer signature is not a valid Asseco/Certum signature ($($signature.Status), $($signature.SignerCertificate.Subject))."
    }
    $p = Start-Process msiexec.exe -ArgumentList @('/i', "`"$msi`"", '/quiet', '/norestart', 'ALLUSERS=1', 'REBOOT=ReallySuppress') -PassThru -Wait
    if ($p.ExitCode -notin 0, 3010) { throw "SimplySign installation failed (msiexec exit code $($p.ExitCode))." }
    Remove-Item -LiteralPath $msi -Force
}
if (-not (Test-Path -LiteralPath $exe)) { throw "SimplySign Desktop is missing after installation: $exe" }

# Unattended settings (no credentials are stored here):
# - no login dialog when signtool asks for the key: a dropped session fails fast instead of hanging the job;
# - certificates stay registered in CurrentUser\My while connected, so signtool finds them by thumbprint.
$key = 'HKCU:\Software\Certum\SimplySign'
New-Item -Path $key -Force | Out-Null
$settings = [ordered]@{
    ShowLoginDialogOnStart = 0; ShowLoginDialogOnAppRequest = 0; RememberLastUserName = 0; Autostart = 0
    UnregisterCertificatesOnDisconnect = 1; RememberPINinCSP = 1; ForgetPINinCSPonDisconnect = 1; LangID = 9
}
foreach ($name in $settings.Keys) { New-ItemProperty -Path $key -Name $name -Value $settings[$name] -PropertyType DWord -Force | Out-Null }

$signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin\10.*\x64\signtool.exe" -ErrorAction SilentlyContinue |
    Sort-Object { [version]$_.Directory.Parent.Name } -Descending | Select-Object -First 1
if (-not $signtool) { throw 'signtool.exe (Windows SDK) not found on this runner.' }

if ($env:GITHUB_ENV) {
    "CODESIGN_SIMPLYSIGN_EXE=$exe" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
    "CODESIGN_SIGNTOOL=$($signtool.FullName)" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
}
Write-Host "SimplySign Desktop $version installed; signtool: $($signtool.FullName)"
