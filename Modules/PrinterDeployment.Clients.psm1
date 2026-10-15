Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'PrinterDeployment.Core.psm1')

function Get-PDClientIdentity {
    param([ValidateSet('Machine','UserConnection')][string]$Scope = 'Machine')
    $computer = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [Environment]::MachineName }
    $sid = ''; $name = 'SYSTEM'
    if ($Scope -eq 'UserConnection') {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $sid = $identity.User.Value; $name = $identity.Name
    }
    [pscustomobject]@{ ComputerName=$computer.ToUpperInvariant(); Scope=$Scope; UserSid=$sid; UserName=$name }
}

function Get-PDClientFolderName {
    param($Identity)
    if ($Identity.ComputerName -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,62}$') { throw 'Invalid reporting computer name.' }
    if ($Identity.Scope -eq 'Machine' -and $Identity.UserSid -eq '') { return $Identity.ComputerName.ToUpperInvariant() }
    if ($Identity.Scope -ne 'UserConnection' -or $Identity.UserSid -notmatch '^S-1-\d+(-\d+)+$') { throw 'Invalid reporting user identity.' }
    $Identity.ComputerName.ToUpperInvariant() + '--user-' + (Get-PDHash $Identity.UserSid).Substring(0,16)
}

function Get-PDConfigurationHash {
    param($Config)
    # Normalize JSON date handling so a GUI-created request and its saved/read copy agree.
    $normalized = $Config | ConvertTo-Json -Depth 12 -Compress | ConvertFrom-Json
    Get-PDHash ($normalized | ConvertTo-Json -Depth 12 -Compress)
}

function Get-PDConfigurationContentHash {
    param($Config)
    # Versioned, order-independent encoding shared with the Mac app. RequestedAt is
    # display metadata; removal identity and all operational settings remain included.
    $builder = New-Object Text.StringBuilder
    [void]$builder.Append('PDConfig1:')
    function Add-Value($Value) {
        if ($null -eq $Value) { [void]$builder.Append('z'); return }
        if ($Value -is [bool]) { [void]$builder.Append($(if ($Value) { 'b1' } else { 'b0' })); return }
        if ($Value -is [string]) { [void]$builder.Append('s').Append([Text.Encoding]::UTF8.GetByteCount($Value)).Append(':').Append($Value); return }
        if ($Value -is [System.Collections.IDictionary] -or $Value -is [pscustomobject]) {
            $isMap = $Value -is [System.Collections.IDictionary]
            [string[]]$keys = @(@(if ($isMap) { $Value.Keys } else { $Value.PSObject.Properties.Name }) | Where-Object { $_ -ne 'RequestedAt' })
            [Array]::Sort($keys, [StringComparer]::Ordinal)
            [void]$builder.Append('o').Append($keys.Count).Append(':')
            foreach ($key in $keys) { Add-Value $key; if ($isMap) { Add-Value $Value[$key] } else { Add-Value $Value.$key } }; return
        }
        if ($Value -is [System.Collections.IEnumerable]) {
            [void]$builder.Append('a').Append(@($Value).Count).Append(':'); foreach ($item in $Value) { Add-Value $item }; return
        }
        if ($Value -is [ValueType] -and $Value -isnot [datetime] -and $Value -isnot [datetimeoffset]) {
            [void]$builder.Append('n').Append(([decimal]$Value).ToString('G29',[Globalization.CultureInfo]::InvariantCulture)).Append(';'); return
        }
        throw 'Unsupported configuration value for report comparison.'
    }
    Add-Value $Config
    Get-PDHash $builder.ToString()
}

function Get-PDReportedPrinterStatusText {
    param([string]$Status)
    switch ($Status) {
        'Installed' { 'Installed and verified' }
        'Missing' { 'Configured queue missing' }
        'Needs reconciliation' { 'Present; settings not verified' }
        'Unknown' { 'Inventory unavailable' }
        'Unsupported architecture' { 'Skipped; no compatible driver' }
        default { $Status }
    }
}

function Get-PDReportErrorExplanation {
    param([string]$Message)
    if ($Message -match 'specified printer already exists|0x8007070a|0x800700b7') {
        return 'Windows reported a printer/device registration conflict while adding a queue. This is not confirmation that the requested queue is installed. Check the per-printer verification below and review older copies in Reported printers.'
    }
    if ($Message -match "exists outside this tool.s management|Name conflict:") { return 'A same-name queue is present, but this deployment could not verify its connection/ownership. Review its driver and port before renaming or removing an old copy.' }
    return ''
}

