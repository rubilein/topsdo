# Subcommands. Each command receives the context and its argument array.

function Get-TdArgRest {
    param([string[]]$Argv, [int]$From)
    if ($Argv.Count -le $From) { return , @() }
    return , [string[]]$Argv[$From..($Argv.Count - 1)]
}

# --- add / append -------------------------------------------------------------------

function Add-TdNewTodo {
    param($Ctx, [string]$Line)
    $list = Get-TdCtxList $Ctx
    $t = New-TdTodo $Line
    if (-not $t.Text) { throw 'Refusing to add an empty todo.' }
    Convert-TdTodoDates $t
    if (-not $t.Completed -and -not $t.CreationDate -and (Get-TdOptBool 'add' 'auto_creation_date' $true)) {
        $t.CreationDate = Format-TdDate (Get-TdToday)
    }
    # resolve dependency shortcuts before the new item changes any identifiers
    $deps = New-Object System.Collections.Generic.List[object]
    foreach ($rel in @('before', 'after', 'partof', 'children-of', 'parents-of')) {
        foreach ($v in (Get-TdTagValues $t $rel)) {
            $target = Find-TdTodo $list $v
            Remove-TdTag -Todo $t -Key $rel -Value $v
            if ($null -eq $target) { Write-TdErr $Ctx "Invalid todo number given: $v"; continue }
            $deps.Add(@($rel, $target))
        }
    }
    $list.Items.Add($t)
    foreach ($d in $deps) {
        $target = $d[1]
        switch ($d[0]) {
            'before' { Add-TdDependency $list $target $t }
            'partof' { Add-TdDependency $list $target $t }
            'after' { Add-TdDependency $list $t $target }
            'children-of' {
                # new item becomes a child of the parents of the target
                foreach ($p in (Get-TdParents $list $target)) { Add-TdDependency $list $p $t }
            }
            'parents-of' {
                # new item becomes a parent of the children of the target
                foreach ($c in (Get-TdChildren $list $target)) { Add-TdDependency $list $t $c }
            }
        }
    }
    $list.Dirty = $true
    Update-TdListIds $list
    Write-TdTodoLine $Ctx $t
    return $t
}

function Invoke-TdCmdAdd {
    param($Ctx, [string[]]$Argv)
    $o = Split-TdOptions $Argv @('-f=')
    $lines = @()
    if ($o.Options.ContainsKey('-f')) {
        $f = $o.Options['-f']
        if ($f -eq '-') { $lines = [Console]::In.ReadToEnd() -split "`r?`n" }
        else { $lines = (Read-TdTextFile (Resolve-TdPath $f)) -split "`r?`n" }
    }
    else {
        if ($o.Rest.Count -eq 0) { throw 'Usage: add <text>' }
        $lines = @([string]::Join(' ', $o.Rest))
    }
    foreach ($l in $lines) { if ($l.Trim()) { [void](Add-TdNewTodo $Ctx $l) } }
}

function Invoke-TdCmdAppend {
    param($Ctx, [string[]]$Argv)
    if ($Argv.Count -lt 2) { throw 'Usage: append <ID> <text>' }
    $t = (Resolve-TdTodoIds $Ctx @($Argv[0]))[0]
    Add-TdTodoText $t ([string]::Join(' ', (Get-TdArgRest $Argv 1)))
    Convert-TdTodoDates $t
    (Get-TdCtxList $Ctx).Dirty = $true
    Write-TdTodoLine $Ctx $t
}

# --- del / do ---------------------------------------------------------------------

function Get-TdSubtasks {
    <# All (recursive) unfinished children of a todo. #>
    param($List, $Todo, $Seen = $null)
    if ($null -eq $Seen) { $Seen = New-Object System.Collections.Generic.List[object] }
    foreach ($c in (Get-TdChildren $List $Todo)) {
        if ($c.Completed -or $Seen.Contains($c)) { continue }
        $Seen.Add($c)
        [void](Get-TdSubtasks $List $c $Seen)
    }
    return , $Seen.ToArray()
}

function Get-TdTargets {
    <# Resolves IDs, or a filter expression when -e was given. #>
    param($Ctx, $Parsed)
    if ($Parsed.Options.ContainsKey('-e')) {
        return , (Resolve-TdExpression $Ctx $Parsed.Rest)
    }
    return , (Resolve-TdTodoIds $Ctx $Parsed.Rest)
}

