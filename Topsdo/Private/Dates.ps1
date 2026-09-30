# Date parsing, relative dates and human readable dates.

$script:TdInvariant = [Globalization.CultureInfo]::InvariantCulture

$script:TdWeekdays = @{
    mo = 1; mon = 1; monday = 1
    tu = 2; tue = 2; tues = 2; tuesday = 2
    we = 3; wed = 3; wednesday = 3
    th = 4; thu = 4; thur = 4; thurs = 4; thursday = 4
    fr = 5; fri = 5; friday = 5
    sa = 6; sat = 6; saturday = 6
    su = 0; sun = 0; sunday = 0
}

function Get-TdToday {
    if ($null -ne $script:TdTodayOverride) { return $script:TdTodayOverride }
    return [datetime]::Today
}

function ConvertTo-TdDate {
    param([string]$Text)
    if (-not $Text -or $Text -notmatch '^\d{4}-\d{2}-\d{2}$') { return $null }
    $d = [datetime]::MinValue
    if ([datetime]::TryParseExact($Text, 'yyyy-MM-dd', $script:TdInvariant, [Globalization.DateTimeStyles]::None, [ref]$d)) {
        return $d
    }
    return $null
}

function Format-TdDate {
    param($Date)
    if ($null -eq $Date) { return '' }
    return ([datetime]$Date).ToString('yyyy-MM-dd', $script:TdInvariant)
}

function Add-TdPeriod {
    param([datetime]$Date, [int]$Amount, [string]$Unit)
    switch ($Unit.ToLowerInvariant()) {
        'd' { return $Date.AddDays($Amount) }
        'w' { return $Date.AddDays(7 * $Amount) }
        'm' { return $Date.AddMonths($Amount) }
        'y' { return $Date.AddYears($Amount) }
        'b' {
            $step = 1
            if ($Amount -lt 0) { $step = -1 }
            $left = [Math]::Abs($Amount)
            $d = $Date
            while ($left -gt 0) {
                $d = $d.AddDays($step)
                if ($d.DayOfWeek -ne [DayOfWeek]::Saturday -and $d.DayOfWeek -ne [DayOfWeek]::Sunday) { $left-- }
            }
            return $d
        }
    }
    throw "Invalid period unit: $Unit"
}

function ConvertFrom-TdPeriod {
    <# Parses a pattern like 3d, -2w, +1m (leading + is returned as Strict). #>
    param([string]$Text)
    if ($Text -match '^(\+)?(-?\d*)([dwmyb])$') {
        $n = 1
        if ($Matches[2] -ne '' -and $Matches[2] -ne '-') { $n = [int]$Matches[2] }
        elseif ($Matches[2] -eq '-') { $n = -1 }
        return [pscustomobject]@{ Strict = ($Matches[1] -eq '+'); Amount = $n; Unit = $Matches[3].ToLowerInvariant() }
    }
    return $null
}

function Resolve-TdRelativeDate {
    <#
      Converts absolute (yyyy-mm-dd) and relative date expressions to a date:
      today/tod, tomorrow/tom, yesterday, weekday names (next occurrence),
      and periods like 3d, 2w, 1m, 1y, 5b (business days), optionally negative.
    #>
    param([string]$Text, $Offset = $null)
    if (-not $Text) { return $null }
    $today = Get-TdToday
    $base = $today
    if ($null -ne $Offset) { $base = [datetime]$Offset }
    $s = $Text.Trim().ToLowerInvariant()
    $abs = ConvertTo-TdDate $s
    if ($null -ne $abs) { return $abs }
    switch ($s) {
        { $_ -eq 'today' -or $_ -eq 'tod' } { return $today }
        { $_ -eq 'tomorrow' -or $_ -eq 'tom' } { return $today.AddDays(1) }
        { $_ -eq 'yesterday' } { return $today.AddDays(-1) }
    }
    if ($script:TdWeekdays.ContainsKey($s)) {
        $diff = ($script:TdWeekdays[$s] - [int]$today.DayOfWeek + 7) % 7
        if ($diff -eq 0) { $diff = 7 }
        return $today.AddDays($diff)
    }
    $p = ConvertFrom-TdPeriod $s
    if ($null -ne $p -and -not $p.Strict) { return Add-TdPeriod $base $p.Amount $p.Unit }
    return $null
}

function Get-TdHumanDate {
    param([datetime]$Date)
    $days = [int]($Date.Date - (Get-TdToday)).TotalDays
    if ($days -eq 0) { return 'today' }
    if ($days -eq 1) { return 'tomorrow' }
    if ($days -eq -1) { return 'yesterday' }
    $abs = [Math]::Abs($days)
    if ($abs -lt 14) { $n = "$abs days" }
    elseif ($abs -lt 60) { $n = '{0} weeks' -f [int][Math]::Round($abs / 7.0) }
    elseif ($abs -lt 365) {
        $m = [int][Math]::Round($abs / 30.44)
        $n = '{0} months' -f $m
    }
    else {
        $y = [Math]::Round($abs / 365.25, 1)
        $ys = $y.ToString($script:TdInvariant)
        if ($ys -eq '1') { $n = '1 year' } else { $n = "$ys years" }
    }
    if ($days -gt 0) { return "in $n" }
    return "$n ago"
}
