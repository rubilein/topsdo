# topsdo - a todo.txt manager for PowerShell 5.1 and 7+, inspired by topydo.

$script:TdVersion = '1.0.0'
$script:TdCfg = $null
$script:TdTodayOverride = $null

foreach ($file in @('Config', 'Dates', 'Todo', 'TodoList', 'View', 'Core', 'Commands', 'LineEditor', 'Prompt', 'Columns')) {
    . (Join-Path (Join-Path $PSScriptRoot 'Private') "$file.ps1")
}

function Invoke-TopsdoCli {
    <#
    .SYNOPSIS
      Runs topsdo with an explicit argument list (used by topsdo.ps1).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string[]]$Arguments = @(),
        [switch]$NoColor
    )
    $argv = @($Arguments)
    $configFile = $null; $todoFile = $null; $doneFile = $null; $color = $null
    $i = 0
    while ($i -lt $argv.Count) {
        $a = $argv[$i]
        if (@('-c', '-t', '-d', '-C') -ccontains $a) {
            if ($i + 1 -ge $argv.Count) { [Console]::Error.WriteLine("Option $a requires a value."); $global:LASTEXITCODE = 2; return }
            $v = $argv[$i + 1]
            switch -CaseSensitive ($a) {
                '-c' { $configFile = $v }
                '-t' { $todoFile = $v }
                '-d' { $doneFile = $v }
                '-C' { $color = ($v -ne '0') }
            }
            $i += 2
            continue
        }
        if ($a -eq '-v' -or $a -eq '--version') { $argv = @('version'); $i = 0; break }
        if ($a -eq '-h' -or $a -eq '--help') { $argv = @('help'); $i = 0; break }
        break
    }
    $rest = @()
    if ($i -lt $argv.Count) { $rest = [string[]]$argv[$i..($argv.Count - 1)] }

    try { $ctx = New-TdContext -ConfigFile $configFile -TodoFile $todoFile -DoneFile $doneFile -Color $color }
    catch { [Console]::Error.WriteLine($_.Exception.Message); $global:LASTEXITCODE = 2; return }
    if ($null -eq $color) {
        $redirected = $false
        try { $redirected = [Console]::IsOutputRedirected } catch { }
        if ($NoColor -or $redirected) { $ctx.Color = $false }
    }
    Invoke-TdCommand $ctx $rest
    Send-TdOutput $ctx
    $global:LASTEXITCODE = $ctx.ExitCode
    foreach ($line in $ctx.Emitted) { $line }
}

function Invoke-Topsdo {
    <#
    .SYNOPSIS
      topsdo - todo.txt manager inspired by topydo (alias: topsdo).
    .DESCRIPTION
      Usage: topsdo [-c CONFIG] [-t TODO.TXT] [-d DONE.TXT] [-C 0|1] <command> [args]
      Run 'topsdo help' for the list of commands, 'topsdo prompt' for the
      interactive prompt and 'topsdo columns' for the column mode.
      Quote arguments containing @ ( ) < > so PowerShell passes them unchanged:
        topsdo add '(A) Call Bob @phone due:fri'
    #>
    # No param block on purpose: every word (also -x style options) ends up in $args.
    $piped = $MyInvocation.PipelinePosition -lt $MyInvocation.PipelineLength
    Invoke-TopsdoCli -Arguments (ConvertTo-TdArgList $args) -NoColor:$piped
}

function Get-TopsdoItem {
    <#
    .SYNOPSIS
      Returns todo items as objects for further processing in PowerShell.
    .EXAMPLE
      Get-TopsdoItem '+work' | Where-Object Due -lt (Get-Date)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Filter = '',
        [switch]$All,
        [string]$Path,
        [string]$ConfigFile
    )
    $ctx = New-TdContext -ConfigFile $ConfigFile -TodoFile $Path -Color $false
    $list = Get-TdCtxList $ctx
    $items = Select-TdTodos -List $list -Items $list.Items -Filters (ConvertTo-TdFilter (Split-TdCommandLine $Filter)) -ShowAll:$All
    $items = Sort-TdTodos -List $list -Items $items -Expression (Get-TdOpt 'sort' 'sort_string' '')
    foreach ($t in $items) {
        [pscustomobject]@{
            PSTypeName     = 'Topsdo.Item'
            Id             = $t.Uid
            Line           = $t.Number
            Priority       = $t.Priority
            Text           = $t.Text
            Completed      = $t.Completed
            CompletionDate = $(if ($t.CompletionDate) { ConvertTo-TdDate $t.CompletionDate } else { $null })
            CreationDate   = $(if ($t.CreationDate) { ConvertTo-TdDate $t.CreationDate } else { $null })
            Due            = $t.Due
            Start          = $t.Start
            Projects       = $t.Projects
            Contexts       = $t.Contexts
            Tags           = $t.Tags
            Importance     = Get-TdImportance $t
            Source         = Get-TdTodoSource $t
        }
    }
}

Set-Alias -Name topsdo -Value Invoke-Topsdo
Export-ModuleMember -Function Invoke-Topsdo, Invoke-TopsdoCli, Get-TopsdoItem -Alias topsdo
