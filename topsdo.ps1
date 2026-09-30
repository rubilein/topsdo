#!/usr/bin/env pwsh
# topsdo launcher: works with Windows PowerShell 5.1 and PowerShell 7+.
#   .\topsdo.ps1 add '(A) Call Bob @phone due:fri'
#   .\topsdo.ps1 ls
#   .\topsdo.ps1 prompt
#   .\topsdo.ps1 columns
# No param block on purpose: options like -x must reach topsdo unchanged.
Import-Module (Join-Path (Join-Path $PSScriptRoot 'Topsdo') 'Topsdo.psd1') -Force -DisableNameChecking
$tdArgs = @()
foreach ($a in $args) {
    if ($a -is [array]) { $tdArgs += , ([string]::Join(',', @($a | ForEach-Object { "$_" }))) } else { $tdArgs += , "$a" }
}
$piped = $MyInvocation.PipelinePosition -lt $MyInvocation.PipelineLength
Invoke-TopsdoCli -Arguments $tdArgs -NoColor:$piped
exit $LASTEXITCODE
