<#
.SYNOPSIS
    Onboards an existing FroeFam repository onto the shared ci-pipeline.

.DESCRIPTION
    Writes the seven caller workflows into a local clone, seeds
    .github/semver-rules.md, .github/review-prompt.md, .github/CODEOWNERS and
    .github/dependabot.yml when they are absent, and applies the GitHub side:
    pipeline labels (copied from FroeFam/TalkingPointsSummary), repository
    settings, Actions workflow permissions, fork approval policy (public repos
    only), the "Main" ruleset from ruleset-main.json (no bypass actors on
    private repos) and membership of every selected-visibility org secret,
    Dependabot secret and variable (DOCKER_* secrets only for -Registry
    dockerhub).

    Idempotent: every item is read first and only changed when it differs.
    The script NEVER commits, pushes or deletes anything. It never reads or
    prints a secret value (only names).

.EXAMPLE
    ./scripts/New-ConsumerRepo.ps1 -Repo MyService -Language dotnet -Registry ghcr `
        -Solution MyService.slnx -UnitTestProject tests/MyService.Tests/MyService.Tests.csproj `
        -Images '[{"name":"myservice","dockerfile":"Dockerfile","context":".","platforms":["linux/amd64"],"title":"MyService"}]' -WhatIf

.EXAMPLE
    ./scripts/New-ConsumerRepo.ps1 -Repo my-py-service -Language python -Registry dockerhub `
        -ImageNamespace drache42 -PythonVersion 3.14 -PythonMatrix '["3.13","3.14"]' `
        -IntegrationPlatforms '["linux/amd64","linux/arm64"]' `
        -Images '[{"name":"my-py-service","dockerfile":"docker/Dockerfile","context":".","platforms":["linux/amd64","linux/arm64"],"title":"My Py Service"}]'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Repo,
    [Parameter(Mandatory)] [ValidateSet('dotnet', 'python')] [string] $Language,
    [Parameter(Mandatory)] [ValidateSet('ghcr', 'dockerhub')] [string] $Registry,
    [Parameter(Mandatory)] [string] $Images,
    [string] $Solution = '',
    [string] $UnitTestProject = '',
    [string] $IntegrationTestProject = '',
    [string] $PythonVersion = '',
    [string] $PythonMatrix = '',
    [string] $ImageNamespace = '',
    [string] $IntegrationPlatforms = '',
    # Optional review-model input for pr.yml. Consumers omit it (pipeline
    # default). The sandboxes pass the expression form
    # '${{ vars.SANDBOX_REVIEW_MODEL || ''claude-haiku-4-5'' }}'.
    [string] $ReviewModel = '',
    [string] $Path = '',
    [switch] $WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$Owner = 'FroeFam'
$LabelSource = 'FroeFam/TalkingPointsSummary'
$PipelineLabels = @('semver: major', 'semver: minor', 'semver: patch', 'semver: unknown', 'skip-release')
$PipelineRoot = Split-Path -Parent $PSScriptRoot
$TemplateDir = Join-Path $PipelineRoot 'templates'
$RulesetFile = Join-Path $PipelineRoot 'ruleset-main.json'
if (-not $Path) { $Path = Join-Path 'D:\Code' $Repo }

$script:Actions = [System.Collections.Generic.List[object]]::new()
function Add-Result([string] $Area, [string] $Item, [string] $Result) {
    $script:Actions.Add([pscustomobject]@{ Area = $Area; Item = $Item; Result = $Result })
    Write-Host ('[{0}] {1}: {2}' -f $Area, $Item, $Result)
}
function Get-ChangeWord([string] $Verb) { if ($WhatIf) { "would $Verb" } else { $Verb } }

# ---------------------------------------------------------------------------
# gh helper: returns stdout text; throws on failure unless the HTTP status is
# listed in -Allow (then returns $null).
# ---------------------------------------------------------------------------
function Invoke-Gh {
    param([Parameter(Mandatory)] [string[]] $Arguments, [int[]] $Allow = @())
    $out = & gh @Arguments 2>&1
    $code = $LASTEXITCODE
    $global:LASTEXITCODE = 0
    $text = (@($out | ForEach-Object { "$_" }) -join "`n")
    if ($code -ne 0) {
        foreach ($s in $Allow) { if ($text -match "HTTP $s") { return $null } }
        throw "gh $($Arguments -join ' ') failed (exit $code): $text"
    }
    return $text
}
function Invoke-GhJson {
    param([Parameter(Mandatory)] [string[]] $Arguments, [int[]] $Allow = @())
    $t = Invoke-Gh -Arguments $Arguments -Allow $Allow
    if ($null -eq $t -or $t.Trim() -eq '') { return $null }
    return ($t | ConvertFrom-Json -NoEnumerate)
}
function Invoke-GhWithBody {
    param([Parameter(Mandatory)] [string] $Method, [Parameter(Mandatory)] [string] $Endpoint, [Parameter(Mandatory)] $Body)
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($tmp, ($Body | ConvertTo-Json -Depth 20 -Compress), [System.Text.UTF8Encoding]::new($false))
        Invoke-Gh -Arguments @('api', '-X', $Method, $Endpoint, '--input', $tmp) | Out-Null
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

# Desired-is-subset-of-actual comparison (server responses carry extra fields).
function Test-Subset($Desired, $Actual) {
    if ($Desired -is [array]) {
        if ($Actual -isnot [array] -or $Actual.Count -ne $Desired.Count) { return $false }
        for ($i = 0; $i -lt $Desired.Count; $i++) { if (-not (Test-Subset $Desired[$i] $Actual[$i])) { return $false } }
        return $true
    }
    if ($Desired -is [System.Management.Automation.PSCustomObject]) {
        if ($Actual -isnot [System.Management.Automation.PSCustomObject]) { return $false }
        foreach ($p in $Desired.PSObject.Properties) {
            $a = $Actual.PSObject.Properties[$p.Name]
            if ($null -eq $a) { return $false }
            if (-not (Test-Subset $p.Value $a.Value)) { return $false }
        }
        return $true
    }
    return ("$Desired" -ceq "$Actual")
}

function ConvertTo-CompactJson([string] $Name, [string] $Json) {
    try { $v = $Json | ConvertFrom-Json -NoEnumerate } catch { throw "-$Name is not valid JSON: $Json" }
    return (ConvertTo-Json -InputObject $v -Depth 20 -Compress)
}

function Test-Ascii([string] $Text) { return ($Text -cmatch '^[\x00-\x7F]*$') }

# ---------------------------------------------------------------------------
# 1. Validate inputs
# ---------------------------------------------------------------------------
if ($Language -eq 'dotnet') {
    if (-not $Solution -or -not $UnitTestProject) { throw '-Language dotnet requires -Solution and -UnitTestProject.' }
    if ($PythonVersion -or $PythonMatrix -or $IntegrationPlatforms) { throw '-PythonVersion, -PythonMatrix and -IntegrationPlatforms are only valid with -Language python.' }
} else {
    if (-not $PythonVersion -or -not $PythonMatrix) { throw '-Language python requires -PythonVersion and -PythonMatrix.' }
    if ($Solution -or $UnitTestProject -or $IntegrationTestProject) { throw '-Solution, -UnitTestProject and -IntegrationTestProject are only valid with -Language dotnet.' }
    $PythonMatrix = ConvertTo-CompactJson 'PythonMatrix' $PythonMatrix
    if ($IntegrationPlatforms) { $IntegrationPlatforms = ConvertTo-CompactJson 'IntegrationPlatforms' $IntegrationPlatforms }
}
if ($Registry -eq 'dockerhub' -and -not $ImageNamespace) { throw '-Registry dockerhub requires -ImageNamespace.' }

$Images = ConvertTo-CompactJson 'Images' $Images
$imageList = @($Images | ConvertFrom-Json -NoEnumerate)
if ($imageList.Count -eq 1 -and $imageList[0] -is [array]) { $imageList = @($imageList[0]) }
if ($imageList.Count -eq 0) { throw '-Images must be a non-empty JSON array.' }
foreach ($img in $imageList) {
    foreach ($k in 'name', 'dockerfile', 'context', 'platforms', 'title') {
        if ($null -eq $img.PSObject.Properties[$k]) { throw "Every -Images entry needs '$k' ($($img | ConvertTo-Json -Compress))." }
    }
    if (@($img.platforms).Count -eq 0) { throw "Image '$($img.name)' has no platforms." }
}

$values = [ordered]@{
    Repo                   = $Repo
    Solution               = $Solution
    UnitTestProject        = $UnitTestProject
    IntegrationTestProject = $IntegrationTestProject
    PythonVersion          = $PythonVersion
    PythonMatrix           = $PythonMatrix
    IntegrationPlatforms   = $IntegrationPlatforms
    Registry               = $Registry
    ImageNamespace         = $ImageNamespace
    Images                 = $Images
    ReviewModel            = $ReviewModel
    LanguageIdioms         = $(if ($Language -eq 'dotnet') { 'C# / .NET' } else { 'Python' })
}
foreach ($k in $values.Keys) {
    if (-not (Test-Ascii $values[$k])) { throw "-$k contains non-ASCII characters." }
}
foreach ($k in 'PythonVersion', 'PythonMatrix', 'IntegrationPlatforms', 'Images') {
    if ($values[$k].Contains("'")) { throw "-$k must not contain a single quote (it is written inside a single-quoted YAML scalar)." }
}

# ---------------------------------------------------------------------------
# 2. Validate gh auth, repository and local clone
# ---------------------------------------------------------------------------
& gh auth status *> $null
if ($LASTEXITCODE -ne 0) { throw 'gh is not authenticated. Run gh auth login first.' }
$global:LASTEXITCODE = 0

$repoInfo = Invoke-GhJson -Arguments @('api', "repos/$Owner/$Repo") -Allow 404
if ($null -eq $repoInfo) { throw "Repository $Owner/$Repo does not exist (create or transfer it first)." }
if ($repoInfo.full_name -ne "$Owner/$Repo") { throw "repos/$Owner/$Repo resolves to $($repoInfo.full_name) (renamed or transferred); use the current name." }
$isPrivate = [bool] $repoInfo.private
$repoId = $repoInfo.id

if (-not (Test-Path -LiteralPath (Join-Path $Path '.git'))) { throw "Local clone not found at $Path (pass -Path)." }
$origin = (& git -C $Path remote get-url origin 2>$null)
$global:LASTEXITCODE = 0
if ("$origin" -notmatch [regex]::Escape("$Owner/$Repo")) { Write-Warning "origin of $Path is '$origin', expected $Owner/$Repo." }

Write-Host ("Target: {0}/{1} ({2}, id {3}), clone {4}{5}" -f $Owner, $Repo, $(if ($isPrivate) { 'private' } else { 'public' }), $repoId, $Path, $(if ($WhatIf) { ' [WhatIf]' } else { '' }))

# ---------------------------------------------------------------------------
# 3. Local files
# ---------------------------------------------------------------------------
function Expand-Template([string] $Name) {
    $raw = [System.IO.File]::ReadAllText((Join-Path $TemplateDir $Name))
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($raw -replace "`r`n", "`n").TrimEnd("`n").Split("`n")) {
        $tokens = [regex]::Matches($line, '\{\{\??([A-Za-z]+)\}\}') | ForEach-Object { $_.Groups[1].Value }
        $drop = $false
        foreach ($t in $tokens) {
            if (-not $values.Contains($t)) { throw "Template $Name uses unknown token {{$t}}." }
            if ([string]::IsNullOrEmpty($values[$t])) { $drop = $true }
        }
        if ($drop) { continue }
        $line = [regex]::Replace($line, '\{\{\?[A-Za-z]+\}\}', '')
        $line = [regex]::Replace($line, '\{\{([A-Za-z]+)\}\}', { param($m) $values[$m.Groups[1].Value] })
        $out.Add($line)
    }
    return (($out -join "`n") + "`n")
}

