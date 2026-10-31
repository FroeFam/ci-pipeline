# Pure helpers for release-notes.ps1, dot-sourced by it and by the Pester tests.
# Everything that comes from a PR (title, body, file names, model output) is
# untrusted: it only reaches the notes through ConvertTo-SafeText.

function ConvertTo-SafeText {
    param([AllowNull()][string]$Text, [int]$Max = 140)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }

    $t = $Text.Normalize([System.Text.NormalizationForm]::FormKC)
    # Control, format (bidi, zero-width), separator and surrogate characters become a space.
    $t = [regex]::Replace($t, '[\p{C}\p{Z}]+', ' ')
    # Drop anything that would autolink before the allowlist keeps ':' and '/'.
    $t = [regex]::Replace($t, '(?i)\b[a-z][a-z0-9+.\-]*:/{1,2}\S*', '')
    $t = [regex]::Replace($t, '(?i)\bwww\.\S*', '')
    # Allowlist: letters, digits, space and a few plain punctuation marks. This removes
    # # @ [ ] < > ` * | & \ ! and ~, so no mentions, issue refs, links, images or markup.
    $t = [regex]::Replace($t, '[^\p{L}\p{N} .,;:''"()/+_\-]', '')
    $t = ([regex]::Replace($t, ' {2,}', ' ')).Trim()
    if ($t.Length -gt $Max) { $t = $t.Substring(0, $Max).TrimEnd() }
    return $t
}

function Test-DependabotAuthor {
    param([string]$Login)
    return $Login -in @('app/dependabot', 'dependabot[bot]', 'dependabot')
}

function Get-DependabotUpdates {
    # Returns objects with Name, From, To parsed from a Dependabot PR body. Names and
    # versions come from a third-party registry, so they are validated, not trusted.
    param([AllowNull()][string]$Body)

    if ([string]::IsNullOrWhiteSpace($Body)) { return @() }

    # <details> holds third-party release notes and commit lists: never read update lines from it.
    $b = [regex]::Replace($Body, '(?is)<details>.*?</details>', ' ')
    # [text](url) -> text, and drop backticks, so every format reads the same.
    $b = [regex]::Replace($b, '\[([^\]]+)\]\([^)]*\)', '$1')
    $b = $b -replace '`', ''

    $found = [System.Collections.Generic.List[object]]::new()
    $add = {
        param($name, $from, $to)
        $from = $from.Trim().TrimEnd('.', ',', ';')
        $to   = $to.Trim().TrimEnd('.', ',', ';')
        if ($name -match '^[\w@./:-]{1,100}$' -and
            $from -match '^[\w.+-]{1,50}$' -and
            $to   -match '^[\w.+-]{1,50}$' -and
            $from -match '\d' -and $to -match '\d' -and   # skips table header and separator rows
            $from -ne $to) {
            $found.Add([pscustomobject]@{ Name = $name; From = $from; To = $to })
        }
    }

    foreach ($m in [regex]::Matches($b, '(?m)\b(?:Bumps?|Updates?|Updated|Bumped)\s+(\S+)\s+from\s+(\S+)\s+to\s+(\S+)')) {
        & $add $m.Groups[1].Value $m.Groups[2].Value $m.Groups[3].Value
    }
    foreach ($m in [regex]::Matches($b, '(?m)^\|\s*([^|\s]+)\s*\|\s*([^|\s]+)\s*\|\s*([^|\s]+)\s*\|')) {
        & $add $m.Groups[1].Value $m.Groups[2].Value $m.Groups[3].Value
    }

    return @($found)
}

function Merge-DependencyUpdates {
    # Input is in merge order, each item @{ Number; Updates }. A package bumped more than
    # once keeps its earliest From and latest To; a net no-op is dropped.
    param([object[]]$Items)

    $map = [ordered]@{}
    foreach ($item in $Items) {
        foreach ($u in $item.Updates) {
            if ($map.Contains($u.Name)) {
                $map[$u.Name].To = $u.To
                $map[$u.Name].Numbers += $item.Number
            } else {
                $map[$u.Name] = [pscustomobject]@{ Name = $u.Name; From = $u.From; To = $u.To; Numbers = @($item.Number) }
            }
        }
    }
    return @($map.Values | Where-Object { $_.From -ne $_.To })
}

function ConvertFrom-ModelNotes {
    # Strict parse of the model reply. Returns a hashtable number -> sanitized sentence,
    # or $null when the reply is not exactly a JSON object keyed by the expected numbers
    # with string values. Individual unusable sentences are left out (caller falls back).
    param([AllowNull()][string]$Text, [int[]]$ExpectedNumbers)

    if ([string]::IsNullOrWhiteSpace($Text) -or $Text.Length -gt 20000) { return $null }

    $raw = ($Text -replace '(?ms)^\s*```[a-zA-Z]*\s*', '') -replace '(?ms)```\s*$', ''
    # ConvertFrom-Json keeps the last of duplicate keys, so count key-like tokens up front.
    if ([regex]::Matches($raw, '"\d+"\s*:').Count -ne @($ExpectedNumbers).Count) { return $null }
    try {
        $parsed = $raw.Trim() | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    } catch {
        return $null
    }
    if ($parsed -isnot [System.Collections.IDictionary]) { return $null }

    $expected = @($ExpectedNumbers | ForEach-Object { "$_" } | Sort-Object)
    $actual   = @($parsed.Keys | ForEach-Object { "$_" } | Sort-Object)
    if (($expected -join ',') -ne ($actual -join ',')) { return $null }

    $result = @{}
    foreach ($n in $ExpectedNumbers) {
        $v = $parsed["$n"]
        if ($v -isnot [string]) { continue }
        $safe = ConvertTo-SafeText $v 140
        if ($safe) { $result[$n] = $safe }
    }
    return $result
}

function Format-ReleaseNotes {
    # Sections: @{ Title; Lines } in display order. Lines are already safe text.
    param([object[]]$Sections, [string]$Footer)

    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($s in $Sections) {
        if (@($s.Lines).Count -eq 0) { continue }
        $out.Add("## $($s.Title)")
        $out.Add('')
        foreach ($l in $s.Lines) { $out.Add("- $l") }
        $out.Add('')
    }
    if ($out.Count -eq 0) {
        $out.Add('Maintenance release.')
        $out.Add('')
    }
    if ($Footer) { $out.Add($Footer) }
    return ($out -join "`n").TrimEnd() + "`n"
}
