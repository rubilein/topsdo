# Column mode: a full-screen, keyboard driven view with one column per filter.
# Rendering only uses System.Console (colors, cursor positioning), which works
# in Windows PowerShell 5.1 (conhost / Windows Terminal) and PowerShell 7.

$script:TdActionHelp = [ordered]@{
    up             = 'Move up'
    down           = 'Move down'
    home           = 'First item'
    end            = 'Last item'
    page_up        = 'Page up'
    page_down      = 'Page down'
    half_page_up   = 'Half page up'
    half_page_down = 'Half page down'
    prev_column    = 'Previous column'
    next_column    = 'Next column'
    first_column   = 'First column'
    last_column    = 'Last column'
    mark           = 'Mark / unmark item'
    mark_all       = 'Mark all items in column'
    reset          = 'Clear marks, search and pending keys'
    postpone       = 'Postpone (then e.g. 3d, 1w, 2m)'
    postpone_s     = 'Postpone incl. start date'
    pri            = 'Set priority (then A-Z, - removes)'
    add            = 'Add a todo'
    append         = 'Append text to item'
    tag            = 'Set a tag on item'
    command_line   = 'Enter any topsdo command ({} = selection)'
    search         = 'Search in column'
    repeat         = 'Repeat last command on selection'
    details        = 'Show item details'
    new_column     = 'New column'
    edit_column    = 'Edit column'
    copy_column    = 'Copy column'
    delete_column  = 'Delete column'
    swap_left      = 'Move column left'
    swap_right     = 'Move column right'
    reload         = 'Reload todo file'
    help           = 'This help'
    quit           = 'Quit column mode'
}

# --- column definitions ---------------------------------------------------------------

function New-TdColumn {
    param([string]$Title = 'All tasks', [string]$Filter = '', [string]$Sort = '', [string]$Group = '', [bool]$ShowAll = $false)
    return @{
        Title = $Title; Filter = $Filter; Sort = $Sort; Group = $Group; ShowAll = $ShowAll
        Rows = (New-Object System.Collections.Generic.List[object]); Sel = 0; Top = 0; Search = ''; Count = 0
    }
}

function Import-TdColumns {
    param([string]$Path)
    $cols = New-Object System.Collections.Generic.List[object]
    if ($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $ini = Read-TdIniFile -Path $Path -CaseSensitiveSections @()
        foreach ($sec in $ini.Keys) {
            $s = $ini[$sec]
            $title = $sec
            if ($s.Contains('title')) { $title = $s['title'] }
            $showAll = $false
            if ($s.Contains('show_all')) { $showAll = @('1', 'yes', 'true', 'on') -contains $s['show_all'].ToLowerInvariant() }
            $cols.Add((New-TdColumn -Title $title -Filter "$($s['filterexpr'])" -Sort "$($s['sortexpr'])" -Group "$($s['groupexpr'])" -ShowAll $showAll))
        }
    }
    if ($cols.Count -eq 0) { $cols.Add((New-TdColumn)) }
    return , $cols
}

function Export-TdColumns {
    param($Ui)
    $sb = New-Object System.Text.StringBuilder
    $used = @{}
    foreach ($c in $Ui.Columns) {
        $name = ($c.Title.ToLowerInvariant() -replace '[^a-z0-9]+', '_').Trim('_')
        if (-not $name) { $name = 'column' }
        $n = $name; $i = 2
        while ($used.ContainsKey($n)) { $n = "${name}_$i"; $i++ }
        $used[$n] = $true
        [void]$sb.AppendLine("[$n]")
        [void]$sb.AppendLine("title = $($c.Title)")
        [void]$sb.AppendLine("filterexpr = $($c.Filter)")
        [void]$sb.AppendLine("sortexpr = $($c.Sort)")
        [void]$sb.AppendLine("groupexpr = $($c.Group)")
        [void]$sb.AppendLine("show_all = $([int]$c.ShowAll)")
        [void]$sb.AppendLine()
    }
    Write-TdTextFile -Path $Ui.ColumnFile -Content $sb.ToString()
}

# --- data -------------------------------------------------------------------------

function Get-TdTodoKey { param($Todo) return Get-TdTodoSource $Todo }

function Update-TdColumnsData {
    param($Ui)
    $ctx = $Ui.Ctx
    $list = Get-TdCtxList $ctx
    $index = New-TdDepIndex $list
    $w = Get-TdIdWidth $list.Items
    $fmt = Get-TdOpt 'columns' 'column_format' '%I %x %{(}p{)} %s %k %{(}h{)}'
    $globalSort = Get-TdOpt 'sort' 'sort_string' ''
    $segCache = @{}
    foreach ($col in $Ui.Columns) {
        $selKey = $null
        if ($col.Sel -lt $col.Rows.Count -and $null -ne $col.Rows[$col.Sel].Todo) { $selKey = Get-TdTodoKey $col.Rows[$col.Sel].Todo }
        $words = @(Split-TdCommandLine $col.Filter) + @(Split-TdCommandLine $col.Search)
        $filters = $null
        try { $filters = ConvertTo-TdFilter $words } catch { $filters = @() }
        $items = Select-TdTodos -List $list -Items $list.Items -Filters $filters -ShowAll:$col.ShowAll -Index $index
        $sort = $globalSort
        if ($col.Sort) { $sort = $col.Sort }
        $items = Sort-TdTodos -List $list -Items $items -Expression $sort -Index $index
        $rows = New-Object System.Collections.Generic.List[object]
        foreach ($g in (Group-TdTodos $items $col.Group)) {
            if ($g.Label) { $rows.Add(@{ Todo = $null; Header = $g.Label }) }
            foreach ($t in $g.Items) {
                if (-not $segCache.ContainsKey($t.Number)) {
                    $segCache[$t.Number] = Get-TdSegments (Format-TdTodo $t $fmt $w) $t
                }
                $rows.Add(@{ Todo = $t; Header = $null; Segs = $segCache[$t.Number] })
            }
        }
        $col.Rows = $rows
        $col.Count = @($items).Count
        $newSel = -1
        if ($null -ne $selKey) {
            for ($i = 0; $i -lt $rows.Count; $i++) {
                if ($null -ne $rows[$i].Todo -and (Get-TdTodoKey $rows[$i].Todo) -eq $selKey) { $newSel = $i; break }
            }
        }
        if ($newSel -lt 0) { $newSel = [Math]::Min($col.Sel, [Math]::Max(0, $rows.Count - 1)) }
        $col.Sel = $newSel
        Move-TdColumnSelection $col 0
    }
    # drop marks of items that no longer exist
    $keys = @{}
    foreach ($t in $list.Items) { $keys[(Get-TdTodoKey $t)] = $true }
    foreach ($m in @($Ui.Marks)) { if (-not $keys.ContainsKey($m)) { [void]$Ui.Marks.Remove($m) } }
}