function Write-RepoFile([string] $RelPath, [string] $Content, [switch] $SeedOnly) {
    $full = Join-Path $Path $RelPath
    if (-not (Test-Ascii $Content)) { throw "Generated $RelPath is not ASCII." }
    if (Test-Path -LiteralPath $full) {
        $existing = ([System.IO.File]::ReadAllText($full)) -replace "`r`n", "`n"
        if ($existing -ceq $Content) { Add-Result 'file' $RelPath 'no change'; return }
        if ($SeedOnly) { Add-Result 'file' $RelPath 'exists (differs from seed), left unchanged'; return }
        if (-not $WhatIf) { [System.IO.File]::WriteAllText($full, $Content, [System.Text.UTF8Encoding]::new($false)) }
        Add-Result 'file' $RelPath (Get-ChangeWord 'update')
        return
    }
    if (-not $WhatIf) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $full) | Out-Null
        [System.IO.File]::WriteAllText($full, $Content, [System.Text.UTF8Encoding]::new($false))
    }
    Add-Result 'file' $RelPath (Get-ChangeWord 'create')
}

$callers = [ordered]@{
    'pr.yml'               = "pr.$Language.yml"
    'classify-pr.yml'      = 'classify-pr.yml'
    'label-gate.yml'       = 'label-gate.yml'
    'automerge.yml'        = 'automerge.yml'
    'main.yml'             = "main.$Language.yml"
    'claude-comments.yml'  = 'claude-comments.yml'
    'ci-failure-alert.yml' = 'ci-failure-alert.yml'
}
foreach ($c in $callers.Keys) { Write-RepoFile ".github/workflows/$c" (Expand-Template $callers[$c]) }

