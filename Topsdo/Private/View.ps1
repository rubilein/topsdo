# Filtering, sorting, grouping and formatting of todo items.

# --- filters --------------------------------------------------------------------

function ConvertTo-TdFilter {
    <#
      Turns filter words into filter objects. Supported words:
        text        substring match          -text      negation of any word
        /regex/     regular expression       +project   @context
        (A) (<B) (>=C) (!A)                  priority (A is highest)
        key:value key:<value key:>=value key:!value     tags; dates, numbers
    #>
    param([string[]]$Words)
    $res = New-Object System.Collections.Generic.List[object]
    foreach ($w in $Words) {
        if (-not $w) { continue }
        $neg = $false
        if ($w.Length -gt 1 -and $w.StartsWith('-', [StringComparison]::Ordinal)) { $neg = $true; $w = $w.Substring(1) }
        $f = [pscustomobject]@{ Type = 'text'; Negate = $neg; Key = $null; Op = $null; Value = $w }
        if ($w.Length -gt 2 -and $w.StartsWith('/', [StringComparison]::Ordinal) -and $w.EndsWith('/', [StringComparison]::Ordinal)) {
            $f.Type = 'regex'; $f.Value = $w.Substring(1, $w.Length - 2)
        }
        elseif ($w -match '^\+(\S+)$') { $f.Type = 'project'; $f.Value = $Matches[1] }
        elseif ($w -match '^@(\S+)$') { $f.Type = 'context'; $f.Value = $Matches[1] }
        elseif ($w -match '^\((<=|>=|!=|<|>|=|!)?([A-Za-z])\)$') {
            $f.Type = 'priority'; $f.Op = $Matches[1]; $f.Value = $Matches[2].ToUpperInvariant()
            if (-not $f.Op) { $f.Op = '=' }
        }
        elseif ($w -match '^([^\s:]+):(<=|>=|!=|<|>|=|!)?(\S*)$' -and ($Matches[2] -or $Matches[3])) {
            $f.Type = 'tag'; $f.Key = $Matches[1]; $f.Op = $Matches[2]; $f.Value = $Matches[3]
            if (-not $f.Op) { $f.Op = '=' }
        }
        $res.Add($f)
    }
    return , $res.ToArray()
}

function Compare-TdValues {
    param($A, $B, [string]$Op)
    $c = 0
    if ($A -is [datetime] -and $B -is [datetime]) { $c = $A.CompareTo($B) }
    elseif ($A -is [double] -and $B -is [double]) { $c = $A.CompareTo($B) }
    else { $c = [string]::Compare([string]$A, [string]$B, [StringComparison]::OrdinalIgnoreCase) }
    switch ($Op) {
        '=' { return $c -eq 0 }
        '!' { return $c -ne 0 }
        '!=' { return $c -ne 0 }
        '<' { return $c -lt 0 }
        '<=' { return $c -le 0 }
        '>' { return $c -gt 0 }
        '>=' { return $c -ge 0 }
    }
    return $false
}

function ConvertTo-TdComparable {
    param([string]$Text, [bool]$AsDate)
    if ($AsDate) {
        $d = Resolve-TdRelativeDate $Text
        if ($null -ne $d) { return $d }
    }
    $n = 0.0
    if ([double]::TryParse($Text, [Globalization.NumberStyles]::Float, $script:TdInvariant, [ref]$n)) { return $n }
    return $Text
}