function Move-TdColumnSelection {
    <# Moves the selection by Delta rows, skipping group headers. #>
    param($Col, [int]$Delta)
    $n = $Col.Rows.Count
    if ($n -eq 0) { $Col.Sel = 0; return }
    $s = $Col.Sel + $Delta
    if ($s -lt 0) { $s = 0 }
    if ($s -ge $n) { $s = $n - 1 }
    $dir = 1
    if ($Delta -lt 0) { $dir = -1 }
    $probe = $s
    while ($probe -ge 0 -and $probe -lt $n -and $null -eq $Col.Rows[$probe].Todo) { $probe += $dir }
    if ($probe -lt 0 -or $probe -ge $n) {
        $probe = $s
        while ($probe -ge 0 -and $probe -lt $n -and $null -eq $Col.Rows[$probe].Todo) { $probe -= $dir }
    }
    if ($probe -ge 0 -and $probe -lt $n) { $Col.Sel = $probe } else { $Col.Sel = $s }
}

function Get-TdSelectedTodo {
    param($Ui)
    $col = $Ui.Columns[$Ui.Focus]
    if ($col.Sel -lt $col.Rows.Count) { return $col.Rows[$col.Sel].Todo }
    return $null
}

function Get-TdColumnsTargets {
    <# Marked todos, or the selected one. #>
    param($Ui)
    $res = New-Object System.Collections.Generic.List[object]
    if ($Ui.Marks.Count -gt 0) {
        foreach ($t in (Get-TdCtxList $Ui.Ctx).Items) { if ($Ui.Marks.Contains((Get-TdTodoKey $t))) { $res.Add($t) } }
    }
    else {
        $t = Get-TdSelectedTodo $Ui
        if ($null -ne $t) { $res.Add($t) }
    }
    return , $res.ToArray()
}

# --- screen -----------------------------------------------------------------------

function Test-TdVirtualTerminal {
    try { return [bool]$Host.UI.SupportsVirtualTerminal } catch { return $false }
}

function Enter-TdScreen {
    param($Ui)
    $Ui.Alt = Test-TdVirtualTerminal
    if ($Ui.Alt) { [Console]::Write([char]27 + '[?1049h') }
    try { [Console]::CursorVisible = $false } catch { }
    [Console]::TreatControlCAsInput = $true
    [Console]::ResetColor()
    [Console]::Clear()
    $Ui.Prev = @{}
}

function Exit-TdScreen {
    param($Ui)
    [Console]::ResetColor()
    [Console]::Clear()
    if ($Ui.Alt) { [Console]::Write([char]27 + '[?1049l') }
    try { [Console]::CursorVisible = $true } catch { }
    [Console]::TreatControlCAsInput = $Ui.OldCtrlC
}

function Format-TdCell {
    <# Fits colored segments into exactly Width characters. #>
    param($Segs, [int]$Width, $Bg = $null)
    $out = New-Object System.Collections.Generic.List[object]
    $used = 0
    foreach ($s in $Segs) {
        if ($used -ge $Width) { break }
        $t = $s.T -replace "[`t`r`n]", ' '
        if ($t.Length -gt $Width - $used) { $t = $t.Substring(0, $Width - $used) }
        if ($t.Length -eq 0) { continue }
        $b = $Bg
        if ($null -ne $s.B) { $b = $s.B }
        $out.Add(@{ T = $t; F = $s.F; B = $b })
        $used += $t.Length
    }
    if ($used -lt $Width) { $out.Add(@{ T = (' ' * ($Width - $used)); F = $null; B = $Bg }) }
    return , $out.ToArray()
}

function Get-TdWindowTop {
    # conhost uses buffer coordinates; the visible window may start below row 0
    try { return [Console]::WindowTop } catch { return 0 }
}

function Write-TdScreenRow {
    param([int]$Y, $Segs)
    try { [Console]::SetCursorPosition(0, $Y + (Get-TdWindowTop)) } catch { return }
    foreach ($s in $Segs) {
        [Console]::ResetColor()
        if ($null -ne $s.F) { [Console]::ForegroundColor = $s.F }
        if ($null -ne $s.B) { [Console]::BackgroundColor = $s.B }
        [Console]::Write($s.T)
    }
    [Console]::ResetColor()
}