Write-RepoFile '.github/semver-rules.md' (Expand-Template 'semver-rules.md') -SeedOnly
Write-RepoFile '.github/review-prompt.md' (Expand-Template 'review-prompt.md') -SeedOnly
Write-RepoFile '.github/CODEOWNERS' (Expand-Template 'CODEOWNERS') -SeedOnly

# dependabot.yml: language ecosystem, docker per Dockerfile directory that
# exists in the clone, github-actions; weekly with non-major groups (TPS/WoL form).
function Get-DependabotBlock([string] $Ecosystem, [string] $Directory, [string] $Group) {
    @(
        "  - package-ecosystem: $Ecosystem"
        "    directory: $Directory"
        '    schedule:'
        '      interval: weekly'
        '    target-branch: main'
        '    groups:'
        "      $Group-non-major:"
        '        update-types:'
        '          - minor'
        '          - patch'
    ) -join "`n"
}
$blocks = [System.Collections.Generic.List[string]]::new()
if ($Language -eq 'dotnet') { $blocks.Add((Get-DependabotBlock 'nuget' '/' 'nuget')) } else { $blocks.Add((Get-DependabotBlock 'pip' '/' 'pip')) }
$dockerDirs = @($imageList | Where-Object { Test-Path -LiteralPath (Join-Path $Path $_.dockerfile) } |
        ForEach-Object { $d = (Split-Path -Parent ($_.dockerfile -replace '\\', '/')) -replace '\\', '/'; if ($d) { "/$d" } else { '/' } } |
        Select-Object -Unique)
