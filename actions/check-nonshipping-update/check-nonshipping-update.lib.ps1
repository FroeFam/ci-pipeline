# Pure helpers for check-nonshipping-update.ps1, dot-sourced by it and by the
# Pester tests. Decides whether a Dependabot PR changes nothing that ships, so
# the release for it can be deferred with skip-release.
#
# Nothing here needs hand maintenance: it uses only path conventions and the
# development flag Dependabot itself reports. When unsure it answers "ships",
# because an extra release costs nothing and a missed one does.

# Paths that never end up in a shipped image: test projects and folders, docs,
# markdown and repository automation.
$script:NonShippingPathPatterns = @(
    '(?i)^tests?/'
    '(?i)^docs?/'
    '(?i)^\.github/'
    '(?i)(^|/)[^/]+\.(unit|integration)?tests?/'
    '(?i)\.md$'
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
        $shipping = @($Dependencies | Where-Object { $_.dependencyType -ne 'direct:development' })
        if ($shipping.Count -eq 0) {
            return @{ Skip = $true; Reason = "all $($Dependencies.Count) updated package(s) are development dependencies" }
        }
    }

    return @{ Skip = $false; Reason = 'the update changes shipping files or runtime packages' }
}
