# Run locally (needs gh, logged in as the repositories' owner). Creates the `codesign` environment in each
# repository, limits it to the release refs, and stores the Certum credentials there. The values are piped to
# `gh secret set` on stdin: they never appear on a command line, in the shell history or in this script's output.
#
#   ./tools/Set-CodesignSecrets.ps1 -Email you@example.com -OtpAuthFile D:\secure\otpauth.txt
#   ./tools/Set-CodesignSecrets.ps1 -Thumbprint 0123...   # only (re)write the CERTUM_THUMBPRINT variable
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

$otp = $null
if ($OtpAuthFile) {
    $otp = (Get-Content -LiteralPath $OtpAuthFile -Raw).Trim()
    if ($otp -notmatch '^otpauth://totp/') { throw "$OtpAuthFile does not contain an otpauth://totp/ URI." }
}

foreach ($repo in $Repository) {
    Write-Host "== $repo"
    # Environment restricted to custom branch/tag policies.
    '{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}' |
        gh api -X PUT "repos/$repo/environments/codesign" --input - | Out-Null
    $existing = @(gh api "repos/$repo/environments/codesign/deployment-branch-policies" --jq '.branch_policies[] | .type + ":" + .name')
    foreach ($b in $Branches) { if ("branch:$b" -notin $existing) { gh api -X POST "repos/$repo/environments/codesign/deployment-branch-policies" -f name=$b -f type=branch | Out-Null } }
    foreach ($t in $Tags) { if ("tag:$t" -notin $existing) { gh api -X POST "repos/$repo/environments/codesign/deployment-branch-policies" -f name=$t -f type=tag | Out-Null } }

    if ($Email) { $Email | gh secret set CERTUM_EMAIL --env codesign --repo $repo }
    if ($otp) { $otp | gh secret set CERTUM_OTPAUTH --env codesign --repo $repo }
    if ($Thumbprint) { gh variable set CERTUM_THUMBPRINT --env codesign --repo $repo --body ($Thumbprint -replace '\s', '').ToUpperInvariant() }
    gh secret list --env codesign --repo $repo
}
$otp = $null