function Get-PDReportConfigurationStatus {
    param($Report, $Config, [switch]$Unsaved)
    if ($Unsaved) { return 'Unsaved changes' }
    if (-not $Report) { return 'No computer report' }
    $matches = if ($Report.PSObject.Properties['ConfigurationContentHash']) { $Report.ConfigurationContentHash -eq (Get-PDConfigurationContentHash $Config) } else { $Report.ConfigurationHash -eq (Get-PDConfigurationHash $Config) }
    if ($matches) { 'Current' } else { 'Update pending' }
}

function Get-PDClientRemovalRequests {
    param($Config, $Identity)
    if (-not $Config.PSObject.Properties['ClientRemovals']) { return }
    @($Config.ClientRemovals | Where-Object {
        $_.ComputerName -eq $Identity.ComputerName -and $_.Scope -eq $Identity.Scope -and $_.UserSid -eq $Identity.UserSid
    })
}

function Set-PDClientRemovalSelection {
    param($Config, $Report, $Printer, [bool]$Selected)
    if ($Report.DeploymentId -ne $Config.DeploymentId) { throw 'This report belongs to a different deployment.' }
    [void](Get-PDClientFolderName $Report)
    if ($Report.Scope -eq 'UserConnection' -and $Printer.Type -ne 'Connection') { throw 'User-logon cleanup can only remove user connections. Use a machine report for machine queues.' }
    if ($Report.Scope -eq 'Machine' -and $Printer.Type -eq 'Connection') { throw 'Select this connection from its user report instead.' }
    if ($Printer.Name -in @($Config.Printers | ForEach-Object { $_.Name })) { throw 'Remove this printer from the desired configuration before scheduling its removal.' }
    if (-not $Config.PSObject.Properties['ClientRemovals']) { $Config | Add-Member -NotePropertyName ClientRemovals -NotePropertyValue @() }
    $others = @($Config.ClientRemovals | Where-Object {
        -not ($_.ComputerName -eq $Report.ComputerName -and $_.Scope -eq $Report.Scope -and $_.UserSid -eq $Report.UserSid -and $_.Name -eq $Printer.Name)
    })
    $existing = @(Get-PDClientRemovalRequests $Config $Report | Where-Object { $_.Name -eq $Printer.Name })
    if ($Selected) {
        # Preserve a request ID until explicitly cleared, so completed requests remain one-shot.
        $request = if ($existing.Count) { $existing[0] } else {
            [pscustomobject]@{ Id=[guid]::NewGuid().ToString(); ComputerName=$Report.ComputerName; Scope=$Report.Scope; UserSid=$Report.UserSid
                Name=$Printer.Name; DriverName=$Printer.DriverName; PortName=$Printer.PortName; RequestedAt=(Get-Date).ToUniversalTime().ToString('o') }
        }
        $others += @($request)
    }
    $Config.ClientRemovals = $others
}

