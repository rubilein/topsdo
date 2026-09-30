# A small single-line editor with history and completion that works the same
# in Windows PowerShell 5.1 and PowerShell 7 on every platform.

function Test-TdInteractiveConsole {
    # The ISE has no real console (no ReadKey / cursor positioning).
    if ($Host.Name -eq 'Windows PowerShell ISE Host') { return $false }
    try {
        if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { return $false }
        [void][Console]::KeyAvailable
        return ([Console]::WindowWidth -gt 0)
    }
    catch { return $false }
}

function Get-TdCommonPrefix {
    param([string[]]$Words)
    if ($Words.Count -eq 0) { return '' }
    $p = $Words[0]
    foreach ($w in $Words) {
        $i = 0
        while ($i -lt $p.Length -and $i -lt $w.Length -and [char]::ToLowerInvariant($p[$i]) -eq [char]::ToLowerInvariant($w[$i])) { $i++ }
        $p = $p.Substring(0, $i)
    }
    return $p
}

function Write-TdAt {
    param([int]$X, [int]$Y, [string]$Text, $Fg = $null, $Bg = $null)
    try { [Console]::SetCursorPosition($X, $Y) } catch { return }
    if ($null -ne $Fg) { [Console]::ForegroundColor = $Fg }
    if ($null -ne $Bg) { [Console]::BackgroundColor = $Bg }
    [Console]::Write($Text)
    if ($null -ne $Fg -or $null -ne $Bg) { [Console]::ResetColor() }
}

$script:TdEditKeys = @('Escape', 'LeftArrow', 'RightArrow', 'Home', 'End', 'Backspace', 'Delete', 'UpArrow', 'DownArrow', 'Tab')

