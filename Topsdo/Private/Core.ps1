# Runtime context, output handling, tokenizing and command dispatch.

$script:TdIsWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows

function New-TdContext {
    param([string]$ConfigFile, [string]$TodoFile, [string]$DoneFile, $Color = $null)
    [void](Import-TdConfig -ConfigFile $ConfigFile)
    if ($TodoFile) { $script:TdCfg['topsdo']['filename'] = $TodoFile }
    if ($DoneFile) { $script:TdCfg['topsdo']['archive_filename'] = $DoneFile }
    $useColor = Get-TdOptBool 'topsdo' 'colors' $true
    if ($null -ne $Color) { $useColor = [bool]$Color }
    return @{
        TodoPath    = (Resolve-TdPath (Get-TdOpt 'topsdo' 'filename' 'todo.txt'))
        DonePath    = (Resolve-TdPath (Get-TdOpt 'topsdo' 'archive_filename' 'done.txt'))
        List        = $null
        Buffer      = (New-Object System.Collections.Generic.List[object])
        Mode        = 'cli'
        Color       = $useColor
        ExitCode    = 0
        Ui          = $null
        Emitted     = (New-Object System.Collections.Generic.List[string])
    }
}

function Get-TdCtxList {
    <# Returns the todo list, reloading it when the file changed on disk. #>
    param($Ctx)
    if ($null -eq $Ctx.List -or ($Ctx.List.Stamp -ne (Get-TdFileStamp $Ctx.TodoPath) -and -not $Ctx.List.Dirty)) {
        $Ctx.List = Read-TdList $Ctx.TodoPath
    }
    return $Ctx.List
}

# --- output -------------------------------------------------------------------

function Write-TdOut {
    param($Ctx, [string]$Text, $Todo = $null)
    $segs = $null
    if ($null -ne $Todo) { $segs = Get-TdSegments $Text $Todo }
    else { $segs = @(@{ T = $Text; F = $null }) }
    $Ctx.Buffer.Add(@{ Text = $Text; Segs = $segs; Error = $false })
}

function Write-TdErr {
    param($Ctx, [string]$Text)
    $Ctx.ExitCode = 1
    $Ctx.Buffer.Add(@{ Text = $Text; Segs = @(@{ T = $Text; F = [ConsoleColor]::Red }); Error = $true })
}

function Write-TdTodoLine {
    param($Ctx, $Todo, [string]$Prefix = '', [string]$Format)
    if (-not $Format) { $Format = Get-TdOpt 'ls' 'list_format' '%I %x %{(}p{)} %s %k %{(}h{)}' }
    $w = 1
    if ($null -ne $Ctx.List) { $w = Get-TdIdWidth $Ctx.List.Items }
    Write-TdOut $Ctx ($Prefix + (Format-TdTodo -Todo $Todo -Format $Format -IdWidth $w)) $Todo
}

function Write-TdSegmentsToHost {
    param($Segs)
    foreach ($s in $Segs) {
        if ($null -ne $s.F) { Write-Host -NoNewline -ForegroundColor $s.F $s.T }
        else { Write-Host -NoNewline $s.T }
    }
    Write-Host ''
}

function Send-TdOutput {
    <#
      Flushes buffered output. Colored/prompt output goes to the host; plain
      CLI output is collected in $Ctx.Emitted so it can be piped.
    #>
    param($Ctx)
    foreach ($e in $Ctx.Buffer) {
        if ($e.Error) {
            if ($Ctx.Mode -eq 'cli' -and -not $Ctx.Color) { [Console]::Error.WriteLine($e.Text) }
            else { Write-Host -ForegroundColor Red $e.Text }
        }
        elseif ($Ctx.Mode -eq 'cli' -and -not $Ctx.Color) { $Ctx.Emitted.Add($e.Text) }
        elseif ($Ctx.Color) { Write-TdSegmentsToHost $e.Segs }
        else { Write-Host $e.Text }
    }
    $Ctx.Buffer.Clear()
}

function Read-TdConfirm {
    param($Ctx, [string]$Question)
    if ($null -ne $Ctx.AssumeYes) { return [bool]$Ctx.AssumeYes }
    if ($Ctx.Mode -eq 'columns') { return Read-TdColumnsConfirm $Ctx $Question }
    if ($Ctx.Color -or $Ctx.Mode -ne 'cli') { Send-TdOutput $Ctx }
    else {
        # plain CLI output is buffered for the pipeline; show context before asking
        foreach ($e in $Ctx.Buffer) { Write-Host $e.Text }
        $Ctx.Buffer.Clear()
    }
    $answer = Read-Host "$Question [y/N]"
    return ($answer -match '^\s*(y|yes|j|ja)\s*$')
}

