BeforeAll {
    . (Join-Path $PSScriptRoot 'release-notes.lib.ps1')
}

Describe 'ConvertTo-SafeText' {
    It 'strips mentions, links, issue refs and markup' {
        $r = ConvertTo-SafeText 'Fix [click](https://evil.example/x) @everyone #123 <img src=x> `code` **bold** www.evil.example/y'
        $r | Should -Not -Match '[@#\[\]<>`*]'
        $r | Should -Not -Match 'evil'
        $r | Should -Not -Match '://'
    }
    It 'removes bidi, zero-width and control characters and collapses newlines' {
        $r = ConvertTo-SafeText "Add`u{202E}thing`u{200B}`r`n## Breaking Changes`n- fake"
        $r | Should -Not -Match '[\u202E\u200B\r\n#]'
    }
    It 'caps length' {
        (ConvertTo-SafeText ('a' * 500) 140).Length | Should -BeLessOrEqual 140
    }
    It 'returns empty for null and whitespace' {
        ConvertTo-SafeText $null | Should -Be ''
        ConvertTo-SafeText "  `n " | Should -Be ''
    }
    It 'keeps ordinary text' {
        ConvertTo-SafeText 'Add retry to the weekly digest job.' | Should -Be 'Add retry to the weekly digest job.'
    }
}