function Get-TdRowSignature {
    param($Segs)
    $sb = New-Object System.Text.StringBuilder
    foreach ($s in $Segs) { [void]$sb.Append($s.T).Append([char]1).Append("$($s.F)").Append([char]2).Append("$($s.B)").Append([char]3) }
    return $sb.ToString()
}

function Get-TdStatusSegs {
    param($Ui, [int]$Width)
    $left = ''
    $leftColor = $null
    if ($Ui.Mode -eq 'postpone' -or $Ui.Mode -eq 'postpone_s') { $left = "Postpone by (e.g. 3d, 2w, 1m; Esc cancels): $($Ui.ModeBuf)" }
    elseif ($Ui.Mode -eq 'pri') { $left = 'Priority (A-Z, - removes, Esc cancels): ' }
    elseif ($Ui.Pending) { $left = $Ui.Pending }
    elseif ($Ui.Status) { $left = $Ui.Status; $leftColor = $Ui.StatusColor }
    $col = $Ui.Columns[$Ui.Focus]
    $right = ' [{0}/{1}] ' -f ($Ui.Focus + 1), $Ui.Columns.Count
    if ($col.Search) { $right = " /$($col.Search)" + $right }
    if ($Ui.Marks.Count -gt 0) { $right = " $($Ui.Marks.Count) marked" + $right }
    $right += '?:help q:quit '
    $space = $Width - $right.Length
    if ($space -lt 0) { $space = 0; $right = $right.Substring(0, [Math]::Min($right.Length, $Width)) }
    if ($left.Length -gt $space) { $left = $left.Substring(0, $space) }
    $segs = @(
        @{ T = $left.PadRight($space); F = $leftColor; B = $null },
        @{ T = $right; F = [ConsoleColor]::DarkGray; B = $null }
    )
    return , $segs
}

function Show-TdColumns {
    param($Ui)
    $W = [Console]::WindowWidth
    $H = [Console]::WindowHeight
    if ($W -ne $Ui.W -or $H -ne $Ui.H) {
        $Ui.W = $W; $Ui.H = $H; $Ui.Prev = @{}
        [Console]::ResetColor(); [Console]::Clear()
    }
    if ($W -lt 10 -or $H -lt 4) { return }
    $bodyH = $H - 2
    $n = $Ui.Columns.Count
    $cfgW = Get-TdOptInt 'columns' 'column_width' 40
    if ($cfgW -lt 10) { $cfgW = 10 }
    $maxVis = [Math]::Max(1, [int][Math]::Floor(($W + 1) / ($cfgW + 1)))
    $vis = [Math]::Min($n, $maxVis)
    $cw = [int][Math]::Floor(($W - ($vis - 1)) / $vis)
    if ($Ui.Focus -lt $Ui.First) { $Ui.First = $Ui.Focus }
    if ($Ui.Focus -ge $Ui.First + $vis) { $Ui.First = $Ui.Focus - $vis + 1 }
    if ($Ui.First + $vis -gt $n) { $Ui.First = [Math]::Max(0, $n - $vis) }

    $focusBg = ConvertTo-TdColor (Get-TdOpt 'columns' 'focus_background' 'DarkCyan')
    $cursorBg = ConvertTo-TdColor (Get-TdOpt 'columns' 'cursor_background' 'DarkGray')
    $markBg = ConvertTo-TdColor (Get-TdOpt 'columns' 'mark_background' 'DarkMagenta')
    $sep = @{ T = '|'; F = [ConsoleColor]::DarkGray; B = $null }

    $rows = New-Object 'System.Collections.Generic.List[object]'
    for ($y = 0; $y -lt $H - 1; $y++) { $rows.Add((New-Object System.Collections.Generic.List[object])) }

    for ($ci = $Ui.First; $ci -lt $Ui.First + $vis; $ci++) {
        $col = $Ui.Columns[$ci]
        $focused = ($ci -eq $Ui.Focus)
        if ($ci -gt $Ui.First) { foreach ($r in $rows) { $r.Add($sep) } }
        # header
        $title = " $($col.Title) ($($col.Count))"
        $hb = [ConsoleColor]::DarkGray
        if ($focused) { $hb = $focusBg }
        $rows[0].AddRange([object[]](Format-TdCell @(@{ T = $title; F = [ConsoleColor]::White; B = $null }) $cw $hb))
        # keep selection visible
        if ($col.Sel -lt $col.Top) { $col.Top = $col.Sel }
        if ($col.Sel -ge $col.Top + $bodyH) { $col.Top = $col.Sel - $bodyH + 1 }
        if ($col.Top -gt [Math]::Max(0, $col.Rows.Count - $bodyH)) { $col.Top = [Math]::Max(0, $col.Rows.Count - $bodyH) }
        if ($col.Top -lt 0) { $col.Top = 0 }
        for ($r = 0; $r -lt $bodyH; $r++) {
            $idx = $col.Top + $r
            $cell = $null
            if ($idx -lt $col.Rows.Count) {
                $row = $col.Rows[$idx]
                if ($null -eq $row.Todo) {
                    $cell = Format-TdCell @(@{ T = $row.Header; F = [ConsoleColor]::Yellow; B = $null }) $cw $null
                }
                else {
                    $bg = $null
                    $marked = $Ui.Marks.Contains((Get-TdTodoKey $row.Todo))
                    if ($marked) { $bg = $markBg }
                    if ($focused -and $idx -eq $col.Sel) { $bg = $cursorBg }
                    $prefix = ' '
                    if ($marked) { $prefix = '*' }
                    $segs = @(@{ T = $prefix; F = [ConsoleColor]::Yellow; B = $null }) + @($row.Segs)
                    $cell = Format-TdCell $segs $cw $bg
                }
            }
            else { $cell = Format-TdCell @() $cw $null }
            $rows[$r + 1].AddRange([object[]]$cell)
        }
    }
    $total = $vis * $cw + ($vis - 1)
    if ($total -lt $W) { foreach ($r in $rows) { $r.Add(@{ T = (' ' * ($W - $total)); F = $null; B = $null }) } }

    # overlay (details, help, command output)
    if ($null -ne $Ui.Overlay) {
        $lines = $Ui.Overlay
        $avail = $H - 3
        $count = [Math]::Min($lines.Count, [Math]::Max(1, $avail - 2))
        if ($Ui.OverlayTop -gt $lines.Count - $count) { $Ui.OverlayTop = [Math]::Max(0, $lines.Count - $count) }
        $boxTop = $H - 1 - ($count + 2)
        if ($boxTop -lt 1) { $boxTop = 1 }
        $inner = $W - 4
        $bb = [ConsoleColor]::DarkBlue
        $title = "-[ $($Ui.OverlayTitle) ]"
        $rows[$boxTop] = [System.Collections.Generic.List[object]](Format-TdCell @(@{ T = '+' + $title + ('-' * [Math]::Max(0, $W - 2 - $title.Length)) + '+'; F = [ConsoleColor]::Gray; B = $null }) $W $bb)
        for ($i = 0; $i -lt $count; $i++) {
            $segs = $lines[$Ui.OverlayTop + $i]
            $row = New-Object System.Collections.Generic.List[object]
            $row.Add(@{ T = '| '; F = [ConsoleColor]::Gray; B = $bb })
            $row.AddRange([object[]](Format-TdCell $segs $inner $bb))
            $row.Add(@{ T = ' |'; F = [ConsoleColor]::Gray; B = $bb })
            $rows[$boxTop + 1 + $i] = $row
        }
        $more = ''
        if ($lines.Count -gt $count) { $more = " {0}-{1}/{2} j/k scroll " -f ($Ui.OverlayTop + 1), ($Ui.OverlayTop + $count), $lines.Count }
        $foot = "-[ any key closes ]$more"
        $rows[$boxTop + 1 + $count] = [System.Collections.Generic.List[object]](Format-TdCell @(@{ T = '+' + $foot + ('-' * [Math]::Max(0, $W - 2 - $foot.Length)) + '+'; F = [ConsoleColor]::Gray; B = $null }) $W $bb)
    }

    for ($y = 0; $y -lt $H - 1; $y++) {
        $sig = Get-TdRowSignature $rows[$y]
        if ($Ui.Prev[$y] -ne $sig) { Write-TdScreenRow $y $rows[$y]; $Ui.Prev[$y] = $sig }
    }
    # status line: never write the bottom-right cell (it would scroll the console)
    $status = Get-TdStatusSegs $Ui ($W - 1)
    $sig = Get-TdRowSignature $status
    if ($Ui.Prev[$H - 1] -ne $sig) { Write-TdScreenRow ($H - 1) $status; $Ui.Prev[$H - 1] = $sig }
}