function Invoke-TdCmdDel {
    param($Ctx, [string[]]$Argv)
    $o = Split-TdOptions $Argv @('-f', '-e')
    $list = Get-TdCtxList $Ctx
    $targets = New-Object System.Collections.Generic.List[object]
    foreach ($t in (Get-TdTargets $Ctx $o)) { if (-not $targets.Contains($t)) { $targets.Add($t) } }
    if ($targets.Count -eq 0) { Write-TdOut $Ctx 'No todos matched.'; return }
    foreach ($t in @($targets.ToArray())) {
        $subs = Get-TdSubtasks $list $t
        if ($subs.Count -gt 0 -and -not $o.Options.ContainsKey('-f')) {
            if (Read-TdConfirm $Ctx "$($t.Uid): also remove $($subs.Count) subtask(s)?") {
                foreach ($s in $subs) { if (-not $targets.Contains($s)) { $targets.Add($s) } }
            }
        }
    }
    $w = Get-TdIdWidth $list.Items
    foreach ($t in $targets) {
        Write-TdOut $Ctx ('Removed: ' + (Format-TdTodo $t '%I %r' $w)) $t
    }
    foreach ($t in $targets) { [void]$list.Items.Remove($t) }
    [void](Clear-TdDanglingDeps $list)
    $list.Dirty = $true
}

function Invoke-TdCmdDo {
    param($Ctx, [string[]]$Argv)
    $o = Split-TdOptions $Argv @('-d=', '-s', '-f', '-e')
    $list = Get-TdCtxList $Ctx
    $date = Get-TdToday
    if ($o.Options.ContainsKey('-d')) {
        $date = Resolve-TdRelativeDate $o.Options['-d']
        if ($null -eq $date) { throw "Invalid date: $($o.Options['-d'])" }
    }
    $targets = New-Object System.Collections.Generic.List[object]
    foreach ($t in (Get-TdTargets $Ctx $o)) { if (-not $targets.Contains($t)) { $targets.Add($t) } }
    if ($targets.Count -eq 0) { Write-TdOut $Ctx 'No todos matched.'; return }
    $w = Get-TdIdWidth $list.Items
    $queue = New-Object System.Collections.Generic.List[object]
    foreach ($t in $targets) {
        if ($t.Completed) { Write-TdErr $Ctx "$($t.Uid): todo has already been completed."; continue }
        $subs = Get-TdSubtasks $list $t
        if ($subs.Count -gt 0 -and -not $o.Options.ContainsKey('-f')) {
            foreach ($s in $subs) { Write-TdOut $Ctx ('  ' + (Format-TdTodo $s '%I %r' $w)) $s }
            if (Read-TdConfirm $Ctx "$($t.Uid): also mark $($subs.Count) subtask(s) as done?") {
                foreach ($s in $subs) { if (-not $queue.Contains($s)) { $queue.Add($s) } }
            }
        }
        if (-not $queue.Contains($t)) { $queue.Add($t) }
    }
    $new = New-Object System.Collections.Generic.List[object]
    foreach ($t in $queue) {
        $next = New-TdRecurrence -Todo $t -Strict:($o.Options.ContainsKey('-s')) -CompletionDate $date
        Complete-TdTodo $t $date
        Write-TdOut $Ctx ('Completed: ' + (Format-TdTodo $t '%I %r' $w)) $t
        if ($null -ne $next) { $new.Add($next) }
    }
    foreach ($n in $new) {
        $list.Items.Add($n)
        Update-TdListIds $list
        Write-TdTodoLine $Ctx $n 'Recurring: '
    }
    $list.Dirty = $true
}

# --- pri / depri / postpone / tag -------------------------------------------------------

function Invoke-TdCmdPri {
    param($Ctx, [string[]]$Argv)
    if ($Argv.Count -lt 2) { throw 'Usage: pri <ID>... <PRIORITY>' }
    $prio = $Argv[$Argv.Count - 1].ToUpperInvariant()
    if ($prio -notmatch '^[A-Z]$') { throw "Invalid priority given: $($Argv[$Argv.Count - 1])" }
    $todos = Resolve-TdTodoIds $Ctx ([string[]]$Argv[0..($Argv.Count - 2)])
    foreach ($t in $todos) {
        if ($t.Completed) { Write-TdErr $Ctx "$($t.Uid): todo has already been completed."; continue }
        if ($t.Priority -eq $prio) { Write-TdOut $Ctx "$($t.Uid): priority is already $prio." }
        elseif ($t.Priority) { Write-TdOut $Ctx "$($t.Uid): priority changed from $($t.Priority) to $prio." }
        else { Write-TdOut $Ctx "$($t.Uid): priority set to $prio." }
        $t.Priority = $prio
        Write-TdTodoLine $Ctx $t
    }
    (Get-TdCtxList $Ctx).Dirty = $true
}

