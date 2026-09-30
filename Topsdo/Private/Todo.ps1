# A single todo.txt item: parsing, serialization and tag manipulation.

$script:TdProjectRx = '(?<!\S)\+(\S*\w)'
$script:TdContextRx = '(?<!\S)@(\S*\w)'
$script:TdTagRx = '^([^\s:]+):([^\s:/]\S*)$'

function New-TdTodo {
    param([string]$Line)
    $t = [pscustomobject]@{
        Completed      = $false
        CompletionDate = $null
        Priority       = $null
        CreationDate   = $null
        Text           = ''
        Number         = 0
        Uid            = ''
        Projects       = @()
        Contexts       = @()
        Tags           = @()
        Due            = $null
        Start          = $null
    }
    Set-TdTodoSource -Todo $t -Line $Line
    return $t
}

function Set-TdTodoSource {
    param($Todo, [string]$Line)
    $l = ($Line -replace '[\r\n]', ' ').Trim()
    $Todo.Completed = $false
    $Todo.CompletionDate = $null
    $Todo.Priority = $null
    $Todo.CreationDate = $null
    $Todo.Text = $l
    $d = '(\d{4}-\d{2}-\d{2})'
    if ($l -cmatch "^x(?= |$)(?: $d)?(?: $d)?(?: (.*))?$") {
        $Todo.Completed = $true
        if ($Matches[1]) { $Todo.CompletionDate = $Matches[1] }
        if ($Matches[2]) { $Todo.CreationDate = $Matches[2] }
        $Todo.Text = "$($Matches[3])"
    }
    elseif ($l -cmatch "^\(([A-Z])\)(?: $d)?(?: (.*))?$") {
        $Todo.Priority = $Matches[1]
        if ($Matches[2]) { $Todo.CreationDate = $Matches[2] }
        $Todo.Text = "$($Matches[3])"
    }
    elseif ($l -match "^$d(?: (.*))?$") {
        $Todo.CreationDate = $Matches[1]
        $Todo.Text = "$($Matches[2])"
    }
    Update-TdTodoParse $Todo
}

function Update-TdTodoParse {
    param($Todo)
    $Todo.Text = ($Todo.Text -replace '\s+', ' ').Trim()
    $projects = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($Todo.Text, $script:TdProjectRx)) {
        if (-not $projects.Contains($m.Groups[1].Value)) { $projects.Add($m.Groups[1].Value) }
    }
    $contexts = New-Object System.Collections.Generic.List[string]
    foreach ($m in [regex]::Matches($Todo.Text, $script:TdContextRx)) {
        if (-not $contexts.Contains($m.Groups[1].Value)) { $contexts.Add($m.Groups[1].Value) }
    }
    $tags = New-Object System.Collections.Generic.List[object]
    foreach ($word in ($Todo.Text -split ' ')) {
        if ($word -match $script:TdTagRx) {
            $tags.Add([pscustomobject]@{ Key = $Matches[1]; Value = $Matches[2] })
        }
    }
    $Todo.Projects = $projects.ToArray()
    $Todo.Contexts = $contexts.ToArray()
    $Todo.Tags = $tags.ToArray()
    $Todo.Due = ConvertTo-TdDate (Get-TdTag $Todo (Get-TdTagName 'due'))
    $Todo.Start = ConvertTo-TdDate (Get-TdTag $Todo (Get-TdTagName 'start'))
}

function Get-TdTodoSource {
    param($Todo)
    $parts = New-Object System.Collections.Generic.List[string]
    if ($Todo.Completed) {
        $parts.Add('x')
        if ($Todo.CompletionDate) { $parts.Add($Todo.CompletionDate) }
        if ($Todo.CreationDate) { $parts.Add($Todo.CreationDate) }
    }
    else {
        if ($Todo.Priority) { $parts.Add("($($Todo.Priority))") }
        if ($Todo.CreationDate) { $parts.Add($Todo.CreationDate) }
    }
    if ($Todo.Text) { $parts.Add($Todo.Text) }
    return [string]::Join(' ', $parts.ToArray())
}

function Get-TdTag {
    param($Todo, [string]$Key)
    foreach ($tag in $Todo.Tags) { if ($tag.Key -eq $Key) { return $tag.Value } }
    return $null
}

function Get-TdTagValues {
    param($Todo, [string]$Key)
    $vals = New-Object System.Collections.Generic.List[string]
    foreach ($tag in $Todo.Tags) { if ($tag.Key -eq $Key) { $vals.Add($tag.Value) } }
    return , $vals.ToArray()
}

function Test-TdTag {
    param($Todo, [string]$Key, [string]$Value)
    foreach ($tag in $Todo.Tags) {
        if ($tag.Key -eq $Key -and (-not $Value -or $tag.Value -eq $Value)) { return $true }
    }
    return $false
}

function Set-TdTag {
    <#
      Sets tag Key to Value. Without -Add, all existing occurrences (or only
      the one with OldValue) are replaced by a single occurrence.
      An empty Value removes the tag.
    #>
    param($Todo, [string]$Key, [string]$Value, [string]$OldValue, [switch]$Add)
    if (-not $Value) { Remove-TdTag -Todo $Todo -Key $Key -Value $OldValue; return }
    if ($Add -or -not (Test-TdTag $Todo $Key)) {
        $Todo.Text = ("$($Todo.Text) ${Key}:$Value").Trim()
        Update-TdTodoParse $Todo
        return
    }
    $out = New-Object System.Collections.Generic.List[string]
    $done = $false
    foreach ($word in ($Todo.Text -split ' ')) {
        if ($word -match $script:TdTagRx -and $Matches[1] -eq $Key -and (-not $OldValue -or $Matches[2] -eq $OldValue)) {
            if (-not $done) { $out.Add("${Key}:$Value"); $done = $true }
            continue
        }
        $out.Add($word)
    }
    $Todo.Text = [string]::Join(' ', $out.ToArray())
    Update-TdTodoParse $Todo
}