function Show-TdOverlay {
    param($Ui, [string]$Title, $Lines)
    $wrapped = New-Object System.Collections.Generic.List[object]
    $inner = [Math]::Max(10, [Console]::WindowWidth - 4)
    foreach ($l in $Lines) {
        if ($l -is [string]) { $segs = @(@{ T = $l; F = $null; B = $null }) } else { $segs = $l }
        $text = [string]::Join('', @($segs | ForEach-Object { $_.T }))
        if ($text.Length -le $inner) { $wrapped.Add($segs); continue }
        $color = $null
        if (@($segs).Count -gt 0) { $color = @($segs)[0].F }
        for ($i = 0; $i -lt $text.Length; $i += $inner) {
            $wrapped.Add(@(@{ T = $text.Substring($i, [Math]::Min($inner, $text.Length - $i)); F = $color; B = $null }))
        }
    }
    $Ui.Overlay = $wrapped
    $Ui.OverlayTitle = $Title
    $Ui.OverlayTop = 0
}

# --- input -------------------------------------------------------------------------

function Get-TdKeyName {
    param([ConsoleKeyInfo]$Key)
    $ctrl = ($Key.Modifiers -band [ConsoleModifiers]::Control) -ne 0
    $shift = ($Key.Modifiers -band [ConsoleModifiers]::Shift) -ne 0
    switch ($Key.Key) {
        'UpArrow' { return '<Up>' }
        'DownArrow' { return '<Down>' }
        'LeftArrow' { return '<Left>' }
        'RightArrow' { return '<Right>' }
        'Enter' { return '<Enter>' }
        'Escape' { return '<Esc>' }
        'Tab' { if ($shift) { return '<S-Tab>' } return '<Tab>' }
        'Backspace' { return '<BS>' }
        'Delete' { return '<Del>' }
        'Home' { return '<Home>' }
        'End' { return '<End>' }
        'PageUp' { return '<PgUp>' }
        'PageDown' { return '<PgDn>' }
        'Spacebar' { if (-not $ctrl) { return '<Space>' } }
    }
    $k = $Key.Key.ToString()
    if ($k -match '^F\d{1,2}$') { return "<$k>" }
    if ($ctrl -and $k -match '^[A-Z]$') { return '<C-' + $k.ToLowerInvariant() + '>' }
    if ([int]$Key.KeyChar -ge 32) { return [string]$Key.KeyChar }
    return ''
}