function Invoke-TdCmdDepri {
    param($Ctx, [string[]]$Argv)
    foreach ($t in (Resolve-TdTodoIds $Ctx $Argv)) {
        if ($t.Priority) {
            $t.Priority = $null
            Write-TdOut $Ctx "$($t.Uid): priority removed."
            Write-TdTodoLine $Ctx $t
        }
    }
    (Get-TdCtxList $Ctx).Dirty = $true
}

function Invoke-TdCmdPostpone {
    param($Ctx, [string[]]$Argv)
    $o = Split-TdOptions $Argv @('-s')
    $rest = $o.Rest
    if ($rest.Count -lt 2) { throw 'Usage: postpone [-s] <ID>... <PATTERN>' }
    $p = ConvertFrom-TdPeriod $rest[$rest.Count - 1]
    if ($null -eq $p -or $p.Strict) { throw "Invalid date pattern given: $($rest[$rest.Count - 1])" }
    $todos = Resolve-TdTodoIds $Ctx ([string[]]$rest[0..($rest.Count - 2)])
    $dueKey = Get-TdTagName 'due'
    $startKey = Get-TdTagName 'start'
    foreach ($t in $todos) {
        $today = Get-TdToday
        $oldDue = $t.Due
        $base = $today
        if ($null -ne $oldDue) { $base = $oldDue }
        $newDue = Add-TdPeriod $base $p.Amount $p.Unit
        Set-TdTag -Todo $t -Key $dueKey -Value (Format-TdDate $newDue)
        if ($o.Options.ContainsKey('-s') -and $null -ne $t.Start) {
            if ($null -ne $oldDue) { $shift = ($newDue - $oldDue).Days } else { $shift = ($newDue - $today).Days }
            Set-TdTag -Todo $t -Key $startKey -Value (Format-TdDate $t.Start.AddDays($shift))
        }
        Write-TdTodoLine $Ctx $t
    }
    (Get-TdCtxList $Ctx).Dirty = $true
}

function Invoke-TdCmdTag {
    param($Ctx, [string[]]$Argv)
    $o = Split-TdOptions $Argv @('-a', '-f')
    $rest = $o.Rest
    if ($rest.Count -lt 2) { throw 'Usage: tag [-a] <ID> <NAME> [VALUE]' }
    $t = (Resolve-TdTodoIds $Ctx @($rest[0]))[0]
    $key = $rest[1]
    $value = ''
    if ($rest.Count -gt 2) { $value = [string]::Join(' ', (Get-TdArgRest $rest 2)) }
    if ($value -and ($key -eq (Get-TdTagName 'due') -or $key -eq (Get-TdTagName 'start'))) {
        $d = Resolve-TdRelativeDate $value
        if ($null -ne $d) { $value = Format-TdDate $d }
    }
    if ($value) { Set-TdTag -Todo $t -Key $key -Value $value -Add:($o.Options.ContainsKey('-a')) }
    else { Remove-TdTag -Todo $t -Key $key }
    (Get-TdCtxList $Ctx).Dirty = $true
    Write-TdTodoLine $Ctx $t
}

# --- ls / lsprj / lscon ----------------------------------------------------------------

function ConvertTo-TdJsonObject {
    param($Todo)
    $tags = [ordered]@{}
    foreach ($tag in $Todo.Tags) {
        if ($tags.Contains($tag.Key)) { $tags[$tag.Key] = @($tags[$tag.Key]) + $tag.Value } else { $tags[$tag.Key] = $tag.Value }
    }
    return [ordered]@{
        id              = $Todo.Uid
        line            = $Todo.Number
        source          = (Get-TdTodoSource $Todo)
        text            = $Todo.Text
        completed       = $Todo.Completed
        completion_date = $Todo.CompletionDate
        priority        = $Todo.Priority
        creation_date   = $Todo.CreationDate
        due             = (Format-TdDate $Todo.Due)
        start           = (Format-TdDate $Todo.Start)
        projects        = @($Todo.Projects)
        contexts        = @($Todo.Contexts)
        tags            = $tags
    }
}

