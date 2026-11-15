# Pure helpers for resolve-dependabot-classification.ps1, dot-sourced by it and
# by the Pester tests.
#
# The model sees a diff and calls a runtime image jump (dotnet/sdk 10.0 to 11.0)
# "a dependency update", so it labels it patch. The size of the version jump is
# a fact Dependabot reports, so the floor is applied deterministically:
#   - a major update of a Docker image  -> at least major (the runtime the
#     service runs on changed)
#   - a major update of any other package -> at least minor (a notable change
#     that does not break the service's own contract)
# The model's answer stands when it is already at or above the floor.

$script:Rank = @{ unknown = 0; patch = 1; minor = 2; major = 3 }

function Get-ClassificationRank {
    param([AllowNull()][string]$Name)
    if ($Name -and $script:Rank.ContainsKey($Name)) { return $script:Rank[$Name] }
    return 0
}

# Package names go into a PR comment: keep only characters that can appear in one.
function ConvertTo-SafePackageName {
    param([AllowNull()][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return '' }
    return ([regex]::Replace($Name, '[^A-Za-z0-9._/@:\-]', ''))
}

# Returns @{ Classification = <string>; Rationale = <string> }.
function Resolve-Classification {
    param(
        [AllowNull()][string]$Classification,
        [AllowNull()][string]$Rationale,
        [object[]]$Dependencies = @()
    )

    $Dependencies = @($Dependencies | Where-Object { $null -ne $_ })
    $majors = @($Dependencies | Where-Object { $_.updateType -eq 'version-update:semver-major' })

    if ($majors.Count -eq 0) {
        return @{ Classification = $Classification; Rationale = $Rationale }
    }

    $floor = 'minor'
    foreach ($d in $majors) { if ($d.packageEcosystem -eq 'docker') { $floor = 'major' } }

    if ((Get-ClassificationRank $Classification) -ge (Get-ClassificationRank $floor)) {
        return @{ Classification = $Classification; Rationale = $Rationale }
    }

    $names = (@($majors | ForEach-Object { ConvertTo-SafePackageName $_.dependencyName } | Where-Object { $_ } | Select-Object -Unique) -join ', ')
    $kind = if ($floor -eq 'major') { 'a runtime image' } else { 'a package' }
    $text = "Dependabot reports a major version update of $names, which is $kind jump and never a patch, so the classification is raised to $floor."
    return @{ Classification = $floor; Rationale = $text }
}
