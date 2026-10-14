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
function Invoke-GuiButton {
    param([System.Windows.Forms.Button]$Button)
    $method=$Button.GetType().GetMethod('OnClick',[Reflection.BindingFlags]'Instance,NonPublic')
    [void]$method.Invoke($Button,@([EventArgs]::Empty))
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
    Assert-Gui (@($children | Where-Object { $_ -is [System.Windows.Forms.ComboBox] -and $_.Items.Contains('ARM64') }).Count -eq 0) 'Global architecture selector remains.'
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
    Assert-Gui ($port.Enabled -and $port.Value -eq 9100) 'Type 4 mode did not use the RAW port default.'
    $kind.SelectedItem='Type3'
    Assert-Gui ($port.Enabled -and $port.Value -eq 9100) 'Type 3 RAW controls unavailable.'
    $kind.SelectedItem='IPP'
    Assert-Gui (-not $port.Enabled -and $port.Value -eq 631) 'Switching back to IPP changed its default port.'
    Write-Host 'PASS Printer editor constructs and switches between IPP and Type 4.'

    $newEditor=New-PDPrinterEditorForm -Root $tempRoot -Architecture x64 -Owner $form; $forms.Add($newEditor)
    $fields=@(Get-GuiChildren $newEditor)
    ($fields | Where-Object { $_.Name -eq 'PrinterName' }).Text='New IPP'
    ($fields | Where-Object { $_.Name -eq 'PrinterHost' }).Text='192.0.2.55'
    $protocol=($fields | Where-Object { $_.Name -eq 'IppProtocol' }); $protocol.SelectedItem='ipps'
    Assert-Gui (($fields | Where-Object { $_.Name -eq 'IppSubpath' }).Text -eq '/ipp') 'Default subpath missing.'
    Invoke-GuiButton ($fields | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text -eq 'Save printer' })
    Assert-Gui ($newEditor.Tag.Result.Address -eq 'ipps://192.0.2.55:631/ipp') 'GUI did not build the IPPS URL.'
    Write-Host 'PASS IPP editor saves an address from host/protocol/default subpath.'

    $sample=Read-PDConfiguration (Join-Path $projectRoot 'examples\printers.ipp.json')
    foreach ($savedAddress in @('ipp://PRINTER.example.com/ipp/print','ipps://printer.example.com:443/ipp/print','https://printer.example.com/ipp/print?queue=1')) {
        $sample.Printers[0].Address=$savedAddress
        $edit=New-PDPrinterEditorForm -Printer $sample.Printers[0] -Root $tempRoot -Architecture x64 -Owner $form; $forms.Add($edit)
        $fields=@(Get-GuiChildren $edit)
        Invoke-GuiButton ($fields | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text -eq 'Save printer' })
        Assert-Gui ($edit.Tag.Result.Address -ceq $savedAddress) 'Unchanged editing rewrote the saved URI.'
    }
    Write-Host 'PASS Existing IPP/custom-port/HTTPS addresses are preserved on unchanged edits.'

    $local=[pscustomobject]@{ Name='Computer queue'; Type='Local'; DriverName='Class'; PortName='IPP'; Location='' }
    $shared=[pscustomobject]@{ Name='\\domain\printer'; Type='Connection'; DriverName='Legacy'; PortName='UNC'; Location='' }
    $data.Config=New-PDConfiguration
    $machine=New-PDClientReport -Config $data.Config -Identity ([pscustomobject]@{ ComputerName='PC001'; Scope='Machine'; UserSid=''; UserName='SYSTEM' }) -After @($local) -Result Success -StartedAt (Get-Date -Format o)
    $user=New-PDClientReport -Config $data.Config -Identity ([pscustomobject]@{ ComputerName='PC001'; Scope='UserConnection'; UserSid='S-1-5-21-1-2-3-1001'; UserName='DOMAIN\Alice' }) -After @($local,$shared) -Result Success -StartedAt (Get-Date -Format o)
    Write-PDClientReport $tempRoot $machine; Write-PDClientReport $tempRoot $user
    $clientFields=@(Get-GuiChildren $clientPanel[0])
    Invoke-GuiButton ($clientFields | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text -eq 'Refresh computers' })
    $computerGrid=($clientFields | Where-Object { $_ -is [System.Windows.Forms.DataGridView] -and $_.Columns.Contains('Computer') })
    $printerGrid=($clientFields | Where-Object { $_ -is [System.Windows.Forms.DataGridView] -and $_.Columns.Contains('Remove') })
    Assert-Gui ($computerGrid.Rows.Count -eq 1 -and $printerGrid.Rows.Count -eq 2) 'Combined computer/user GUI did not deduplicate local queues.'
    $userRow=@($printerGrid.Rows | Where-Object { $_.Tag.Report.Scope -eq 'UserConnection' })[0]
    $userRow.Cells['Remove'].Value=$true
    Assert-Gui ($data.Config.ClientRemovals.Count -eq 1 -and $data.Config.ClientRemovals[0].UserSid -eq $user.UserSid) 'Combined inventory selection targeted the wrong context.'
    Write-Host 'PASS Combined inventory displays one computer and routes user removals correctly.'

    $driverFolder=Join-Path $tempRoot 'Drivers\test'; New-Item -Path $driverFolder -ItemType Directory -Force | Out-Null
    @'
[Version]
Class=Printer
ClassVer=4.0
[Manufacturer]
Vendor=Models,NTamd64,NTarm64
[Models.NTamd64]
"Shared model"=Install,ID
[Models.NTarm64]
"Shared model"=Install,ID
"ARM-only model"=Install,ARMID
'@ | Set-Content (Join-Path $driverFolder 'printer.inf') -Encoding Unicode
    $driverPrinter=[pscustomobject]@{ Name='ARM queue'; Kind='Type4'; Address='192.0.2.59'; PortNumber=9100; Location=''; Comment=''; PackagePath='Drivers\test'; InfPath='Drivers\test\printer.inf'; DriverName='ARM-only model' }
    $driverEditor=New-PDPrinterEditorForm -Printer $driverPrinter -Root $tempRoot -Owner $form; $forms.Add($driverEditor)
    $fields=@(Get-GuiChildren $driverEditor); $driverControl=($fields | Where-Object { $_.Name -eq 'DriverModel' }); $support=($fields | Where-Object { $_.Name -eq 'DriverSupport' })
    Assert-Gui ($driverControl.Items.Contains('Shared model') -and $driverControl.Items.Contains('ARM-only model') -and $support.Text -match 'ARM64' -and $support.Text -notmatch 'x64,') 'ARM-only driver support was not displayed.'
    $driverControl.SelectedItem='Shared model'
    Assert-Gui ($support.Text -match 'x64, ARM64') 'Driver selection did not update architecture support.'
    $connection=($fields | Where-Object { $_ -is [System.Windows.Forms.ComboBox] -and $_.Items.Contains('Type4') }); $connection.SelectedItem='IPP'; $connection.SelectedItem='Type4'
    Assert-Gui ($support.Text -match 'x64, ARM64') 'Connection switching lost the selected driver support label.'
    Invoke-GuiButton ($fields | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text -eq 'Save printer' })
    Assert-Gui ($driverEditor.Tag.Result.DriverName -eq 'Shared model') 'Detected driver could not be saved.'
    Write-Host 'PASS Driver editor detects both architectures and updates support for each selected model.'

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
    Write-Host 'All 8 Windows PowerShell GUI smoke checks passed.'
} finally {
    foreach ($form in $forms) { $form.Dispose() }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