function Invoke-TdCmdLs {
    param($Ctx, [string[]]$Argv)
    $o = Split-TdOptions $Argv @('-x', '-n=', '-N', '-s=', '-g=', '-f=', '-F=', '-i=') -Anywhere
    $list = Get-TdCtxList $Ctx
    $index = New-TdDepIndex $list
    if ($o.Options.ContainsKey('-i')) {
        $items = Resolve-TdTodoIds $Ctx @($o.Options['-i'])
        $filters = ConvertTo-TdFilter $o.Rest
        $items = Select-TdTodos -List $list -Items $items -Filters $filters -ShowAll -Index $index
    }
    else {
        $filters = ConvertTo-TdFilter $o.Rest
        $items = Select-TdTodos -List $list -Items $list.Items -Filters $filters -ShowAll:($o.Options.ContainsKey('-x')) -Index $index
    }
    $sortExpr = Get-TdOpt 'sort' 'sort_string' ''
    if ($o.Options.ContainsKey('-s')) { $sortExpr = $o.Options['-s'] }
    $items = Sort-TdTodos -List $list -Items $items -Expression $sortExpr -Index $index

    $limit = Get-TdOptInt 'ls' 'list_limit' -1
    if ($o.Options.ContainsKey('-n')) { $limit = [int]$o.Options['-n'] }
    if ($o.Options.ContainsKey('-N')) {
        try { $limit = [Math]::Max(1, [Console]::WindowHeight - 3) } catch { }
    }
    if ($limit -ge 0 -and $items.Count -gt $limit) { $items = @($items[0..([Math]::Max(0, $limit - 1))]); if ($limit -eq 0) { $items = @() } }

    $format = 'text'
    if ($o.Options.ContainsKey('-f')) { $format = $o.Options['-f'].ToLowerInvariant() }
    switch ($format) {
        'json' {
            $objs = @($items | ForEach-Object { ConvertTo-TdJsonObject $_ })
            $json = ConvertTo-Json -InputObject $objs -Depth 5
            if ($objs.Count -eq 0) { $json = '[]' }
            foreach ($l in ($json -split "`r?`n")) { Write-TdOut $Ctx $l }
        }
        'dot' {
            Write-TdOut $Ctx 'digraph topsdo {'
            Write-TdOut $Ctx '  node [shape=box];'
            foreach ($t in $items) {
                $label = (Format-TdTodo $t '%s') -replace '\\', '\\' -replace '"', '\"'
                Write-TdOut $Ctx ('  "{0}" [label="{0}: {1}"];' -f $t.Uid, $label)
            }
            foreach ($t in $items) {
                foreach ($c in (Get-TdChildren $list $t)) {
                    if ($items -contains $c) { Write-TdOut $Ctx ('  "{0}" -> "{1}";' -f $t.Uid, $c.Uid) }
                }
            }
            Write-TdOut $Ctx '}'
        }
        'text' {
            $fmt = Get-TdOpt 'ls' 'list_format' '%I %x %{(}p{)} %s %k %{(}h{)}'
            if ($o.Options.ContainsKey('-F')) { $fmt = $o.Options['-F'] }
            $group = Get-TdOpt 'sort' 'group_string' ''
            if ($o.Options.ContainsKey('-g')) { $group = $o.Options['-g'] }
            $w = Get-TdIdWidth $list.Items
            $groups = Group-TdTodos $items $group
            $first = $true
            foreach ($g in $groups) {
                if ($g.Label) {
                    if (-not $first) { Write-TdOut $Ctx '' }
                    Write-TdOut $Ctx $g.Label
                    Write-TdOut $Ctx ('=' * $g.Label.Length)
                }
                $first = $false
                foreach ($t in $g.Items) { Write-TdOut $Ctx (Format-TdTodo $t $fmt $w) $t }
            }
        }
        default { throw "Unknown output format: $format (use text, json or dot)" }
    }
}

function Invoke-TdCmdLsprj {
    param($Ctx, [string[]]$Argv)
    $set = @{}
    foreach ($t in (Get-TdCtxList $Ctx).Items) { foreach ($p in $t.Projects) { $set[$p] = $true } }
    foreach ($p in (@($set.Keys) | Sort-Object)) { Write-TdOut $Ctx $p }
}

function Invoke-TdCmdLscon {
    param($Ctx, [string[]]$Argv)
    $set = @{}
    foreach ($t in (Get-TdCtxList $Ctx).Items) { foreach ($c in $t.Contexts) { $set[$c] = $true } }
    foreach ($c in (@($set.Keys) | Sort-Object)) { Write-TdOut $Ctx $c }
}

# --- dep ---------------------------------------------------------------------------

