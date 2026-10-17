$ErrorActionPreference = 'Stop'

$files = Get-Content -Path /tmp/pr_files.txt -Raw -ErrorAction SilentlyContinue
$diff  = Get-Content -Path /tmp/pr_truncated.diff -Raw -ErrorAction SilentlyContinue

function Write-Result([string]$Classification, [string]$Rationale) {
    "classification=$Classification" | Add-Content -Path $env:GITHUB_OUTPUT
    'rationale<<EOF_RATIONALE'       | Add-Content -Path $env:GITHUB_OUTPUT
    $Rationale                       | Add-Content -Path $env:GITHUB_OUTPUT
    'EOF_RATIONALE'                  | Add-Content -Path $env:GITHUB_OUTPUT
}

if ([string]::IsNullOrWhiteSpace($env:ANTHROPIC_MODEL)) {
    Write-Host 'ANTHROPIC_MODEL variable is not set -- skipping classification.'
    Write-Result 'unknown' 'ANTHROPIC_MODEL variable is not configured -- set it and apply a semver label manually.'
    exit 0
}

$defaultRules = 'MAJOR: a backward-incompatible change to a public interface, command line, configuration or data format. MINOR: a backward-compatible new feature. PATCH: a bug fix, refactor, documentation, test change, or dependency update with no behavior change.'

# Project rules are read from the BASE SHA so a PR cannot rewrite its own rules.
$rules = $null
try {
    $fetched = gh api "repos/$env:GITHUB_REPOSITORY/contents/$($env:SEMVER_RULES_PATH)?ref=$env:BASE_SHA" -H 'Accept: application/vnd.github.raw' 2>$null
    if ($LASTEXITCODE -eq 0 -and $fetched) {
        $rules = (@($fetched) -join "`n").Trim()
    }
} catch {
    $rules = $null
}
if ([string]::IsNullOrWhiteSpace($rules)) {
    Write-Output "::warning::Could not read $($env:SEMVER_RULES_PATH) at the base SHA; using the neutral default semver rules."
    $rules = $defaultRules
}

$systemPrompt = @"
You are a semantic versioning expert for the $($env:REPO_NAME) application. Apply standard semver principles adapted for a deployed application: major = breaking deployment change; minor = new backward-compatible capability; patch = everything else. The changed-files list is always complete; the diff content may be truncated on very large PRs.

Project-specific rules (apply the HIGHEST matching tier):

$rules

Respond with valid JSON only, no other text: {"classification": "major"|"minor"|"patch", "rationale": "one sentence explaining the primary signal"}
"@

$userContent = "PR Title: $($env:PR_TITLE)`n`nChanged files (complete):`n$files`n`nDiff (may be truncated):`n$diff"

$payload = @{
    model      = $env:ANTHROPIC_MODEL
    max_tokens = 256
    system     = $systemPrompt
    messages   = @(
        @{
            role    = 'user'
            content = $userContent
        }
    )
} | ConvertTo-Json -Depth 5 -Compress

$classification = ''
$rationale      = ''

try {
    $response = Invoke-RestMethod `
        -Method Post `
        -Uri 'https://api.anthropic.com/v1/messages' `
        -Headers @{
            'x-api-key'         = $env:ANTHROPIC_API_KEY
            'anthropic-version' = '2023-06-01'
        } `
        -ContentType 'application/json' `
        -Body $payload

    $rawText        = $response.content[0].text
    # Strip markdown code fences that some models add despite being told not to
    $rawText        = ($rawText -replace '(?ms)^\s*```[a-zA-Z]*\s*', '') -replace '(?ms)```\s*$', ''
    $parsed         = $rawText.Trim() | ConvertFrom-Json -ErrorAction SilentlyContinue
    $classification = $parsed.classification
    $rationale      = $parsed.rationale
} catch {
    Write-Host "API call failed: $_"
}

$validClassifications = @('major', 'minor', 'patch')
if ([string]::IsNullOrWhiteSpace($classification) -or $classification -notin $validClassifications) {
    $classification = 'unknown'
    $rationale      = 'Classification failed -- please apply a semver label manually.'
}

Write-Result $classification $rationale
