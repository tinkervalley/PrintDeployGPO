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
. (Join-Path $PSScriptRoot 'DiscoveryFixtures.ps1')
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
    $kind = @($editorChildren | Where-Object { $_ -is [System.Windows.Forms.ComboBox] -and $_.Items.Contains('IPP') })[0]
    $port = @($editorChildren | Where-Object { $_ -is [System.Windows.Forms.NumericUpDown] })[0]
    Assert-Gui (-not $port.Enabled) 'IPP mode did not disable RAW port controls.'
    $kind.SelectedItem = 'Type4'
    Assert-Gui ($port.Enabled -and $port.Value -eq 9100) 'Type 4 mode did not use the RAW port default.'
    $kind.SelectedItem='Type3'
    Assert-Gui ($port.Enabled -and $port.Value -eq 9100) 'Type 3 RAW controls unavailable.'
    $kind.SelectedItem='IPP'
    Assert-Gui (-not $port.Enabled -and $port.Value -eq 631) 'Switching back to IPP changed its default port.'
    Write-Host 'PASS Printer editor constructs and switches between IPP and Type 4.'

    $discovery=New-PDDiscoveryForm -Owner $form; $forms.Add($discovery)
    $discoveryFields=@(Get-GuiChildren $discovery)
    Assert-Gui (@($discoveryFields | Where-Object { $_.Name -eq 'DiscoveredPrinters' }).Count -eq 1 -and $null -eq $discovery.Tag.Scanner) 'Discovery dialog did not construct without scanning.'
    $catalog=New-Object PrintDeployGPO.Discovery.Catalog; $catalog.Add((New-DiscoveryAdvertisement '_ipps._tcp.local.' 443 'ipp/print'))
    $detected=$catalog.Printers()[0]
    $discoveryGrid=($discoveryFields | Where-Object { $_.Name -eq 'DiscoveredPrinters' })
    $row=$discoveryGrid.Rows.Add([object[]]@($detected.Name,'IPPS',$detected.Address,$detected.Port,$detected.Subpath,$detected.Model)); $discoveryGrid.Rows[$row].Tag=$detected; $discoveryGrid.Rows[$row].Selected=$true
    Invoke-GuiButton ($discoveryFields | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text -eq 'Use selected printer' })
    Assert-Gui ($discovery.Tag.Result.Address -eq $detected.Address -and $discovery.Tag.Result.Port -eq 443) 'Discovery picker lost the selected endpoint.'
    & $editor.Tag.ApplyDiscovery $detected
    Assert-Gui (($editorChildren | Where-Object { $_.Name -eq 'PrinterHost' }).Text -eq 'printer.local' -and ($editorChildren | Where-Object { $_.Name -eq 'IppProtocol' }).SelectedItem -eq 'ipps' -and ($editorChildren | Where-Object { $_.Name -eq 'IppSubpath' }).Text -eq '/ipp/print' -and $port.Value -eq 443 -and $port.Enabled) 'Discovery did not fill advertised IPPS host, path and custom port.'
    $catalog=New-Object PrintDeployGPO.Discovery.Catalog; $catalog.Add((New-DiscoveryAdvertisement '_pdl-datastream._tcp.local.' 9101))
    & $editor.Tag.ApplyDiscovery ($catalog.Printers()[0])
    Assert-Gui ($kind.SelectedItem -eq 'Type4' -and $port.Value -eq 9101 -and ($editorChildren | Where-Object { $_.Name -eq 'PrinterName' }).Text -eq 'Test. Printer') 'RAW discovery failed or changed the chosen queue name.'
    Write-Host 'PASS Discovery controls apply advertised IPPS and RAW endpoints without scanning or installing printers.'

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
    Assert-Gui ($computerGrid.Columns['Result'].HeaderText -eq 'Last run' -and $computerGrid.Columns['Configuration'].HeaderText -eq 'Configuration' -and $computerGrid.Rows[0].Cells['Result'].Value -eq 'Completed' -and $computerGrid.Rows[0].Cells['Configuration'].Value -eq 'Current') 'Run result and configuration revision were not independently displayed.'
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
    $driverPrinter=[pscustomobject]@{ Name='ARM queue'; Kind='Type4'; Address='192.0.2.59'; PortNumber=9100; Location=''; Comment=''; PackagePath='Drivers\test'; InfPath='Drivers\test\printer.inf'; DriverName='arm-ONLY MODEL' }
    $driverEditor=New-PDPrinterEditorForm -Printer $driverPrinter -Root $tempRoot -Owner $form; $forms.Add($driverEditor)
    $fields=@(Get-GuiChildren $driverEditor); $driverControl=($fields | Where-Object { $_.Name -eq 'DriverModel' }); $support=($fields | Where-Object { $_.Name -eq 'DriverSupport' })
    Assert-Gui ($driverControl.Items.Contains('Shared model') -and $driverControl.Items.Contains('ARM-only model') -and $support.Text -match 'ARM64' -and $support.Text -notmatch 'x64,') 'ARM-only driver support was not displayed.'
    $driverControl.SelectedItem='Shared model'
    Assert-Gui ($support.Text -match 'x64, ARM64') 'Driver selection did not update architecture support.'
    $connection=($fields | Where-Object { $_ -is [System.Windows.Forms.ComboBox] -and $_.Items.Contains('IPP') }); $connection.SelectedItem='IPP'; $connection.SelectedItem='Type4'
    Assert-Gui ($support.Text -match 'x64, ARM64') 'Connection switching lost the selected driver support label.'
    Invoke-GuiButton ($fields | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text -eq 'Save printer' })
    Assert-Gui ($driverEditor.Tag.Result.DriverName -eq 'Shared model') 'Detected driver could not be saved.'
    Write-Host 'PASS Driver editor detects both architectures and updates support for each selected model.'

    (Get-Content (Join-Path $driverFolder 'printer.inf') -Raw).Replace('ClassVer=4.0','') | Set-Content (Join-Path $driverFolder 'legacy.inf') -Encoding Unicode
    $nativePrinter=[pscustomobject]@{ Name='One native queue'; Kind='Type4'; Address='192.0.2.60'; PortNumber=9100; Location=''; Comment=''; PackagePath=''; InfPath=''; DriverName=''; DriverPackages=[pscustomobject]@{
        x64=[pscustomobject]@{ Kind='Type3'; PackagePath='Drivers\test'; InfPath='Drivers\test\legacy.inf'; DriverName='Shared model' }
        ARM64=[pscustomobject]@{ Kind='Type4'; PackagePath='Drivers\test'; InfPath='Drivers\test\printer.inf'; DriverName='ARM-only model' }
    } }
    $nativeEditor=New-PDPrinterEditorForm -Printer $nativePrinter -Root $tempRoot -Owner $form; $forms.Add($nativeEditor)
    $fields=@(Get-GuiChildren $nativeEditor); $target=($fields | Where-Object { $_.Name -eq 'DriverPackageTarget' }); $type=($fields | Where-Object { $_.Name -eq 'DriverPackageKind' }); $driver=($fields | Where-Object { $_.Name -eq 'DriverModel' })
    Assert-Gui ($target.SelectedItem -eq 'x64' -and $type.SelectedItem -eq 'Type3' -and $driver.Items.Count -eq 1) 'x64 package did not load or offered an ARM-only model.'
    $target.SelectedItem='ARM64'
    Assert-Gui ($type.SelectedItem -eq 'Type4' -and $driver.SelectedItem -eq 'ARM-only model') 'ARM64 package was overwritten by the x64 slot.'
    $driver.SelectedItem='Shared model'; $target.SelectedItem='x64'; $target.SelectedItem='ARM64'
    Assert-Gui ($driver.SelectedItem -eq 'Shared model' -and $nativePrinter.DriverPackages.ARM64.DriverName -eq 'ARM-only model') 'Switching slots lost edits or changed the original configuration before Save.'
    Invoke-GuiButton ($fields | Where-Object { $_ -is [System.Windows.Forms.Button] -and $_.Text -eq 'Save printer' })
    $saved=$nativeEditor.Tag.Result
    Assert-Gui ($saved.Name -eq $nativePrinter.Name -and $saved.DriverName -eq '' -and $saved.DriverPackages.x64.Kind -eq 'Type3' -and $saved.DriverPackages.ARM64.Kind -eq 'Type4' -and $saved.DriverPackages.ARM64.DriverName -eq 'Shared model') 'Saving did not preserve independent native driver packages on one queue.'
    Write-Host 'PASS One printer preserves separate x64 and ARM64 driver types, packages and selections.'

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
    Write-Host 'All 10 Windows PowerShell GUI smoke checks passed.'
} finally {
    foreach ($form in $forms) { $form.Dispose() }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
