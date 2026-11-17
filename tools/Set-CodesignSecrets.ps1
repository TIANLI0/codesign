# Run locally (needs gh, logged in as the repositories' owner). Creates the `codesign` environment in each
# repository, limits it to the release refs, and stores the Certum credentials there. The values go to `gh` through
# a short-lived file: they never appear on a command line, in the shell history or in this script's output.
#
#   ./tools/Set-CodesignSecrets.ps1 -Email you@example.com -OtpAuthFile D:\secure\otpauth.txt
#   ./tools/Set-CodesignSecrets.ps1 -Thumbprint 0123...   # only (re)write the CERTUM_THUMBPRINT variable
# Every call is retried (flaky connections to api.github.com); the script is idempotent and ends with a check.
param(
    [string[]]$Repository = @('TIANLI0/codesign', 'TIANLI0/THRM', 'TIANLI0/EncoDeck', 'TIANLI0/MediaDuet', 'TIANLI0/FluentSetup'),
    [string]$Email,
    [string]$OtpAuthFile,
    [string]$Thumbprint,
    # Refs allowed to use the environment (and therefore to sign).
    [string[]]$Branches = @('main'),
    [string[]]$Tags = @('v*', 'V*')
)
$ErrorActionPreference = 'Stop'
$env:GH_PROMPT_DISABLED = '1'

function Invoke-Gh {
    for ($i = 1; ; $i++) {
        $out = & gh @args 2>&1
        if ($LASTEXITCODE -eq 0) { return $out }
        if ("$out" -match 'already exists') { return $null }
        if ($i -ge 6) { throw "gh $($args[0..1] -join ' ') failed: $out" }
        Start-Sleep -Seconds (3 * $i)
    }
}

$otp = $null
if ($OtpAuthFile) {
    $otp = (Get-Content -LiteralPath $OtpAuthFile -Raw).Trim()
    if ($otp -notmatch '^otpauth://totp/') { throw "$OtpAuthFile does not contain an otpauth://totp/ URI." }
}

foreach ($repo in $Repository) {
    Write-Host "== $repo"
    # Environment restricted to custom branch/tag policies.
    $json = [IO.Path]::GetTempFileName()
    try {
        [IO.File]::WriteAllText($json, '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}')
        Invoke-Gh api -X PUT "repos/$repo/environments/codesign" --input $json | Out-Null
    } finally { Remove-Item $json }
    $policies = "$(Invoke-Gh api "repos/$repo/environments/codesign/deployment-branch-policies")" | ConvertFrom-Json
    $existing = @($policies.branch_policies | ForEach-Object { "$($_.type):$($_.name)" })
    foreach ($b in $Branches) { if ("branch:$b" -notin $existing) { Invoke-Gh api -X POST "repos/$repo/environments/codesign/deployment-branch-policies" -f "name=$b" -f type=branch | Out-Null } }
    foreach ($t in $Tags) { if ("tag:$t" -notin $existing) { Invoke-Gh api -X POST "repos/$repo/environments/codesign/deployment-branch-policies" -f "name=$t" -f type=tag | Out-Null } }

    # Secrets through a short-lived dotenv file (UTF-8 without BOM): Windows PowerShell's pipe to a native program
    # can add a BOM or re-encode, which would silently corrupt the value.
    $lines = @()
    if ($Email) { $lines += "CERTUM_EMAIL='$($Email.Trim())'" }
    if ($otp) { $lines += "CERTUM_OTPAUTH='$otp'" }
    if ($lines) {
        $envFile = [IO.Path]::GetTempFileName()
        try {
            [IO.File]::WriteAllText($envFile, ($lines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
            Invoke-Gh secret set --env codesign --repo $repo --env-file $envFile | Out-Null
        } finally { Remove-Item -LiteralPath $envFile -Force }
    }
    if ($Thumbprint) { Invoke-Gh variable set CERTUM_THUMBPRINT --env codesign --repo $repo --body ($Thumbprint -replace '\s', '').ToUpperInvariant() | Out-Null }

    $policies = "$(Invoke-Gh api "repos/$repo/environments/codesign/deployment-branch-policies")" | ConvertFrom-Json
    $secrets = "$(Invoke-Gh api "repos/$repo/environments/codesign/secrets")" | ConvertFrom-Json
    $variables = "$(Invoke-Gh api "repos/$repo/environments/codesign/variables")" | ConvertFrom-Json
    Write-Host ("   refs: {0}`n   secrets: {1}`n   variables: {2}" -f
        (($policies.branch_policies | ForEach-Object { "$($_.type) $($_.name)" }) -join ', '),
        (($secrets.secrets | ForEach-Object name) -join ', '),
        (($variables.variables | ForEach-Object { "$($_.name)=$($_.value)" }) -join ', '))
}
$otp = $null