function Resolve-TdDepPair {
    <# Returns @(parent, child) for 'A to|after|before|partof B'. #>
    param($Ctx, [string[]]$Words)
    if ($Words.Count -eq 2) { $Words = @($Words[0], 'to', $Words[1]) }
    if ($Words.Count -ne 3) { throw 'Usage: dep add|rm <ID> [to|before|after|partof] <ID>' }
    $a = (Resolve-TdTodoIds $Ctx @($Words[0]))[0]
    $b = (Resolve-TdTodoIds $Ctx @($Words[2]))[0]
    switch ($Words[1].ToLowerInvariant()) {
        { $_ -eq 'to' -or $_ -eq 'after' } { return , @($a, $b) }
        { $_ -eq 'before' -or $_ -eq 'partof' } { return , @($b, $a) }
    }
    throw "Unknown relation: $($Words[1])"
}

function Invoke-TdCmdDep {
    param($Ctx, [string[]]$Argv)
    if ($Argv.Count -eq 0) { throw 'Usage: dep add|rm|ls|clean ...' }
    $list = Get-TdCtxList $Ctx
    $sub = $Argv[0].ToLowerInvariant()
    $rest = Get-TdArgRest $Argv 1
    switch ($sub) {
        'add' {
            $pair = Resolve-TdDepPair $Ctx $rest
            Add-TdDependency $list $pair[0] $pair[1]
            Write-TdTodoLine $Ctx $pair[0]
            Write-TdTodoLine $Ctx $pair[1]
        }
        { $_ -eq 'rm' -or $_ -eq 'del' } {
            $pair = Resolve-TdDepPair $Ctx $rest
            if (-not (Remove-TdDependency $list $pair[0] $pair[1])) { Write-TdErr $Ctx 'No such dependency.' }
            else { Write-TdTodoLine $Ctx $pair[0]; Write-TdTodoLine $Ctx $pair[1] }
        }
        'ls' {
            $found = @()
            if ($rest.Count -eq 2 -and $rest[1] -eq 'to') {
                $found = Get-TdChildren $list ((Resolve-TdTodoIds $Ctx @($rest[0]))[0])
            }
            elseif ($rest.Count -eq 2 -and $rest[0] -eq 'to') {
                $found = Get-TdParents $list ((Resolve-TdTodoIds $Ctx @($rest[1]))[0])
            }
            else { throw 'Usage: dep ls <ID> to | dep ls to <ID>' }
            foreach ($t in $found) { Write-TdTodoLine $Ctx $t }
        }
        'clean' {
            if (Clear-TdDanglingDeps $list) { Write-TdOut $Ctx 'Removed dangling dependency tags.' }
            else { Write-TdOut $Ctx 'Nothing to clean.' }
        }
        default { throw "Unknown dep subcommand: $sub" }
    }
}

# --- sort / archive / edit / revert ----------------------------------------------------

function Invoke-TdCmdSort {
    param($Ctx, [string[]]$Argv)
    $list = Get-TdCtxList $Ctx
    $expr = Get-TdOpt 'sort' 'sort_string' ''
    if ($Argv.Count -gt 0) { $expr = $Argv[0] }
    $sorted = Sort-TdTodos -List $list -Items $list.Items -Expression $expr
    $list.Items.Clear()
    foreach ($t in $sorted) { $list.Items.Add($t) }
    $list.Dirty = $true
    Update-TdListIds $list
    Write-TdOut $Ctx "Sorted $($list.Items.Count) todos by '$expr'."
}

function Invoke-TdCmdArchive {
    param($Ctx, [string[]]$Argv)
    $n = Invoke-TdArchive $Ctx
    Write-TdOut $Ctx "Archived $n completed todo(s) to $($Ctx.DonePath)."
}