# --- helpers --------------------------------------------------------------------

function Split-TdCommandLine {
    <# Shell-like splitting honoring single and double quotes. #>
    param([string]$Line)
    $tokens = New-Object System.Collections.Generic.List[string]
    if (-not $Line) { return , $tokens.ToArray() }
    $sb = New-Object System.Text.StringBuilder
    $quote = [char]0
    $inToken = $false
    foreach ($c in $Line.ToCharArray()) {
        if ($quote -ne [char]0) {
            if ($c -eq $quote) { $quote = [char]0 } else { [void]$sb.Append($c) }
        }
        elseif ($c -eq '"' -or $c -eq "'") { $quote = $c; $inToken = $true }
        elseif ([char]::IsWhiteSpace($c)) {
            if ($inToken) { $tokens.Add($sb.ToString()); [void]$sb.Clear(); $inToken = $false }
        }
        else { [void]$sb.Append($c); $inToken = $true }
    }
    if ($inToken) { $tokens.Add($sb.ToString()) }
    return , $tokens.ToArray()
}

function ConvertTo-TdArgList {
    <# Flattens PowerShell arguments (arrays from "1,2" become "1,2"). #>
    param($Arguments)
    $res = New-Object System.Collections.Generic.List[string]
    foreach ($a in @($Arguments)) {
        if ($null -eq $a) { continue }
        if ($a -is [array]) { $res.Add([string]::Join(',', @($a | ForEach-Object { "$_" }))) }
        else { $res.Add("$a") }
    }
    return , $res.ToArray()
}

function Split-TdOptions {
    <#
      Parses options. $Spec lists the option names, a trailing '=' marks
      options that take a value (e.g. '-n='). Options are case-sensitive.
      By default parsing stops at the first word that is not an option; with
      -Anywhere options may appear between other words. '--' ends options.
    #>
    param([string[]]$Argv, [string[]]$Spec, [switch]$Anywhere)
    $names = @($Spec | ForEach-Object { $_.TrimEnd('=') })
    $opts = New-Object System.Collections.Hashtable ([StringComparer]::Ordinal)
    $rest = New-Object System.Collections.Generic.List[string]
    $argv2 = @($Argv)
    $i = 0
    $parsing = $true
    while ($i -lt $argv2.Count) {
        $a = $argv2[$i]
        if ($parsing -and $a -eq '--') { $parsing = $false; $i++; continue }
        if (-not $parsing -or $names -cnotcontains $a) {
            $rest.Add($a)
            if (-not $Anywhere) { $parsing = $false }
            $i++
            continue
        }
        if ($Spec -ccontains "$a=") {
            if ($i + 1 -ge $argv2.Count) { throw "Option $a requires a value." }
            $opts[$a] = $argv2[$i + 1]; $i += 2
        }
        else { $opts[$a] = $true; $i++ }
    }
    return @{ Options = $opts; Rest = [string[]]$rest.ToArray() }
}

function Resolve-TdTodoIds {
    <# Resolves ids (also comma separated) to todo objects; throws on unknown ids. #>
    param($Ctx, [string[]]$Ids)
    $list = Get-TdCtxList $Ctx
    $res = New-Object System.Collections.Generic.List[object]
    foreach ($raw in $Ids) {
        foreach ($id in ($raw -split ',')) {
            if (-not $id.Trim()) { continue }
            $t = Find-TdTodo $list $id
            if ($null -eq $t) { throw "Invalid todo number given: $id" }
            if (-not $res.Contains($t)) { $res.Add($t) }
        }
    }
    if ($res.Count -eq 0) { throw 'No todo number given.' }
    return , $res.ToArray()
}

function Resolve-TdExpression {
    <# Todos matching a filter expression (used by -e options). #>
    param($Ctx, [string[]]$Words, [switch]$ShowAll)
    $list = Get-TdCtxList $Ctx
    $filters = ConvertTo-TdFilter $Words
    return , (Select-TdTodos -List $list -Items $list.Items -Filters $filters -ShowAll:$ShowAll)
}

function Invoke-TdEditor {
    param([string]$File)
    $ed = $env:TOPSDO_EDITOR
    if (-not $ed) { $ed = $env:VISUAL }
    if (-not $ed) { $ed = $env:EDITOR }
    if (-not $ed) {
        if ($script:TdIsWindows) { $ed = 'notepad.exe' }
        elseif (Get-Command nano -ErrorAction SilentlyContinue) { $ed = 'nano' }
        else { $ed = 'vi' }
    }
    $parts = Split-TdCommandLine $ed
    $exe = $parts[0]
    $edArgs = @()
    if ($parts.Count -gt 1) { $edArgs = $parts[1..($parts.Count - 1)] }
    # Start-Process keeps the editor attached to the console even when the
    # caller's output is captured.
    $quoted = @($edArgs) + @('"' + $File + '"')
    Start-Process -FilePath $exe -ArgumentList $quoted -Wait -NoNewWindow
}