function Read-TdLine {
    <#
      Reads one line. Keys: Left/Right, Home/End (Ctrl+A/E), Backspace/Delete,
      Ctrl+U/K/W, Up/Down history, Tab completion, Enter. Esc cancels (returns
      $null) with -EscCancels, otherwise clears the line. Ctrl+D on an empty
      line returns $null. Ctrl+C returns $null.
    #>
    param(
        [string]$Prompt = '> ',
        [string]$Initial = '',
        $History = $null,
        $Ctx = $null,
        [switch]$EscCancels,
        [int]$Row = -1,
        $PromptColor = $null
    )
    if (-not (Test-TdInteractiveConsole)) {
        $redirected = $false
        try { $redirected = [Console]::IsInputRedirected -and $Host.Name -ne 'Windows PowerShell ISE Host' } catch { }
        if ($redirected) { return [Console]::In.ReadLine() }
        return Read-Host $Prompt.TrimEnd(' ', '>')
    }
    if ($Row -ge 0) { $top = $Row; $left = 0 } else { $top = [Console]::CursorTop; $left = [Console]::CursorLeft }
    $text = $Initial
    $pos = $text.Length
    $histIdx = -1
    if ($null -ne $History) { $histIdx = $History.Count }
    $saved = ''
    $cycle = $null
    $oldCtrlC = [Console]::TreatControlCAsInput
    [Console]::TreatControlCAsInput = $true
    try {
        while ($true) {
            # --- render (single line, scrolls horizontally) ---
            $width = [Console]::WindowWidth - $left - $Prompt.Length - 1
            if ($width -lt 5) { $width = 5 }
            $offset = 0
            if ($pos -ge $width) { $offset = $pos - $width + 1 }
            $visible = $text
            if ($offset -gt 0) { $visible = $text.Substring($offset) }
            if ($visible.Length -gt $width) { $visible = $visible.Substring(0, $width) }
            Write-TdAt $left $top $Prompt $PromptColor
            [Console]::Write($visible.PadRight($width))
            try { [Console]::SetCursorPosition($left + $Prompt.Length + $pos - $offset, $top) } catch { }

            $k = [Console]::ReadKey($true)
            $ctrl = ($k.Modifiers -band [ConsoleModifiers]::Control) -ne 0
            if ($k.Key -ne [ConsoleKey]::Tab) { $cycle = $null }
            if ($ctrl -and $k.Key -eq [ConsoleKey]::C) { return $null }
            if ($ctrl -and $k.Key -eq [ConsoleKey]::D) {
                if ($text -eq '') { return $null }
                if ($pos -lt $text.Length) { $text = $text.Remove($pos, 1) }
                continue
            }
            if ($ctrl -and $k.Key -eq [ConsoleKey]::A) { $pos = 0; continue }
            if ($ctrl -and $k.Key -eq [ConsoleKey]::E) { $pos = $text.Length; continue }
            if ($ctrl -and $k.Key -eq [ConsoleKey]::U) { $text = $text.Substring($pos); $pos = 0; continue }
            if ($ctrl -and $k.Key -eq [ConsoleKey]::K) { $text = $text.Substring(0, $pos); continue }
            if ($ctrl -and $k.Key -eq [ConsoleKey]::W) {
                $p = $pos
                while ($p -gt 0 -and $text[$p - 1] -eq ' ') { $p-- }
                while ($p -gt 0 -and $text[$p - 1] -ne ' ') { $p-- }
                $text = $text.Remove($p, $pos - $p); $pos = $p
                continue
            }
            switch ($k.Key) {
                'Enter' { return $text }
                'Escape' {
                    if ($EscCancels) { return $null }
                    $text = ''; $pos = 0
                    continue
                }
                'LeftArrow' { if ($pos -gt 0) { $pos-- }; continue }
                'RightArrow' { if ($pos -lt $text.Length) { $pos++ }; continue }
                'Home' { $pos = 0; continue }
                'End' { $pos = $text.Length; continue }
                'Backspace' { if ($pos -gt 0) { $text = $text.Remove($pos - 1, 1); $pos-- }; continue }
                'Delete' { if ($pos -lt $text.Length) { $text = $text.Remove($pos, 1) }; continue }
                'UpArrow' {
                    if ($null -ne $History -and $histIdx -gt 0) {
                        if ($histIdx -eq $History.Count) { $saved = $text }
                        $histIdx--; $text = $History[$histIdx]; $pos = $text.Length
                    }
                    continue
                }
                'DownArrow' {
                    if ($null -ne $History -and $histIdx -lt $History.Count) {
                        $histIdx++
                        if ($histIdx -eq $History.Count) { $text = $saved } else { $text = $History[$histIdx] }
                        $pos = $text.Length
                    }
                    continue
                }
                'Tab' {
                    if ($null -eq $Ctx) { continue }
                    if ($null -ne $cycle) {
                        $cycle.Index = ($cycle.Index + 1) % $cycle.Items.Count
                        $word = $cycle.Items[$cycle.Index]
                        $text = $cycle.Before + $word + $cycle.After
                        $pos = $cycle.Before.Length + $word.Length
                        continue
                    }
                    $c = Get-TdCompletions $Ctx $text.Substring(0, $pos)
                    if ($c.Items.Count -eq 0) { continue }
                    $before = $text.Substring(0, $c.Start)
                    $after = $text.Substring($pos)
                    $cur = $text.Substring($c.Start, $pos - $c.Start)
                    if ($c.Items.Count -eq 1) {
                        $word = $c.Items[0] + ' '
                        $text = $before + $word + $after; $pos = $before.Length + $word.Length
                        continue
                    }
                    $prefix = Get-TdCommonPrefix $c.Items
                    if ($prefix.Length -gt $cur.Length) {
                        $text = $before + $prefix + $after; $pos = $before.Length + $prefix.Length
                    }
                    else {
                        $cycle = @{ Items = $c.Items; Index = 0; Before = $before; After = $after }
                        $text = $before + $c.Items[0] + $after; $pos = $before.Length + $c.Items[0].Length
                    }
                    continue
                }
            }
            # 'continue' inside switch only leaves the switch, so skip handled keys here
            if ($script:TdEditKeys -contains $k.Key.ToString() -or $ctrl) { continue }
            $ch = $k.KeyChar
            if ([int]$ch -ge 32 -and [int]$ch -ne 127) { $text = $text.Insert($pos, [string]$ch); $pos++ }
        }
    }
    finally {
        [Console]::TreatControlCAsInput = $oldCtrlC
    }
}