function Invoke-TdCmdEdit {
    param($Ctx, [string[]]$Argv)
    $o = Split-TdOptions $Argv @('-d', '-e')
    if ($o.Options.ContainsKey('-d')) { Invoke-TdEditor $Ctx.DonePath; $Ctx.List = $null; return }
    if ($o.Rest.Count -eq 0 -and -not $o.Options.ContainsKey('-e')) {
        $list = Get-TdCtxList $Ctx
        if (-not (Test-Path -LiteralPath $Ctx.TodoPath)) { Save-TdList $list }
        Invoke-TdEditor $Ctx.TodoPath
        $Ctx.List = $null
        return
    }
    $list = Get-TdCtxList $Ctx
    $todos = Get-TdTargets $Ctx $o
    if ($todos.Count -eq 0) { Write-TdOut $Ctx 'No todos matched.'; return }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('topsdo-' + [Guid]::NewGuid().ToString('N').Substring(0, 8) + '.txt')
    $original = [string]::Join("`n", @($todos | ForEach-Object { Get-TdTodoSource $_ })) + "`n"
    Write-TdTextFile $tmp $original
    try {
        Invoke-TdEditor $tmp
        $edited = Read-TdTextFile $tmp
    }
    finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
    if ($edited.Trim() -eq $original.Trim()) { Write-TdOut $Ctx 'Editing aborted: no changes.'; return }
    $pos = $list.Items.IndexOf($todos[0])
    foreach ($t in $todos) { [void]$list.Items.Remove($t) }
    if ($pos -gt $list.Items.Count) { $pos = $list.Items.Count }
    $newTodos = New-Object System.Collections.Generic.List[object]
    foreach ($l in ($edited -split "`r?`n")) {
        if (-not $l.Trim()) { continue }
        $t = New-TdTodo $l
        Convert-TdTodoDates $t
        $newTodos.Add($t)
    }
    $list.Items.InsertRange($pos, $newTodos)
    $list.Dirty = $true
    Update-TdListIds $list
    foreach ($t in $newTodos) { Write-TdTodoLine $Ctx $t }
}

function Invoke-TdCmdRevert {
    param($Ctx, [string[]]$Argv)
    $entries = Read-TdBackups $Ctx
    if ($Argv.Count -gt 0 -and ($Argv[0] -eq 'ls' -or $Argv[0] -eq '-l')) {
        if ($entries.Count -eq 0) { Write-TdOut $Ctx 'No backups available.'; return }
        $n = 0
        for ($i = $entries.Count - 1; $i -ge 0; $i--) {
            $n++
            Write-TdOut $Ctx ('{0}. {1}: {2}' -f $n, $entries[$i].Time, $entries[$i].Command)
        }
        return
    }
    if ($entries.Count -eq 0) { throw 'No backup available to revert to.' }
    $last = $entries[$entries.Count - 1]
    Write-TdTextFile $Ctx.TodoPath "$($last.Todo)"
    if ("$($last.Done)" -ne '' -or (Test-Path -LiteralPath $Ctx.DonePath)) { Write-TdTextFile $Ctx.DonePath "$($last.Done)" }
    $entries.RemoveAt($entries.Count - 1)
    Write-TdBackups $Ctx $entries
    $Ctx.List = $null
    Write-TdOut $Ctx "Reverted: $($last.Command)"
}

# --- help / misc ---------------------------------------------------------------------

function Invoke-TdCmdHelp {
    param($Ctx, [string[]]$Argv)
    if ($Argv.Count -gt 0) {
        $name = Get-TdCommandName $Argv[0]
        if (-not $script:TdCommands.Contains($name)) { throw "Unknown command: $($Argv[0])" }
        $c = $script:TdCommands[$name]
        Write-TdOut $Ctx "Usage: $($c.Usage)"
        Write-TdOut $Ctx ''
        foreach ($l in ($c.Help -split "`n")) { Write-TdOut $Ctx $l.TrimEnd() }
        $al = @($script:TdCommandAliases.Keys | Where-Object { $script:TdCommandAliases[$_] -eq $name } | Sort-Object)
        if ($al.Count) { Write-TdOut $Ctx ''; Write-TdOut $Ctx ('Aliases: ' + [string]::Join(', ', $al)) }
        return
    }
    Write-TdOut $Ctx 'topsdo - a todo.txt manager for PowerShell (inspired by topydo)'
    Write-TdOut $Ctx ''
    Write-TdOut $Ctx 'Usage: t [-c CONFIG] [-t TODO.TXT] [-d DONE.TXT] [-C 0|1] [-v] <command> [args]'
    Write-TdOut $Ctx ''
    Write-TdOut $Ctx 'Commands:'
    foreach ($k in $script:TdCommands.Keys) {
        Write-TdOut $Ctx ('  {0,-9} {1}' -f $k, $script:TdCommands[$k].Summary)
    }
    Write-TdOut $Ctx ''
    Write-TdOut $Ctx "Run 'help <command>' for details. In PowerShell, quote arguments containing"
    Write-TdOut $Ctx "@, (, ), < or > - e.g. t add '(A) Call Bob @phone due:fri'."
}

function Invoke-TdCmdVersion {
    param($Ctx, [string[]]$Argv)
    Write-TdOut $Ctx "topsdo $script:TdVersion (PowerShell $($PSVersionTable.PSVersion))"
}