function Wait-TdKey {
    <# Waits for a key; returns $null when the screen needs a refresh instead. #>
    param($Ui)
    $ticks = 0
    while (-not [Console]::KeyAvailable) {
        Start-Sleep -Milliseconds 40
        $ticks++
        if ([Console]::WindowWidth -ne $Ui.W -or [Console]::WindowHeight -ne $Ui.H) { return $null }
        if ($ticks % 25 -eq 0) {
            $list = $Ui.Ctx.List
            if ($null -eq $list -or $list.Stamp -ne (Get-TdFileStamp $Ui.Ctx.TodoPath)) {
                Update-TdColumnsData $Ui
                return $null
            }
        }
    }
    return [Console]::ReadKey($true)
}

function Read-TdColumnsLine {
    param($Ui, [string]$Prompt, [string]$Initial = '', [switch]$NoHistory)
    $H = [Console]::WindowHeight
    try { [Console]::CursorVisible = $true } catch { }
    $hist = $Ui.History
    if ($NoHistory) { $hist = $null }
    try {
        $line = Read-TdLine -Prompt $Prompt -Initial $Initial -History $hist -Ctx $Ui.Ctx -EscCancels -Row ($H - 1 + (Get-TdWindowTop)) -PromptColor ([ConsoleColor]::Yellow)
    }
    finally {
        try { [Console]::CursorVisible = $false } catch { }
        [Console]::TreatControlCAsInput = $true
        $Ui.Prev.Remove($H - 1)
    }
    return $line
}

function Read-TdColumnsConfirm {
    param($Ctx, [string]$Question)
    $ui = $Ctx.Ui
    $H = [Console]::WindowHeight
    $W = [Console]::WindowWidth
    $q = "$Question [y/N] "
    if ($q.Length -gt $W - 1) { $q = $q.Substring(0, $W - 1) }
    Write-TdAt 0 ($H - 1 + (Get-TdWindowTop)) $q.PadRight($W - 1) ([ConsoleColor]::Yellow)
    $ui.Prev.Remove($H - 1)
    $k = [Console]::ReadKey($true)
    return (@('y', 'Y', 'j', 'J') -contains [string]$k.KeyChar)
}

function Invoke-TdColumnsCommandLine {
    <# Runs a topsdo command line and shows its output. #>
    param($Ui, [string]$Line)
    $tokens = Split-TdCommandLine $Line
    if ($tokens.Count -eq 0) { return }
    $name = Get-TdCommandName $tokens[0]
    if ($name -eq 'quit' -or $name -eq 'exit' -or $name -eq 'q') { $Ui.Quit = $true; return }
    $ctx = $Ui.Ctx
    if ($name -eq 'edit') {
        Exit-TdScreen $Ui
        try { Invoke-TdCommand $ctx $tokens }
        finally { Enter-TdScreen $Ui; $Ui.W = 0 }
    }
    elseif ($name -eq 'columns' -or $name -eq 'prompt') {
        Write-TdErr $ctx "'$name' is not available inside column mode."
    }
    else {
        Invoke-TdCommand $ctx $tokens
    }
    $out = @($ctx.Buffer.ToArray())
    $ctx.Buffer.Clear()
    $ctx.ExitCode = 0
    Update-TdColumnsData $Ui
    if ($out.Count -eq 1) {
        $Ui.Status = $out[0].Text
        $Ui.StatusColor = $null
        if ($out[0].Error) { $Ui.StatusColor = [ConsoleColor]::Red }
    }
    elseif ($out.Count -gt 1) {
        Show-TdOverlay $Ui $Line @($out | ForEach-Object { , $_.Segs })
    }
}

function Invoke-TdColumnsTemplate {
    <# Runs a command template where {} is replaced by the target ids. #>
    param($Ui, [string]$Template, [switch]$NoRemember)
    $line = $Template
    if ($Template.Contains('{}')) {
        $targets = Get-TdColumnsTargets $Ui
        if ($targets.Count -eq 0) { $Ui.Status = 'No item selected.'; $Ui.StatusColor = [ConsoleColor]::Red; return }
        $ids = [string]::Join(' ', @($targets | ForEach-Object { $_.Uid }))
        $line = $Template.Replace('{}', $ids)
    }
    if (-not $NoRemember) { $Ui.LastCmd = $Template }
    $Ui.Marks.Clear()
    Invoke-TdColumnsCommandLine $Ui $line
}

function Edit-TdColumnDefinition {
    param($Ui, $Col)
    $title = Read-TdColumnsLine $Ui 'Title: ' $Col.Title -NoHistory
    if ($null -eq $title) { return $false }
    $filter = Read-TdColumnsLine $Ui 'Filter (e.g. +work due:<=1w): ' $Col.Filter -NoHistory
    if ($null -eq $filter) { return $false }
    $sort = Read-TdColumnsLine $Ui 'Sort (empty = default): ' $Col.Sort -NoHistory
    if ($null -eq $sort) { return $false }
    $group = Read-TdColumnsLine $Ui 'Group (project, context, due, ...): ' $Col.Group -NoHistory
    if ($null -eq $group) { return $false }
    $sa = 'n'
    if ($Col.ShowAll) { $sa = 'y' }
    $showAll = Read-TdColumnsLine $Ui 'Show all incl. hidden/blocked/completed (y/n): ' $sa -NoHistory
    if ($null -eq $showAll) { return $false }
    if (-not $title.Trim()) { $title = 'Untitled' }
    $Col.Title = $title.Trim(); $Col.Filter = $filter.Trim(); $Col.Sort = $sort.Trim(); $Col.Group = $group.Trim()
    $Col.ShowAll = ($showAll.Trim() -match '^(y|yes|j|ja|1|true)$')
    $Col.Search = ''
    return $true
}