Describe 'Get-DependabotUpdates' {
    It 'parses a single-package body' {
        $u = @(Get-DependabotUpdates 'Bumps [Npgsql](https://github.com/npgsql/npgsql) from 9.0.2 to 9.0.3.')
        $u.Count | Should -Be 1
        $u[0].Name | Should -Be 'Npgsql'
        $u[0].From | Should -Be '9.0.2'
        $u[0].To   | Should -Be '9.0.3'
    }
    It 'parses grouped Updates lines' {
        $body = @'
Bumps the nuget group with 2 updates: [A.B](https://x) and [C](https://y).

Updates `A.B` from 1.0.0 to 1.1.0
<details><summary>Release notes</summary>Updates `Fake` from 9 to 10 </details>

Updates `C` from 2.0.0 to 3.0.0
'@
        $u = @(Get-DependabotUpdates $body)
        ($u | ForEach-Object { "$($_.Name) $($_.From)>$($_.To)" }) | Should -Be @('A.B 1.0.0>1.1.0', 'C 2.0.0>3.0.0')
    }
    It 'parses the Updated [name](url) from x to y form and ignores details blocks' {
        $body = @'
Updated [MailKit](https://github.com/jstedfast/MailKit) from 4.18.1 to 4.18.2.

<details>
<summary>Release notes</summary>
Updated [Evil](https://x) from 1.0 to 99.0.
</details>

Updated [Markdig](https://github.com/xoofx/markdig) from 1.4.2 to 1.5.0.
'@
        $u = @(Get-DependabotUpdates $body)
        ($u | ForEach-Object { "$($_.Name) $($_.From)>$($_.To)" }) | Should -Be @('MailKit 4.18.1>4.18.2', 'Markdig 1.4.2>1.5.0')
    }
    It 'parses a table' {
        $body = "| Package | From | To |`n| --- | --- | --- |`n| [Foo](https://x) | `1.0.0` | `2.0.0` |"
        $u = @(Get-DependabotUpdates $body)
        $u.Count | Should -Be 1
        $u[0].Name | Should -Be 'Foo'
    }
    It 'rejects hostile names and versions' {
        @(Get-DependabotUpdates 'Updates `evil<script>` from 1 to 2').Count | Should -Be 0
        @(Get-DependabotUpdates 'Updates foo from 1 to 2 [x](http://a)').Count | Should -Be 1
        @(Get-DependabotUpdates 'Updates foo from 1 to @everyone').Count | Should -Be 0
    }
    It 'never accepts a URL-shaped package name but accepts real ecosystem names' {
        @(Get-DependabotUpdates 'Updated https://evil.example from 1.0 to 2.0').Count | Should -Be 0
        @(Get-DependabotUpdates 'Updated //evil.example/x from 1.0 to 2.0').Count | Should -Be 0
        @(Get-DependabotUpdates 'Updated javascript:alert from 1.0 to 2.0').Count | Should -Be 1  # plain name:part, no scheme slashes
        @(Get-DependabotUpdates 'Updated @types/node from 20.1.0 to 20.2.0').Count | Should -Be 1
        @(Get-DependabotUpdates 'Updated actions/checkout from 4 to 5').Count | Should -Be 1
        @(Get-DependabotUpdates 'Updated org.apache:commons-lang3 from 3.1 to 3.2').Count | Should -Be 1
    }
    It 'returns nothing for an unparseable body' {
        @(Get-DependabotUpdates 'nothing useful here').Count | Should -Be 0
        @(Get-DependabotUpdates $null).Count | Should -Be 0
    }
}

Describe 'Merge-DependencyUpdates' {
    It 'keeps earliest from and latest to, drops net no-ops' {
        $items = @(
            @{ Number = 1; Updates = @([pscustomobject]@{ Name = 'A'; From = '1'; To = '2' }, [pscustomobject]@{ Name = 'B'; From = '1'; To = '2' }) }
            @{ Number = 2; Updates = @([pscustomobject]@{ Name = 'A'; From = '2'; To = '3' }, [pscustomobject]@{ Name = 'B'; From = '2'; To = '1' }) }
        )
        $m = @(Merge-DependencyUpdates $items)
        $m.Count | Should -Be 1
        $m[0].Name | Should -Be 'A'
        $m[0].From | Should -Be '1'
        $m[0].To   | Should -Be '3'
        $m[0].Numbers | Should -Be @(1, 2)
    }
}

Describe 'ConvertFrom-ModelNotes' {
    It 'accepts exactly the expected keys and sanitizes values' {
        $r = ConvertFrom-ModelNotes -Text '{"1":"Add retries.","2":"See @everyone https://evil.example now"}' -ExpectedNumbers @(1, 2)
        $r[1] | Should -Be 'Add retries.'
        $r[2] | Should -Not -Match '@|evil'
    }
    It 'tolerates a code fence' {
        $r = ConvertFrom-ModelNotes -Text "``````json`n{`"1`":`"Fix it.`"}`n``````" -ExpectedNumbers @(1)
        $r[1] | Should -Be 'Fix it.'
    }
    It 'rejects extra, missing, or non-object replies' {
        ConvertFrom-ModelNotes -Text '{"1":"a","9":"b"}' -ExpectedNumbers @(1) | Should -BeNullOrEmpty
        ConvertFrom-ModelNotes -Text '{"1":"a"}' -ExpectedNumbers @(1, 2) | Should -BeNullOrEmpty
        ConvertFrom-ModelNotes -Text '["a"]' -ExpectedNumbers @(1) | Should -BeNullOrEmpty
        ConvertFrom-ModelNotes -Text 'Sure! Here you go' -ExpectedNumbers @(1) | Should -BeNullOrEmpty
        ConvertFrom-ModelNotes -Text ('x' * 30000) -ExpectedNumbers @(1) | Should -BeNullOrEmpty
    }
    It 'skips non-string values so the caller falls back' {
        $r = ConvertFrom-ModelNotes -Text '{"1":{"a":"b"},"2":"ok"}' -ExpectedNumbers @(1, 2)
        $r.ContainsKey(1) | Should -BeFalse
        $r[2] | Should -Be 'ok'
    }
    It 'rejects duplicate keys' {
        ConvertFrom-ModelNotes -Text '{"1":"a","1":"b"}' -ExpectedNumbers @(1) | Should -BeNullOrEmpty
    }
}

Describe 'Format-ReleaseNotes' {
    It 'omits empty sections and appends the footer' {
        $t = Format-ReleaseNotes -Footer 'F' -Sections @(@{ Title = 'New Features'; Lines = @('One (#1)') }, @{ Title = 'Empty'; Lines = @() })
        $t | Should -Match '## New Features'
        $t | Should -Not -Match 'Empty'
        $t | Should -Match 'F\s*$'
    }
    It 'says maintenance release when there is nothing' {
        Format-ReleaseNotes -Sections @() | Should -Match 'Maintenance release'
    }
}
