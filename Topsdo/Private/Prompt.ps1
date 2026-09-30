# Prompt mode: an interactive shell for topsdo commands.

function Get-TdCompletions {
    <# Completion candidates for the word before the cursor. #>
    param($Ctx, [string]$Before)
    $start = $Before.LastIndexOf(' ') + 1
    $word = $Before.Substring($start)
    $head = $Before.Substring(0, $start).Trim()
    $cands = New-Object System.Collections.Generic.List[string]
    if ($head -eq '') {
        foreach ($k in $script:TdCommands.Keys) { $cands.Add($k) }
        foreach ($k in $script:TdCommandAliases.Keys) { $cands.Add($k) }
        if ($script:TdCfg.Contains('aliases')) { foreach ($k in $script:TdCfg['aliases'].Keys) { $cands.Add($k) } }
        if ($Ctx.Mode -eq 'prompt') { $cands.Add('exit'); $cands.Add('quit') }
    }
    else {
        $list = $null
        try { $list = Get-TdCtxList $Ctx } catch { }
        $firstWord = (Split-TdCommandLine $head)[0]
        if ($word.StartsWith('+') -and $null -ne $list) {
            foreach ($t in $list.Items) { foreach ($p in $t.Projects) { if (-not $cands.Contains("+$p")) { $cands.Add("+$p") } } }
        }
        elseif ($word.StartsWith('@') -and $null -ne $list) {
            foreach ($t in $list.Items) { foreach ($c in $t.Contexts) { if (-not $cands.Contains("@$c")) { $cands.Add("@$c") } } }
        }
        elseif ($word -match '^([^\s:]+):') {
            $key = $Matches[1]
            if ($key -eq (Get-TdTagName 'due') -or $key -eq (Get-TdTagName 'start')) {
                foreach ($d in @('today', 'tomorrow', 'mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun', '1d', '2d', '1w', '2w', '1m', '3m', '1y')) {
                    $cands.Add("${key}:$d")
                }
            }
        }
        elseif ($firstWord -eq 'help') {
            foreach ($k in $script:TdCommands.Keys) { $cands.Add($k) }
        }
        elseif ($firstWord -eq 'dep' -and $head -eq 'dep') {
            foreach ($k in @('add', 'rm', 'ls', 'clean')) { $cands.Add($k) }
        }
    }
    $res = @($cands | Where-Object { $_.StartsWith($word, [StringComparison]::OrdinalIgnoreCase) } | Sort-Object -Unique)
    return @{ Start = $start; Items = [string[]]$res }
}

function Get-TdHistoryPath {
    $p = Get-TdOpt 'topsdo' 'history_file' '~/.topsdo_history'
    return Resolve-TdPath $p
}

function Start-TdPrompt {
    param($Ctx)
    $Ctx.Mode = 'prompt'
    $interactive = Test-TdInteractiveConsole
    $history = New-Object System.Collections.Generic.List[string]
    $histPath = Get-TdHistoryPath
    if ($interactive -and (Test-Path -LiteralPath $histPath -PathType Leaf)) {
        foreach ($l in [IO.File]::ReadAllLines($histPath)) { if ($l.Trim()) { $history.Add($l) } }
    }
    if ($interactive) {
        Write-Host "topsdo $script:TdVersion - prompt mode. 'help' lists commands, 'exit' or Ctrl+D quits." -ForegroundColor DarkGray
    }
    while ($true) {
        $line = Read-TdLine -Prompt 'topsdo> ' -History $history -Ctx $Ctx -PromptColor ([ConsoleColor]::Green)
        if ($interactive) { [Console]::WriteLine() }
        if ($null -eq $line) { break }
        $line = $line.Trim()
        if ($line -eq '') { continue }
        if ($line -eq 'exit' -or $line -eq 'quit' -or $line -eq 'q') { break }
        if ($history.Count -eq 0 -or $history[$history.Count - 1] -ne $line) { $history.Add($line) }
        $tokens = Split-TdCommandLine $line
        if ((Get-TdCommandName $tokens[0]) -eq 'columns') {
            try {
                $o = Split-TdOptions ([string[]](Get-TdArgRest $tokens 1)) @('-l=')
                Start-TdColumns -Ctx $Ctx -ColumnFile $o.Options['-l']
            }
            catch { Write-TdErr $Ctx $_.Exception.Message }
            $Ctx.Mode = 'prompt'
        }
        else {
            Invoke-TdCommand $Ctx $tokens
        }
        Send-TdOutput $Ctx
    }
    if ($interactive) {
        try {
            $keep = @($history | Select-Object -Last 500)
            Write-TdTextFile $histPath ([string]::Join("`n", $keep) + "`n")
        }
        catch { }
    }
    $Ctx.ExitCode = 0
}