function Test-TdFilterMatch {
    param($Filter, $Todo)
    $ic = Get-TdOptBool 'topsdo' 'ignore_case' $true
    $m = $false
    switch ($Filter.Type) {
        'text' {
            $src = Get-TdTodoSource $Todo
            if ($ic) { $m = $src.IndexOf($Filter.Value, [StringComparison]::OrdinalIgnoreCase) -ge 0 }
            else { $m = $src.Contains($Filter.Value) }
        }
        'regex' {
            $opt = [Text.RegularExpressions.RegexOptions]::None
            if ($ic) { $opt = [Text.RegularExpressions.RegexOptions]::IgnoreCase }
            try { $m = [regex]::IsMatch((Get-TdTodoSource $Todo), $Filter.Value, $opt) } catch { $m = $false }
        }
        'project' { foreach ($p in $Todo.Projects) { if ($p -eq $Filter.Value) { $m = $true } } }
        'context' { foreach ($c in $Todo.Contexts) { if ($c -eq $Filter.Value) { $m = $true } } }
        'priority' {
            if ($Todo.Priority) {
                # A is the highest priority: compare inverted character codes.
                $a = [double](100 - [int][char]$Todo.Priority)
                $b = [double](100 - [int][char]$Filter.Value)
                $m = Compare-TdValues $a $b $Filter.Op
            }
            else { $m = ($Filter.Op -eq '!' -or $Filter.Op -eq '!=' -or $Filter.Op -eq '<' -or $Filter.Op -eq '<=') }
        }
        'tag' {
            $vals = Get-TdTagValues $Todo $Filter.Key
            if ($Filter.Value -eq '' -or $Filter.Value -eq '*') {
                # key:* -> tag present, key:! / key:!* -> tag absent
                $m = ($vals.Count -gt 0)
                if ($Filter.Op -eq '!' -or $Filter.Op -eq '!=') { $m = -not $m }
            }
            elseif ($vals.Count -eq 0) {
                $m = ($Filter.Op -eq '!' -or $Filter.Op -eq '!=')
            }
            else {
                $isDate = ($Filter.Key -eq (Get-TdTagName 'due') -or $Filter.Key -eq (Get-TdTagName 'start'))
                $want = ConvertTo-TdComparable $Filter.Value $true
                foreach ($v in $vals) {
                    $have = ConvertTo-TdComparable $v ($isDate -or $want -is [datetime])
                    if ($want -is [datetime] -and $have -isnot [datetime]) { $cmpWant = $Filter.Value } else { $cmpWant = $want }
                    if ($have -is [double] -and $cmpWant -isnot [double]) { $have = $v }
                    if ($cmpWant -is [double] -and $have -isnot [double]) { $cmpWant = $Filter.Value }
                    if (Compare-TdValues $have $cmpWant $Filter.Op) { $m = $true; break }
                }
            }
        }
    }
    if ($Filter.Negate) { return -not $m }
    return $m
}

function Select-TdTodos {
    <#
      Applies the standard view filters (hide completed, future start, blocked,
      hidden items) unless -ShowAll, then all filter objects.
    #>
    param($List, $Items, $Filters, [switch]$ShowAll, $Index)
    if ($null -eq $Index) { $Index = New-TdDepIndex $List }
    $res = New-Object System.Collections.Generic.List[object]
    foreach ($t in $Items) {
        if (-not $ShowAll) {
            if ($t.Completed) { continue }
            if (-not (Test-TdTodoActive $t)) { continue }
            if (Test-TdTodoHidden $t) { continue }
            if (Test-TdBlocked $Index $t) { continue }
        }
        $ok = $true
        foreach ($f in $Filters) { if (-not (Test-TdFilterMatch $f $t)) { $ok = $false; break } }
        if ($ok) { $res.Add($t) }
    }
    return , $res.ToArray()
}

# --- sorting --------------------------------------------------------------------

function ConvertTo-TdSortSpec {
    param([string]$Expression)
    $res = New-Object System.Collections.Generic.List[object]
    foreach ($part in ($Expression -split ',')) {
        $p = $part.Trim()
        if (-not $p) { continue }
        $desc = $false
        if ($p -match '^(asc|desc):(.+)$') { $desc = ($Matches[1] -eq 'desc'); $p = $Matches[2] }
        $res.Add([pscustomobject]@{ Field = $p.ToLowerInvariant(); Descending = $desc })
    }
    return , $res.ToArray()
}

function Get-TdFieldKey {
    <#
      Sort key for a field; types are consistent per field. $null means the
      value is missing (sorted last). No sentinel characters are used: culture
      aware comparison in .NET Framework (PS 5.1) ignores control characters.
    #>
    param($Todo, [string]$Field, $Index)
    switch ($Field) {
        'importance' { return [double](Get-TdImportance $Todo) }
        { $_ -eq 'importance-avg' -or $_ -eq 'importance_avg' } { return [double](Get-TdAverageImportance $Index $Todo) }
        'priority' { if ($Todo.Priority) { return [double](91 - [int][char]$Todo.Priority) } return [double]0 }
        'due' { if ($null -ne $Todo.Due) { return Format-TdDate $Todo.Due } return '9999-99-99' }
        { $_ -eq 'start' -or $_ -eq 't' } { if ($null -ne $Todo.Start) { return Format-TdDate $Todo.Start } return '0000-00-00' }
        { $_ -eq 'creation' -or $_ -eq 'created' } { if ($Todo.CreationDate) { return $Todo.CreationDate } return '9999-99-99' }
        { $_ -eq 'completion' -or $_ -eq 'completed' -or $_ -eq 'done' } {
            if ($Todo.Completed) { return '1' + "$($Todo.CompletionDate)" } return '0'
        }
        'text' { return $Todo.Text.ToLowerInvariant() }
        'length' { return [double]$Todo.Text.Length }
        { $_ -eq 'project' -or $_ -eq 'projects' } { if ($Todo.Projects.Count) { return (@($Todo.Projects | Sort-Object)[0]).ToLowerInvariant() } return $null }
        { $_ -eq 'context' -or $_ -eq 'contexts' } { if ($Todo.Contexts.Count) { return (@($Todo.Contexts | Sort-Object)[0]).ToLowerInvariant() } return $null }
        { $_ -eq 'line' -or $_ -eq 'number' -or $_ -eq 'id' } { return [double]$Todo.Number }
        default {
            $v = Get-TdTag $Todo $Field
            if ($null -eq $v) { return $null }
            return $v.ToLowerInvariant()
        }
    }
}