function Save-TdColumnsSafe {
    param($Ui)
    try { Export-TdColumns $Ui; return $true }
    catch { $Ui.Status = "Could not save columns: $($_.Exception.Message)"; $Ui.StatusColor = [ConsoleColor]::Red; return $false }
}

function Get-TdDetailLines {
    param($Ui, $Todo)
    $list = Get-TdCtxList $Ui.Ctx
    $w = Get-TdIdWidth $list.Items
    $L = New-Object System.Collections.Generic.List[object]
    $L.Add((Get-TdSegments (Get-TdTodoSource $Todo) $Todo))
    $L.Add('')
    $L.Add("ID:          $($Todo.Uid)   (line $($Todo.Number))")
    if ($Todo.Priority) { $L.Add("Priority:    $($Todo.Priority)") }
    if ($Todo.CreationDate) { $d = ConvertTo-TdDate $Todo.CreationDate; $L.Add("Created:     $($Todo.CreationDate) ($(Get-TdHumanDate $d))") }
    if ($null -ne $Todo.Due) { $L.Add("Due:         $(Format-TdDate $Todo.Due) ($(Get-TdHumanDate $Todo.Due))") }
    if ($null -ne $Todo.Start) { $L.Add("Start:       $(Format-TdDate $Todo.Start) ($(Get-TdHumanDate $Todo.Start))") }
    if ($Todo.Completed) { $L.Add("Completed:   $($Todo.CompletionDate)") }
    if ($Todo.Projects.Count) { $L.Add('Projects:    ' + [string]::Join(' ', @($Todo.Projects | ForEach-Object { "+$_" }))) }
    if ($Todo.Contexts.Count) { $L.Add('Contexts:    ' + [string]::Join(' ', @($Todo.Contexts | ForEach-Object { "@$_" }))) }
    if ($Todo.Tags.Count) { $L.Add('Tags:        ' + [string]::Join(' ', @($Todo.Tags | ForEach-Object { "$($_.Key):$($_.Value)" }))) }
    $L.Add("Importance:  $(Get-TdImportance $Todo)")
    $children = Get-TdChildren $list $Todo
    if ($children.Count) {
        $L.Add(''); $L.Add('Depends on:')
        foreach ($c in $children) { $L.Add((Get-TdSegments ('  ' + (Format-TdTodo $c '%I %x %{(}p{)} %s' $w)) $c)) }
    }
    $parents = Get-TdParents $list $Todo
    if ($parents.Count) {
        $L.Add(''); $L.Add('Required by:')
        foreach ($p in $parents) { $L.Add((Get-TdSegments ('  ' + (Format-TdTodo $p '%I %x %{(}p{)} %s' $w)) $p)) }
    }
    return , $L.ToArray()
}

function Get-TdKeymapHelp {
    param($Ui)
    $byAction = [ordered]@{}
    foreach ($k in $Ui.Keymap.Keys) {
        $a = $Ui.Keymap[$k]
        if (-not $byAction.Contains($a)) { $byAction[$a] = New-Object System.Collections.Generic.List[string] }
        $byAction[$a].Add($k)
    }
    $lines = New-Object System.Collections.Generic.List[object]
    foreach ($a in $script:TdActionHelp.Keys) {
        if ($byAction.Contains($a)) { $lines.Add(('{0,-16} {1}' -f [string]::Join(' ', $byAction[$a].ToArray()), $script:TdActionHelp[$a])) }
    }
    foreach ($a in $byAction.Keys) {
        if (-not $script:TdActionHelp.Contains($a)) { $lines.Add(('{0,-16} {1}' -f [string]::Join(' ', $byAction[$a].ToArray()), $a)) }
    }
    $lines.Add('')
    $lines.Add('Commands (:) run like in prompt mode; {} is replaced by the marked or')
    $lines.Add('selected item ids. Key bindings: [column_keymap] in the config file.')
    return , $lines.ToArray()
}

