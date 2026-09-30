# Todo list files: loading, saving, identifiers, dependencies, backups.

$script:TdUtf8 = New-Object System.Text.UTF8Encoding $false

function Get-TdFileStamp {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $fi = New-Object System.IO.FileInfo $Path
    return "$($fi.LastWriteTimeUtc.Ticks)-$($fi.Length)"
}

function Read-TdTextFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
}

function Write-TdTextFile {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [IO.File]::WriteAllText($Path, $Content, $script:TdUtf8)
}

function Read-TdList {
    param([string]$Path)
    $list = [pscustomobject]@{
        Path    = $Path
        Items   = (New-Object System.Collections.Generic.List[object])
        Newline = [Environment]::NewLine
        Stamp   = ''
        Dirty   = $false
    }
    $raw = Read-TdTextFile $Path
    if ($raw.Contains("`r`n")) { $list.Newline = "`r`n" } elseif ($raw.Contains("`n")) { $list.Newline = "`n" }
    foreach ($line in ($raw -split "`r?`n")) {
        if ($line.Trim() -ne '') { $list.Items.Add((New-TdTodo $line)) }
    }
    $list.Stamp = Get-TdFileStamp $Path
    Update-TdListIds $list
    return $list
}

function ConvertTo-TdListText {
    param($List)
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($t in $List.Items) { $lines.Add((Get-TdTodoSource $t)) }
    if ($lines.Count -eq 0) { return '' }
    return [string]::Join($List.Newline, $lines.ToArray()) + $List.Newline
}

function Save-TdList {
    param($List)
    Write-TdTextFile -Path $List.Path -Content (ConvertTo-TdListText $List)
    $List.Stamp = Get-TdFileStamp $List.Path
    $List.Dirty = $false
    Update-TdListIds $List
}

function Get-TdHashString {
    <#
      Derives a short identifier from a hash. The first character is always a
      letter (when the alphabet has letters): PowerShell would otherwise parse
      words like 15d or 2kb as numbers.
    #>
    param([string]$Text, [string]$Alphabet)
    $sha = [Security.Cryptography.SHA1]::Create()
    try { $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) } finally { $sha.Dispose() }
    $letters = [string]::Join('', @($Alphabet.ToCharArray() | Where-Object { [char]::IsLetter($_) }))
    if (-not $letters) { $letters = $Alphabet }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append($letters[$bytes[0] % $letters.Length])
    for ($i = 1; $i -lt 10; $i++) { [void]$sb.Append($Alphabet[$bytes[$i] % $Alphabet.Length]) }
    return $sb.ToString()
}

function Update-TdListIds {
    param($List)
    $i = 0
    foreach ($t in $List.Items) { $i++; $t.Number = $i; $t.Uid = "$i" }
    if ((Get-TdOpt 'topsdo' 'identifiers' 'linenumber') -ne 'text') { return }
    $alphabet = Get-TdOpt 'topsdo' 'identifier_alphabet' '0123456789abcdefghijklmnopqrstuvwxyz'
    if (-not $alphabet) { $alphabet = '0123456789abcdefghijklmnopqrstuvwxyz' }
    $seen = @{}
    $hashes = New-Object System.Collections.Generic.List[string]
    foreach ($t in $List.Items) {
        $src = Get-TdTodoSource $t
        $n = 0
        if ($seen.ContainsKey($src)) { $n = $seen[$src] + 1 }
        $seen[$src] = $n
        $hashes.Add((Get-TdHashString "$src#$n" $alphabet))
    }
    $len = 3
    while ($len -lt 10) {
        $set = New-Object 'System.Collections.Generic.HashSet[string]'
        $unique = $true
        foreach ($h in $hashes) { if (-not $set.Add($h.Substring(0, $len))) { $unique = $false; break } }
        if ($unique) { break }
        $len++
    }
    for ($k = 0; $k -lt $List.Items.Count; $k++) { $List.Items[$k].Uid = $hashes[$k].Substring(0, $len) }
}

function Find-TdTodo {
    param($List, [string]$Id)
    $Id = $Id.Trim()
    if ((Get-TdOpt 'topsdo' 'identifiers' 'linenumber') -eq 'text') {
        foreach ($t in $List.Items) { if ($t.Uid -eq $Id) { return $t } }
        return $null
    }
    $n = 0
    if ([int]::TryParse($Id, [ref]$n) -and $n -ge 1 -and $n -le $List.Items.Count) { return $List.Items[$n - 1] }
    return $null
}

# --- dependencies -----------------------------------------------------------

function Get-TdChildren {
    <# Todos that the given todo depends on (they carry p:<id of todo>). #>
    param($List, $Todo)
    $id = Get-TdTag $Todo 'id'
    $res = New-Object System.Collections.Generic.List[object]
    if (-not $id) { return , $res.ToArray() }
    foreach ($t in $List.Items) {
        if (-not [object]::ReferenceEquals($t, $Todo) -and (Get-TdTagValues $t 'p') -contains $id) { $res.Add($t) }
    }
    return , $res.ToArray()
}

function Get-TdParents {
    param($List, $Todo)
    $ps = Get-TdTagValues $Todo 'p'
    $res = New-Object System.Collections.Generic.List[object]
    if ($ps.Count -eq 0) { return , $res.ToArray() }
    foreach ($t in $List.Items) {
        $id = Get-TdTag $t 'id'
        if ($id -and $ps -contains $id -and -not [object]::ReferenceEquals($t, $Todo)) { $res.Add($t) }
    }
    return , $res.ToArray()
}

