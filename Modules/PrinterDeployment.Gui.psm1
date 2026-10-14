Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'PrinterDeployment.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'PrinterDeployment.Clients.psm1')
Import-Module (Join-Path $PSScriptRoot 'PrinterDeployment.Discovery.psm1')

function New-PDLabel {
    param([string]$Text)
    $label = New-Object Windows.Forms.Label
    $label.Text = $Text; $label.AutoSize = $true; $label.Anchor = 'Left'; $label.Margin = '6,8,6,8'
    $label
}

function New-PDButton {
    param([string]$Text, [scriptblock]$Click)
    $button = New-Object Windows.Forms.Button
    $button.Text = $Text; $button.AutoSize = $true; $button.Height = 32; $button.Margin = '5,5,5,5'
    if ($Click) { $button.Add_Click($Click) }
    $button
}

function Show-PDError {
    param($ErrorRecord)
    [Windows.Forms.MessageBox]::Show($ErrorRecord.Exception.Message, 'Printer Deployment Tool', 'OK', 'Error') | Out-Null
}

function Copy-PDPackage {
    param([string]$Source, [string]$Destination)
    $sourceFull = [IO.Path]::GetFullPath($Source).TrimEnd('\','/')
    $destFull = [IO.Path]::GetFullPath($Destination).TrimEnd('\','/')
    if ($sourceFull -eq $destFull) { return }
    if ($destFull.StartsWith($sourceFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'The deployment folder cannot be inside the source driver package.' }
    $items = @(Get-Item -LiteralPath $sourceFull -Force) + @(Get-ChildItem -LiteralPath $sourceFull -Recurse -Force)
    if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Choose a package without symbolic links or junctions.' }
    if (Test-Path -LiteralPath $destFull) { throw "Package destination already exists: $destFull" }
    New-Item -ItemType Directory -Path (Split-Path -Parent $destFull) -Force | Out-Null
    Copy-Item -LiteralPath $sourceFull -Destination $destFull -Recurse -Force
}

function Get-PDStartupScript {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$DeploymentId)
    $id = [guid]::Empty
    if (-not [guid]::TryParse($DeploymentId, [ref]$id) -or $id -eq [guid]::Empty) { throw 'Startup export requires a valid deployment identity.' }
    if ($Root -match '["\r\n]') { throw 'Deployment folder must not contain quotes or line breaks.' }
    $rootLiteral = "'" + $Root.Replace("'", "''") + "'"
    $template = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'Templates\Install-PrinterDeploymentTask.ps1.template'))
    $template.Replace('__PDT_DEPLOYMENT_ID__', $id.ToString()).Replace('__PDT_ROOT_LITERAL__', $rootLiteral)
}

function Get-PDUserLogonScript {
    param([Parameter(Mandatory)][string]$Root)
    if ($Root -match '["\r\n]') { throw 'Deployment folder must not contain quotes or line breaks.' }
    $rootLiteral = "'" + $Root.Replace("'", "''") + "'"
    $template = [IO.File]::ReadAllText((Join-Path (Split-Path -Parent $PSScriptRoot) 'Templates\Report-UserPrinters.ps1.template'))
    $template.Replace('__PDT_ROOT_LITERAL__', $rootLiteral)
}