function Invoke-TdColumnsAction {
    param($Ui, [string]$Action)
    $col = $Ui.Columns[$Ui.Focus]
    $bodyH = [Math]::Max(1, [Console]::WindowHeight - 2)
    if ($Action.StartsWith('cmd ')) { Invoke-TdColumnsTemplate $Ui $Action.Substring(4).Trim(); return }
    switch ($Action) {
        'up' { Move-TdColumnSelection $col -1 }
        'down' { Move-TdColumnSelection $col 1 }
        'home' { $col.Sel = 0; Move-TdColumnSelection $col 0 }
        'end' { $col.Sel = [Math]::Max(0, $col.Rows.Count - 1); Move-TdColumnSelection $col 0 }
        'page_up' { Move-TdColumnSelection $col (-$bodyH) }
        'page_down' { Move-TdColumnSelection $col $bodyH }
        'half_page_up' { Move-TdColumnSelection $col (-[int][Math]::Floor($bodyH / 2)) }
        'half_page_down' { Move-TdColumnSelection $col ([int][Math]::Floor($bodyH / 2)) }
        'prev_column' { if ($Ui.Focus -gt 0) { $Ui.Focus-- } }
        'next_column' { if ($Ui.Focus -lt $Ui.Columns.Count - 1) { $Ui.Focus++ } }
        'first_column' { $Ui.Focus = 0 }
        'last_column' { $Ui.Focus = $Ui.Columns.Count - 1 }
        'mark' {
            $t = Get-TdSelectedTodo $Ui
            if ($null -ne $t) {
                $key = Get-TdTodoKey $t
                if (-not $Ui.Marks.Remove($key)) { [void]$Ui.Marks.Add($key) }
                Move-TdColumnSelection $col 1
            }
        }
        'mark_all' {
            $keys = @($col.Rows | Where-Object { $null -ne $_.Todo } | ForEach-Object { Get-TdTodoKey $_.Todo })
            $all = $true
            foreach ($k in $keys) { if (-not $Ui.Marks.Contains($k)) { $all = $false } }
            foreach ($k in $keys) { if ($all) { [void]$Ui.Marks.Remove($k) } else { [void]$Ui.Marks.Add($k) } }
        }
        'reset' {
            $Ui.Marks.Clear(); $Ui.Status = ''
            if ($col.Search) { $col.Search = ''; Update-TdColumnsData $Ui }
        }
        { $_ -eq 'postpone' -or $_ -eq 'postpone_s' -or $_ -eq 'pri' } {
            if ((Get-TdColumnsTargets $Ui).Count -eq 0) { $Ui.Status = 'No item selected.'; $Ui.StatusColor = [ConsoleColor]::Red }
            else { $Ui.Mode = $Action; $Ui.ModeBuf = '' }
        }
        'add' { $l = Read-TdColumnsLine $Ui ':' 'add '; if ($l) { Invoke-TdColumnsCommandLine $Ui $l } }
        'append' {
            $t = Get-TdSelectedTodo $Ui
            if ($null -ne $t) { $l = Read-TdColumnsLine $Ui ':' "append $($t.Uid) "; if ($l) { Invoke-TdColumnsCommandLine $Ui $l } }
        }
        'tag' {
            $t = Get-TdSelectedTodo $Ui
            if ($null -ne $t) { $l = Read-TdColumnsLine $Ui ':' "tag $($t.Uid) "; if ($l) { Invoke-TdColumnsCommandLine $Ui $l } }
        }
        'command_line' {
            $l = Read-TdColumnsLine $Ui ':'
            if ($l -and $l.Trim()) {
                if ($Ui.History.Count -eq 0 -or $Ui.History[$Ui.History.Count - 1] -ne $l) { $Ui.History.Add($l) }
                if ($l.Contains('{}')) { Invoke-TdColumnsTemplate $Ui $l } else { Invoke-TdColumnsCommandLine $Ui $l }
            }
        }
        'search' {
            $l = Read-TdColumnsLine $Ui '/' $col.Search -NoHistory
            if ($null -ne $l) { $col.Search = $l.Trim(); $col.Sel = 0; Update-TdColumnsData $Ui }
        }
        'repeat' { if ($Ui.LastCmd) { Invoke-TdColumnsTemplate $Ui $Ui.LastCmd } }
        'details' {
            $t = Get-TdSelectedTodo $Ui
            if ($null -ne $t) { Show-TdOverlay $Ui "Item $($t.Uid)" (Get-TdDetailLines $Ui $t) }
        }
        'new_column' {
            $c = New-TdColumn -Title '' -Filter ''
            if (Edit-TdColumnDefinition $Ui $c) {
                $Ui.Columns.Insert($Ui.Focus + 1, $c); $Ui.Focus++
                [void](Save-TdColumnsSafe $Ui); Update-TdColumnsData $Ui
            }
        }
        'edit_column' {
            if (Edit-TdColumnDefinition $Ui $col) { [void](Save-TdColumnsSafe $Ui); Update-TdColumnsData $Ui }
        }
        'copy_column' {
            $c = New-TdColumn -Title "$($col.Title) (copy)" -Filter $col.Filter -Sort $col.Sort -Group $col.Group -ShowAll $col.ShowAll
            $Ui.Columns.Insert($Ui.Focus + 1, $c); $Ui.Focus++
            [void](Save-TdColumnsSafe $Ui); Update-TdColumnsData $Ui
        }
        'delete_column' {
            if ($Ui.Columns.Count -le 1) { $Ui.Status = 'Cannot delete the last column.'; $Ui.StatusColor = [ConsoleColor]::Red }
            elseif (Read-TdColumnsConfirm $Ui.Ctx "Delete column '$($col.Title)'?") {
                $Ui.Columns.RemoveAt($Ui.Focus)
                if ($Ui.Focus -ge $Ui.Columns.Count) { $Ui.Focus = $Ui.Columns.Count - 1 }
                [void](Save-TdColumnsSafe $Ui)
            }
        }
        'swap_left' {
            if ($Ui.Focus -gt 0) {
                $Ui.Columns.RemoveAt($Ui.Focus); $Ui.Columns.Insert($Ui.Focus - 1, $col); $Ui.Focus--
                [void](Save-TdColumnsSafe $Ui)
            }
        }
        'swap_right' {
            if ($Ui.Focus -lt $Ui.Columns.Count - 1) {
                $Ui.Columns.RemoveAt($Ui.Focus); $Ui.Columns.Insert($Ui.Focus + 1, $col); $Ui.Focus++
                [void](Save-TdColumnsSafe $Ui)
            }
        }
        'reload' { $Ui.Ctx.List = $null; Update-TdColumnsData $Ui; $Ui.Prev = @{}; $Ui.Status = 'Reloaded.' }
        'help' { Show-TdOverlay $Ui 'Key bindings' (Get-TdKeymapHelp $Ui) }
        'quit' { $Ui.Quit = $true }
        default { $Ui.Status = "Unknown action: $Action"; $Ui.StatusColor = [ConsoleColor]::Red }
    }
}

