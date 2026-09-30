# Configuration handling: INI parsing, defaults and lookup.

$script:TdDefaultIni = @'
[topsdo]
filename = todo.txt
archive_filename = done.txt
default_command = ls
; colors: 1 = on, 0 = off
colors = 1
; identifiers: linenumber or text
identifiers = linenumber
identifier_alphabet = 0123456789abcdefghijklmnopqrstuvwxyz
; move completed items to archive_filename after 'do'
archive = 1
backup_count = 5
ignore_case = 1
; prompt mode command history
history_file = ~/.topsdo_history

[add]
auto_creation_date = 1

[ls]
hide_tags = id,p,ical
hidden_item_tags = h
list_limit = -1
list_format = %I %x %{(}p{)} %s %k %{(}h{)}

[sort]
sort_string = desc:importance,due,desc:priority
group_string =
ignore_weekends = 1

[tags]
tag_due = due
tag_start = t
tag_recurrence = rec
tag_star = star

[dep]
append_parent_projects = 0
append_parent_contexts = 0

[colors]
priority_colors = A:Cyan,B:Yellow,C:Blue
project_color = Red
context_color = Magenta
metadata_color = Green
link_color = DarkCyan
completed_color = DarkGray
overdue_color = Red

[columns]
column_width = 40
column_file = ~/.topsdo_columns
column_format = %I %x %{(}p{)} %s %k %{(}h{)}
focus_background = DarkCyan
cursor_background = DarkGray
mark_background = DarkMagenta

[column_keymap]
<Up> = up
k = up
<Down> = down
j = down
<Left> = prev_column
h = prev_column
<Right> = next_column
l = next_column
<Tab> = next_column
<S-Tab> = prev_column
gg = home
<Home> = home
G = end
<End> = end
<PgUp> = page_up
<C-b> = page_up
<PgDn> = page_down
<C-f> = page_down
<C-u> = half_page_up
<C-d> = half_page_down
0 = first_column
$ = last_column
x = cmd do {}
d = cmd del {}
e = cmd edit {}
u = cmd revert
pp = postpone
ps = postpone_s
pr = pri
pd = cmd depri {}
m = mark
<Space> = mark
<C-a> = mark_all
<Esc> = reset
a = add
A = append
t = tag
: = command_line
/ = search
. = repeat
<Enter> = details
N = new_column
E = edit_column
C = copy_column
D = delete_column
< = swap_left
> = swap_right
r = reload
<F5> = reload
? = help
q = quit

[aliases]
'@

function New-TdOrderedDict {
    # Ordinal (case-sensitive) ordered dictionary.
    New-Object System.Collections.Specialized.OrderedDictionary
}

function ConvertFrom-TdIni {
    param([string[]]$Lines, [string[]]$CaseSensitiveSections = @('column_keymap', 'aliases'))
    $result = New-TdOrderedDict
    $section = $null
    foreach ($raw in $Lines) {
        if ($null -eq $raw) { continue }
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#', [StringComparison]::Ordinal) -or $line.StartsWith(';', [StringComparison]::Ordinal)) { continue }
        if ($line -match '^\[(.+)\]$') {
            $section = $Matches[1].Trim()
            if (-not $result.Contains($section)) { $result[$section] = New-TdOrderedDict }
            continue
        }
        if ($null -eq $section) { continue }
        $idx = $line.IndexOf([char]'=', 1)
        if ($idx -lt 1) { continue }
        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim()
        if ($CaseSensitiveSections -notcontains $section.ToLowerInvariant()) { $key = $key.ToLowerInvariant() }
        $result[$section][$key] = $val
    }
    return , $result
}

function Read-TdIniFile {
    param([string]$Path, [string[]]$CaseSensitiveSections = @('column_keymap', 'aliases'))
    $lines = [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)
    return , (ConvertFrom-TdIni -Lines $lines -CaseSensitiveSections $CaseSensitiveSections)
}

