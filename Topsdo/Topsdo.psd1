@{
    RootModule           = 'Topsdo.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = '5b0f3c8e-7a57-4a55-9d0e-2f4b8f1f6c1d'
    Author               = 'topsdo contributors'
    Copyright            = '(c) topsdo contributors. GPL-3.0-or-later.'
    Description          = 'A todo.txt manager for PowerShell inspired by topydo: CLI, prompt mode and column mode.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @('Invoke-Topsdo', 'Invoke-TopsdoCli', 'Get-TopsdoItem')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @('topsdo')
    PrivateData          = @{
        PSData = @{
            Tags       = @('todo', 'todotxt', 'todo.txt', 'topydo', 'productivity', 'tui')
            LicenseUri = 'https://www.gnu.org/licenses/gpl-3.0.html'
        }
    }
}
