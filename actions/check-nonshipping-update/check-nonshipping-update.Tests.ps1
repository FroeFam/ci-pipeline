BeforeAll {
    . (Join-Path $PSScriptRoot 'check-nonshipping-update.lib.ps1')
    function New-Dep([string]$Name, [string]$Type = 'direct:production') {
        [pscustomobject]@{ dependencyName = $Name; dependencyType = $Type }
    }
}

Describe 'Test-NonShippingPath' {
    It 'treats test, docs and automation paths as non-shipping' -ForEach @(
        'tests/OpConnectMcp.Tests/OpConnectMcp.Tests.csproj'
        'test/foo.py'
        'src/Thing/Thing.Tests/Thing.Tests.csproj'
        'tests/TalkingPointsSummary.IntegrationTests/x.csproj'
        'docs/spec.md'
        'README.md'
        '.github/dependabot.yml'
    ) {
        Test-NonShippingPath $_ | Should -BeTrue
    }
    It 'treats application and build files as shipping' -ForEach @(
        'src/OpConnectMcp/OpConnectMcp.csproj'
        'Directory.Packages.props'
        'Dockerfile'
        'docker/Dockerfile'
        'poetry.lock'
        'pyproject.toml'
        'src/app.py'
    ) {
        Test-NonShippingPath $_ | Should -BeFalse
    }
    It 'returns false for empty input' {
        Test-NonShippingPath '' | Should -BeFalse
        Test-NonShippingPath $null | Should -BeFalse
    }
}

Describe 'Get-NonShippingDecision' {
    It 'skips a PR that touches only a test project (onepassword-connect-mcp PR 14)' {
        $d = Get-NonShippingDecision -Files @('tests/OpConnectMcp.Tests/OpConnectMcp.Tests.csproj') `
            -Dependencies @((New-Dep 'Microsoft.NET.Test.Sdk'), (New-Dep 'Microsoft.AspNetCore.Mvc.Testing'))
        $d.Skip | Should -BeTrue
    }
    It 'skips when Dependabot types every package as a development dependency' {
        $d = Get-NonShippingDecision -Files @('poetry.lock', 'pyproject.toml') `
            -Dependencies @((New-Dep 'ruff' 'direct:development'), (New-Dep 'pytest' 'direct:development'))
        $d.Skip | Should -BeTrue
    }
    It 'releases a shared-file bump when Dependabot reports production type' {
        $d = Get-NonShippingDecision -Files @('Directory.Packages.props') -Dependencies @((New-Dep 'xunit'))
        $d.Skip | Should -BeFalse
    }
    It 'releases a mixed group that includes a non-development package' {
        $d = Get-NonShippingDecision -Files @('poetry.lock') `
            -Dependencies @((New-Dep 'ruff' 'direct:development'), (New-Dep 'flask'))
        $d.Skip | Should -BeFalse
    }
    It 'releases a runtime-only PR' {
        $d = Get-NonShippingDecision -Files @('src/App/App.csproj') -Dependencies @((New-Dep 'ModelContextProtocol.AspNetCore'))
        $d.Skip | Should -BeFalse
    }
    It 'releases when metadata is missing and a shipping file changed' {
        $d = Get-NonShippingDecision -Files @('src/App/App.csproj', 'tests/A/A.csproj') -Dependencies @()
        $d.Skip | Should -BeFalse
    }
    It 'releases when nothing is known' {
        (Get-NonShippingDecision -Files @() -Dependencies @()).Skip | Should -BeFalse
    }
    It 'skips on files alone when metadata is missing' {
        (Get-NonShippingDecision -Files @('tests/A/A.csproj') -Dependencies @()).Skip | Should -BeTrue
    }
}