foreach ($d in $dockerDirs) { $blocks.Add((Get-DependabotBlock 'docker' $d 'docker')) }
$blocks.Add((Get-DependabotBlock 'github-actions' '/' 'actions'))
$dependabot = "version: 2`nupdates:`n" + ($blocks -join "`n`n") + "`n"
Write-RepoFile '.github/dependabot.yml' $dependabot -SeedOnly

# ---------------------------------------------------------------------------
# 4. Labels (copied from TPS, descriptions made ASCII)
# ---------------------------------------------------------------------------
$srcLabels = @(Invoke-GhJson -Arguments @('api', "repos/$LabelSource/labels?per_page=100"))
if ($srcLabels.Count -eq 1 -and $srcLabels[0] -is [array]) { $srcLabels = @($srcLabels[0]) }
$dstLabels = @(Invoke-GhJson -Arguments @('api', "repos/$Owner/$Repo/labels?per_page=100"))
if ($dstLabels.Count -eq 1 -and $dstLabels[0] -is [array]) { $dstLabels = @($dstLabels[0]) }
foreach ($ln in $PipelineLabels) {
    $src = $srcLabels | Where-Object name -CEQ $ln | Select-Object -First 1
    if (-not $src) { throw "Label '$ln' not found in $LabelSource." }
    $desc = ("$($src.description)" -replace [char]0x2014, '--' -replace [char]0x2013, '-') -replace '[^\x00-\x7F]', ''
    $color = "$($src.color)".ToLowerInvariant()
    $dst = $dstLabels | Where-Object name -CEQ $ln | Select-Object -First 1
    if (-not $dst) {
        if (-not $WhatIf) { Invoke-Gh -Arguments @('api', '-X', 'POST', "repos/$Owner/$Repo/labels", '-f', "name=$ln", '-f', "color=$color", '-f', "description=$desc") | Out-Null }
        Add-Result 'label' $ln (Get-ChangeWord 'create')
    } elseif ("$($dst.color)".ToLowerInvariant() -ne $color -or "$($dst.description)" -cne $desc) {
        if (-not $WhatIf) { Invoke-Gh -Arguments @('api', '-X', 'PATCH', "repos/$Owner/$Repo/labels/$([uri]::EscapeDataString($ln))", '-f', "color=$color", '-f', "description=$desc") | Out-Null }
        Add-Result 'label' $ln (Get-ChangeWord 'update')
    } else { Add-Result 'label' $ln 'no change' }
}