function Invoke-TdArchive {
    <# Moves completed todos to the archive file. Returns the number moved. #>
    param($Ctx)
    $list = Get-TdCtxList $Ctx
    $done = @($list.Items | Where-Object { $_.Completed })
    if ($done.Count -eq 0) { return 0 }
    $archive = Read-TdList $Ctx.DonePath
    foreach ($t in $done) {
        [void]$list.Items.Remove($t)
        $archive.Items.Add($t)
    }
    Save-TdList $archive
    $list.Dirty = $true
    return $done.Count
}

# --- dispatch ---------------------------------------------------------------------

function Get-TdCommandName {
    param([string]$Name)
    $n = $Name.ToLowerInvariant()
    if ($script:TdCommandAliases.ContainsKey($n)) { $n = $script:TdCommandAliases[$n] }
    return $n
}

function Expand-TdAlias {
    param([string[]]$Tokens)
    $aliases = $null
    if ($script:TdCfg.Contains('aliases')) { $aliases = $script:TdCfg['aliases'] }
    $depth = 0
    while ($null -ne $aliases -and $Tokens.Count -gt 0 -and $aliases.Contains($Tokens[0]) -and $depth -lt 10) {
        $depth++
        $exp = Split-TdCommandLine $aliases[$Tokens[0]]
        $rest = @()
        if ($Tokens.Count -gt 1) { $rest = $Tokens[1..($Tokens.Count - 1)] }
        $new = New-Object System.Collections.Generic.List[string]
        $used = $false
        foreach ($e in $exp) {
            if ($e -eq '{}') { foreach ($r in $rest) { $new.Add($r) }; $used = $true }
            else { $new.Add($e) }
        }
        if (-not $used) { foreach ($r in $rest) { $new.Add($r) } }
        if ($new.Count -gt 0 -and $new[0] -eq $Tokens[0]) { $Tokens = $new.ToArray(); break }
        $Tokens = $new.ToArray()
    }
    return , $Tokens
}

function Invoke-TdCommand {
    <# Runs one command (tokens: name + arguments) against the context. #>
    param($Ctx, [string[]]$Tokens)
    $Tokens = @($Tokens)
    if ($Tokens.Count -eq 0) { $Tokens = Split-TdCommandLine (Get-TdOpt 'topsdo' 'default_command' 'ls') }
    $Tokens = Expand-TdAlias $Tokens
    if ($Tokens.Count -eq 0) { return }
    $name = Get-TdCommandName $Tokens[0]
    $argv = @()
    if ($Tokens.Count -gt 1) { $argv = [string[]]$Tokens[1..($Tokens.Count - 1)] }
    if (-not $script:TdCommands.Contains($name)) {
        Write-TdErr $Ctx "Unknown command: $($Tokens[0]). Try 'help'."
        return
    }
    $cmd = $script:TdCommands[$name]
    $before = $null
    if ($cmd.Mutating) {
        $before = @{ Todo = (Read-TdTextFile $Ctx.TodoPath); Done = (Read-TdTextFile $Ctx.DonePath) }
        # always start a mutating command from the file state on disk
        $Ctx.List = $null
    }
    try {
        $null = & $cmd.Fn $Ctx $argv
        if ($cmd.Mutating) {
            $list = Get-TdCtxList $Ctx
            if ($cmd.Archive -and (Get-TdOptBool 'topsdo' 'archive' $true)) { [void](Invoke-TdArchive $Ctx) }
            if ($list.Dirty) { Save-TdList $list }
        }
    }
    catch {
        Write-TdErr $Ctx $_.Exception.Message
        if ($cmd.Mutating) { $Ctx.List = $null }
    }
    if ($cmd.Mutating) {
        $afterTodo = Read-TdTextFile $Ctx.TodoPath
        $afterDone = Read-TdTextFile $Ctx.DonePath
        if ($afterTodo -ne $before.Todo -or $afterDone -ne $before.Done) {
            Push-TdBackup -Ctx $Ctx -Label ([string]::Join(' ', $Tokens)) -TodoText $before.Todo -DoneText $before.Done
        }
    }
}

function Invoke-TdCommandLine {
    param($Ctx, [string]$Line)
    Invoke-TdCommand $Ctx (Split-TdCommandLine $Line)
}
