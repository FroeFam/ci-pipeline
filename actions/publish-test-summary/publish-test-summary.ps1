$ErrorActionPreference = 'Stop'

$format = $env:RESULTS_FORMAT
$path   = $env:RESULTS_PATH

function Get-Count($Counters, [string]$Name) {
    $value = $Counters.$Name
    if ([string]::IsNullOrWhiteSpace("$value")) {
        return 0
    }
    return [int]$value
}

$rows    = New-Object System.Collections.Generic.List[string]
$total   = 0
$passed  = 0
$failed  = 0
$skipped = 0

if ($format -eq 'trx') {
    $files = Get-ChildItem -Path $path -Filter *.trx -Recurse -ErrorAction SilentlyContinue
    if (-not $files) {
        "## Test Results`n`nNo TRX files were produced." | Add-Content -Path $env:GITHUB_STEP_SUMMARY
        exit 0
    }

    foreach ($file in $files) {
        [xml]$trx = Get-Content -Path $file.FullName -Raw
        $counters = $trx.TestRun.ResultSummary.Counters

        $fileTotal   = Get-Count $counters total
        $filePassed  = Get-Count $counters passed
        $fileFailed  = (Get-Count $counters failed) + (Get-Count $counters error) + (Get-Count $counters timeout) + (Get-Count $counters aborted)
        $fileSkipped = (Get-Count $counters notExecuted) + (Get-Count $counters notRunnable) + (Get-Count $counters inconclusive)

        $total   += $fileTotal
        $passed  += $filePassed
        $failed  += $fileFailed
        $skipped += $fileSkipped

        $rows.Add("| $($file.BaseName) | $filePassed | $fileFailed | $fileSkipped | $fileTotal |")
    }
} elseif ($format -eq 'junit') {
    $files = Get-ChildItem -Path $path -Filter *.xml -Recurse -ErrorAction SilentlyContinue
    if (-not $files) {
        "## Test Results`n`nNo JUnit XML files were produced." | Add-Content -Path $env:GITHUB_STEP_SUMMARY
        exit 0
    }

    foreach ($file in $files) {
        [xml]$doc = Get-Content -Path $file.FullName -Raw
        $suites = if ($doc.testsuites) { $doc.testsuites.testsuite } else { @($doc.testsuite) }

        foreach ($suite in $suites) {
            if (-not $suite) { continue }

            $sTests    = [int]($suite.tests    ?? 0)
            $sFailures = [int]($suite.failures ?? 0)
            $sErrors   = [int]($suite.errors   ?? 0)
            $sSkipped  = [int]($suite.skipped  ?? 0)
            $sPassed   = $sTests - $sFailures - $sErrors - $sSkipped

            $total   += $sTests
            $passed  += $sPassed
            $failed  += ($sFailures + $sErrors)
            $skipped += $sSkipped

            $suiteName = if ($suite.name) { "$($file.BaseName) ($($suite.name))" } else { $file.BaseName }
            $rows.Add("| $suiteName | $sPassed | $($sFailures + $sErrors) | $sSkipped | $sTests |")
        }
    }
} else {
    throw "Unknown test results format '$format' (expected trx or junit)."
}

@(
    "## Test Results"
    ""
    "| Suite | Passed | Failed | Skipped | Total |"
    "| --- | ---: | ---: | ---: | ---: |"
    $rows
    ""
    "**Overall:** Passed $passed, Failed $failed, Skipped $skipped, Total $total"
) | Add-Content -Path $env:GITHUB_STEP_SUMMARY