function Invoke-TdCmdPrompt {
    param($Ctx, [string[]]$Argv)
    if ($Ctx.Mode -ne 'cli') { throw 'Already running interactively.' }
    Start-TdPrompt $Ctx
}

function Invoke-TdCmdColumns {
    param($Ctx, [string[]]$Argv)
    if ($Ctx.Mode -eq 'columns') { throw 'Already in column mode.' }
    $o = Split-TdOptions $Argv @('-l=')
    Start-TdColumns -Ctx $Ctx -ColumnFile $o.Options['-l']
}

# --- registry --------------------------------------------------------------------

$script:TdCommands = [ordered]@{
    add      = @{ Fn = 'Invoke-TdCmdAdd'; Mutating = $true; Summary = 'Add a todo item'
        Usage = 'add <TEXT> | add -f <FILE|->'
        Help = @'
Adds a todo. Relative dates in due: and t: are converted (today, tomorrow,
mon..sun, 3d, 2w, 1m, 1y, 5b). A creation date is added automatically.
Dependency shortcuts:
  before:ID     the new todo must be done before ID (ID depends on it)
  after:ID      the new todo depends on ID
  partof:ID     the new todo is a subtask of ID
  children-of:ID / parents-of:ID
-f FILE adds every line of FILE ('-' reads standard input).
'@
    }
    append   = @{ Fn = 'Invoke-TdCmdAppend'; Mutating = $true; Summary = 'Append text to a todo'; Usage = 'append <ID> <TEXT>'; Help = 'Appends text (e.g. tags) to the todo with the given ID.' }
    archive  = @{ Fn = 'Invoke-TdCmdArchive'; Mutating = $true; Summary = 'Move completed todos to the archive'; Usage = 'archive'; Help = 'Moves completed todos to the archive file (done.txt).' }
    columns  = @{ Fn = 'Invoke-TdCmdColumns'; Mutating = $false; Summary = 'Start the interactive column mode'
        Usage = 'columns [-l COLUMN_FILE]'
        Help = @'
Starts a full-screen view with one column per saved filter. Press ? inside
column mode for the key bindings. Columns are stored in column_file
(default ~/.topsdo_columns), a file with one INI section per column:
  [today]
  title = Due today
  filterexpr = due:<=today
  sortexpr = desc:importance,due
  groupexpr = project
  show_all = 0
'@
    }
    del      = @{ Fn = 'Invoke-TdCmdDel'; Mutating = $true; Summary = 'Delete todo items'
        Usage = 'del [-f] <ID>... | del -e <EXPRESSION>'
        Help = "Deletes todos. -e deletes all todos matching a filter expression.`n-f does not ask whether subtasks should be removed as well."
    }
    dep      = @{ Fn = 'Invoke-TdCmdDep'; Mutating = $true; Summary = 'Manage dependencies'
        Usage = 'dep add|rm <ID> [to|before|after|partof] <ID> | dep ls <ID> to | dep ls to <ID> | dep clean'
        Help = @'
add    'dep add 1 to 2' / 'dep add 1 after 2': todo 1 depends on todo 2.
       'dep add 1 before 2' / 'dep add 1 partof 2': todo 2 depends on todo 1.
rm     removes such a dependency.
ls     'dep ls 1 to': todos that 1 depends on; 'dep ls to 1': todos depending on 1.
clean  removes dangling id:/p: tags.
Todos with unfinished subtasks are hidden in 'ls' unless -x is given.
'@
    }
    depri    = @{ Fn = 'Invoke-TdCmdDepri'; Mutating = $true; Summary = 'Remove priority'; Usage = 'depri <ID>...'; Help = 'Removes the priority of the given todos.' }
    do       = @{ Fn = 'Invoke-TdCmdDo'; Mutating = $true; Archive = $true; Summary = 'Mark todos as done'
        Usage = 'do [-d DATE] [-s] [-f] <ID>... | do -e <EXPRESSION>'
        Help = @'
Marks todos as completed. Recurring todos (rec:1w, rec:+1m) create a new
instance. -d sets the completion date (relative dates allowed), -s makes
the recurrence strict (based on the old due date instead of today), -f does
not ask about unfinished subtasks. -e completes all todos matching the
expression. Completed todos are archived when archive = 1.
'@
    }
    edit     = @{ Fn = 'Invoke-TdCmdEdit'; Mutating = $true; Summary = 'Edit todos in a text editor'
        Usage = 'edit [<ID>...] | edit -e <EXPRESSION> | edit -d'
        Help = "Without IDs the whole todo file is opened, -d opens the archive.`nThe editor is taken from TOPSDO_EDITOR, VISUAL or EDITOR (fallback: notepad / nano / vi)."
    }
    help     = @{ Fn = 'Invoke-TdCmdHelp'; Mutating = $false; Summary = 'Show help'; Usage = 'help [COMMAND]'; Help = 'Shows the list of commands or help for one command.' }
    ls       = @{ Fn = 'Invoke-TdCmdLs'; Mutating = $false; Summary = 'List todos'
        Usage = 'ls [-x] [-n N] [-N] [-s SORT] [-g GROUP] [-f text|json|dot] [-F FORMAT] [-i IDS] [EXPRESSION]'
        Help = @'
Lists todos, hiding completed ones, those with a start date in the future,
blocked ones (unfinished subtasks) and hidden ones (h:1). -x shows all.
Expression words (all must match):
  word  -word  /regex/  +project  @context  (A)  (<B)  (>=C)
  tag:value  due:<today  due:<=1w  t:>tomorrow
  due:*  (has a due date)   due:!  (no due date)
Options (may also follow the expression; '--' ends options):
  -n N       show at most N items        -N  fit to terminal height
  -s SORT    e.g. desc:importance,due    fields: importance, importance-avg,
             priority, due, start, creation, completed, text, length,
             project, context, line or any tag name
  -g GROUP   group by project, context, priority, due, start or a tag
  -f FORMAT  text (default), json or dot (Graphviz dependencies)
  -F FORMAT  line format: %i id, %I padded id, %p priority, %P (A),
             %s text, %k tags, %K all tags, %x completion, %X relative,
             %c/%C creation, %d/%D due, %t/%T start, %h/%H relative
             summary, %r raw line, %z star. %{pre}X{post} adds text only
             when the value is not empty.
  -i IDS     only the given ids (comma separated)
'@
    }
    lscon    = @{ Fn = 'Invoke-TdCmdLscon'; Mutating = $false; Summary = 'List contexts'; Usage = 'lscon'; Help = 'Lists all contexts in the todo file.' }
    lsprj    = @{ Fn = 'Invoke-TdCmdLsprj'; Mutating = $false; Summary = 'List projects'; Usage = 'lsprj'; Help = 'Lists all projects in the todo file.' }
    postpone = @{ Fn = 'Invoke-TdCmdPostpone'; Mutating = $true; Summary = 'Postpone the due date'
        Usage = 'postpone [-s] <ID>... <PATTERN>'
        Help = "Moves the due date by PATTERN (e.g. 1d, 2w, 1m, 3b). Without a due date, it is`nset relative to today. -s moves the start date along."
    }
    pri      = @{ Fn = 'Invoke-TdCmdPri'; Mutating = $true; Summary = 'Set priority'; Usage = 'pri <ID>... <PRIORITY>'; Help = 'Sets the priority (A-Z) of the given todos.' }
    prompt   = @{ Fn = 'Invoke-TdCmdPrompt'; Mutating = $false; Summary = 'Start the interactive prompt mode'
        Usage = 'prompt'
        Help = "Interactive shell: enter commands without the 't' prefix and without`nPowerShell quoting. Tab completes commands, projects, contexts and dates;`nUp/Down browse history. 'exit', 'quit' or Ctrl+D leave."
    }
    revert   = @{ Fn = 'Invoke-TdCmdRevert'; Mutating = $false; Summary = 'Undo the last change'; Usage = 'revert [ls]'; Help = "Restores the state before the last modifying command.`n'revert ls' lists the available backups (backup_count)." }
    sort     = @{ Fn = 'Invoke-TdCmdSort'; Mutating = $true; Summary = 'Sort the todo file'; Usage = 'sort [EXPRESSION]'; Help = 'Sorts the todo file permanently (default: sort_string).' }
    tag      = @{ Fn = 'Invoke-TdCmdTag'; Mutating = $true; Summary = 'Set or remove a tag'
        Usage = 'tag [-a] <ID> <NAME> [VALUE]'
        Help = "Sets tag NAME to VALUE (relative dates for due/start). Without VALUE the tag is`nremoved. -a adds another NAME:VALUE even if the tag exists."
    }
    version  = @{ Fn = 'Invoke-TdCmdVersion'; Mutating = $false; Summary = 'Show the version'; Usage = 'version'; Help = 'Shows the version.' }
}

$script:TdCommandAliases = @{
    app  = 'append'
    rm   = 'del'
    x    = 'do'
    done = 'do'
    list = 'ls'
    p    = 'pri'
    dp   = 'depri'
    '?'  = 'help'
}
