# Pure helpers for check-nonshipping-update.ps1, dot-sourced by it and by the
# Pester tests. Decides whether a Dependabot PR changes nothing that ships, so
# the release for it can be deferred with skip-release.
#
# The bias is deliberate: a wrong "skip" only delays a release until the next
# PR without skip-release (the release window carries over), while a wrong
# "ship" is the status quo. So a PR is skipped only when EVERY changed file or
# EVERY updated package is recognised as non-shipping.

# Paths that never end up in a shipped image: test projects and folders, docs,
# markdown and repository automation.
$script:NonShippingPathPatterns = @(
    '(?i)^tests?/'
    '(?i)^docs?/'
    '(?i)^\.github/'
    '(?i)(^|/)[^/]+\.(unit|integration)?tests?/'
    '(?i)\.md$'
)

# Package names that are test or lint tooling, matched against the whole name.
$script:NonShippingPackagePatterns = @(
    # .NET test tooling
    '^Microsoft\.NET\.Test\.Sdk$'
    '^Microsoft\.TestPlatform(\..+)?$'
    '^Microsoft\.AspNetCore\.Mvc\.Testing$'
    '^xunit(\..+)?$'
    '^NUnit.*$'
    '^MSTest.*$'
    '^coverlet\..+$'
    '^Moq$'
    '^NSubstitute.*$'
    '^FluentAssertions.*$'
    '^Shouldly$'
    '^AutoFixture.*$'
    '^Bogus$'
    '^WireMock.*$'
    '^Testcontainers.*$'
    '^Verify(\..+)?$'
    '^ReportGenerator$'
    '^JunitXml\.TestLogger$'
    # Python test and lint tooling
    '^pytest([-_.].+)?$'
    '^ruff$'
    '^mypy$'
    '^black$'
    '^isort$'
    '^flake8([-_.].+)?$'
    '^pylint$'
    '^bandit$'
    '^coverage$'
    '^tox$'
    '^hypothesis$'
    '^freezegun$'
    '^responses$'
    '^pre-commit$'
    '^testcontainers$'
    '^types-.+$'
)

function Test-NonShippingPath {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $p = $Path -replace '\\', '/'
    foreach ($pattern in $script:NonShippingPathPatterns) {
        if ($p -match $pattern) { return $true }
    }
    return $false
}

function Test-NonShippingDependency {
    param([AllowNull()][string]$Name, [AllowNull()][string]$Type)

    # Dependabot itself says the dependency is development-only.
    if ($Type -eq 'direct:development') { return $true }
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    foreach ($pattern in $script:NonShippingPackagePatterns) {
        if ($Name -match "(?i)$pattern") { return $true }
    }
    return $false
}

# Returns @{ Skip = <bool>; Reason = <string> }.
# $Files: changed file paths. $Dependencies: objects with dependencyName and
# dependencyType (the shape of dependabot/fetch-metadata updated-dependencies-json).
function Get-NonShippingDecision {
    param([string[]]$Files = @(), [object[]]$Dependencies = @())

    $Files = @($Files | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $Dependencies = @($Dependencies | Where-Object { $null -ne $_ })

    if ($Files.Count -gt 0) {
        $shipping = @($Files | Where-Object { -not (Test-NonShippingPath $_) })
        if ($shipping.Count -eq 0) {
            return @{ Skip = $true; Reason = "all $($Files.Count) changed file(s) are test, docs or automation files" }
        }
    }

    if ($Dependencies.Count -gt 0) {
        $shipping = @($Dependencies | Where-Object { -not (Test-NonShippingDependency $_.dependencyName $_.dependencyType) })
        if ($shipping.Count -eq 0) {
            return @{ Skip = $true; Reason = "all $($Dependencies.Count) updated package(s) are test or development tooling" }
        }
        $names = (@($shipping | ForEach-Object { $_.dependencyName }) -join ', ')
        return @{ Skip = $false; Reason = "ships: $names" }
    }

    return @{ Skip = $false; Reason = 'changed files include shipping code' }
}
