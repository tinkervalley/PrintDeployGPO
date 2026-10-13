#requires -Version 5.1
# Construct real Windows Forms controls without displaying dialogs or changing printers.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
if ($env:OS -ne 'Windows_NT') { throw 'GUI smoke tests require Windows.' }
if ($PSVersionTable.PSEdition -ne 'Desktop' -or $PSVersionTable.PSVersion.Major -ne 5) { throw 'Run GUI smoke tests with Windows PowerShell 5.1.' }
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'Modules\PrinterDeployment.Gui.psm1') -Force
function Assert-Gui {
    param($Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}
function Get-GuiChildren {
    param([System.Windows.Forms.Control]$Parent)
    foreach ($child in $Parent.Controls) { $child; Get-GuiChildren $child }
}
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('pdt-gui-' + [guid]::NewGuid().ToString('N'))
$forms = New-Object 'System.Collections.Generic.List[System.Windows.Forms.Form]'
try {
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    $fresh = @(New-PDConfigurationForm -ConfigPath (Join-Path $tempRoot 'missing.json') -SourceRoot $projectRoot)
    Assert-Gui ($fresh.Count -eq 1 -and $fresh[0] -is [System.Windows.Forms.Form]) 'Fresh GUI construction emitted values other than its Form.'
    $form = $fresh[0]; $forms.Add($form)
    $children = @(Get-GuiChildren $form)
    $tabs = @($children | Where-Object { $_ -is [System.Windows.Forms.TabPage] })
    Assert-Gui ('Clients and inventories' -in $tabs.Text -and 'Printers' -in $tabs.Text -and 'GPO deployment' -in $tabs.Text) 'Main GUI tabs are missing.'
    Write-Host 'PASS Fresh configuration GUI constructs with a single Form result.'

    $status = New-PDLabel 'Test status'
    $data = @{ Config=(New-PDConfiguration); Root=$tempRoot; Dirty=$false }
    $clientPanel = @(New-PDClientsPanel -Data $data -Owner $form -StatusLabel $status)
    Assert-Gui ($clientPanel.Count -eq 1 -and $clientPanel[0] -is [System.Windows.Forms.TableLayoutPanel]) 'Client panel factory leaked collection indexes into its return value.'
    # Reproduce the exact failing usage: Controls.Add accepts the factory's single control.
    $form.Controls.Add($clientPanel[0])
    Assert-Gui ($clientPanel[0].RowStyles.Count -eq 4) 'Client panel layout did not initialize.'
    Write-Host 'PASS Client panel can be added to a real Windows Forms control collection.'

    $editorResult = @(New-PDPrinterEditorForm -Root $tempRoot -Architecture x64 -Owner $form)
    Assert-Gui ($editorResult.Count -eq 1 -and $editorResult[0] -is [System.Windows.Forms.Form]) 'Printer editor emitted values other than its Form.'
    $editor = $editorResult[0]; $forms.Add($editor)
    $editorChildren = @(Get-GuiChildren $editor)
    $kind = @($editorChildren | Where-Object { $_ -is [System.Windows.Forms.ComboBox] -and $_.Items.Contains('Type4') })[0]
    $port = @($editorChildren | Where-Object { $_ -is [System.Windows.Forms.NumericUpDown] })[0]
    Assert-Gui (-not $port.Enabled) 'IPP mode did not disable RAW port controls.'
    $kind.SelectedItem = 'Type4'
    Assert-Gui ($port.Enabled) 'Type 4 mode did not enable RAW port controls.'
    Write-Host 'PASS Printer editor constructs and switches between IPP and Type 4.'

    $config = New-PDConfiguration
    $sample = Read-PDConfiguration (Join-Path $projectRoot 'examples\printers.ipp.json')
    $config.Printers = @($sample.Printers)
    $configPath = Join-Path $tempRoot 'printers.json'
    Write-PDJson $config $configPath
    $loaded = @(New-PDConfigurationForm -ConfigPath $configPath -SourceRoot $projectRoot)
    Assert-Gui ($loaded.Count -eq 1 -and $loaded[0] -is [System.Windows.Forms.Form]) 'Existing-config GUI did not return a single Form.'
    $forms.Add($loaded[0])
    $grids = @(Get-GuiChildren $loaded[0] | Where-Object { $_ -is [System.Windows.Forms.DataGridView] })
    Assert-Gui (@($grids | Where-Object { $_.Columns.Contains('Address') -and $_.Rows.Count -eq 1 }).Count -eq 1) 'Saved printer did not populate the main GUI.'
    Write-Host 'PASS Existing configuration populates the printer grid.'
    Write-Host 'All 4 Windows PowerShell GUI smoke checks passed.'
} finally {
    foreach ($form in $forms) { $form.Dispose() }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
