#requires -Version 5.1
<#
.SYNOPSIS
Configures or silently deploys machine-wide IPP and Type 4 printers.
.EXAMPLE
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\PrinterDeployment.ps1
.EXAMPLE
powershell.exe -NoProfile -NonInteractive -File .\PrinterDeployment.ps1 -Mode Deploy -ConfigPath \\server\Printers\printers.json -WhatIf
#>
[CmdletBinding()]
param(
    [ValidateSet('Configure', 'Deploy', 'Validate', 'CleanupUser')]
    [string]$Mode = 'Configure',
    [string]$ConfigPath,
    [switch]$WhatIf,
    [ValidateRange(1, 10)][int]$RetryCount = 3,
    [ValidateRange(0, 60)][int]$RetrySeconds = 20
)
$ErrorActionPreference = 'Stop'
try {
    # Resolve defaults after parameter binding, when the saved script's path is available.
    $scriptDirectory = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptDirectory)) {
        $scriptFile = $MyInvocation.MyCommand.Path
        if ([string]::IsNullOrWhiteSpace($scriptFile)) { throw 'Run the saved PrinterDeployment.ps1 file with -File, or use Launch-Configurator.cmd.' }
        $scriptDirectory = Split-Path -Parent $scriptFile
    }
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) { $ConfigPath = Join-Path $scriptDirectory 'printers.json' }
    $ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
    Import-Module (Join-Path $scriptDirectory 'Modules\PrinterDeployment.Core.psm1') -Force
    if ($Mode -eq 'Validate') {
        $config = Read-PDConfiguration -Path $ConfigPath
        Assert-PDConfiguration -Config $config -Root (Split-Path -Parent $ConfigPath)
        Write-Output 'Configuration and packaged driver models are valid.'
        exit 0
    }
    if ($env:OS -ne 'Windows_NT') { throw 'Configure, Deploy and CleanupUser require Windows.' }
    if (-not [Environment]::Is64BitProcess) { throw 'Use 64-bit Windows PowerShell (System32), not SysWOW64.' }
    if ($Mode -eq 'Configure') {
        if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') { throw 'Launch the GUI with powershell.exe -STA.' }
        Import-Module (Join-Path $scriptDirectory 'Modules\PrinterDeployment.Gui.psm1') -Force
        Show-PDConfiguration -ConfigPath $ConfigPath -SourceRoot $scriptDirectory
    } else {
        Import-Module (Join-Path $scriptDirectory 'Modules\PrinterDeployment.Deploy.psm1') -Force
        if ($Mode -eq 'CleanupUser') {
            Invoke-PDUserCleanup -ConfigPath $ConfigPath -WhatIf:$WhatIf
        } else {
            Invoke-PDDeployment -ConfigPath $ConfigPath -WhatIf:$WhatIf -RetryCount $RetryCount -RetrySeconds $RetrySeconds
        }
    }
    exit 0
} catch {
    Write-Error -ErrorRecord $_ -ErrorAction Continue
    exit 1
}