function Resolve-TdPath {
    param([string]$Path)
    if (-not $Path) { return $Path }
    if ($Path -eq '~') { $Path = $HOME }
    elseif ($Path.StartsWith('~/', [StringComparison]::Ordinal) -or $Path.StartsWith('~\', [StringComparison]::Ordinal)) { $Path = Join-Path $HOME $Path.Substring(2) }
    $Path = [Environment]::ExpandEnvironmentVariables($Path)
    return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Get-TdConfigCandidates {
    $list = New-Object System.Collections.Generic.List[string]
    $xdg = $env:XDG_CONFIG_HOME
    if (-not $xdg) { $xdg = Join-Path $HOME '.config' }
    $list.Add((Join-Path (Join-Path $xdg 'topsdo') 'config'))
    if ($env:APPDATA) { $list.Add((Join-Path (Join-Path $env:APPDATA 'topsdo') 'config')) }
    $list.Add((Join-Path $HOME '.topsdo'))
    $list.Add((Resolve-TdPath 'topsdo.conf'))
    $list.Add((Resolve-TdPath '.topsdo'))
    return $list.ToArray()
}

function Import-TdConfig {
    <#
      Builds the effective configuration: built-in defaults, overlaid by the
      config files found (or only the explicitly given one).
    #>
    param([string]$ConfigFile)
    $cfg = ConvertFrom-TdIni -Lines ($script:TdDefaultIni -split "`r?`n")
    # topydo compatibility: accept [topydo] as an alias for [topsdo]
    $files = @()
    if ($ConfigFile) {
        $p = Resolve-TdPath $ConfigFile
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "Config file not found: $p" }
        $files = @($p)
    }
    elseif ($env:TOPSDO_CONFIG) {
        $files = @(Resolve-TdPath $env:TOPSDO_CONFIG)
    }
    else {
        $files = @(Get-TdConfigCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
    }
    foreach ($f in $files) {
        $ini = Read-TdIniFile -Path $f
        foreach ($sec in @($ini.Keys)) {
            $target = $sec.ToLowerInvariant()
            if ($target -eq 'topydo') { $target = 'topsdo' }
            if (-not $cfg.Contains($target)) { $cfg[$target] = New-TdOrderedDict }
            foreach ($k in @($ini[$sec].Keys)) { $cfg[$target][$k] = $ini[$sec][$k] }
        }
    }
    $script:TdCfg = $cfg
    $script:TdConfigFiles = $files
    return , $cfg
}

function Get-TdOpt {
    param([string]$Section, [string]$Key, $Default = $null)
    $cfg = $script:TdCfg
    if ($null -ne $cfg -and $cfg.Contains($Section)) {
        $sec = $cfg[$Section]
        if ($sec.Contains($Key)) { return $sec[$Key] }
    }
    return $Default
}

function Get-TdOptBool {
    param([string]$Section, [string]$Key, [bool]$Default = $false)
    $v = Get-TdOpt $Section $Key $null
    if ($null -eq $v -or $v -eq '') { return $Default }
    return @('1', 'yes', 'true', 'on') -contains $v.ToString().ToLowerInvariant()
}

function Get-TdOptInt {
    param([string]$Section, [string]$Key, [int]$Default = 0)
    $v = Get-TdOpt $Section $Key $null
    $n = 0
    if ($null -ne $v -and [int]::TryParse($v, [ref]$n)) { return $n }
    return $Default
}

function Get-TdOptList {
    param([string]$Section, [string]$Key)
    $v = Get-TdOpt $Section $Key ''
    return @($v -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}

function Get-TdTagName {
    param([ValidateSet('due', 'start', 'rec', 'star')][string]$Kind)
    switch ($Kind) {
        'due' { return Get-TdOpt 'tags' 'tag_due' 'due' }
        'start' { return Get-TdOpt 'tags' 'tag_start' 't' }
        'rec' { return Get-TdOpt 'tags' 'tag_recurrence' 'rec' }
        'star' { return Get-TdOpt 'tags' 'tag_star' 'star' }
    }
}

function ConvertTo-TdColor {
    param([string]$Name)
    if (-not $Name) { return $null }
    # [Enum]::TryParse(Type, ...) is .NET Core only; this works in PS 5.1 too
    $n = $Name.Trim()
    foreach ($c in [Enum]::GetNames([ConsoleColor])) {
        if ([string]::Equals($c, $n, [StringComparison]::OrdinalIgnoreCase)) { return [ConsoleColor]$c }
    }
    return $null
}

function Get-TdPriorityColors {
    $map = @{}
    foreach ($pair in (Get-TdOptList 'colors' 'priority_colors')) {
        $kv = $pair -split ':', 2
        if ($kv.Count -eq 2) {
            $c = ConvertTo-TdColor $kv[1]
            if ($null -ne $c) { $map[$kv[0].Trim().ToUpperInvariant()] = $c }
        }
    }
    return $map
}