# ---------------------------------------------------------------------------
# 5. Repository settings, workflow permissions, fork policy
# ---------------------------------------------------------------------------
$desiredSettings = [ordered]@{ allow_auto_merge = $true; delete_branch_on_merge = $false; allow_merge_commit = $true; allow_squash_merge = $true; allow_rebase_merge = $true; has_wiki = $false }
$diff = @($desiredSettings.Keys | Where-Object { [bool] $repoInfo.$_ -ne $desiredSettings[$_] })
if ($diff.Count -eq 0) { Add-Result 'settings' 'repository' 'no change' } else {
    if (-not $WhatIf) {
        $ghArgs = @('api', '-X', 'PATCH', "repos/$Owner/$Repo")
        foreach ($k in $diff) { $ghArgs += @('-F', "$k=$($desiredSettings[$k].ToString().ToLowerInvariant())") }
        Invoke-Gh -Arguments $ghArgs | Out-Null
    }
    Add-Result 'settings' "repository ($($diff -join ', '))" (Get-ChangeWord 'update')
}

$wf = Invoke-GhJson -Arguments @('api', "repos/$Owner/$Repo/actions/permissions/workflow")
if ($wf.default_workflow_permissions -eq 'read') { Add-Result 'settings' 'default workflow permissions read' 'no change' } else {
    if (-not $WhatIf) { Invoke-Gh -Arguments @('api', '-X', 'PUT', "repos/$Owner/$Repo/actions/permissions/workflow", '-f', 'default_workflow_permissions=read') | Out-Null }
    Add-Result 'settings' 'default workflow permissions read' (Get-ChangeWord 'update')
}

if ($isPrivate) { Add-Result 'settings' 'fork approval policy' 'skipped (private repository)' } else {
    $fp = Invoke-GhJson -Arguments @('api', "repos/$Owner/$Repo/actions/permissions/fork-pr-contributor-approval")
    if ($fp.approval_policy -eq 'all_external_contributors') { Add-Result 'settings' 'fork approval policy all_external_contributors' 'no change' } else {
        if (-not $WhatIf) { Invoke-Gh -Arguments @('api', '-X', 'PUT', "repos/$Owner/$Repo/actions/permissions/fork-pr-contributor-approval", '-f', 'approval_policy=all_external_contributors') | Out-Null }
        Add-Result 'settings' "fork approval policy all_external_contributors (was $($fp.approval_policy))" (Get-ChangeWord 'update')
    }
}

# ---------------------------------------------------------------------------
# 6. Ruleset "Main"
# ---------------------------------------------------------------------------
$ruleset = [System.IO.File]::ReadAllText($RulesetFile) | ConvertFrom-Json
if ($isPrivate) { $ruleset.bypass_actors = [object[]] @() }
$existingSets = @(Invoke-GhJson -Arguments @('api', "repos/$Owner/$Repo/rulesets?per_page=100"))
if ($existingSets.Count -eq 1 -and $existingSets[0] -is [array]) { $existingSets = @($existingSets[0]) }
$match = @($existingSets | Where-Object { $_.source_type -eq 'Repository' -and $_.name -ieq $ruleset.name })
if ($match.Count -gt 1) { throw "More than one repository ruleset named '$($ruleset.name)' (case-insensitive) exists; resolve manually." }
if ($match.Count -eq 0) {
    if (-not $WhatIf) { Invoke-GhWithBody -Method POST -Endpoint "repos/$Owner/$Repo/rulesets" -Body $ruleset }
    Add-Result 'ruleset' $ruleset.name (Get-ChangeWord 'create')
} else {
    $id = $match[0].id
    $current = Invoke-GhJson -Arguments @('api', "repos/$Owner/$Repo/rulesets/$id")
    if (Test-Subset $ruleset $current) { Add-Result 'ruleset' "$($ruleset.name) (id $id)" 'no change' } else {
        if (-not $WhatIf) { Invoke-GhWithBody -Method PUT -Endpoint "repos/$Owner/$Repo/rulesets/$id" -Body $ruleset }
        Add-Result 'ruleset' "$($ruleset.name) (id $id)" (Get-ChangeWord 'update')
    }
}
$others = @($existingSets | Where-Object { $_.source_type -eq 'Repository' -and $_.name -ine $ruleset.name })
foreach ($o in $others) { Write-Warning "Other repository ruleset '$($o.name)' (id $($o.id)) exists; review it manually (this script never deletes)." }