function Sort-TdTodos {
    param($List, $Items, [string]$Expression, $Index)
    if ($null -eq $Index) { $Index = New-TdDepIndex $List }
    $spec = ConvertTo-TdSortSpec $Expression
    $arr = @(foreach ($x in $Items) { $x })
    if ($arr.Count -le 1 -or $spec.Count -eq 0) { return , $arr }
    $wrapped = New-Object System.Collections.Generic.List[object]
    foreach ($t in $arr) {
        $o = @{ T = $t; N = [double]$t.Number }
        for ($i = 0; $i -lt $spec.Count; $i++) {
            $k = Get-TdFieldKey $t $spec[$i].Field $Index
            $o["M$i"] = [int]($null -eq $k)
            if ($null -eq $k) { $k = '' }
            $o["K$i"] = $k
        }
        $wrapped.Add([pscustomobject]$o)
    }
    $props = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $spec.Count; $i++) {
        $props.Add(@{ Expression = "M$i"; Descending = $false })
        $props.Add(@{ Expression = "K$i"; Descending = $spec[$i].Descending })
    }
    $props.Add(@{ Expression = 'N'; Descending = $false })
    $sorted = $wrapped | Sort-Object -Property $props.ToArray()
    return , @($sorted | ForEach-Object { $_.T })
}

function Get-TdGroupValues {
    <# Returns the group (sort key + label) entries an item belongs to. #>
    param($Todo, [string]$Field)
    $res = New-Object System.Collections.Generic.List[object]
    switch ($Field) {
        { $_ -eq 'project' -or $_ -eq 'projects' } {
            foreach ($p in $Todo.Projects) { $res.Add(@($p.ToLowerInvariant(), "+$p")) }
        }
        { $_ -eq 'context' -or $_ -eq 'contexts' } {
            foreach ($c in $Todo.Contexts) { $res.Add(@($c.ToLowerInvariant(), "@$c")) }
        }
        'priority' { if ($Todo.Priority) { $res.Add(@($Todo.Priority, "Priority $($Todo.Priority)")) } }
        'due' { if ($null -ne $Todo.Due) { $res.Add(@((Format-TdDate $Todo.Due), "Due $(Get-TdHumanDate $Todo.Due)")) } }
        { $_ -eq 'start' -or $_ -eq 't' } { if ($null -ne $Todo.Start) { $res.Add(@((Format-TdDate $Todo.Start), "Start $(Get-TdHumanDate $Todo.Start)")) } }
        'importance' { $i = Get-TdImportance $Todo; $res.Add(@(('{0:D3}' -f $i), "Importance $i")) }
        default { foreach ($v in (Get-TdTagValues $Todo $Field)) { $res.Add(@($v.ToLowerInvariant(), "${Field}:$v")) } }
    }
    return , $res.ToArray()
}