function Invoke-TdColumnsModeKey {
    <# Handles keys while waiting for a postpone pattern or a priority. #>
    param($Ui, [ConsoleKeyInfo]$Key, [string]$Name)
    if ($Name -eq '<Esc>' -or ($Name -eq '<C-c>')) { $Ui.Mode = ''; $Ui.ModeBuf = ''; return }
    $ch = [string]$Key.KeyChar
    if ($Ui.Mode -eq 'pri') {
        $Ui.Mode = ''
        if ($ch -match '^[A-Za-z]$') { Invoke-TdColumnsTemplate $Ui ('pri {} ' + $ch.ToUpperInvariant()) }
        elseif ($ch -eq '-' -or $Name -eq '<Del>' -or $Name -eq '<BS>') { Invoke-TdColumnsTemplate $Ui 'depri {}' }
        return
    }
    # postpone
    if ($ch -match '^[0-9]$') { $Ui.ModeBuf += $ch; return }
    if ($Name -eq '<BS>') { if ($Ui.ModeBuf) { $Ui.ModeBuf = $Ui.ModeBuf.Substring(0, $Ui.ModeBuf.Length - 1) }; return }
    if ($ch -match '^[dwmyb]$') {
        $n = $Ui.ModeBuf
        if (-not $n) { $n = '1' }
        $flag = ''
        if ($Ui.Mode -eq 'postpone_s') { $flag = '-s ' }
        $Ui.Mode = ''; $Ui.ModeBuf = ''
        Invoke-TdColumnsTemplate $Ui "postpone $flag{} $n$ch"
    }
}

function Invoke-TdColumnsKey {
    param($Ui, [ConsoleKeyInfo]$Key)
    $name = Get-TdKeyName $Key
    if ($null -ne $Ui.Overlay) {
        $lines = $Ui.Overlay.Count
        switch ($name) {
            { $_ -eq 'j' -or $_ -eq '<Down>' } { $Ui.OverlayTop++; return }
            { $_ -eq 'k' -or $_ -eq '<Up>' } { if ($Ui.OverlayTop -gt 0) { $Ui.OverlayTop-- }; return }
            { $_ -eq '<PgDn>' -or $_ -eq '<Space>' } { $Ui.OverlayTop += 10; return }
            '<PgUp>' { $Ui.OverlayTop = [Math]::Max(0, $Ui.OverlayTop - 10); return }
        }
        $Ui.Overlay = $null
        return
    }
    if ($Ui.Mode) { Invoke-TdColumnsModeKey $Ui $Key $name; return }
    if (-not $name) { return }
    $Ui.Status = ''
    $Ui.StatusColor = $null
    $seq = $Ui.Pending + $name
    if ($Ui.Keymap.ContainsKey($seq)) { $Ui.Pending = ''; Invoke-TdColumnsAction $Ui $Ui.Keymap[$seq]; return }
    foreach ($k in $Ui.Keymap.Keys) {
        if ($k.Length -gt $seq.Length -and $k.StartsWith($seq, [StringComparison]::Ordinal)) { $Ui.Pending = $seq; return }
    }
    $Ui.Pending = ''
    if ($seq -ne $name -and $Ui.Keymap.ContainsKey($name)) { Invoke-TdColumnsAction $Ui $Ui.Keymap[$name] }
}

function Start-TdColumns {
    param($Ctx, [string]$ColumnFile)
    if (-not (Test-TdInteractiveConsole)) { throw 'Column mode requires an interactive console.' }
    if (-not $ColumnFile) { $ColumnFile = Get-TdOpt 'columns' 'column_file' '~/.topsdo_columns' }
    $ColumnFile = Resolve-TdPath $ColumnFile
    $keymap = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    if ($script:TdCfg.Contains('column_keymap')) {
        $km = $script:TdCfg['column_keymap']
        foreach ($k in $km.Keys) { if ($km[$k]) { $keymap[$k] = $km[$k] } }
    }
    $ui = @{
        Ctx = $Ctx; Columns = (Import-TdColumns $ColumnFile); ColumnFile = $ColumnFile
        Focus = 0; First = 0; Marks = (New-Object 'System.Collections.Generic.HashSet[string]')
        Pending = ''; Mode = ''; ModeBuf = ''; Status = ''; StatusColor = $null
        Overlay = $null; OverlayTitle = ''; OverlayTop = 0
        Prev = @{}; W = 0; H = 0; Quit = $false; LastCmd = ''; Keymap = $keymap
        History = (New-Object System.Collections.Generic.List[string]); Alt = $false
        OldCtrlC = [Console]::TreatControlCAsInput
    }
    $prevMode = $Ctx.Mode
    $Ctx.Mode = 'columns'
    $Ctx.Ui = $ui
    Enter-TdScreen $ui
    try {
        Update-TdColumnsData $ui
        while (-not $ui.Quit) {
            Show-TdColumns $ui
            $key = Wait-TdKey $ui
            if ($null -eq $key) { continue }
            try { Invoke-TdColumnsKey $ui $key }
            catch { $ui.Status = $_.Exception.Message; $ui.StatusColor = [ConsoleColor]::Red }
        }
    }
    finally {
        Exit-TdScreen $ui
        $Ctx.Mode = $prevMode
        $Ctx.Ui = $null
    }
}
