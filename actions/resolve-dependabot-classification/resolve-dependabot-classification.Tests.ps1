BeforeAll {
    . (Join-Path $PSScriptRoot 'resolve-dependabot-classification.lib.ps1')
    function New-Dep([string]$Name, [string]$Eco, [string]$Update) {
        [pscustomobject]@{ dependencyName = $Name; packageEcosystem = $Eco; updateType = $Update }
    }
}

Describe 'Resolve-Classification' {
    It 'raises a major Docker image update the model called patch (onepassword-connect-mcp PR 13)' {
        $r = Resolve-Classification -Classification 'patch' -Rationale 'dependency update' `
            -Dependencies @((New-Dep 'dotnet/sdk' 'docker' 'version-update:semver-major'))
        $r.Classification | Should -Be 'major'
        $r.Rationale | Should -Match 'dotnet/sdk'
        $r.Rationale | Should -Match 'runtime image'
    }
    It 'raises a major package update the model called patch to minor (TalkingPointsSummary MailKit 5)' {
        $r = Resolve-Classification -Classification 'patch' -Rationale 'x' `
            -Dependencies @((New-Dep 'MailKit' 'nuget' 'version-update:semver-major'))
        $r.Classification | Should -Be 'minor'
        $r.Rationale | Should -Match 'MailKit'
    }
    It 'raises a major package update the model called unknown' {
        (Resolve-Classification -Classification 'unknown' -Rationale '' `
            -Dependencies @((New-Dep 'gunicorn' 'pip' 'version-update:semver-major'))).Classification | Should -Be 'minor'
    }
    It 'takes the highest floor in a mixed group' {
        $r = Resolve-Classification -Classification 'patch' -Rationale 'x' -Dependencies @(
            (New-Dep 'MailKit' 'nuget' 'version-update:semver-major'),
            (New-Dep 'dotnet/aspnet' 'docker' 'version-update:semver-major'))
        $r.Classification | Should -Be 'major'
    }
    It 'keeps a higher model classification and its rationale' {
        $r = Resolve-Classification -Classification 'major' -Rationale 'breaks the API' `
            -Dependencies @((New-Dep 'MailKit' 'nuget' 'version-update:semver-major'))
        $r.Classification | Should -Be 'major'
        $r.Rationale | Should -Be 'breaks the API'
    }
    It 'does not raise a minor or patch update' {
        $r = Resolve-Classification -Classification 'patch' -Rationale 'bump' -Dependencies @(
            (New-Dep 'xunit' 'nuget' 'version-update:semver-minor'),
            (New-Dep 'ruff' 'pip' 'version-update:semver-patch'))
        $r.Classification | Should -Be 'patch'
        $r.Rationale | Should -Be 'bump'
    }
    It 'passes through with no dependency metadata' {
        $r = Resolve-Classification -Classification 'minor' -Rationale 'new tool' -Dependencies @()
        $r.Classification | Should -Be 'minor'
        $r.Rationale | Should -Be 'new tool'
    }
    It 'strips unsafe characters from package names' {
        $r = Resolve-Classification -Classification 'patch' -Rationale 'x' `
            -Dependencies @((New-Dep 'evil<script>@x' 'nuget' 'version-update:semver-major'))
        $r.Rationale | Should -Not -Match '[<>]'
    }
}
