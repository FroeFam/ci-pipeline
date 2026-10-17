$ErrorActionPreference = 'Stop'

# First match wins:
#   (1) bot actor                                   -> false / bot
#   (2) pull_request(_target) from another repo     -> false / fork
#   (3) collaborator permission admin|maintain|write -> true
#   (4) anything else or an API error               -> false (fail closed, warning)

$repo  = $env:GITHUB_REPOSITORY
$actor = $env:GUARD_ACTOR
$event = $env:GUARD_EVENT

function Set-Result([string]$Trusted, [string]$Reason) {
    "trusted=$Trusted" | Add-Content -Path $env:GITHUB_OUTPUT
    "reason=$Reason"   | Add-Content -Path $env:GITHUB_OUTPUT
    Write-Host "trusted=$Trusted reason=$Reason actor=$actor"
    exit 0
}

if ([string]::IsNullOrWhiteSpace($actor)) {
    Write-Output '::warning::trusted-actor-guard: no actor supplied; treating as untrusted.'
    Set-Result 'false' 'no-actor'
}

if ($actor.EndsWith('[bot]')) {
    Set-Result 'false' 'bot'
}

if ($event -in @('pull_request', 'pull_request_target')) {
    if ($env:GUARD_HEAD_REPO -ne $repo) {
        Set-Result 'false' 'fork'
    }
}

$permission = $null
try {
    $permission = gh api "repos/$repo/collaborators/$actor/permission" --jq .permission 2>$null
    if ($LASTEXITCODE -ne 0) {
        $permission = $null
    }
} catch {
    $permission = $null
}

if ($null -eq $permission) {
    Write-Output "::warning::trusted-actor-guard: could not read the permission of '$actor'; treating as untrusted."
    Set-Result 'false' 'api-error'
}

$permission = "$permission".Trim()
if ($permission -in @('admin', 'maintain', 'write')) {
    Set-Result 'true' "permission-$permission"
}

Write-Output "::warning::trusted-actor-guard: '$actor' has permission '$permission'; treating as untrusted."
Set-Result 'false' "permission-$permission"