function New-TdDepIndex {
    <# Index for fast dependency lookups over a whole list. #>
    param($List)
    $children = @{}
    $parents = @{}
    foreach ($t in $List.Items) {
        $id = Get-TdTag $t 'id'
        if ($id) { $parents[$id] = $t }
        foreach ($p in (Get-TdTagValues $t 'p')) {
            if (-not $children.ContainsKey($p)) { $children[$p] = New-Object System.Collections.Generic.List[object] }
            $children[$p].Add($t)
        }
    }
    return @{ Children = $children; Parents = $parents }
}

function Test-TdBlocked {
    param($Index, $Todo)
    $id = Get-TdTag $Todo 'id'
    if (-not $id -or -not $Index.Children.ContainsKey($id)) { return $false }
    foreach ($c in $Index.Children[$id]) { if (-not $c.Completed) { return $true } }
    return $false
}

function Get-TdAverageImportance {
    param($Index, $Todo)
    $own = Get-TdImportance $Todo
    $sum = 0; $cnt = 0
    foreach ($p in (Get-TdTagValues $Todo 'p')) {
        if ($Index.Parents.ContainsKey($p)) { $sum += Get-TdImportance $Index.Parents[$p]; $cnt++ }
    }
    if ($cnt -gt 0) { return [Math]::Max([double]$own, $sum / $cnt) }
    return [double]$own
}

function New-TdDepId {
    param($List)
    $max = 0
    foreach ($t in $List.Items) {
        foreach ($k in @('id', 'p')) {
            foreach ($v in (Get-TdTagValues $t $k)) { $n = 0; if ([int]::TryParse($v, [ref]$n) -and $n -gt $max) { $max = $n } }
        }
    }
    return [string]($max + 1)
}

function Add-TdDependency {
    <# Makes Parent depend on Child. #>
    param($List, $Parent, $Child)
    if ([object]::ReferenceEquals($Parent, $Child)) { throw 'A todo cannot depend on itself.' }
    $id = Get-TdTag $Parent 'id'
    if (-not $id) {
        $id = New-TdDepId $List
        Set-TdTag -Todo $Parent -Key 'id' -Value $id
    }
    if (-not (Test-TdTag $Child 'p' $id)) { Set-TdTag -Todo $Child -Key 'p' -Value $id -Add }
    if (Get-TdOptBool 'dep' 'append_parent_projects' $false) {
        foreach ($p in $Parent.Projects) { if ($Child.Projects -notcontains $p) { Add-TdTodoText $Child "+$p" } }
    }
    if (Get-TdOptBool 'dep' 'append_parent_contexts' $false) {
        foreach ($c in $Parent.Contexts) { if ($Child.Contexts -notcontains $c) { Add-TdTodoText $Child "@$c" } }
    }
    $List.Dirty = $true
}

function Remove-TdDependency {
    param($List, $Parent, $Child)
    $id = Get-TdTag $Parent 'id'
    if (-not $id -or -not (Test-TdTag $Child 'p' $id)) { return $false }
    Remove-TdTag -Todo $Child -Key 'p' -Value $id
    if ((Get-TdChildren $List $Parent).Count -eq 0) { Remove-TdTag -Todo $Parent -Key 'id' }
    $List.Dirty = $true
    return $true
}

function Clear-TdDanglingDeps {
    <# Removes p: tags without parent and id: tags without children. #>
    param($List)
    $ids = @{}
    $ps = @{}
    foreach ($t in $List.Items) {
        $id = Get-TdTag $t 'id'
        if ($id) { $ids[$id] = $true }
        foreach ($p in (Get-TdTagValues $t 'p')) { $ps[$p] = $true }
    }
    $changed = $false
    foreach ($t in $List.Items) {
        foreach ($p in (Get-TdTagValues $t 'p')) {
            if (-not $ids.ContainsKey($p)) { Remove-TdTag -Todo $t -Key 'p' -Value $p; $changed = $true }
        }
        $id = Get-TdTag $t 'id'
        if ($id -and -not $ps.ContainsKey($id)) { Remove-TdTag -Todo $t -Key 'id'; $changed = $true }
    }
    if ($changed) { $List.Dirty = $true }
    return $changed
}

# --- backups (revert) -----------------------------------------------------------

function Get-TdBackupPath {
    param($Ctx)
    $dir = Split-Path -Parent $Ctx.TodoPath
    if (-not $dir) { $dir = '.' }
    return (Join-Path $dir '.topsdo_backup')
}

function Read-TdBackups {
    param($Ctx)
    $path = Get-TdBackupPath $Ctx
    $res = New-Object System.Collections.Generic.List[object]
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        try {
            $json = Read-TdTextFile $path
            if ($json.Trim()) {
                # PS 5.1 returns JSON arrays as a single object; foreach enumerates both variants.
                $parsed = ConvertFrom-Json $json
                foreach ($e in $parsed) { if ($null -ne $e) { $res.Add($e) } }
            }
        }
        catch { }
    }
    return , $res
}

function Write-TdBackups {
    param($Ctx, $Entries)
    $path = Get-TdBackupPath $Ctx
    $arr = @($Entries | ForEach-Object { $_ })
    $json = ConvertTo-Json -InputObject $arr -Depth 4
    if ($arr.Count -eq 0) { $json = '[]' }
    Write-TdTextFile -Path $path -Content $json
}

function Push-TdBackup {
    param($Ctx, [string]$Label, [string]$TodoText, [string]$DoneText)
    $count = Get-TdOptInt 'topsdo' 'backup_count' 5
    if ($count -le 0) { return }
    $entries = Read-TdBackups $Ctx
    $entries.Add([pscustomobject]@{
            Time    = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss', $script:TdInvariant)
            Command = $Label
            Todo    = $TodoText
            Done    = $DoneText
        })
    while ($entries.Count -gt $count) { $entries.RemoveAt(0) }
    Write-TdBackups $Ctx $entries
}