function Get-PDGpoGuide {
    param([string]$Root)
    if (-not $Root) { $Root = '\\server\share\Printers' }
    $scriptPath = $Root.TrimEnd('\','/') + '\PrinterDeployment.ps1'
    $configPath = $Root.TrimEnd('\','/') + '\printers.json'
    @"
1. Save deployment bundle in this UNC folder:
   $Root

2. Computer GPO > Policies > Windows Settings > Scripts > Startup > PowerShell Scripts.
   Use Show Files, copy Install-PrinterDeploymentTask.ps1, add it with parameters blank.
   This registers ONE scheduled task, running as SYSTEM.
   It installs computer printers, reports inventory and applies computer removals.
   Runs about one minute after registration/startup and daily at noon; failures retry.

3. User GPO > Policies > Windows Settings > Scripts > Logon > PowerShell Scripts.
   Use Show Files, copy Report-UserPrinters.ps1, add it with parameters blank.
   This runs as the signed-in user and creates NO scheduled task.
   It reports user printers and applies removals selected for that computer/user.
   Leave Advanced cleanup's legacy-name checkbox off for inventory alone.
   Enable 'Always wait for the network at computer startup and logon' where needed.

4. Clients and inventories: Refresh computers, select a computer, check unwanted queues.
   Save deployment bundle. Computer removals run at the next task; user removals at logon.
   Stop deploying a managed printer in the Printers tab before scheduling its removal.
   Disable the old printer GPO or it may add deleted connections again.

Permissions: computer accounts AND reporting users need SMB Change, with NTFS Read
on scripts/config/drivers and create-own-folder/write access only inside Client Logs.
Only administrators may modify the deployment bundle. Use Set public log access to
repair Client Logs permissions. Follow your organization's script-signing policy.

Existing task deployments need only the updated bundle and the user logon GPO script.
Printer edits do not require replacing either GPO script. If the folder changes,
re-export and replace both GPO copies. Removing the GPO does not delete the task.

Manual user inventory from the signed-in user's PowerShell:
& "$scriptPath" -Mode CleanupUser -ConfigPath "$configPath"

Preview computer changes from elevated PowerShell:
& "$scriptPath" -Mode Deploy -ConfigPath "$configPath" -WhatIf

IPP uses Microsoft IPP Class Driver. Type3/Type4 use signed extracted driver packages matching the client architecture. Incompatible driver selections are skipped; IPP runs on either architecture.
Windows Protected Print Mode blocks Type3/Type4 drivers; use a compatible policy.
Computer logs: %ProgramData%\PrinterDeploymentTool\<DeploymentId>\
User logs: %LOCALAPPDATA%\PrinterDeploymentTool\<DeploymentId>\

"@
}

function New-PDDiscoveryForm {
    param($Owner)
    Initialize-PDDiscovery
    $form=New-Object Windows.Forms.Form; $form.Text='Discover network printers'; $form.Size='1060,500'; $form.MinimumSize='850,420'; $form.StartPosition='CenterParent'; $form.Font=New-Object Drawing.Font('Segoe UI',10)
    $layout=New-Object Windows.Forms.TableLayoutPanel; $layout.Dock='Fill'; $layout.Padding='12,12,12,12'; $layout.ColumnCount=1; $layout.RowCount=4
    foreach ($style in @('AutoSize','Percent','AutoSize','AutoSize')) { [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle($style,100))) }
    $form.Controls.Add($layout)
    $hint=New-PDLabel 'Discovery searches the local network using Bonjour/mDNS. Other VLANs or printers without advertisements may need manual entry. Type3/Type4 drivers must still be selected manually.'; $hint.MaximumSize='1000,0'
    $layout.Controls.Add($hint,0,0)
    $grid=New-Object Windows.Forms.DataGridView; $grid.Name='DiscoveredPrinters'; $grid.Dock='Fill'; $grid.ReadOnly=$true; $grid.AllowUserToAddRows=$false; $grid.AllowUserToDeleteRows=$false; $grid.MultiSelect=$false; $grid.SelectionMode='FullRowSelect'; $grid.RowHeadersVisible=$false; $grid.AutoSizeColumnsMode='Fill'
    foreach ($column in @('Name','Protocol','Address','Port','Subpath','Model')) { [void]$grid.Columns.Add($column,$column) }
    $layout.Controls.Add($grid,0,1)
    $status=New-PDLabel 'Select Scan to search for advertised printers.'; $status.MaximumSize='1000,0'; $layout.Controls.Add($status,0,2)
    $buttons=New-Object Windows.Forms.FlowLayoutPanel; $buttons.AutoSize=$true; $layout.Controls.Add($buttons,0,3)
    $data=@{ Scanner=$null; Result=$null }; $form.Tag=$data
    $timer=New-Object Windows.Forms.Timer; $timer.Interval=100
    $scan=New-PDButton 'Scan again' $null
    $start={
        if ($data.Scanner) { $data.Scanner.Dispose() }
        $grid.Rows.Clear(); $scan.Enabled=$false; $status.Text='Searching the local network for advertised IPP, IPPS and RAW printers...'
        $data.Scanner=New-Object PrintDeployGPO.Discovery.Scan; $timer.Start()
    }.GetNewClosure()
    $timer.Add_Tick({
        if (-not $data.Scanner -or -not $data.Scanner.Work.IsCompleted) { return }
        $timer.Stop(); $scan.Enabled=$true
        try {
            $printers=$data.Scanner.Work.GetAwaiter().GetResult()
            foreach ($printer in $printers) { $index=$grid.Rows.Add([object[]]@($printer.Name,$printer.Protocol.ToUpperInvariant(),$printer.Address,$printer.Port,$(if ($printer.Protocol -ne 'raw') { $printer.Subpath } else { '' }),$printer.Model)); $grid.Rows[$index].Tag=$printer }
            $grid.ClearSelection()
            $status.Text=if ($grid.Rows.Count) { "$($grid.Rows.Count) advertised endpoints found. Select one to fill the editor." } else { 'No advertised printers found. Check Bonjour/mDNS, firewalls and network isolation, or enter the printer manually.' }
        } catch { $status.Text='Discovery failed: ' + $_.Exception.Message }
        finally { $data.Scanner.Dispose(); $data.Scanner=$null }
    }.GetNewClosure())
    $scan.Add_Click($start)
    $use=New-PDButton 'Use selected printer' ({
        if (-not $grid.SelectedRows.Count) { $status.Text='Select a detected printer first.'; return }
        $data.Result=$grid.SelectedRows[0].Tag; $form.DialogResult='OK'; $form.Close()
    }.GetNewClosure())
    $cancel=New-PDButton 'Cancel' $null; $cancel.DialogResult='Cancel'
    $buttons.Controls.AddRange(@($scan,$use,$cancel)); $form.AcceptButton=$use; $form.CancelButton=$cancel
    $form.Add_Shown($start)
    $form.Add_FormClosed({ $timer.Stop(); $timer.Dispose(); if ($data.Scanner) { $data.Scanner.Dispose(); $data.Scanner=$null } }.GetNewClosure())
    $form.Add_Disposed({ if ($data.Scanner) { $data.Scanner.Dispose(); $data.Scanner=$null }; $timer.Dispose() }.GetNewClosure())
    return $form
}

function Show-PDDiscovery {
    param($Owner)
    $form=New-PDDiscoveryForm -Owner $Owner
    try { if ($form.ShowDialog($Owner) -eq 'OK') { $form.Tag.Result } } finally { $form.Dispose() }
}

function New-PDPrinterEditorForm {
    param($Printer, [string]$Root, [string]$Architecture, $Owner)
    $dialog = New-Object Windows.Forms.Form
    $dialog.Text = if ($Printer) { 'Edit printer' } else { 'Add printer' }
    $dialog.Size = '820,670'; $dialog.MinimumSize = '740,650'; $dialog.StartPosition = 'CenterParent'
    $dialog.Font = New-Object Drawing.Font('Segoe UI', 10); $dialog.AutoScaleMode = 'Dpi'
    $layout = New-Object Windows.Forms.TableLayoutPanel
    $layout.Dock = 'Fill'; $layout.Padding = '14,14,14,14'; $layout.ColumnCount = 2; $layout.RowCount = 12
    [void]$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute', 175)))
    [void]$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
    for ($row = 0; $row -lt 12; $row++) { [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize'))) }
    $dialog.Controls.Add($layout)
    $name = New-Object Windows.Forms.TextBox; $name.Name = 'PrinterName'
    $kind = New-Object Windows.Forms.ComboBox; $kind.Name = 'ConnectionKind'; $kind.DropDownStyle = 'DropDownList'; $kind.Items.AddRange(@('IPP','Type4','Type3'))
    $address = New-Object Windows.Forms.TextBox; $address.Name = 'PrinterHost'
    $discover=New-PDButton 'Discover...' $null; $discover.Name='DiscoverPrinters'
    $addressPanel=New-Object Windows.Forms.TableLayoutPanel; $addressPanel.AutoSize=$true; $addressPanel.ColumnCount=2; [void]$addressPanel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent',100))); [void]$addressPanel.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('AutoSize'))); $address.Dock='Fill'; $addressPanel.Controls.Add($address,0,0); $addressPanel.Controls.Add($discover,1,0)
    $protocol = New-Object Windows.Forms.ComboBox; $protocol.Name = 'IppProtocol'; $protocol.DropDownStyle = 'DropDownList'; $protocol.Items.AddRange(@('ipp','ipps')); $protocol.SelectedIndex = 0
    $subpath = New-Object Windows.Forms.TextBox; $subpath.Name = 'IppSubpath'; $subpath.Text = '/ipp'
    $port = New-Object Windows.Forms.NumericUpDown; $port.Name = 'PrinterPort'; $port.Minimum = 1; $port.Maximum = 65535; $port.Value = 631
    $customPort = New-Object Windows.Forms.CheckBox; $customPort.Name = 'CustomIppPort'; $customPort.Text = 'Use custom port'; $customPort.AutoSize = $true
    $portPanel = New-Object Windows.Forms.FlowLayoutPanel; $portPanel.AutoSize = $true; $portPanel.Controls.AddRange(@($customPort, $port))
    $location = New-Object Windows.Forms.TextBox; $comment = New-Object Windows.Forms.TextBox
    $package = New-Object Windows.Forms.TextBox; $package.ReadOnly = $true
    $packageTarget = New-Object Windows.Forms.ComboBox; $packageTarget.Name='DriverPackageTarget'; $packageTarget.DropDownStyle='DropDownList'; $packageTarget.Items.AddRange(@('Shared/default','x64','ARM64')); $packageTarget.SelectedIndex=0
    $packageKind = New-Object Windows.Forms.ComboBox; $packageKind.Name='DriverPackageKind'; $packageKind.DropDownStyle='DropDownList'; $packageKind.Items.AddRange(@('Type4','Type3')); $packageKind.SelectedIndex=0
    $packagePanel=New-Object Windows.Forms.TableLayoutPanel; $packagePanel.AutoSize=$true; $packagePanel.ColumnCount=1; $packagePanel.RowCount=2
    $packageToolbar=New-Object Windows.Forms.FlowLayoutPanel; $packageToolbar.AutoSize=$true
    $packageToolbar.Controls.AddRange(@($packageTarget,$packageKind)); $packagePanel.Controls.Add($packageToolbar,0,0); $package.Dock='Fill'; $packagePanel.Controls.Add($package,0,1)
    $model = New-Object Windows.Forms.ComboBox; $model.Name = 'DriverModel'; $model.DropDownStyle = 'DropDownList'
    $hint = New-Object Windows.Forms.Label; $hint.Name = 'DriverSupport'; $hint.AutoSize = $true; $hint.MaximumSize = '590,0'
    $hint.Text = 'Enter an IP address or hostname. IPP/IPPS use port 631 automatically; enable a custom port if needed (for example 443). IPPS requires a trusted certificate matching the hostname.'
    $labels = @('Printer name', 'Connection type', 'IP address / hostname', 'IPP protocol', 'IPP subpath', 'Port', 'Location', 'Comment', 'Packaged INF', 'Detected driver name')
    $controls = @($name, $kind, $addressPanel, $protocol, $subpath, $portPanel, $location, $comment, $packagePanel, $model)
    $fieldLabels = @()
    for ($i = 0; $i -lt $controls.Count; $i++) {
        $fieldLabel = New-PDLabel $labels[$i]; $fieldLabels += $fieldLabel
        $layout.Controls.Add($fieldLabel, 0, $i)
        $controls[$i].Dock = 'Fill'; $controls[$i].Margin = '6,5,6,5'; $layout.Controls.Add($controls[$i], 1, $i)
    }
    $layout.Controls.Add($hint, 1, 10)
    $buttons = New-Object Windows.Forms.FlowLayoutPanel; $buttons.Dock = 'Fill'; $buttons.AutoSize = $true
    $layout.Controls.Add($buttons, 1, 11)
    # Mutable dialog data is captured by event-handler closures.
    $data = @{ PackagePath = ''; InfPath = ''; Result = $null; OriginalAddress = ''; OriginalParts = $null; TcpPort = 9100; IppPort = 631; PreviousKind = ''; DriverCatalog = @(); Slots=@{}; Target='Shared/default'; LoadingSlot=$false }
    $applyDiscovery={
        param($printer)
        if ([string]::IsNullOrWhiteSpace($name.Text)) { $name.Text=$printer.Name }
        if ([string]::IsNullOrWhiteSpace($location.Text)) { $location.Text=$printer.Location }
        $address.Text=$printer.Address
        if ($printer.Protocol -in @('ipp','ipps')) {
            $kind.SelectedItem='IPP'; $protocol.SelectedItem=$printer.Protocol; $subpath.Text=$printer.Subpath
            $customPort.Checked=$printer.Port -ne (Get-PDIppDefaultPort $printer.Protocol); $port.Value=$printer.Port; $data.IppPort=$printer.Port
        } else {
            if ($kind.SelectedItem -ne 'Type3') { $kind.SelectedItem='Type4' }
            $port.Value=$printer.Port; $data.TcpPort=$printer.Port
        }
    }.GetNewClosure()
    $data.ApplyDiscovery=$applyDiscovery
    $discover.Add_Click({ try { $printer=Show-PDDiscovery -Owner $dialog; if ($printer) { & $applyDiscovery $printer } } catch { Show-PDError $_ } }.GetNewClosure())
    $storeSlot = {
        if ($data.LoadingSlot) { return }
        $value = if ($data.Slots.ContainsKey($data.Target)) { $data.Slots[$data.Target] } else { [pscustomobject]@{ Kind='Type4'; PackagePath=''; InfPath=''; DriverName='' } }
        if (-not $value.PSObject.Properties['Kind']) { $value | Add-Member -NotePropertyName Kind -NotePropertyValue ([string]$kind.SelectedItem) }
        $value.Kind=[string]$packageKind.SelectedItem; $value.PackagePath=$data.PackagePath; $value.InfPath=$data.InfPath; $value.DriverName=[string]$model.SelectedItem
        $data.Slots[$data.Target]=$value
    }.GetNewClosure()
    $loadSlot = {
        $data.LoadingSlot=$true
        try {
            $value = if ($data.Slots.ContainsKey($data.Target)) { $data.Slots[$data.Target] } else { [pscustomobject]@{ Kind=[string]$kind.SelectedItem; PackagePath=''; InfPath=''; DriverName='' } }
            $selectedKind=if ($data.Target -eq 'Shared/default' -or -not $value.PSObject.Properties['Kind']) { [string]$kind.SelectedItem } else { $value.Kind }
            $packageKind.SelectedItem=$selectedKind; $packageKind.Enabled=$data.Target -ne 'Shared/default'
            $data.PackagePath=$value.PackagePath; $data.InfPath=$value.InfPath; $package.Text=$value.InfPath
            $model.Items.Clear(); $data.DriverCatalog=@()
            if ($value.InfPath) {
                try {
                    $data.DriverCatalog=@(Get-PDInfDriverCatalog (Resolve-PDResource $Root $value.InfPath) -DriverType ([int]$selectedKind.Substring(4)) | Where-Object { $data.Target -eq 'Shared/default' -or $data.Target -in $_.Architectures })
                    $model.Items.AddRange([object[]]@($data.DriverCatalog | ForEach-Object { $_.Name }))
                    $selected=@($data.DriverCatalog | Where-Object { $_.Name -eq $value.DriverName })
                    if ($selected.Count) { $model.SelectedItem=$selected[0].Name }
                    else { $hint.Text='Select a model compatible with this package target.' }
                } catch { $hint.Text='Package needs attention: ' + $_.Exception.Message }
            } else { $hint.Text='No package for ' + $data.Target + '. Import a package or use the shared/default fallback.' }
        } finally { $data.LoadingSlot=$false }
    }.GetNewClosure()
    $packageTarget.Add_SelectedIndexChanged({
        if ($data.LoadingSlot) { return }; & $storeSlot; $data.Target=[string]$packageTarget.SelectedItem; & $loadSlot
    }.GetNewClosure())
    $packageKind.Add_SelectedIndexChanged({
        if ($data.LoadingSlot) { return }
        $data.Slots[$data.Target]=[pscustomobject]@{ Kind=[string]$packageKind.SelectedItem; PackagePath=''; InfPath=''; DriverName='' }; & $loadSlot
    }.GetNewClosure())
    $clearPackage=New-PDButton 'Clear this package' ({
        $data.Slots[$data.Target]=[pscustomobject]@{ Kind=[string]$packageKind.SelectedItem; PackagePath=''; InfPath=''; DriverName='' }; & $loadSlot
    }.GetNewClosure())
    $packageToolbar.Controls.Add($clearPackage)
    $import = New-PDButton 'Import driver package...' $null
    $import.Add_Click({
        try {
            if (-not $Root -or -not (Test-Path -LiteralPath $Root -PathType Container)) { throw 'Choose the deployment folder first.' }
            $folder = New-Object Windows.Forms.FolderBrowserDialog
            $folder.Description = 'Choose the FULL extracted vendor package folder, including INF, CAT, manifests and all subfolders.'
            try { if ($folder.ShowDialog($dialog) -ne 'OK') { return }; $source = $folder.SelectedPath }
            finally { $folder.Dispose() }
            $choose = New-Object Windows.Forms.OpenFileDialog
            $choose.Title = 'Select the ' + $packageKind.SelectedItem + ' INF inside this package'; $choose.Filter = 'Driver INF (*.inf)|*.inf'; $choose.InitialDirectory = $source
            try { if ($choose.ShowDialog($dialog) -ne 'OK') { return }; $inf = $choose.FileName }
            finally { $choose.Dispose() }
            if (-not $inf.StartsWith($source.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Select an INF inside the package folder.' }
            $data.DriverCatalog = @(Get-PDInfDriverCatalog -Path $inf -DriverType ([int]([string]$packageKind.SelectedItem).Substring(4)) | Where-Object { $data.Target -eq 'Shared/default' -or $data.Target -in $_.Architectures })
            if (-not $data.DriverCatalog.Count) { throw 'This INF has no models for the selected package target.' }
            $models = @($data.DriverCatalog | ForEach-Object { $_.Name })
            $relativePackage = 'Drivers\' + [guid]::NewGuid().ToString('N')
            $destination = Resolve-PDResource $Root $relativePackage
            Copy-PDPackage $source $destination
            $data.PackagePath = $relativePackage
            $data.InfPath = $relativePackage + '\' + $inf.Substring($source.TrimEnd('\').Length + 1)
            $package.Text = $data.InfPath; $model.Items.Clear(); $model.Items.AddRange([object[]]$models); $model.SelectedIndex = 0; & $storeSlot
        } catch { Show-PDError $_ }
    }.GetNewClosure())
    $save = New-PDButton 'Save printer' $null
    $save.Add_Click({
        try {
            $printerAddress = $address.Text.Trim()
            if ($kind.SelectedItem -eq 'IPP') {
                $original = $data.OriginalParts
                # Preserve the exact saved URI on unchanged edits, so metadata changes do not recreate queues.
                if ($original -and $printerAddress -ceq $original.HostName -and [string]$protocol.SelectedItem -ceq $original.Protocol -and
                    $subpath.Text -ceq $original.Subpath -and [int]$port.Value -eq $original.PortNumber) {
                    $printerAddress = $data.OriginalAddress
                } else {
                    $printerAddress = New-PDIppAddress -HostName $printerAddress -Protocol $protocol.SelectedItem -Subpath $subpath.Text -PortNumber ([int]$port.Value)
                }
            }
            & $storeSlot
            $shared=if ($data.Slots.ContainsKey('Shared/default')) { $data.Slots['Shared/default'] } else { [pscustomobject]@{ PackagePath=''; InfPath=''; DriverName='' } }
            $result = [pscustomobject][ordered]@{
                Name = $name.Text.Trim(); Kind = [string]$kind.SelectedItem; Address = $printerAddress
                PortNumber = [int]$port.Value; Location = $location.Text.Trim(); Comment = $comment.Text.Trim()
                PackagePath = $shared.PackagePath; InfPath = $shared.InfPath; DriverName = $shared.DriverName
            }
            $variants=[ordered]@{}
            if ($result.Kind -ne 'IPP') { foreach ($target in @('x64','ARM64')) { if ($data.Slots.ContainsKey($target)) { $slot=$data.Slots[$target]; if ($slot.PackagePath -or $slot.InfPath -or $slot.DriverName) { $variants[$target]=$slot } } } }
            if ($variants.Count) { $result | Add-Member -NotePropertyName DriverPackages -NotePropertyValue ([pscustomobject]$variants) }
            $testConfig = New-PDConfiguration; if ($variants.Count) { $testConfig.SchemaVersion=2 }; $testConfig.Printers = @($result)
            Assert-PDConfiguration $testConfig $Root
            $data.Result = $result; $dialog.DialogResult = 'OK'; $dialog.Close()
        } catch { Show-PDError $_ }
    }.GetNewClosure())
    $cancel = New-PDButton 'Cancel' $null; $cancel.DialogResult = 'Cancel'
    $buttons.Controls.AddRange(@($import, $save, $cancel)); $dialog.AcceptButton = $save; $dialog.CancelButton = $cancel
    $kind.Add_SelectedIndexChanged({
        $tcp = $kind.SelectedItem -in @('Type3','Type4')
        if ($data.PreviousKind -in @('Type3','Type4')) { & $storeSlot }
        if ($tcp -and $data.PreviousKind -in @('Type3','Type4') -and $data.PreviousKind -ne [string]$kind.SelectedItem) { $data.Slots.Remove('Shared/default') }
        foreach ($row in @(3,4,8,9)) {
            $visible = if ($row -lt 5) { -not $tcp } else { $tcp }
            $controls[$row].Visible = $visible; $fieldLabels[$row].Visible = $visible
            $layout.RowStyles[$row].SizeType = if ($visible) { 'AutoSize' } else { 'Absolute' }; $layout.RowStyles[$row].Height = 0
        }
        if ($data.PreviousKind -eq 'IPP') { $data.IppPort = [int]$port.Value }
        elseif ($data.PreviousKind -in @('Type3','Type4')) { $data.TcpPort = [int]$port.Value }
        if ($tcp) { $port.Value = $data.TcpPort } else { $port.Value = $data.IppPort }
        $data.PreviousKind = [string]$kind.SelectedItem
        $protocol.Enabled = -not $tcp; $subpath.Enabled = -not $tcp; $customPort.Visible = -not $tcp
        if ($tcp) {
            $entry=@($data.DriverCatalog | Where-Object { $_.Name -eq [string]$model.SelectedItem })
            $hint.Text = if ($entry.Count) { 'Selected driver INF declares models for: ' + ($entry[0].Architectures -join ', ') + '. Windows still checks OS compatibility, binaries and signatures during installation.' }
                else { 'Import a package and select a driver to see its declared x64/ARM64 model support.' }
        }
        else { $hint.Text = 'IPP/IPPS work on x64 and ARM64 without a vendor driver package. Port 631 is automatic. IPPS requires a trusted certificate matching the hostname.' }
        $port.Enabled = $tcp -or $customPort.Checked; $model.Enabled = $tcp; $packagePanel.Enabled = $tcp; $import.Enabled = $tcp; $import.Visible = $tcp
        if ($tcp) { & $loadSlot }
    }.GetNewClosure())
    $customPort.Add_CheckedChanged({
        $port.Enabled = $kind.SelectedItem -in @('Type3','Type4') -or $customPort.Checked
        if ($kind.SelectedItem -eq 'IPP' -and -not $customPort.Checked) { $port.Value = Get-PDIppDefaultPort $protocol.SelectedItem }
    }.GetNewClosure())
    $protocol.Add_SelectedIndexChanged({
        if ($kind.SelectedItem -eq 'IPP' -and -not $customPort.Checked) { $port.Value = Get-PDIppDefaultPort $protocol.SelectedItem }
    }.GetNewClosure())
    $model.Add_SelectedIndexChanged({
        $entry=@($data.DriverCatalog | Where-Object { $_.Name -eq [string]$model.SelectedItem })
        if ($entry.Count) { $hint.Text = 'Selected driver INF declares models for: ' + ($entry[0].Architectures -join ', ') + '. Windows still checks OS compatibility, binaries and signatures during installation.' }
    }.GetNewClosure())
    $kind.SelectedIndex = 0
    if ($Printer) {
        $name.Text = $Printer.Name; $kind.SelectedItem = $Printer.Kind; $address.Text = $Printer.Address
        if ($Printer.Kind -eq 'IPP') {
            $parts = Split-PDIppAddress $Printer.Address
            $data.OriginalAddress = $Printer.Address; $data.OriginalParts = $parts
            # HTTP(S) remains available for existing configurations that use those schemes.
            if (-not $protocol.Items.Contains($parts.Protocol)) { [void]$protocol.Items.Add($parts.Protocol) }
            $address.Text = $parts.HostName; $protocol.SelectedItem = $parts.Protocol; $subpath.Text = $parts.Subpath
            $customPort.Checked = $parts.PortNumber -ne (Get-PDIppDefaultPort $parts.Protocol); $port.Value = $parts.PortNumber
        } else { $port.Value = $Printer.PortNumber }
        $location.Text = $Printer.Location; $comment.Text = $Printer.Comment
        $data.Slots['Shared/default']=[pscustomobject]@{ Kind=$Printer.Kind; PackagePath=$Printer.PackagePath; InfPath=$Printer.InfPath; DriverName=$Printer.DriverName }
        if ($Printer.PSObject.Properties['DriverPackages']) { foreach ($property in $Printer.DriverPackages.PSObject.Properties) { $data.Slots[$property.Name]=($property.Value | ConvertTo-Json -Depth 12 | ConvertFrom-Json) } }
        if ($Printer.Kind -in @('Type3','Type4')) {
            if (-not $Printer.DriverName) {
                $first=@('x64','ARM64' | Where-Object { $data.Slots.ContainsKey($_) })
                if ($first.Count) { $data.LoadingSlot=$true; $data.Target=$first[0]; $packageTarget.SelectedItem=$first[0]; $data.LoadingSlot=$false }
            }
            & $loadSlot
        }
    }
    $dialog.Tag = $data
    return $dialog
}

function Show-PDPrinterEditor {
    param($Printer, [string]$Root, [string]$Architecture, $Owner)
    $dialog = New-PDPrinterEditorForm -Printer $Printer -Root $Root -Architecture $Architecture -Owner $Owner
    try { if ($dialog.ShowDialog($Owner) -eq 'OK') { $dialog.Tag.Result } }
    finally { $dialog.Dispose() }
}

function Publish-PDBundle {
    param($Config, [string]$Root, [string]$SourceRoot)
    Assert-PDConfiguration $Config $Root
    foreach ($relative in @('PrinterDeployment.ps1','Launch-Configurator.cmd','README.md','printers.json','GPO-Setup.txt','Install-PrinterDeploymentTask.ps1','Report-UserPrinters.ps1',
        'Modules\PrinterDeployment.Core.psm1','Modules\PrinterDeployment.Deploy.psm1','Modules\PrinterDeployment.Gui.psm1','Modules\PrinterDeployment.Clients.psm1','Modules\PrinterDeployment.Discovery.psm1',
        'Templates\Install-PrinterDeploymentTask.ps1.template','Templates\Report-UserPrinters.ps1.template','Client Logs')) {
        [void](Resolve-PDResource $Root $relative)
    }
    $sourceFull = [IO.Path]::GetFullPath($SourceRoot).TrimEnd('\','/')
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $logFolder = Resolve-PDResource $rootFull 'Client Logs'
    $newLogFolder = -not (Test-Path -LiteralPath $logFolder)
    New-Item -ItemType Directory -Path $logFolder -Force | Out-Null
    if ($newLogFolder -and $env:OS -eq 'Windows_NT') { Set-PDClientLogPermissions $rootFull }
    if ($sourceFull -ne $rootFull) {
        foreach ($file in @('PrinterDeployment.ps1', 'Launch-Configurator.cmd', 'README.md')) {
            Copy-Item -LiteralPath (Join-Path $sourceFull $file) -Destination (Resolve-PDResource $rootFull $file) -Force
        }
        $moduleRoot = Join-Path $rootFull 'Modules'
        New-Item -Path $moduleRoot -ItemType Directory -Force | Out-Null
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $sourceFull 'Modules') -Filter '*.psm1')) {
            Copy-Item -LiteralPath $file.FullName -Destination (Resolve-PDResource $rootFull ('Modules\' + $file.Name)) -Force
        }
    }
    if ($sourceFull -ne $rootFull) {
        New-Item -Path (Join-Path $rootFull 'Templates') -ItemType Directory -Force | Out-Null
        foreach ($file in @('Install-PrinterDeploymentTask.ps1.template','Report-UserPrinters.ps1.template')) {
            Copy-Item -LiteralPath (Join-Path (Join-Path $sourceFull 'Templates') $file) -Destination (Resolve-PDResource $rootFull ('Templates\' + $file)) -Force
        }
    }
    # Publish config last; clients never see references to packages that have not been copied.
    Get-PDStartupScript -Root $rootFull -DeploymentId $Config.DeploymentId |
        Set-Content -LiteralPath (Resolve-PDResource $rootFull 'Install-PrinterDeploymentTask.ps1') -Encoding UTF8
    Get-PDUserLogonScript -Root $rootFull |
        Set-Content -LiteralPath (Resolve-PDResource $rootFull 'Report-UserPrinters.ps1') -Encoding UTF8
    Write-PDJson $Config (Resolve-PDResource $rootFull 'printers.json')
    Get-PDGpoGuide $rootFull | Set-Content -LiteralPath (Resolve-PDResource $rootFull 'GPO-Setup.txt') -Encoding UTF8
}

function New-PDClientsPanel {
    param([hashtable]$Data, $Owner, $StatusLabel)
    $view = @{ Loading=$false; Report=$null }
    $panel = New-Object Windows.Forms.TableLayoutPanel
    $panel.Dock='Fill'; $panel.ColumnCount=1; $panel.RowCount=4; $panel.Padding='10,10,10,10'
    foreach ($height in @(48,160,65)) { [void]$panel.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',$height))) }
    [void]$panel.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100)))
    $toolbar = New-Object Windows.Forms.FlowLayoutPanel; $toolbar.Dock='Fill'; $panel.Controls.Add($toolbar,0,0)
    $clients = New-Object Windows.Forms.DataGridView
    $clients.Dock='Fill'; $clients.ReadOnly=$true; $clients.AllowUserToAddRows=$false; $clients.RowHeadersVisible=$false
    $clients.MultiSelect=$false; $clients.SelectionMode='FullRowSelect'; $clients.AutoSizeColumnsMode='Fill'; $clients.BackgroundColor=[Drawing.Color]::White
    foreach ($spec in @(@('Computer','Computer',20),@('ReportedAt','Last report',20),@('Result','Status',30),@('Installed','Deployed',15),@('Users','User reports',15))) {
        $column = New-Object Windows.Forms.DataGridViewTextBoxColumn; $column.Name=$spec[0]; $column.HeaderText=$spec[1]; $column.FillWeight=$spec[2]
        [void]$clients.Columns.Add($column)
    }
    $panel.Controls.Add($clients,0,1)
    $detail = New-Object Windows.Forms.TextBox; $detail.Dock='Fill'; $detail.Multiline=$true; $detail.ReadOnly=$true; $detail.ScrollBars='Vertical'
    $detail.Text='Select a computer to see computer and user printers together. Check unwanted queues, then Save deployment bundle. User reporting requires the exported logon script.'
    $panel.Controls.Add($detail,0,2)
    $tabs = New-Object Windows.Forms.TabControl; $tabs.Dock='Fill'; $panel.Controls.Add($tabs,0,3)
    $inventoryTab = New-Object Windows.Forms.TabPage; $inventoryTab.Text='Reported printers'
    $requestsTab = New-Object Windows.Forms.TabPage; $requestsTab.Text='Removal requests'
    $tabs.TabPages.AddRange(@($inventoryTab,$requestsTab))
    $inventory = New-Object Windows.Forms.DataGridView
    $inventory.Dock='Fill'; $inventory.AllowUserToAddRows=$false; $inventory.AllowUserToDeleteRows=$false; $inventory.RowHeadersVisible=$false
    $inventory.AutoSizeColumnsMode='Fill'; $inventory.BackgroundColor=[Drawing.Color]::White
    $check = New-Object Windows.Forms.DataGridViewCheckBoxColumn; $check.Name='Remove'; $check.HeaderText='Remove'; $check.FillWeight=8
    [void]$inventory.Columns.Add($check)
    foreach ($spec in @(@('Name','Printer name',24),@('Owner','Installed for',16),@('Driver','Driver',20),@('Port','Port',16),@('Desired','Deployment',10),@('Request','Removal status',14))) {
        $column=New-Object Windows.Forms.DataGridViewTextBoxColumn; $column.Name=$spec[0]; $column.HeaderText=$spec[1]; $column.FillWeight=$spec[2]; $column.ReadOnly=$true
        [void]$inventory.Columns.Add($column)
    }
    $inventoryTab.Controls.Add($inventory)
    $requestsLayout = New-Object Windows.Forms.TableLayoutPanel; $requestsLayout.Dock='Fill'; $requestsLayout.ColumnCount=1; $requestsLayout.RowCount=2
    [void]$requestsLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent',100))); [void]$requestsLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute',44)))
    $requestsTab.Controls.Add($requestsLayout)
    $requests = New-Object Windows.Forms.DataGridView
    $requests.Dock='Fill'; $requests.ReadOnly=$true; $requests.AllowUserToAddRows=$false; $requests.RowHeadersVisible=$false
    $requests.MultiSelect=$false; $requests.SelectionMode='FullRowSelect'; $requests.AutoSizeColumnsMode='Fill'; $requests.BackgroundColor=[Drawing.Color]::White
    foreach ($spec in @(@('Name','Printer',28),@('Owner','Installed for',20),@('Status','Status',15),@('Message','Last result',37))) {
        $column=New-Object Windows.Forms.DataGridViewTextBoxColumn; $column.Name=$spec[0]; $column.HeaderText=$spec[1]; $column.FillWeight=$spec[2]; [void]$requests.Columns.Add($column)
    }
    $requestsLayout.Controls.Add($requests,0,0)
    $showReport = {
        $view.Loading=$true
        try {
            $inventory.Rows.Clear(); $requests.Rows.Clear()
            if (-not $view.Report) { return }
            $computer=$view.Report
            $wanted=@($Data.Config.Printers | ForEach-Object { $_.Name })
            foreach ($entry in @($computer.Printers)) {
                $report=$entry.Report; $p=$entry.Printer
                $pending=@(Get-PDClientRemovalRequests $Data.Config $report)
                $request=@($pending | Where-Object { $_.Name -eq $p.Name })
                $removalStatus=''
                if ($request.Count) {
                    $result=@($report.RemovalResults | Where-Object { $_.Id -eq $request[0].Id })
                    $removalStatus=if ($result.Count) { $result[0].Status } else { 'Pending next run' }
                }
                $desired=$p.Name -in $wanted
                $deployment=if ($desired) { 'Managed' } else { 'Extra' }
                if (-not $entry.CanRemove) { $removalStatus='Needs matching context report' }
                elseif ($desired) { $removalStatus='Remove from Printers first' }
                $index=$inventory.Rows.Add([object[]]@(($request.Count -gt 0),$p.Name,$entry.Owner,$p.DriverName,$p.PortName,$deployment,$removalStatus))
                $inventory.Rows[$index].Tag=$entry
                $inventory.Rows[$index].Cells['Remove'].ReadOnly=$desired -or -not $entry.CanRemove
                $inventory.Rows[$index].Cells['Remove'].ToolTipText=if ($desired) { 'Stop deploying this printer in the Printers tab before scheduling removal.' } else { 'Remove once on the next computer run or this user logon.' }
            }
            $details=@()
            foreach ($report in @($computer.Reports)) {
                $ownerText=if ($report.Scope -eq 'Machine') { 'Computer' } else { $report.UserName }
                $seen=([datetimeoffset]::Parse($report.ReportedAt)).LocalDateTime.ToString('yyyy-MM-dd HH:mm')
                $verification=@($report.ConfiguredPrinters | ForEach-Object { "$($_.Name): $($_.Status)" }) -join '; '
                $details += "$ownerText ($seen): $($report.Result). $($report.ErrorMessage) $($report.InventoryError) $verification"
                foreach ($request in @(Get-PDClientRemovalRequests $Data.Config $report)) {
                    $last=@($report.RemovalResults | Where-Object { $_.Id -eq $request.Id })
                    $status=if ($last.Count) { $last[0].Status } else { 'Pending next run' }
                    $message=if ($last.Count) { $last[0].Message } else { 'Applies on the next run for this computer/user.' }
                    $index=$requests.Rows.Add([object[]]@($request.Name,$ownerText,$status,$message)); $requests.Rows[$index].Tag=$request
                }
            }
            if ($computer.UserReportCount -eq 0) { $details += 'User printers are not reported yet. Add Report-UserPrinters.ps1 as a USER GPO logon script (no additional scheduled task).' }
            $detail.Text=$details -join "`r`n"
        } finally { $view.Loading=$false }
    }.GetNewClosure()
    $refresh = {
        try {
            if (-not $Data.Root) { throw 'Choose a deployment folder first.' }
            $view.Loading=$true; $view.Report=$null; $clients.Rows.Clear(); $inventory.Rows.Clear(); $requests.Rows.Clear()
            $reports=@(Get-PDClientReports -Root $Data.Root -DeploymentId $Data.Config.DeploymentId | Sort-Object ComputerName,Scope,UserName)
            $wanted=@($Data.Config.Printers | ForEach-Object { $_.Name }); $hash=Get-PDConfigurationHash $Data.Config
            $computers=@(Get-PDComputerInventory -Reports $reports)
            foreach ($computer in $computers) {
                $machine=$computer.MachineReport
                $result=if (@($computer.Reports | Where-Object { $_.Result -eq 'Failed' }).Count) { 'Failed' } else { 'Success' }
                $skipped=if ($machine) { @($machine.ConfiguredPrinters | Where-Object { $_.Status -eq 'Unsupported architecture' }).Count } else { 0 }
                if ($skipped) { $result += " / $skipped architecture skipped" }
                if (-not $machine) { $result += ' / no computer report' }
                if ($computer.UserReportCount -eq 0) { $result += ' / user inventory missing' }
                if (@($computer.Reports | Where-Object { $_.ConfigurationHash -ne $hash }).Count) { $result += ' / changes pending' }
                $desired='No report'
                if ($machine) {
                    $installed=@($machine.ConfiguredPrinters | Where-Object { $_.Status -eq 'Installed' }).Count
                    $desired="$installed/$(@($machine.ConfiguredPrinters).Count)"
                }
                $latest=@($computer.Reports | Sort-Object { [datetimeoffset]::Parse($_.ReportedAt) } -Descending)[0]
                $seen=([datetimeoffset]::Parse($latest.ReportedAt)).LocalDateTime.ToString('yyyy-MM-dd HH:mm')
                $index=$clients.Rows.Add([object[]]@($computer.ComputerName,$seen,$result,$desired,$computer.UserReportCount)); $clients.Rows[$index].Tag=$computer
                if ($result.StartsWith('Failed')) { $clients.Rows[$index].DefaultCellStyle.ForeColor=[Drawing.Color]::Firebrick }
            }
            $StatusLabel.Text="$($computers.Count) computers loaded. Select a computer to review all reported printers."
        } catch { Show-PDError $_ }
        finally { $view.Loading=$false }
        if ($clients.Rows.Count) { $clients.Rows[0].Selected=$true; $view.Report=$clients.Rows[0].Tag; & $showReport }
    }.GetNewClosure()
    $clients.Add_SelectionChanged({
        if ($view.Loading -or $clients.SelectedRows.Count -ne 1) { return }
        $view.Report=$clients.SelectedRows[0].Tag; & $showReport
    }.GetNewClosure())
    $inventory.Add_CurrentCellDirtyStateChanged({ if ($inventory.IsCurrentCellDirty) { [void]$inventory.CommitEdit([Windows.Forms.DataGridViewDataErrorContexts]::Commit) } }.GetNewClosure())
    $inventory.Add_CellValueChanged({
        param($sender,$eventArgs)
        if ($view.Loading -or -not $view.Report -or $eventArgs.RowIndex -lt 0 -or $eventArgs.ColumnIndex -ne 0) { return }
        try {
            $row=$inventory.Rows[$eventArgs.RowIndex]
            Set-PDClientRemovalSelection -Config $Data.Config -Report $row.Tag.Report -Printer $row.Tag.Printer -Selected ([bool]$row.Cells['Remove'].Value)
            $Data.Dirty=$true; $StatusLabel.Text='Removal selections changed. Save deployment bundle to apply them on the next client run.'
        } catch { Show-PDError $_ }
        # Let the checkbox edit event finish before rebuilding rows.
        if ($Owner.IsHandleCreated -and -not $Owner.IsDisposed) { [void]$Owner.BeginInvoke([Windows.Forms.MethodInvoker]$showReport) }
    }.GetNewClosure())
    $reload=New-PDButton 'Refresh computers' $refresh
    $permissions=New-PDButton 'Set public log access' $null
    $permissions.Add_Click({
        try { if (-not $Data.Root) { throw 'Choose the deployment folder first.' }; Set-PDClientLogPermissions $Data.Root; $StatusLabel.Text='Client Logs permits authenticated read and writes in owned folders. Ensure SMB Change access for reporting accounts.' }
        catch { Show-PDError $_ }
    }.GetNewClosure())
    $toolbar.Controls.AddRange(@($reload,$permissions))
    $clear=New-PDButton 'Clear selected request' $null
    $clear.Add_Click({
        if ($requests.SelectedRows.Count -ne 1) { return }
        $id=$requests.SelectedRows[0].Tag.Id
        $Data.Config.ClientRemovals=@($Data.Config.ClientRemovals | Where-Object { $_.Id -ne $id })
        $Data.Dirty=$true; & $showReport; $StatusLabel.Text='Request cleared. Save deployment bundle to publish this change.'
    }.GetNewClosure())
    $requestsLayout.Controls.Add($clear,0,1)
    $panel
}

function New-PDConfigurationForm {
    param([string]$ConfigPath, [string]$SourceRoot)
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $data = @{ Config = (New-PDConfiguration); Root = ''; Dirty = $false }
    if (Test-Path -LiteralPath $ConfigPath) {
        $data.Config = Read-PDConfiguration $ConfigPath
        $data.Root = [IO.Path]::GetFullPath((Split-Path -Parent $ConfigPath))
        Assert-PDConfiguration $data.Config $data.Root
    }
    $form = New-Object Windows.Forms.Form
    $form.Text = 'Printer Deployment Tool'; $form.Size = '1100,790'; $form.MinimumSize = '930,670'
    $form.StartPosition = 'CenterScreen'; $form.Font = New-Object Drawing.Font('Segoe UI', 10); $form.AutoScaleMode = 'Dpi'
    $layout = New-Object Windows.Forms.TableLayoutPanel
    $layout.Dock = 'Fill'; $layout.Padding = '16,12,16,12'; $layout.ColumnCount = 1; $layout.RowCount = 5
    foreach ($height in @(44, 90)) { [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', $height))) }
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 50)))
    [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 40)))
    $form.Controls.Add($layout)
    $title = New-PDLabel 'Configure once. Deploy silently through Group Policy.'
    $title.Font = New-Object Drawing.Font('Segoe UI', 16, [Drawing.FontStyle]::Bold); $layout.Controls.Add($title, 0, 0)
    $settings = New-Object Windows.Forms.TableLayoutPanel
    $settings.Dock = 'Fill'; $settings.ColumnCount = 3; $settings.RowCount = 2
    [void]$settings.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute', 155)))
    [void]$settings.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 100)))
    [void]$settings.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute', 160)))
    $layout.Controls.Add($settings, 0, 1)
    $rootBox = New-Object Windows.Forms.TextBox; $rootBox.ReadOnly = $true; $rootBox.Dock = 'Fill'; $rootBox.Text = $data.Root
    $settings.Controls.Add((New-PDLabel 'Deployment folder'), 0, 0); $settings.Controls.Add($rootBox, 1, 0)
    $settings.Controls.Add((New-PDLabel 'Driver support is detected per printer; IPP works on x64 and ARM64.'), 1, 1)
    $tabs = New-Object Windows.Forms.TabControl; $tabs.Dock = 'Fill'; $layout.Controls.Add($tabs, 0, 2)
    $printersTab = New-Object Windows.Forms.TabPage; $printersTab.Text = 'Printers'; $printersTab.Padding = '10,10,10,10'
    $cleanupTab = New-Object Windows.Forms.TabPage; $cleanupTab.Text = 'Advanced cleanup'; $cleanupTab.Padding = '16,12,16,12'
    $gpoTab = New-Object Windows.Forms.TabPage; $gpoTab.Text = 'GPO deployment'; $gpoTab.Padding = '10,10,10,10'
    $clientsTab = New-Object Windows.Forms.TabPage; $clientsTab.Text = 'Clients and inventories'
    $tabs.TabPages.AddRange(@($printersTab, $clientsTab, $gpoTab, $cleanupTab))
    $printerLayout = New-Object Windows.Forms.TableLayoutPanel; $printerLayout.Dock = 'Fill'; $printerLayout.ColumnCount = 1; $printerLayout.RowCount = 2
    [void]$printerLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100))); [void]$printerLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 48)))
    $printersTab.Controls.Add($printerLayout)
    $grid = New-Object Windows.Forms.DataGridView
    $grid.Dock = 'Fill'; $grid.ReadOnly = $true; $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false
    $grid.AutoGenerateColumns = $false; $grid.SelectionMode = 'FullRowSelect'; $grid.MultiSelect = $false; $grid.RowHeadersVisible = $false
    $grid.BackgroundColor = [Drawing.Color]::White; $grid.AutoSizeColumnsMode = 'Fill'; $grid.AutoSizeRowsMode = 'AllCells'
    foreach ($column in @(@('Name','Printer name',25), @('Kind','Type',9), @('Address','Endpoint',30), @('DriverName','Driver',26), @('Location','Location',10))) {
        $c = New-Object Windows.Forms.DataGridViewTextBoxColumn; $c.Name = $column[0]; $c.HeaderText = $column[1]; $c.FillWeight = $column[2]
        $grid.Columns.Add($c) | Out-Null
    }
    $printerLayout.Controls.Add($grid, 0, 0)
    $printerButtons = New-Object Windows.Forms.FlowLayoutPanel; $printerButtons.Dock = 'Fill'; $printerLayout.Controls.Add($printerButtons, 0, 1)
    $cleanupLayout = New-Object Windows.Forms.TableLayoutPanel; $cleanupLayout.Dock = 'Fill'; $cleanupLayout.ColumnCount = 1; $cleanupLayout.RowCount = 5
    [void]$cleanupLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 64)))
    [void]$cleanupLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 40)))
    [void]$cleanupLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 42)))
    [void]$cleanupLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Absolute', 40)))
    [void]$cleanupLayout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
    $cleanupTab.Controls.Add($cleanupLayout)
    $cleanupHelp = New-PDLabel 'Cleanup runs before installing the configured queues. Listed names are exact matches and can be removed on every run. Preview with -WhatIf before applying.'
    $cleanupHelp.MaximumSize = '880,0'; $cleanupLayout.Controls.Add($cleanupHelp, 0, 0)
    $stale = New-Object Windows.Forms.CheckBox; $stale.Text = 'Remove printers previously managed by this deployment when they leave the configuration'; $stale.Dock = 'Fill'
    $user = New-Object Windows.Forms.CheckBox; $user.Text = 'Remove listed legacy names from user connections too (does not enable inventory reporting)'; $user.Dock = 'Fill'
    $cleanupLayout.Controls.Add($stale, 0, 1); $cleanupLayout.Controls.Add($user, 0, 2)
    $cleanupLayout.Controls.Add((New-PDLabel 'Legacy printer names to remove (one per line, no wildcards):'), 0, 3)
    $legacy = New-Object Windows.Forms.TextBox; $legacy.Multiline = $true; $legacy.ScrollBars = 'Both'; $legacy.Dock = 'Fill'; $legacy.WordWrap = $false
    $cleanupLayout.Controls.Add($legacy, 0, 4)
    $guide = New-Object Windows.Forms.TextBox; $guide.Multiline = $true; $guide.ReadOnly = $true; $guide.ScrollBars = 'Both'; $guide.Dock = 'Fill'; $guide.WordWrap = $false
    $guide.Font = New-Object Drawing.Font('Consolas', 10); $gpoTab.Controls.Add($guide)
    $actions = New-Object Windows.Forms.FlowLayoutPanel; $actions.Dock = 'Fill'; $layout.Controls.Add($actions, 0, 3)
    $status = New-PDLabel 'Choose a deployment folder, add printers, then save the deployment bundle.'; $status.Dock = 'Fill'; $layout.Controls.Add($status, 0, 4)
    $clientsTab.Controls.Add((New-PDClientsPanel -Data $data -Owner $form -StatusLabel $status))
    $refresh = {
        $grid.Rows.Clear()
        foreach ($p in @($data.Config.Printers)) {
            $driverText = Get-PDPrinterDriverSummary $p
            $index = $grid.Rows.Add([object[]]@($p.Name, $p.Kind, $p.Address, $driverText, $p.Location)); $grid.Rows[$index].Tag = $p
        }
        $rootBox.Text = $data.Root; $guide.Text = Get-PDGpoGuide $data.Root
    }.GetNewClosure()
    $loadCleanup = {
        $stale.Checked = $data.Config.Cleanup.RemoveStaleManaged; $user.Checked = $data.Config.Cleanup.CleanupUserConnections
        $legacy.Lines = [string[]]@($data.Config.Cleanup.LegacyPrinterNames)
    }.GetNewClosure()
    $sync = {
        if (@($data.Config.Printers | Where-Object { $_.PSObject.Properties['DriverPackages'] }).Count) { $data.Config.SchemaVersion=2 }
        $data.Config.Cleanup.RemoveStaleManaged = $stale.Checked; $data.Config.Cleanup.CleanupUserConnections = $user.Checked
        $data.Config.Cleanup.LegacyPrinterNames = @($legacy.Lines | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)
    }.GetNewClosure()
    $folderButton = New-PDButton 'Choose folder...' $null; $settings.Controls.Add($folderButton, 2, 0)
    $folderButton.Add_Click({
        try {
            $prompt = New-Object Windows.Forms.Form; $prompt.Text = 'Deployment folder'; $prompt.Size = '760,220'; $prompt.StartPosition = 'CenterParent'
            $prompt.Font = $form.Font
            $text = New-Object Windows.Forms.TextBox; $text.SetBounds(18,50,700,28); $text.Text = $data.Root; $text.Anchor = 'Top,Left,Right'
            $label = New-PDLabel 'Enter a UNC share (recommended) or a local staging folder:'; $label.SetBounds(18,15,700,28)
            $browse = New-PDButton 'Browse...' $null; $browse.SetBounds(18,100,100,32)
            $browse.Add_Click({
                $picker = New-Object Windows.Forms.FolderBrowserDialog
                try { if ($picker.ShowDialog($prompt) -eq 'OK') { $text.Text = $picker.SelectedPath } } finally { $picker.Dispose() }
            }.GetNewClosure())
            $ok = New-PDButton 'Use folder' $null; $ok.SetBounds(490,100,110,32); $ok.DialogResult = 'OK'
            $cancel = New-PDButton 'Cancel' $null; $cancel.SetBounds(610,100,100,32); $cancel.DialogResult = 'Cancel'
            $prompt.Controls.AddRange(@($text,$label,$browse,$ok,$cancel)); $prompt.AcceptButton = $ok; $prompt.CancelButton = $cancel
            try { if ($prompt.ShowDialog($form) -ne 'OK') { return }; $chosen = $text.Text.Trim() } finally { $prompt.Dispose() }
            if ($chosen -notmatch '^(\\\\[^\\]+\\[^\\]+|[A-Za-z]:\\)' -or $chosen -match '["\r\n]') { throw 'Use a full UNC path or absolute drive path.' }
            $chosen = [IO.Path]::GetFullPath($chosen)
            New-Item -Path $chosen -ItemType Directory -Force | Out-Null
            [void](Resolve-PDResource $chosen 'printers.json')
            # Move configurations by COPYING packages; keep the original deployment intact.
            if ($data.Root -and $data.Root.TrimEnd('\') -ne $chosen.TrimEnd('\')) {
                $packages=@($data.Config.Printers | Where-Object { $_.Kind -in @('Type3','Type4') } | ForEach-Object {
                    if ($_.PackagePath) { $_ }
                    if ($_.PSObject.Properties['DriverPackages']) { foreach ($property in $_.DriverPackages.PSObject.Properties) { $property.Value } }
                } | Sort-Object PackagePath -Unique)
                foreach ($p in $packages) { Copy-PDPackage (Resolve-PDResource $data.Root $p.PackagePath) (Resolve-PDResource $chosen $p.PackagePath) }
            }
            $data.Root = $chosen; $data.Dirty = $true; & $refresh
        } catch { Show-PDError $_ }
    }.GetNewClosure())
    $add = New-PDButton 'Add printer...' $null
    $add.Add_Click({
        try {
            if (-not $data.Root) { throw 'Choose the deployment folder first.' }
            $p = Show-PDPrinterEditor -Root $data.Root -Owner $form
            if ($p) {
                if ($p.Name -in @($data.Config.Printers | ForEach-Object { $_.Name })) { throw 'A printer with this name is already configured.' }
                $data.Config.Printers = @($data.Config.Printers) + @($p); $data.Dirty = $true; & $refresh
            }
        } catch { Show-PDError $_ }
    }.GetNewClosure())
    $edit = New-PDButton 'Edit selected...' $null
    $editAction = {
        try {
            if ($grid.SelectedRows.Count -ne 1) { return }
            $old = $grid.SelectedRows[0].Tag
            $p = Show-PDPrinterEditor -Printer $old -Root $data.Root -Owner $form
            if ($p) {
                $others = @($data.Config.Printers | Where-Object { $_.Name -ne $old.Name })
                if ($p.Name -in @($others | ForEach-Object { $_.Name })) { throw 'A printer with this name is already configured.' }
                $data.Config.Printers = $others + @($p); $data.Dirty = $true; & $refresh
            }
        } catch { Show-PDError $_ }
    }.GetNewClosure()
    $edit.Add_Click($editAction); $grid.Add_CellDoubleClick($editAction)
    $remove = New-PDButton 'Remove selected' $null
    $remove.Add_Click({
        if ($grid.SelectedRows.Count -ne 1) { return }
        $selected = $grid.SelectedRows[0].Tag
        if ([Windows.Forms.MessageBox]::Show("Remove '$($selected.Name)' from the configuration?", 'Remove printer', 'YesNo', 'Question') -ne 'Yes') { return }
        $data.Config.Printers = @($data.Config.Printers | Where-Object { $_.Name -ne $selected.Name }); $data.Dirty = $true; & $refresh
    }.GetNewClosure())
    $printerButtons.Controls.AddRange(@($add,$edit,$remove))
    $load = New-PDButton 'Open configuration...' $null
    $load.Add_Click({
        try {
            if ($data.Dirty -and [Windows.Forms.MessageBox]::Show('Discard unsaved configuration changes?', 'Open configuration', 'YesNo', 'Question') -ne 'Yes') { return }
            $picker = New-Object Windows.Forms.OpenFileDialog; $picker.Filter = 'Printer configuration (*.json)|*.json'
            try { if ($picker.ShowDialog($form) -ne 'OK') { return }; $path = $picker.FileName } finally { $picker.Dispose() }
            $config = Read-PDConfiguration $path; $root = Split-Path -Parent $path; Assert-PDConfiguration $config $root
            $data.Config = $config; $data.Root = $root; & $loadCleanup; & $refresh
            $data.Dirty = $false; $status.Text = 'Configuration loaded.'
        } catch { Show-PDError $_ }
    }.GetNewClosure())
    $validate = New-PDButton 'Validate resources' $null
    $validate.Add_Click({
        try { & $sync; if (-not $data.Root) { throw 'Choose a deployment folder.' }; Assert-PDConfiguration $data.Config $data.Root; $status.Text = 'Configuration, driver names and package paths are valid.' }
        catch { Show-PDError $_ }
    }.GetNewClosure())
    $publish = New-PDButton 'Save deployment bundle' $null
    $publish.Add_Click({
        try {
            & $sync; if (-not $data.Root) { throw 'Choose a deployment folder.' }
            Assert-PDConfiguration $data.Config $data.Root
            $destination = Join-Path $data.Root 'printers.json'
            if (Test-Path -LiteralPath $destination) {
                $current = Read-PDConfiguration $destination
                if ($current.DeploymentId -ne $data.Config.DeploymentId -and
                    [Windows.Forms.MessageBox]::Show('This folder contains a different deployment. Replace its configuration?', 'Replace configuration', 'YesNo', 'Warning') -ne 'Yes') { return }
            }
            Publish-PDBundle $data.Config $data.Root $SourceRoot
            $data.Dirty = $false; $status.Text = 'Bundle saved, including startup and user logon scripts. See GPO deployment.'
        } catch { Show-PDError $_ }
    }.GetNewClosure())
    $copy = New-PDButton 'Copy GPO instructions' $null
    $copy.Add_Click({ [Windows.Forms.Clipboard]::SetText($guide.Text); $status.Text = 'GPO instructions copied.' }.GetNewClosure())
    $actions.Controls.AddRange(@($load,$validate,$publish,$copy))
    foreach ($control in @($stale,$user)) { $control.Add_CheckedChanged({ $data.Dirty = $true }.GetNewClosure()) }
    $legacy.Add_TextChanged({ $data.Dirty = $true }.GetNewClosure())
    $form.Add_FormClosing({
        param($sender,$eventArgs)
        if ($data.Dirty -and [Windows.Forms.MessageBox]::Show('Close without saving configuration changes?', 'Unsaved changes', 'YesNo', 'Question') -ne 'Yes') { $eventArgs.Cancel = $true }
    }.GetNewClosure())
    & $loadCleanup; & $refresh; $data.Dirty = $false
    return $form
}

function Show-PDConfiguration {
    param([string]$ConfigPath, [string]$SourceRoot)
    $form = New-PDConfigurationForm -ConfigPath $ConfigPath -SourceRoot $SourceRoot
    try { [void]$form.ShowDialog() } finally { $form.Dispose() }
}

# Event closures run in dynamic modules; export helpers so event callbacks can resolve them.
Export-ModuleMember -Function *-PD*