function Group-TdTodos {
    <# Returns an array of groups @{ Label; Items } (items keep their order). #>
    param($Items, [string]$Expression)
    $spec = ConvertTo-TdSortSpec $Expression
    $all = @{ Key = ''; Label = ''; Items = (New-Object System.Collections.Generic.List[object]) }
    if ($spec.Count -eq 0) {
        foreach ($t in $Items) { $all.Items.Add($t) }
        return , @([pscustomobject]$all)
    }
    $groups = @{}
    $order = New-Object System.Collections.Generic.List[object]
    foreach ($t in $Items) {
        # each combination: Parts = per level @(missing flag, sort value), L = label
        $keys = @(@{ Parts = @(); L = '' })
        foreach ($s in $spec) {
            $vals = Get-TdGroupValues $t $s.Field
            $missing = 0
            if ($vals.Count -eq 0) { $vals = @(, @('', "No $($s.Field)")); $missing = 1 }
            $next = New-Object System.Collections.Generic.List[object]
            foreach ($k in $keys) {
                foreach ($v in $vals) {
                    $lab = $v[1]
                    if ($k.L) { $lab = "$($k.L), $($v[1])" }
                    $next.Add(@{ Parts = (@($k.Parts) + , @($missing, $v[0])); L = $lab })
                }
            }
            $keys = $next.ToArray()
        }
        foreach ($k in $keys) {
            $id = [string]::Join("`n", @($k.Parts | ForEach-Object { "$($_[0])$($_[1])" }))
            if (-not $groups.ContainsKey($id)) {
                $g = @{ Label = $k.L; Items = (New-Object System.Collections.Generic.List[object]) }
                for ($i = 0; $i -lt $k.Parts.Count; $i++) { $g["M$i"] = $k.Parts[$i][0]; $g["V$i"] = $k.Parts[$i][1] }
                $groups[$id] = $g
                $order.Add($g)
            }
            $groups[$id].Items.Add($t)
        }
    }
    $props = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $spec.Count; $i++) {
        $props.Add(@{ Expression = "M$i"; Descending = $false })
        $props.Add(@{ Expression = "V$i"; Descending = $spec[$i].Descending })
    }
    $ordered = @($order | ForEach-Object { [pscustomobject]$_ } | Sort-Object -Property $props.ToArray())
    return , $ordered
}

# --- formatting -------------------------------------------------------------------

function Get-TdVisibleTags {
    param($Todo, [switch]$All)
    $hide = @()
    if (-not $All) { $hide = Get-TdOptList 'ls' 'hide_tags' }
    $res = New-Object System.Collections.Generic.List[string]
    foreach ($tag in $Todo.Tags) { if ($hide -notcontains $tag.Key) { $res.Add("$($tag.Key):$($tag.Value)") } }
    return , $res.ToArray()
}

function Get-TdTextWithoutTags {
    param($Todo)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($word in ($Todo.Text -split ' ')) { if ($word -notmatch $script:TdTagRx) { $out.Add($word) } }
    return [string]::Join(' ', $out.ToArray())
}

function Get-TdRelativeSummary {
    param($Todo)
    $parts = New-Object System.Collections.Generic.List[string]
    if ($null -ne $Todo.Due) { $parts.Add("due $(Get-TdHumanDate $Todo.Due)") }
    if ($null -ne $Todo.Start -and $Todo.Start -gt (Get-TdToday)) { $parts.Add("starts $(Get-TdHumanDate $Todo.Start)") }
    return [string]::Join(', ', $parts.ToArray())
}

function Get-TdPlaceholder {
    param($Todo, [char]$Ph, [int]$IdWidth)
    switch -CaseSensitive ([string]$Ph) {
        'i' { return $Todo.Uid }
        'I' { return $Todo.Uid.PadLeft($IdWidth) }
        'p' { if ($Todo.Priority) { return $Todo.Priority } return '' }
        'P' { if ($Todo.Priority) { return "($($Todo.Priority))" } return '   ' }
        'x' { if ($Todo.Completed) { return ("x $($Todo.CompletionDate)").Trim() } return '' }
        'X' { if ($Todo.Completed) { $d = ConvertTo-TdDate $Todo.CompletionDate; if ($d) { return "x $(Get-TdHumanDate $d)" } return 'x' } return '' }
        'c' { return "$($Todo.CreationDate)" }
        'C' { $d = ConvertTo-TdDate $Todo.CreationDate; if ($d) { return Get-TdHumanDate $d } return '' }
        'd' { return Format-TdDate $Todo.Due }
        'D' { if ($null -ne $Todo.Due) { return Get-TdHumanDate $Todo.Due } return '' }
        't' { return Format-TdDate $Todo.Start }
        'T' { if ($null -ne $Todo.Start) { return Get-TdHumanDate $Todo.Start } return '' }
        'h' { return Get-TdRelativeSummary $Todo }
        'H' {
            $s = Get-TdRelativeSummary $Todo
            $d = ConvertTo-TdDate $Todo.CreationDate
            if ($d) { if ($s) { $s += ', ' }; $s += "created $(Get-TdHumanDate $d)" }
            return $s
        }
        's' { return Get-TdTextWithoutTags $Todo }
        'k' { return [string]::Join(' ', (Get-TdVisibleTags $Todo)) }
        'K' { return [string]::Join(' ', (Get-TdVisibleTags $Todo -All)) }
        'r' { return Get-TdTodoSource $Todo }
        'z' { if (Test-TdTag $Todo (Get-TdTagName 'star')) { return '*' } return '' }
        '%' { return '%' }
    }
    return ''
}

