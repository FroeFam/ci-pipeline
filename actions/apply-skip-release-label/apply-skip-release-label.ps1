$ErrorActionPreference = 'Stop'

$repo     = $env:GITHUB_REPOSITORY
$prNumber = $env:PR_NUMBER

gh issue edit $prNumber --repo $repo --add-label 'skip-release'
