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

Describe 'Test-NonShippingDependency' {
    It 'recognises test and lint tooling' -ForEach @(
        'Microsoft.NET.Test.Sdk', 'xunit', 'xunit.runner.visualstudio', 'Microsoft.AspNetCore.Mvc.Testing',
        'coverlet.collector', 'Moq', 'FluentAssertions', 'WireMock.Net', 'Testcontainers.PostgreSql',
        'pytest', 'pytest-cov', 'ruff', 'mypy', 'types-requests', 'testcontainers'
    ) {
        Test-NonShippingDependency $_ 'direct:production' | Should -BeTrue
    }
    It 'does not treat runtime packages as tooling' -ForEach @(
        'ModelContextProtocol', 'Markdig', 'Microsoft.EntityFrameworkCore', 'Microsoft.AspNetCore.OpenApi',
        'Microsoft.Extensions.Hosting', 'gunicorn', 'flask', 'xunitish-runtime', 'rufftastic'
    ) {
        Test-NonShippingDependency $_ 'direct:production' | Should -BeFalse
    }
    It 'trusts Dependabot direct:development' {
        Test-NonShippingDependency 'anything-at-all' 'direct:development' | Should -BeTrue
    }
    It 'returns false for an empty name with a production type' {
        Test-NonShippingDependency '' 'direct:production' | Should -BeFalse
    }
}

Describe 'Get-NonShippingDecision' {
    It 'skips a PR that touches only a test project (onepassword-connect-mcp PR 14)' {
        $d = Get-NonShippingDecision -Files @('tests/OpConnectMcp.Tests/OpConnectMcp.Tests.csproj') `
            -Dependencies @((New-Dep 'Microsoft.NET.Test.Sdk'), (New-Dep 'Microsoft.AspNetCore.Mvc.Testing'))
        $d.Skip | Should -BeTrue
    }
    It 'skips a central-props PR where every package is test tooling' {
        $d = Get-NonShippingDecision -Files @('Directory.Packages.props') `
            -Dependencies @((New-Dep 'xunit'), (New-Dep 'Moq'), (New-Dep 'coverlet.collector'))
        $d.Skip | Should -BeTrue
    }
    It 'skips a python dev-tooling PR (WakeOnLanService ruff bump)' {
        $d = Get-NonShippingDecision -Files @('poetry.lock', 'pyproject.toml') -Dependencies @((New-Dep 'ruff'))
        $d.Skip | Should -BeTrue
    }
    It 'does not skip a mixed group that includes a runtime package' {
        $d = Get-NonShippingDecision -Files @('Directory.Packages.props') `
            -Dependencies @((New-Dep 'xunit'), (New-Dep 'Markdig'))
        $d.Skip | Should -BeFalse
        $d.Reason | Should -Match 'Markdig'
    }
    It 'does not skip a runtime-only PR' {
        $d = Get-NonShippingDecision -Files @('src/App/App.csproj') -Dependencies @((New-Dep 'ModelContextProtocol.AspNetCore'))
        $d.Skip | Should -BeFalse
    }
    It 'does not skip when metadata is missing and a shipping file changed' {
        $d = Get-NonShippingDecision -Files @('src/App/App.csproj', 'tests/A/A.csproj') -Dependencies @()
        $d.Skip | Should -BeFalse
    }
    It 'does not skip when nothing is known' {
        (Get-NonShippingDecision -Files @() -Dependencies @()).Skip | Should -BeFalse
    }
    It 'skips on files alone when metadata is missing' {
        (Get-NonShippingDecision -Files @('tests/A/A.csproj') -Dependencies @()).Skip | Should -BeTrue
    }
}