# ---------------------------------------------------------------------------
# 7. Org secrets and variables (names only; values are never read)
# ---------------------------------------------------------------------------
function Add-OrgScope([string] $Kind, [string] $ListEndpoint, [string] $Property, [string] $ItemBase) {
    $resp = Invoke-GhJson -Arguments @('api', "$($ListEndpoint)?per_page=100")
    foreach ($s in @($resp.$Property)) {
        $n = $s.name
        if ($n -like 'DOCKER_*' -and $Registry -ne 'dockerhub') { Add-Result $Kind $n 'skipped (registry is not dockerhub)'; continue }
        if ($s.visibility -ne 'selected') { Add-Result $Kind $n "skipped (visibility $($s.visibility))"; continue }
        $repos = Invoke-GhJson -Arguments @('api', "$ItemBase/$n/repositories?per_page=100")
        if (@($repos.repositories | Where-Object id -EQ $repoId).Count -gt 0) { Add-Result $Kind $n 'no change'; continue }
        if (-not $WhatIf) { Invoke-Gh -Arguments @('api', '-X', 'PUT', "$ItemBase/$n/repositories/$repoId") | Out-Null }
        Add-Result $Kind $n (Get-ChangeWord 'add repository')
    }
}
Add-OrgScope 'actions secret' "orgs/$Owner/actions/secrets" 'secrets' "orgs/$Owner/actions/secrets"
Add-OrgScope 'dependabot secret' "orgs/$Owner/dependabot/secrets" 'secrets' "orgs/$Owner/dependabot/secrets"
Add-OrgScope 'variable' "orgs/$Owner/actions/variables" 'variables' "orgs/$Owner/actions/variables"

# ---------------------------------------------------------------------------
# 8. Summary and next steps
# ---------------------------------------------------------------------------
$changed = @($script:Actions | Where-Object { $_.Result -match '^(would )?(create|update|add repository)' })
Write-Host ''
Write-Host ('Summary for {0}/{1}{2}: {3} item(s) checked, {4} {5}.' -f $Owner, $Repo, $(if ($WhatIf) { ' [WhatIf]' } else { '' }), $script:Actions.Count, $changed.Count, $(if ($WhatIf) { 'would change' } else { 'changed' }))
$script:Actions | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
if ($changed.Count -eq 0) { Write-Host 'No change: the repository already matches the pipeline configuration.' }

Write-Host @"
Next steps (this script never commits or pushes):
  1. Review the local changes in $Path (git status; git diff) and edit the
     .github/semver-rules.md and .github/review-prompt.md seeds for the project.
  2. Commit the callers on a branch, push it and open the cutover PR to main.
  3. On a repository's FIRST pipeline PR, Classify PR cannot run yet (it needs
     classify-pr.yml on main), so add the semver label manually through REST:
       gh api -X POST repos/$Owner/$Repo/issues/<n>/labels -f 'labels[]=semver: <level>'
  4. If a stale failing label-gate check keeps the PR blocked after a manual
     label change, re-run the latest workflow_run "Label Gate" run
     (gh run rerun <id>) and wait for mergeStateStatus CLEAN
     (gh pr view <n> -R $Owner/$Repo --json mergeStateStatus). gh run rerun
     reuses the workflow SHA of the original run, so push a new commit after
     changing workflow files instead.
  5. Merge with gh pr merge <n> --merge; the Main Pipeline then publishes images
     and, when a merged PR exists since the last tag, cuts a release.
"@
