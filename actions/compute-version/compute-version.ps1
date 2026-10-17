$ErrorActionPreference = 'Stop'

$latestTag = git tag -l 'v*' --sort=-v:refname | Select-Object -First 1
Write-Host "Latest tag: $(if ($latestTag) { $latestTag } else { 'none' })"

$initialVersion = if ([string]::IsNullOrWhiteSpace($env:INITIAL_VERSION)) { '1.0.0' } else { $env:INITIAL_VERSION.Trim() }
if ($initialVersion -notmatch '^\d+\.\d+\.\d+$') {
    throw "initial-version '$initialVersion' is not MAJOR.MINOR.PATCH."
}

if (-not $latestTag) {
    # No release yet: the first release is exactly initial-version, whatever
    # the labels say. The skip rules below still apply.
    $parts    = $initialVersion.Split('.')
    $major    = [int]$parts[0]
    $minor    = [int]$parts[1]
    $patch    = [int]$parts[2]
    $taggedAt = '1970-01-01T00:00:00Z'
} else {
    $parts    = $latestTag.TrimStart('v').Split('.')
    $major    = [int]$parts[0]
    $minor    = [int]$parts[1]
    $patch    = [int]$parts[2]
    $taggedAt = git log -1 --format='%cI' $latestTag
}

Write-Host "Current version: $major.$minor.$patch (tagged at $taggedAt)"
$shortSha = $env:GITHUB_SHA.Substring(0, 7)

$allPRs = gh pr list --repo $env:GITHUB_REPOSITORY --state merged --base main --limit 1000 --json number,labels,mergedAt,mergeCommit | ConvertFrom-Json

# Decide which merged PRs belong to the next release window.
#
# The window is the set of commits reachable from this run's commit (HEAD ==
# GITHUB_SHA, the commit the release job will tag) but not from the latest
# release tag: `git rev-list "$latestTag..HEAD"`. A PR counts when its merge
# commit is in that set. The set is enumerated once and membership is an
# in-memory lookup.
#
# The mergedAt-vs-tag-date comparison is kept only for PRs with no recorded
# merge commit. Both sides are parsed as DateTimeOffset, not compared as
# strings: gh reports mergedAt as '...Z' while git %cI uses a numeric offset.
$revListRange  = if ($latestTag) { "$latestTag..HEAD" } else { 'HEAD' }
$windowCommits = [System.Collections.Generic.HashSet[string]]::new(
    [string[]]@(git rev-list $revListRange),
    [System.StringComparer]::OrdinalIgnoreCase)
Write-Host "Commits in release window ($revListRange): $($windowCommits.Count)"

$mergedPRs = @($allPRs | Where-Object {
    if ($null -eq $_.mergedAt) {
        return $false
    }

    $oid = $_.mergeCommit.oid
    if ($oid) {
        return $windowCommits.Contains($oid)
    }

    [datetimeoffset]$_.mergedAt -gt [datetimeoffset]$taggedAt
})

$prCount = $mergedPRs.Count
Write-Host "PRs in next release window: $prCount"

function Write-Skip {
    "skip=true"                    | Add-Content -Path $env:GITHUB_OUTPUT
    "version=$major.$minor.$patch" | Add-Content -Path $env:GITHUB_OUTPUT
    "short_sha=$shortSha"          | Add-Content -Path $env:GITHUB_OUTPUT
    exit 0
}

if ($prCount -eq 0) {
    Write-Host 'No PRs merged since last release.'
    Write-Skip
}

$triggerPR      = $mergedPRs | Sort-Object mergedAt | Select-Object -Last 1
$triggerHasSkip = $triggerPR.labels | Where-Object { $_.name -eq 'skip-release' }

if ($triggerHasSkip) {
    Write-Host 'Triggering PR has skip-release; deferring release.'
    Write-Skip
}

$hasMajor     = $false
$hasMinor     = $false
$hasAnySemver = $false

foreach ($pr in $mergedPRs) {
    $labelNames = @($pr.labels | ForEach-Object { $_.name })
    if ($labelNames -contains 'semver: major') {
        $hasMajor = $true; $hasAnySemver = $true
    } elseif ($labelNames -contains 'semver: minor') {
        $hasMinor = $true; $hasAnySemver = $true
    } elseif ($labelNames -contains 'semver: patch') {
        $hasAnySemver = $true
    }
}

if (-not $hasAnySemver) {
    Write-Host 'No semver labels found among merged PRs; skipping release.'
    Write-Skip
}

if (-not $latestTag) {
    $newVersion = $initialVersion
} elseif ($hasMajor) {
    $newVersion = "$($major + 1).0.0"
} elseif ($hasMinor) {
    $newVersion = "$major.$($minor + 1).0"
} else {
    $newVersion = "$major.$minor.$($patch + 1)"
}

Write-Host "New version: $newVersion"
"skip=false"           | Add-Content -Path $env:GITHUB_OUTPUT
"version=$newVersion"  | Add-Content -Path $env:GITHUB_OUTPUT
"short_sha=$shortSha"  | Add-Content -Path $env:GITHUB_OUTPUT