function Remove-TdTag {
    param($Todo, [string]$Key, [string]$Value)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($word in ($Todo.Text -split ' ')) {
        if ($word -match $script:TdTagRx -and $Matches[1] -eq $Key -and (-not $Value -or $Matches[2] -eq $Value)) { continue }
        $out.Add($word)
    }
    $Todo.Text = [string]::Join(' ', $out.ToArray())
    Update-TdTodoParse $Todo
}

function Add-TdTodoText {
    param($Todo, [string]$Text)
    $Todo.Text = ("$($Todo.Text) $Text").Trim()
    Update-TdTodoParse $Todo
}

function Convert-TdTodoDates {
    <# Rewrites relative dates in date tags (due:tomorrow -> due:2024-01-02). #>
    param($Todo)
    foreach ($key in @((Get-TdTagName 'due'), (Get-TdTagName 'start'))) {
        foreach ($v in (Get-TdTagValues $Todo $key)) {
            $d = Resolve-TdRelativeDate $v
            if ($null -ne $d) {
                $nv = Format-TdDate $d
                if ($nv -ne $v) { Set-TdTag -Todo $Todo -Key $key -Value $nv -OldValue $v }
            }
        }
    }
}

function Test-TdTodoActive {
    <# True when the todo has no start date in the future. #>
    param($Todo)
    return ($null -eq $Todo.Start -or $Todo.Start -le (Get-TdToday))
}

function Test-TdTodoHidden {
    param($Todo)
    foreach ($key in (Get-TdOptList 'ls' 'hidden_item_tags')) {
        foreach ($v in (Get-TdTagValues $Todo $key)) {
            if ($v -eq '1' -or $v -eq 'true' -or $v -eq 'yes') { return $true }
        }
    }
    return $false
}

function Complete-TdTodo {
    param($Todo, $Date)
    if ($null -eq $Date) { $Date = Get-TdToday }
    $Todo.Completed = $true
    $Todo.CompletionDate = Format-TdDate $Date
    $Todo.Priority = $null
}

function Get-TdImportance {
    param($Todo)
    if ($Todo.Completed) { return 0 }
    $r = 2
    switch ($Todo.Priority) { 'A' { $r += 3 } 'B' { $r += 2 } 'C' { $r += 1 } }
    if ($null -ne $Todo.Due) {
        $today = Get-TdToday
        $days = [int]($Todo.Due - $today).TotalDays
        if ($days -ge 7 -and $days -lt 14) { $r += 1 }
        elseif ($days -ge 2 -and $days -lt 7) { $r += 2 }
        elseif ($days -eq 1) { $r += 3 }
        elseif ($days -eq 0) { $r += 5 }
        elseif ($days -lt 0) { $r += 6 }
        if ((Get-TdOptBool 'sort' 'ignore_weekends' $true) -and $Todo.Due.DayOfWeek -eq [DayOfWeek]::Monday -and
            $days -ge 1 -and $days -le 3 -and @([DayOfWeek]::Friday, [DayOfWeek]::Saturday, [DayOfWeek]::Sunday) -contains $today.DayOfWeek) {
            $r += 1
        }
    }
    if (Test-TdTag $Todo (Get-TdTagName 'star')) { $r += 1 }
    return $r
}

function New-TdRecurrence {
    <#
      Returns the next instance of a recurring todo (rec:1w / rec:+1w), or $null.
      Non-strict: new dates are relative to the completion day.
      Strict (+ or -Strict): relative to the old due (or start) date.
    #>
    param($Todo, [switch]$Strict, $CompletionDate)
    $recKey = Get-TdTagName 'rec'
    $rec = Get-TdTag $Todo $recKey
    if (-not $rec) { return $null }
    $p = ConvertFrom-TdPeriod $rec
    if ($null -eq $p) { return $null }
    $isStrict = $Strict -or $p.Strict
    $today = $CompletionDate
    if ($null -eq $today) { $today = Get-TdToday }
    $dueKey = Get-TdTagName 'due'
    $startKey = Get-TdTagName 'start'

    $new = New-TdTodo ''
    $new.Priority = $Todo.Priority
    $new.Text = $Todo.Text
    Update-TdTodoParse $new
    if (Get-TdOptBool 'add' 'auto_creation_date' $true) { $new.CreationDate = Format-TdDate (Get-TdToday) }

    if ($null -ne $Todo.Due) {
        $base = $today
        if ($isStrict) { $base = $Todo.Due }
        $newDue = Add-TdPeriod $base $p.Amount $p.Unit
        Set-TdTag -Todo $new -Key $dueKey -Value (Format-TdDate $newDue)
        if ($null -ne $Todo.Start) {
            $len = ($Todo.Due - $Todo.Start).Days
            Set-TdTag -Todo $new -Key $startKey -Value (Format-TdDate $newDue.AddDays(-$len))
        }
    }
    elseif ($null -ne $Todo.Start) {
        $base = $today
        if ($isStrict) { $base = $Todo.Start }
        Set-TdTag -Todo $new -Key $startKey -Value (Format-TdDate (Add-TdPeriod $base $p.Amount $p.Unit))
    }
    else {
        Set-TdTag -Todo $new -Key $dueKey -Value (Format-TdDate (Add-TdPeriod $today $p.Amount $p.Unit))
    }
    return $new
}