function Format-TdTodo {
    <#
      Renders a todo with a format string. %X inserts a placeholder,
      %{prefix}X{suffix} adds prefix/suffix only when the value is not empty.
    #>
    param($Todo, [string]$Format, [int]$IdWidth = 1)
    $sb = New-Object System.Text.StringBuilder
    $i = 0
    $n = $Format.Length
    while ($i -lt $n) {
        $ch = $Format[$i]
        if ($ch -ne '%' -or $i + 1 -ge $n) { [void]$sb.Append($ch); $i++; continue }
        $i++
        $prefix = ''; $suffix = ''
        if ($Format[$i] -eq '{') {
            $end = $Format.IndexOf([char]'}', $i)
            if ($end -lt 0) { break }
            $prefix = $Format.Substring($i + 1, $end - $i - 1)
            $i = $end + 1
            if ($i -ge $n) { break }
        }
        $ph = $Format[$i]
        $i++
        if ($i -lt $n -and $Format[$i] -eq '{') {
            $end = $Format.IndexOf([char]'}', $i)
            if ($end -ge 0) { $suffix = $Format.Substring($i + 1, $end - $i - 1); $i = $end + 1 }
        }
        $val = Get-TdPlaceholder $Todo $ph $IdWidth
        if ($val -ne '') { [void]$sb.Append($prefix).Append($val).Append($suffix) }
    }
    $s = $sb.ToString()
    if ($Format -notmatch '%[{]?I' -and $Format -notmatch '%P') { $s = $s -replace ' {2,}', ' ' }
    else {
        # keep leading id padding, collapse the rest
        $m = [regex]::Match($s, '^\s*\S+')
        if ($m.Success) { $s = $m.Value + ($s.Substring($m.Length) -replace ' {2,}', ' ') }
    }
    return $s.TrimEnd()
}

function Get-TdIdWidth {
    param($Items)
    $w = 1
    foreach ($t in $Items) { if ($t.Uid.Length -gt $w) { $w = $t.Uid.Length } }
    return $w
}

function Get-TdSegments {
    <#
      Splits a rendered line into colored segments: @{ T = text; F = fg }.
      Base color by priority; projects, contexts, tags and links highlighted.
    #>
    param([string]$Line, $Todo)
    $segs = New-Object System.Collections.Generic.List[object]
    $base = $null
    if ($Todo.Completed) {
        $segs.Add(@{ T = $Line; F = (ConvertTo-TdColor (Get-TdOpt 'colors' 'completed_color' 'DarkGray')) })
        return , $segs.ToArray()
    }
    $prio = Get-TdPriorityColors
    if ($Todo.Priority -and $prio.ContainsKey($Todo.Priority)) { $base = $prio[$Todo.Priority] }
    $cProj = ConvertTo-TdColor (Get-TdOpt 'colors' 'project_color' '')
    $cCtx = ConvertTo-TdColor (Get-TdOpt 'colors' 'context_color' '')
    $cMeta = ConvertTo-TdColor (Get-TdOpt 'colors' 'metadata_color' '')
    $cLink = ConvertTo-TdColor (Get-TdOpt 'colors' 'link_color' '')
    $cOver = ConvertTo-TdColor (Get-TdOpt 'colors' 'overdue_color' '')
    $overdue = ($null -ne $Todo.Due -and $Todo.Due -lt (Get-TdToday))
    $dueKey = Get-TdTagName 'due'
    $pos = 0
    foreach ($m in [regex]::Matches($Line, '(?<!\S)\S+')) {
        $w = $m.Value
        $c = $null
        if ($w -match '^[a-zA-Z][a-zA-Z0-9+.-]*://\S+$') { $c = $cLink }
        elseif ($w -match '^\+\S*\w') { $c = $cProj }
        elseif ($w -match '^@\S*\w') { $c = $cCtx }
        elseif ($w -match $script:TdTagRx) {
            $c = $cMeta
            if ($overdue -and $Matches[1] -eq $dueKey) { $c = $cOver }
        }
        if ($null -eq $c) { continue }
        if ($m.Index -gt $pos) { $segs.Add(@{ T = $Line.Substring($pos, $m.Index - $pos); F = $base }) }
        $segs.Add(@{ T = $w; F = $c })
        $pos = $m.Index + $m.Length
    }
    if ($pos -lt $Line.Length) { $segs.Add(@{ T = $Line.Substring($pos); F = $base }) }
    return , $segs.ToArray()
}
