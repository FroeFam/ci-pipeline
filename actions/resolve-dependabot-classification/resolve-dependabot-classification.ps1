$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'resolve-dependabot-classification.lib.ps1')

$deps = @()
if (-not [string]::IsNullOrWhiteSpace($env:DEPENDENCIES_JSON)) {
    try { $deps = @($env:DEPENDENCIES_JSON | ConvertFrom-Json) } catch { Write-Host '::warning::Could not parse dependency metadata; keeping the model classification.' }
}

$r = Resolve-Classification -Classification $env:CLASSIFICATION -Rationale $env:RATIONALE -Dependencies $deps

"classification=$($r.Classification)" | Add-Content -Path $env:GITHUB_OUTPUT
'rationale<<EOF_RATIONALE'            | Add-Content -Path $env:GITHUB_OUTPUT
$r.Rationale                          | Add-Content -Path $env:GITHUB_OUTPUT
'EOF_RATIONALE'                       | Add-Content -Path $env:GITHUB_OUTPUT

if ($r.Classification -ne $env:CLASSIFICATION) {
    Write-Host "Classification raised from '$($env:CLASSIFICATION)' to '$($r.Classification)'."
}
