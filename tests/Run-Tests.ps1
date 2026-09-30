# Self-contained test runner for topsdo (no Pester needed).
# Works with Windows PowerShell 5.1 and PowerShell 7+:
#   powershell -NoProfile -File tests/Run-Tests.ps1
#   pwsh -NoProfile -File tests/Run-Tests.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path (Join-Path $root 'Topsdo') 'Topsdo.psd1') -Force
$module = Get-Module Topsdo

$script:Passed = 0
$script:Failed = New-Object System.Collections.Generic.List[string]

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $module $Body
        $script:Passed++
        Write-Host "  [ok]   $Name" -ForegroundColor Green
    }
    catch {
        $script:Failed.Add("$Name : $($_.Exception.Message)")
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        Write-Host "         $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Assertion helpers live in the module scope so the test bodies can use them.
& $module {
    function script:Assert-Equal {
        param($Expected, $Actual, [string]$Message = '')
        if ($Expected -is [array] -or $Actual -is [array]) {
            $e = [string]::Join('|', @($Expected)); $a = [string]::Join('|', @($Actual))
            if ($e -cne $a) { throw "Expected [$e] but got [$a]. $Message" }
            return
        }
        if ("$Expected" -cne "$Actual") { throw "Expected [$Expected] but got [$Actual]. $Message" }
    }
    function script:Assert-True { param($Value, [string]$Message = 'Expected true') if (-not $Value) { throw $Message } }
    function script:New-TestContext {
        param([string[]]$Lines = @(), [string]$Config = '')
        $dir = Join-Path ([IO.Path]::GetTempPath()) ('topsdo-test-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir | Out-Null
        $script:TestDirs.Add($dir)
        $cfgPath = Join-Path $dir 'test.conf'
        [IO.File]::WriteAllText($cfgPath, "[topsdo]`nbackup_count = 5`n$Config`n")
        $todo = Join-Path $dir 'todo.txt'
        if ($Lines.Count) { [IO.File]::WriteAllText($todo, ([string]::Join("`n", $Lines) + "`n")) }
        $ctx = New-TdContext -ConfigFile $cfgPath -TodoFile $todo -DoneFile (Join-Path $dir 'done.txt') -Color $false
        $ctx.AssumeYes = $false
        $ctx.Dir = $dir
        return $ctx
    }
    function script:Invoke-Test {
        param($Ctx, [string]$Line)
        $Ctx.Buffer.Clear()
        Invoke-TdCommandLine $Ctx $Line
        $out = @($Ctx.Buffer | ForEach-Object { $_.Text })
        $Ctx.Buffer.Clear()
        return , $out
    }
    function script:Get-TestFile { param($Ctx) return @([IO.File]::ReadAllLines($Ctx.TodoPath) | Where-Object { $_ }) }
    $script:TestDirs = New-Object System.Collections.Generic.List[string]
    # 2026-09-30 is a Wednesday
    $script:TdTodayOverride = [datetime]'2026-09-30'
}

Write-Host "topsdo tests on PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"

Write-Host 'Parsing'
Test-Case 'parses priority, creation date, projects, contexts and tags' {
    [void](Import-TdConfig -ConfigFile $null)
    $t = New-TdTodo '(A) 2026-09-01 Call Bob +family @phone due:2026-10-01 url http://example.com'
    Assert-Equal 'A' $t.Priority
    Assert-Equal '2026-09-01' $t.CreationDate
    Assert-Equal @('family') $t.Projects
    Assert-Equal @('phone') $t.Contexts
    Assert-Equal 1 @($t.Tags).Count 'URLs are not tags'
    Assert-Equal '2026-10-01' (Format-TdDate $t.Due)
    Assert-Equal '(A) 2026-09-01 Call Bob +family @phone due:2026-10-01 url http://example.com' (Get-TdTodoSource $t)
}
Test-Case 'parses completed items' {
    $t = New-TdTodo 'x 2026-09-30 2026-09-01 Done thing'
    Assert-True $t.Completed
    Assert-Equal '2026-09-30' $t.CompletionDate
    Assert-Equal '2026-09-01' $t.CreationDate
    Assert-Equal 'Done thing' $t.Text
    $t2 = New-TdTodo 'xylophone lessons'
    Assert-True (-not $t2.Completed) 'xylophone is not completed'
}
Test-Case 'lower case (a) is not a priority' {
    $t = New-TdTodo '(a) something'
    Assert-Equal '' "$($t.Priority)"
}
Test-Case 'set, replace and remove tags' {
    $t = New-TdTodo 'Task foo:1 bar:2'
    Set-TdTag $t 'foo' '3'
    Assert-Equal 'Task foo:3 bar:2' $t.Text
    Set-TdTag $t 'foo' '4' -Add
    Assert-Equal @('3', '4') (Get-TdTagValues $t 'foo')
    Remove-TdTag $t 'foo' '3'
    Assert-Equal 'Task bar:2 foo:4' $t.Text
    Remove-TdTag $t 'foo'
    Assert-Equal 'Task bar:2' $t.Text
}

Write-Host 'Dates'
Test-Case 'relative dates' {
    Assert-Equal '2026-09-30' (Format-TdDate (Resolve-TdRelativeDate 'today'))
    Assert-Equal '2026-10-01' (Format-TdDate (Resolve-TdRelativeDate 'tom'))
    Assert-Equal '2026-10-05' (Format-TdDate (Resolve-TdRelativeDate 'mon'))
    Assert-Equal '2026-10-07' (Format-TdDate (Resolve-TdRelativeDate 'wednesday')) 'same weekday means next week'
    Assert-Equal '2026-10-14' (Format-TdDate (Resolve-TdRelativeDate '2w'))
    Assert-Equal '2026-10-30' (Format-TdDate (Resolve-TdRelativeDate '1m'))
    Assert-Equal '2026-09-27' (Format-TdDate (Resolve-TdRelativeDate '-3d'))
    Assert-Equal '2026-10-05' (Format-TdDate (Resolve-TdRelativeDate '3b')) 'business days skip the weekend'
    Assert-True ($null -eq (Resolve-TdRelativeDate 'someday'))
}
Test-Case 'human readable dates' {
    Assert-Equal 'today' (Get-TdHumanDate ([datetime]'2026-09-30'))
    Assert-Equal 'tomorrow' (Get-TdHumanDate ([datetime]'2026-10-01'))
    Assert-Equal 'in 5 days' (Get-TdHumanDate ([datetime]'2026-10-05'))
    Assert-Equal '3 days ago' (Get-TdHumanDate ([datetime]'2026-09-27'))
    Assert-Equal 'in 3 weeks' (Get-TdHumanDate ([datetime]'2026-10-21'))
}

Write-Host 'Importance, recurrence'
Test-Case 'importance' {
    Assert-Equal 2 (Get-TdImportance (New-TdTodo 'plain'))
    Assert-Equal 5 (Get-TdImportance (New-TdTodo '(A) prio'))
    Assert-Equal 10 (Get-TdImportance (New-TdTodo '(A) due today due:2026-09-30'))
    Assert-Equal 8 (Get-TdImportance (New-TdTodo 'overdue due:2026-09-01'))
    Assert-Equal 3 (Get-TdImportance (New-TdTodo 'starred star:1'))
}
Test-Case 'recurrence (normal and strict)' {
    $t = New-TdTodo 'Review rec:1w due:2026-09-20 t:2026-09-18'
    $n = New-TdRecurrence $t
    Assert-Equal '2026-10-07' (Format-TdDate $n.Due)
    Assert-Equal '2026-10-05' (Format-TdDate $n.Start) 'start keeps its distance to due'
    $s = New-TdRecurrence (New-TdTodo 'Rent rec:+1m due:2026-09-01')
    Assert-Equal '2026-10-01' (Format-TdDate $s.Due)
    $u = New-TdRecurrence (New-TdTodo 'Water plants rec:3d')
    Assert-Equal '2026-10-03' (Format-TdDate $u.Due)
}

Write-Host 'Filter, sort, format'
Test-Case 'filters' {
    $items = @(
        (New-TdTodo '(A) Alpha +work @office due:2026-10-01'),
        (New-TdTodo '(C) Beta +home due:2026-10-20'),
        (New-TdTodo 'Gamma @office effort:3')
    )
    $f = {
        param($w)
        $r = Select-TdTodos -List $null -Items $items -Filters (ConvertTo-TdFilter $w) -ShowAll -Index @{ Children = @{}; Parents = @{} }
        @($r | ForEach-Object { ($_.Text -split ' ')[0] })
    }
    Assert-Equal @('Alpha') (& $f @('+work'))
    Assert-Equal @('Alpha', 'Gamma') (& $f @('@office'))
    Assert-Equal @('Beta') (& $f @('-@office', '-+work'))
    Assert-Equal @('Alpha') (& $f @('due:<=1w'))
    Assert-Equal @('Beta', 'Gamma') (& $f @('(<A)'))
    Assert-Equal @('Alpha', 'Beta') (& $f @('(>=C)'))
    Assert-Equal @('Gamma') (& $f @('effort:>2'))
    Assert-Equal @('Gamma') (& $f @('due:!'))
    Assert-Equal @('Beta') (& $f @('/b.ta/'))
    Assert-Equal @('Alpha') (& $f @('alpha'))
}
Test-Case 'sorting' {
    $list = [pscustomobject]@{ Items = (New-Object System.Collections.Generic.List[object]) }
    foreach ($l in @('b plain', '(B) a prio', 'c due due:2026-09-30', '(A) d top')) { $list.Items.Add((New-TdTodo $l)) }
    Update-TdListIds $list
    $s = Sort-TdTodos -List $list -Items $list.Items -Expression 'desc:importance,due,desc:priority'
    Assert-Equal @('c', '(A)', '(B)', 'b') @($s | ForEach-Object { ((Get-TdTodoSource $_) -split ' ')[0] })
    $s2 = Sort-TdTodos -List $list -Items $list.Items -Expression 'text'
    Assert-Equal @('a', 'b', 'c', 'd') @($s2 | ForEach-Object { $_.Text.Substring(0, 1) })
}
Test-Case 'grouping' {
    $items = @((New-TdTodo 'one +a'), (New-TdTodo 'two +b +a'), (New-TdTodo 'three'))
    $g = Group-TdTodos $items 'project'
    Assert-Equal @('+a', '+b', 'No project') @($g | ForEach-Object { $_.Label })
    Assert-Equal 2 $g[0].Items.Count
}
Test-Case 'format strings' {
    $t = New-TdTodo '(A) 2026-09-01 Call Bob +family due:2026-10-01 id:4'
    $t.Uid = '7'
    Assert-Equal '7 (A) Call Bob +family due:2026-10-01 (due tomorrow)' (Format-TdTodo $t '%I %x %{(}p{)} %s %k %{(}h{)}')
    Assert-Equal '7|A|2026-10-01|tomorrow' (Format-TdTodo $t '%i|%p|%d|%D')
    Assert-Equal '  7 Call Bob +family' (Format-TdTodo $t '%I %s' 3)
    Assert-Equal 'Call Bob +family [4 weeks ago]' (Format-TdTodo $t '%s %{[}C{]} %{<}t{>}')
}

Write-Host 'Helpers'
Test-Case 'command line splitting' {
    Assert-Equal @('add', '(A) Call Bob', '@phone') (Split-TdCommandLine "add '(A) Call Bob' @phone")
    Assert-Equal @('ls', 'due:<today') (Split-TdCommandLine 'ls "due:<today"')
    Assert-Equal @('a', 'b') (Split-TdCommandLine '  a   b ')
}
Test-Case 'options are case-sensitive' {
    $o = Split-TdOptions @('-n', '3', '-N', 'word') @('-n=', '-N')
    Assert-Equal '3' $o.Options['-n']
    Assert-True $o.Options['-N']
    Assert-Equal @('word') $o.Rest
}
Test-Case 'argument flattening' {
    Assert-Equal @('do', '1,2') (ConvertTo-TdArgList @('do', @(1, 2)))
}
Test-Case 'ini parsing keeps keymap case' {
    $ini = ConvertFrom-TdIni @('[column_keymap]', 'G = end', 'g = x', '[LS]', 'Hide_Tags = a')
    Assert-Equal 'end' $ini['column_keymap']['G']
    Assert-Equal 'x' $ini['column_keymap']['g']
    Assert-Equal 'a' $ini['LS']['hide_tags']
}

Write-Host 'Commands'
Test-Case 'add converts dates, sets creation date, supports dependencies' {
    $ctx = New-TestContext @('Write report +work')
    $out = Invoke-Test $ctx 'add Draft outline due:fri partof:1'
    Assert-Equal @('2 Draft outline due:2026-10-02 (due in 2 days)') $out
    Assert-Equal @('Write report +work id:1', '2026-09-30 Draft outline due:2026-10-02 p:1') (Get-TestFile $ctx)
}
Test-Case 'ls hides completed, future, blocked and hidden items' {
    $ctx = New-TestContext @('Parent id:1', 'Child p:1', 'Future t:2026-12-01', 'Hidden h:1', 'x 2026-09-01 Done')
    Assert-Equal @('2|Child') (Invoke-Test $ctx 'ls -F %i|%s')
    Assert-Equal 5 (Invoke-Test $ctx 'ls -x').Count
    Assert-Equal @('3') (Invoke-Test $ctx 'ls -x -F %i Future')
}
Test-Case 'do completes, recurs and archives' {
    $ctx = New-TestContext @('Weekly review rec:1w due:2026-09-30', 'Other')
    $out = Invoke-Test $ctx 'do 1'
    Assert-True ($out[0] -like 'Completed: *') ($out -join ';')
    Assert-True ($out[1] -like 'Recurring: *due:2026-10-07*') ($out -join ';')
    Assert-Equal @('Other', '2026-09-30 Weekly review rec:1w due:2026-10-07') (Get-TestFile $ctx)
    Assert-Equal @('x 2026-09-30 Weekly review rec:1w due:2026-09-30') @([IO.File]::ReadAllLines($ctx.DonePath))
}
Test-Case 'do with subtasks asks, -d sets the date' {
    $ctx = New-TestContext @('Parent id:1', 'Child p:1')
    $ctx.AssumeYes = $true
    [void](Invoke-Test $ctx 'do -d yesterday 1')
    Assert-Equal 0 @(Get-TestFile $ctx).Count
    Assert-Equal @('x 2026-09-29 Parent id:1', 'x 2026-09-29 Child p:1') @([IO.File]::ReadAllLines($ctx.DonePath))
}
Test-Case 'pri, depri, postpone, tag, append' {
    $ctx = New-TestContext @('Task due:2026-10-01 t:2026-09-29')
    [void](Invoke-Test $ctx 'pri 1 b')
    Assert-Equal '(B) Task due:2026-10-01 t:2026-09-29' @(Get-TestFile $ctx)[0]
    [void](Invoke-Test $ctx 'depri 1')
    [void](Invoke-Test $ctx 'postpone -s 1 1w')
    Assert-Equal 'Task due:2026-10-08 t:2026-10-06' @(Get-TestFile $ctx)[0]
    [void](Invoke-Test $ctx 'tag 1 due tomorrow')
    [void](Invoke-Test $ctx 'tag 1 t')
    [void](Invoke-Test $ctx 'append 1 +proj')
    Assert-Equal 'Task due:2026-10-01 +proj' @(Get-TestFile $ctx)[0]
}
Test-Case 'del removes items and dangling dependencies' {
    $ctx = New-TestContext @('Parent id:1', 'Child p:1', 'Other')
    [void](Invoke-Test $ctx 'del -f 1')
    Assert-Equal @('Child', 'Other') (Get-TestFile $ctx)
    [void](Invoke-Test $ctx 'del -e Other')
    Assert-Equal @('Child') (Get-TestFile $ctx)
}
Test-Case 'dep add/rm/ls/clean' {
    $ctx = New-TestContext @('A', 'B', 'C p:9')
    [void](Invoke-Test $ctx 'dep add 1 to 2')
    # new ids never collide with existing (even dangling) ones
    Assert-Equal @('A id:10', 'B p:10', 'C p:9') (Get-TestFile $ctx)
    Assert-Equal @('2 B') (Invoke-Test $ctx 'dep ls 1 to')
    Assert-Equal @('1 A') (Invoke-Test $ctx 'dep ls to 2')
    [void](Invoke-Test $ctx 'dep add 3 before 1')
    [void](Invoke-Test $ctx 'dep rm 1 to 2')
    [void](Invoke-Test $ctx 'dep clean')
    Assert-Equal @('A id:10', 'B', 'C p:10') (Get-TestFile $ctx)
}
Test-Case 'revert restores the previous state' {
    $ctx = New-TestContext @('One')
    [void](Invoke-Test $ctx 'add Two')
    [void](Invoke-Test $ctx 'do 1')
    Assert-Equal @('2026-09-30 Two') (Get-TestFile $ctx)
    Assert-Equal @('Reverted: do 1') (Invoke-Test $ctx 'revert')
    Assert-Equal @('One', '2026-09-30 Two') (Get-TestFile $ctx)
    [void](Invoke-Test $ctx 'revert')
    Assert-Equal @('One') (Get-TestFile $ctx)
}
Test-Case 'sort, lsprj, lscon, aliases, errors' {
    $ctx = New-TestContext @('b +p2 @c2', 'a +p1 @c1') "[aliases]`nfirst = ls -n 1 -s text {}"
    [void](Invoke-Test $ctx 'sort text')
    Assert-Equal @('a +p1 @c1', 'b +p2 @c2') (Get-TestFile $ctx)
    Assert-Equal @('p1', 'p2') (Invoke-Test $ctx 'lsprj')
    Assert-Equal @('c1', 'c2') (Invoke-Test $ctx 'lscon')
    Assert-Equal @('2 b +p2 @c2') (Invoke-Test $ctx 'first b')
    $ctx.ExitCode = 0
    Assert-Equal @('Invalid todo number given: 9') (Invoke-Test $ctx 'do 9')
    Assert-Equal 1 $ctx.ExitCode
}
Test-Case 'ls json output' {
    $ctx = New-TestContext @('(A) Task +p due:2026-10-01')
    $json = [string]::Join("`n", (Invoke-Test $ctx 'ls -f json'))
    $obj = @(ConvertFrom-Json $json)
    $first = @($obj | ForEach-Object { $_ })[0]
    Assert-Equal 'A' $first.priority
    Assert-Equal '2026-10-01' $first.due
}
Test-Case 'text identifiers are stable and start with a letter' {
    $ctx = New-TestContext @('One', 'Two', 'One') "identifiers = text"
    $ids = Invoke-Test $ctx 'ls -F %i'
    Assert-Equal 3 @($ids | Sort-Object -Unique).Count
    foreach ($id in $ids) { Assert-True ($id -match '^[a-z][0-9a-z]{2,}$') "bad id $id" }
    $out = Invoke-Test $ctx "do $($ids[1])"
    Assert-True ($out[0] -like 'Completed:*Two*') ($out -join ';')
}

Write-Host 'Column mode helpers'
Test-Case 'column file round trip' {
    $ctx = New-TestContext @('a +x', 'b')
    $file = Join-Path $ctx.Dir 'cols'
    [IO.File]::WriteAllText($file, "[one]`ntitle = One`nfilterexpr = +x`n[two]`ntitle = All`nshow_all = 1`ngroupexpr = project`n")
    $cols = Import-TdColumns $file
    Assert-Equal 2 $cols.Count
    Assert-True $cols[1].ShowAll
    $ui = @{ Ctx = $ctx; Columns = $cols; ColumnFile = (Join-Path $ctx.Dir 'cols2'); Marks = (New-Object 'System.Collections.Generic.HashSet[string]') }
    Update-TdColumnsData $ui
    Assert-Equal 1 $cols[0].Count
    Assert-Equal 4 $cols[1].Rows.Count 'group headers are rows'
    Assert-Equal 1 $cols[1].Sel 'selection skips group headers'
    Export-TdColumns $ui
    $again = Import-TdColumns $ui.ColumnFile
    Assert-Equal 'project' $again[1].Group
}
Test-Case 'key names and cells' {
    $k = New-Object System.ConsoleKeyInfo ([char]1), ([ConsoleKey]::A), $false, $false, $true
    Assert-Equal '<C-a>' (Get-TdKeyName $k)
    $k2 = New-Object System.ConsoleKeyInfo 'G', ([ConsoleKey]::G), $true, $false, $false
    Assert-Equal 'G' (Get-TdKeyName $k2)
    $cell = Format-TdCell @(@{ T = 'abcdef'; F = $null }) 4 $null
    Assert-Equal 'abcd' ([string]::Join('', @($cell | ForEach-Object { $_.T })))
    $cell = Format-TdCell @(@{ T = 'ab'; F = $null }) 4 $null
    Assert-Equal 'ab  ' ([string]::Join('', @($cell | ForEach-Object { $_.T })))
}
Test-Case 'prompt completion' {
    $ctx = New-TestContext @('a +work @home')
    $ctx.Mode = 'prompt'
    Assert-Equal @('lscon') (Get-TdCompletions $ctx 'lsc').Items
    Assert-Equal @('+work') (Get-TdCompletions $ctx 'ls +w').Items
    Assert-Equal @('@home') (Get-TdCompletions $ctx 'add x @h').Items
    Assert-True ((Get-TdCompletions $ctx 'add x due:to').Items -contains 'due:today')
}

& $module { foreach ($d in $script:TestDirs) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } }

Write-Host ''
$total = $script:Passed + $script:Failed.Count
if ($script:Failed.Count -gt 0) {
    Write-Host "$($script:Failed.Count) of $total tests failed:" -ForegroundColor Red
    foreach ($f in $script:Failed) { Write-Host "  $f" -ForegroundColor Red }
    exit 1
}
Write-Host "All $total tests passed." -ForegroundColor Green
exit 0