function New-PDClientReport {
    param($Config, $Identity, [object[]]$Before = @(), [object[]]$After = @(), [object[]]$RemovalResults = @(),
        [string]$Result, [string]$ErrorMessage = '', [string]$InventoryError = '', [string]$StartedAt,
        [hashtable]$Records = @{}, [string]$RunId = ([guid]::NewGuid().ToString()), [string[]]$UnsupportedPrinters = @())
    $wanted = @($Config.Printers | ForEach-Object { $_.Name })
    $printers = @($After | ForEach-Object {
        [pscustomobject]@{ Name=[string]$_.Name; Type=[string]$_.Type; DriverName=[string]$_.DriverName; PortName=[string]$_.PortName
            Location=[string]$_.Location; Configured=($_.Name -in $wanted) }
    })
    $verification = @()
    if ($Identity.Scope -eq 'Machine') {
        $verification = @($Config.Printers | ForEach-Object {
            $p = Get-PDPrinterDriverForArchitecture $_ (Get-PDNativeArchitecture); $actual = @($After | Where-Object { $_.Name -eq $p.Name })
            $status = 'Missing'
            if ($p.Name -in $UnsupportedPrinters) { $status = 'Unsupported architecture' }
            elseif ($InventoryError) { $status = 'Unknown' }
            elseif ($actual.Count -eq 1) {
                $driver = if ($p.Kind -eq 'IPP') { 'Microsoft IPP Class Driver' } else { $p.DriverName }
                $status = 'Needs reconciliation'
                if ($actual[0].DriverName -eq $driver -and $Records.ContainsKey($p.Name) -and
                    $Records[$p.Name].Fingerprint -eq (Get-PDPrinterFingerprint $p) -and
                    $Records[$p.Name].PortName -eq $actual[0].PortName -and $Records[$p.Name].DriverName -eq $actual[0].DriverName) { $status = 'Installed' }
            }
            [pscustomobject]@{ Name=$p.Name; Status=$status }
        })
        if ($Result -eq 'Success' -and @($verification | Where-Object { $_.Status -notin @('Installed','Unsupported architecture') }).Count) {
            $Result = 'Failed'
            if (-not $ErrorMessage) { $ErrorMessage = 'One or more desired printers failed final inventory verification.' }
        }
    }
    [pscustomobject][ordered]@{
        SchemaVersion=1; DeploymentId=$Config.DeploymentId; ComputerName=$Identity.ComputerName; Scope=$Identity.Scope
        UserSid=$Identity.UserSid; UserName=$Identity.UserName; RunId=$RunId; StartedAt=$StartedAt
        ReportedAt=(Get-Date).ToUniversalTime().ToString('o'); Result=$Result; ErrorMessage=$ErrorMessage; InventoryError=$InventoryError
        ConfigurationHash=(Get-PDConfigurationHash $Config); ConfigurationContentHash=(Get-PDConfigurationContentHash $Config)
        Before=@($Before | Select-Object Name,Type,DriverName,PortName); Printers=$printers
        ConfiguredPrinters=$verification; RemovalResults=@($RemovalResults)
    }
}

