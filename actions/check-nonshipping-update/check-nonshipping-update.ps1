$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'check-nonshipping-update.lib.ps1')

function Write-Output2([string]$Skip, [string]$Reason) {
    "skip=$Skip" | Add-Content -Path $env:GITHUB_OUTPUT
    Write-Host "skip=$Skip ($Reason)"
    if ($env:GITHUB_STEP_SUMMARY) {
        "Release for this Dependabot PR: skip=$Skip ($Reason)" | Add-Content -Path $env:GITHUB_STEP_SUMMARY
    }
}

$repo     = $env:GITHUB_REPOSITORY
$prNumber = $env:PR_NUMBER

$files = @(gh api "repos/$repo/pulls/$prNumber/files" --paginate --jq '.[].filename')
if ($LASTEXITCODE -ne 0) { throw "Could not list files of PR $prNumber." }

$deps = @()
if (-not [string]::IsNullOrWhiteSpace($env:DEPENDENCIES_JSON)) {
    try { $deps = @($env:DEPENDENCIES_JSON | ConvertFrom-Json) } catch { Write-Host "::warning::Could not parse dependency metadata; using changed files only." }
}

$decision = Get-NonShippingDecision -Files $files -Dependencies $deps
Write-Output2 ($decision.Skip.ToString().ToLower()) $decision.Reason