function Write-PDClientReport {
    param([string]$Root, $Report)
    $folder = Get-PDClientFolderName $Report
    $relative = 'Client Logs\' + $folder
    $destination = Resolve-PDResource $Root $relative
    New-Item -ItemType Directory -Path $destination -Force | Out-Null
    $run = [guid]::Empty
    if (-not [guid]::TryParse($Report.RunId, [ref]$run)) { throw 'Invalid report run ID.' }
    $timestamp = ([datetimeoffset]::Parse($Report.ReportedAt)).UtcDateTime.ToString('yyyyMMdd-HHmmss-fff')
    Write-PDJson $Report (Resolve-PDResource $Root ($relative + '\' + $timestamp + '-' + $run.ToString('N') + '.json'))
    Write-PDJson $Report (Resolve-PDResource $Root ($relative + '\latest.json'))
}

function Get-PDClientReports {
    [CmdletBinding()]
    param([string]$Root, [string]$DeploymentId)
    $logs = Resolve-PDResource $Root 'Client Logs'
    if (-not (Test-Path -LiteralPath $logs)) { return }
    foreach ($folder in @(Get-ChildItem -LiteralPath $logs -Directory)) {
        try {
            $path = Resolve-PDResource $Root ('Client Logs\' + $folder.Name + '\latest.json')
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            if ((Get-Item -LiteralPath $path).Length -gt 4MB) { throw 'Report exceeds the 4 MB size limit.' }
            $report = Read-PDConfiguration $path
            if ($report.DeploymentId -ne $DeploymentId) { continue }
            if ($report.SchemaVersion -ne 1 -or (Get-PDClientFolderName $report) -ne $folder.Name -or
                $report.Result -notin @('Success','Failed') -or $report.Printers -isnot [array] -or
                $report.ConfiguredPrinters -isnot [array] -or $report.RemovalResults -isnot [array]) { throw 'Unsupported report format.' }
            # ConvertFrom-Json can materialize ISO timestamps as DateTime objects.
            foreach ($field in @('ReportedAt','StartedAt')) {
                if ($report.$field -is [datetime] -or $report.$field -is [datetimeoffset]) { $report.$field = ([datetimeoffset]$report.$field).ToString('o') }
            }
            [void][datetimeoffset]::Parse($report.ReportedAt)
            foreach ($field in @('UserName','ReportedAt','StartedAt','ErrorMessage','InventoryError','ConfigurationHash')) {
                if ($report.$field -isnot [string]) { throw 'Invalid report metadata.' }
            }
            if ($report.ConfigurationHash -notmatch '^[0-9a-f]{64}$') { throw 'Invalid report configuration revision.' }
            if ($report.PSObject.Properties['ConfigurationContentHash'] -and $report.ConfigurationContentHash -notmatch '^[0-9a-f]{64}$') { throw 'Invalid report content revision.' }
            foreach ($p in $report.Printers) {
                foreach ($field in @('Name','Type','DriverName','PortName','Location')) { if ($p.$field -isnot [string]) { throw 'Invalid printer inventory.' } }
            }
            foreach ($p in $report.ConfiguredPrinters) {
                if ($p.Name -isnot [string] -or $p.Status -notin @('Installed','Missing','Unknown','Needs reconciliation','Unsupported architecture')) { throw 'Invalid configured-printer result.' }
            }
            foreach ($result in $report.RemovalResults) {
                $id=[guid]::Empty
                if (-not [guid]::TryParse([string]$result.Id,[ref]$id) -or $result.Name -isnot [string] -or $result.Message -isnot [string] -or
                    $result.Status -notin @('Pending','Completed','Changed','Removed','NotFound','Planned','Failed')) { throw 'Invalid removal result.' }
            }
            $report
        } catch { Write-Warning "Skipped client report '$($folder.Name)': $($_.Exception.Message)" }
    }
}

function Get-PDComputerInventory {
    param([object[]]$Reports)
    foreach ($group in @($Reports | Group-Object ComputerName | Sort-Object Name)) {
        $machine = @($group.Group | Where-Object { $_.Scope -eq 'Machine' })
        $users = @($group.Group | Where-Object { $_.Scope -eq 'UserConnection' } | Sort-Object UserName)
        $entries = New-Object 'System.Collections.Generic.List[object]'
        foreach ($report in @($machine) + @($users)) {
            foreach ($printer in @($report.Printers)) {
                # Computer queues are also visible in user snapshots; display each computer queue once.
                if ($report.Scope -eq 'UserConnection' -and $printer.Type -ne 'Connection' -and
                    @($machine | ForEach-Object { $_.Printers } | Where-Object {
                        $_.Name -eq $printer.Name -and $_.DriverName -eq $printer.DriverName -and $_.PortName -eq $printer.PortName
                    }).Count) { continue }
                if ($report.Scope -eq 'Machine' -and $printer.Type -eq 'Connection' -and
                    @($users | ForEach-Object { $_.Printers } | Where-Object { $_.Type -eq 'Connection' -and $_.Name -eq $printer.Name }).Count) { continue }
                $owner = if ($report.Scope -eq 'Machine') { 'Computer' } else { $report.UserName }
                $canRemove = ($report.Scope -eq 'Machine' -and $printer.Type -ne 'Connection') -or
                    ($report.Scope -eq 'UserConnection' -and $printer.Type -eq 'Connection')
                $entries.Add([pscustomobject]@{ Printer=$printer; Report=$report; Owner=$owner; CanRemove=$canRemove })
            }
        }
        [pscustomobject]@{ ComputerName=$group.Name; Reports=@($group.Group); MachineReport=($machine | Select-Object -First 1)
            UserReportCount=$users.Count; Printers=$entries.ToArray() }
    }
}

function Set-PDClientLogPermissions {
    param([string]$Root)
    if ($env:OS -ne 'Windows_NT') { throw 'Configure report permissions from Windows.' }
    $folder = Resolve-PDResource $Root 'Client Logs'
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544', [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)) {
        $identity = New-Object Security.Principal.SecurityIdentifier($sid)
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow')))
    }
    $authenticated = New-Object Security.Principal.SecurityIdentifier('S-1-5-11')
    $creator = New-Object Security.Principal.SecurityIdentifier('S-1-3-0')
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($authenticated,'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow')))
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($authenticated,'CreateDirectories','None','None','Allow')))
    $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule($creator,'Modify','ContainerInherit,ObjectInherit','InheritOnly','Allow')))
    Set-Acl -LiteralPath $folder -AclObject $acl
}

Export-ModuleMember -Function *-PD*
