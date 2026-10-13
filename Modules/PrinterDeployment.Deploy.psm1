Set-StrictMode -Version 2.0
Import-Module (Join-Path $PSScriptRoot 'PrinterDeployment.Core.psm1')
Import-Module (Join-Path $PSScriptRoot 'PrinterDeployment.Clients.psm1')

function Write-PDLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format o), $Level, $Message
    Write-Host $line
    if ($script:PDLogPath) { Add-Content -LiteralPath $script:PDLogPath -Value $line -Encoding UTF8 }
}

function Get-PDInstalledPrinter {
    param([string]$Name)
    $found = @(Get-Printer -ErrorAction Stop | Where-Object { $_.Name -eq $Name })
    if ($found.Count -gt 1) { throw "Multiple printers have the name '$Name'. Resolve this before deployment." }
    if ($found.Count -eq 1) { $found[0] }
}

function Get-PDInstalledDriver {
    param([string]$Name)
    $found = @(Get-PrinterDriver -ErrorAction Stop | Where-Object { $_.Name -eq $Name })
    if ($found.Count -gt 1) { throw "Ambiguous installed driver '$Name'." }
    if ($found.Count -eq 1) { $found[0] }
}

function Install-PDType4Driver {
    param($Printer, [string]$Root)
    $driver = Get-PDInstalledDriver $Printer.DriverName
    if ($driver) {
        if ($driver.MajorVersion -ne 4) { throw "Installed '$($Printer.DriverName)' is not a Type 4 driver." }
        Write-PDLog "Driver already installed: $($Printer.DriverName)"
        return
    }
    $inf = Resolve-PDResource $Root $Printer.InfPath
    # Stage the selected INF, retaining its original package hierarchy on the share.
    # Do not /install across devices or stage every unrelated INF in the package.
    $output = & (Join-Path $env:windir 'System32\pnputil.exe') /add-driver $inf 2>&1
    $code = $LASTEXITCODE
    Write-PDLog ("pnputil ({0}): {1}" -f $code, ($output -join ' '))
    if ($code -notin @(0, 3010)) { throw "Driver staging failed ($code): $inf" }
    if ($code -eq 3010) { throw 'Driver staging requires a restart. Restart this computer and rerun deployment; cleanup has not started.' }
    # Add-PrinterDriver requires an INF in the Driver Store, not the source UNC path.
    # DISM's objects avoid parsing localized pnputil output for oemNN.inf names.
    Import-Module Dism -ErrorAction Stop
    $sourceHash = (Get-FileHash -LiteralPath $inf -Algorithm SHA256).Hash
    $candidates = @(Get-WindowsDriver -Online -All -ErrorAction Stop | Where-Object {
        $_.ClassName -eq 'Printer' -and [IO.Path]::GetFileName($_.OriginalFileName) -eq [IO.Path]::GetFileName($inf)
    })
    $storeInf = $null
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate.OriginalFileName -PathType Leaf) {
            if ((Get-FileHash -LiteralPath $candidate.OriginalFileName -Algorithm SHA256).Hash -eq $sourceHash) {
                $storeInf = $candidate.OriginalFileName; break
            }
        }
    }
    if (-not $storeInf) { throw "Staged INF could not be located in the Driver Store: $inf" }
    Add-PrinterDriver -Name $Printer.DriverName -InfPath $storeInf -ErrorAction Stop
    $driver = Get-PDInstalledDriver $Printer.DriverName
    if (-not $driver -or $driver.MajorVersion -ne 4) { throw "Type 4 driver registration failed: $($Printer.DriverName)" }
}

function Test-PDPort {
    param($Port, $Printer)
    # Win32_TCPIPPrinterPort contains protocol/SNMP properties absent on some PrintManagement versions.
    $Port -and $Port.HostAddress -eq $Printer.Address -and $Port.PortNumber -eq $Printer.PortNumber -and
        $Port.Protocol -eq 1 -and -not $Port.SNMPEnabled
}

function Get-PDTcpPort {
    param([string]$Name)
    @(Get-CimInstance -ClassName Win32_TCPIPPrinterPort -ErrorAction Stop | Where-Object { $_.Name -eq $Name }) | Select-Object -First 1
}

function Save-PDState {
    param([hashtable]$Records, [string]$Path, [string]$DeploymentId, [string[]]$CompletedRemovals = @())
    Write-PDJson -Path $Path -Value ([pscustomobject]@{
        SchemaVersion = 1; DeploymentId = $DeploymentId
        Printers = @($Records.Values | Sort-Object Name); CompletedRemovals=@($CompletedRemovals); UpdatedAt = (Get-Date -Format o)
    })
}

function Invoke-PDSelectedRemovals {
    [CmdletBinding(SupportsShouldProcess)]
    param($Config, $Identity, [hashtable]$Records, $Receipts, [string]$StatePath)
    foreach ($request in @(Get-PDClientRemovalRequests $Config $Identity)) {
        $status = 'Pending'; $message = ''
        try {
            if ($Receipts.Contains($request.Id)) { $status = 'Completed'; $message = 'Already handled on an earlier run.' }
            else {
                $queue = Get-PDInstalledPrinter $request.Name
                if ($queue -and ($queue.DriverName -ne $request.DriverName -or $queue.PortName -ne $request.PortName -or
                    ($Identity.Scope -eq 'Machine' -and $queue.Type -eq 'Connection') -or
                    ($Identity.Scope -eq 'UserConnection' -and $queue.Type -ne 'Connection'))) {
                    $status = 'Changed'; $message = 'Queue no longer matches the selected inventory. Clear and select it again after review.'
                } elseif ($PSCmdlet.ShouldProcess($request.Name, "Apply one-time removal request on $($Identity.ComputerName)")) {
                    if ($queue) { Remove-Printer -InputObject $queue -ErrorAction Stop; $status = 'Removed' }
                    else { $status = 'NotFound' }
                    $Receipts.Add($request.Id)
                    $Records.Remove($request.Name)
                    Save-PDState $Records $StatePath $Config.DeploymentId -CompletedRemovals $Receipts.ToArray()
                    $message = 'Request completed; it will not remove a later re-created queue.'
                } else { $status = 'Planned' }
            }
        } catch { $status = 'Failed'; $message = $_.Exception.Message }
        [pscustomobject]@{ Id=$request.Id; Name=$request.Name; Status=$status; Message=$message }
    }
}

function Complete-PDClientReporting {
    param($Config, [string]$Root, $Identity, [object[]]$Before, [hashtable]$Records, [object[]]$RemovalResults,
        [string]$Result, [string]$ErrorMessage, [string]$StartedAt, [string]$LocalRoot)
    $originalResult = $Result
    $after = @(); $inventoryError = ''
    try { $after = @(Get-Printer -ErrorAction Stop) } catch { $inventoryError = $_.Exception.Message; $Result = 'Failed' }
    $verified = @{}
    foreach ($key in $Records.Keys) { $verified[$key] = $Records[$key] }
    if ($Identity.Scope -eq 'Machine' -and -not $inventoryError) {
        try {
            foreach ($p in @($Config.Printers | Where-Object { $_.Kind -eq 'Type4' })) {
                if (-not (Test-PDPort (Get-PDTcpPort (Get-PDPortName $p)) $p)) { $verified.Remove($p.Name) }
            }
        } catch { $inventoryError = $_.Exception.Message; $Result = 'Failed' }
    }
    $report = New-PDClientReport -Config $Config -Identity $Identity -Before $Before -After $after -Records $verified `
        -RemovalResults $RemovalResults -Result $Result -ErrorMessage $ErrorMessage -InventoryError $inventoryError -StartedAt $StartedAt
    # Keep a local copy even when the share's report folder is unavailable.
    if ($LocalRoot -and (Test-Path -LiteralPath $LocalRoot -PathType Container)) {
        Write-PDJson $report (Join-Path $LocalRoot 'last-report.json')
    }
    Write-PDClientReport -Root $Root -Report $report
    if ($inventoryError) { throw "Client printer inventory failed: $inventoryError" }
    if ($originalResult -eq 'Success' -and $report.Result -eq 'Failed') { throw $report.ErrorMessage }
}

function Assert-PDAdministrator {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Deployment must run elevated or as SYSTEM.' }
}

function Initialize-PDStateFolder {
    param([string]$Path, [switch]$ReadOnly)
    $trusted = @('S-1-5-18', 'S-1-5-32-544')
    # Reject state pre-created by an unprivileged user; ownership records authorize cleanup.
    foreach ($candidate in @((Split-Path -Parent $Path), $Path)) {
        if (Test-Path -LiteralPath $candidate) {
            if ((Get-Item -LiteralPath $candidate -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked state directory is not allowed: $candidate" }
            $owner = (Get-Acl -LiteralPath $candidate).GetOwner([Security.Principal.SecurityIdentifier]).Value
            if ($owner -notin $trusted) { throw "State directory is not owned by SYSTEM or Administrators: $candidate. Have an administrator review and remove it before deployment." }
        }
    }
    if ($ReadOnly) { return }
    foreach ($candidate in @((Split-Path -Parent $Path), $Path)) {
        New-Item -Path $candidate -ItemType Directory -Force | Out-Null
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
        foreach ($sid in $trusted) {
            $identity = New-Object Security.Principal.SecurityIdentifier($sid)
            $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $candidate -AclObject $acl
    }
}

function Invoke-PDDeployment {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)][string]$ConfigPath, [int]$RetryCount = 3, [int]$RetrySeconds = 20)
    $script:PDLogPath = $null
    $dryRun = [bool]$WhatIfPreference
    $mutex = $null; $locked = $false
    $reportConfig = $null; $records = @{}; $installed = @(); $beforeReport = @(); $removalResults = @()
    $receipts = New-Object 'System.Collections.Generic.List[string]'
    $startedAt = (Get-Date).ToUniversalTime().ToString('o'); $runError = ''; $runResult = 'Failed'; $stateRoot = ''
    $root = Split-Path -Parent $ConfigPath
    try {
        $config = $null
        for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
            try {
                $config = Read-PDConfiguration $ConfigPath
                Assert-PDConfiguration $config (Split-Path -Parent $ConfigPath)
                $reportConfig = $config
                break
            } catch {
                if ($attempt -eq $RetryCount) { throw }
                Write-PDLog "Configuration unavailable or invalid; retry $attempt/$RetryCount in $RetrySeconds seconds. $($_.Exception.Message)" 'WARN'
                Start-Sleep -Seconds $RetrySeconds
            }
        }
        $root = Split-Path -Parent $ConfigPath
        $nativeArch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'ARM64' } else { 'x64' }
        if ($config.Architecture -ne $nativeArch) { throw "This configuration targets $($config.Architecture), but this process is $nativeArch." }
        if (-not $dryRun) {
            Assert-PDAdministrator
        }
        Import-Module PrintManagement -ErrorAction Stop
        if (@($config.Printers | Where-Object { $_.Kind -eq 'IPP' }).Count -and
            -not (Get-Command Add-Printer).Parameters.ContainsKey('IppURL')) {
            throw 'This Windows build does not support Add-Printer -IppURL. Update Windows before using IPP deployment.'
        }
        if ((Get-Service Spooler -ErrorAction Stop).Status -ne 'Running') { throw 'The Print Spooler is not running.' }
        $mutex = New-Object Threading.Mutex($false, ("Global\PrinterDeploymentTool-" + $config.DeploymentId))
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another deployment for this configuration is already running.' }
        $stateRoot = Join-Path $env:ProgramData ("PrinterDeploymentTool\" + $config.DeploymentId)
        $statePath = Join-Path $stateRoot 'state.json'
        Initialize-PDStateFolder -Path $stateRoot -ReadOnly:$dryRun
        if (Test-Path -LiteralPath $statePath) {
            $state = Read-PDConfiguration $statePath
            if ($state.SchemaVersion -ne 1 -or $state.DeploymentId -ne $config.DeploymentId) { throw 'Local managed-printer state is invalid. Review it before continuing.' }
            foreach ($record in @($state.Printers)) { $records[$record.Name] = $record }
            if ($state.PSObject.Properties['CompletedRemovals']) { foreach ($id in @($state.CompletedRemovals)) { $receipts.Add([string]$id) } }
        }
        if (-not $dryRun) {
            $script:PDLogPath = Join-Path $stateRoot ("deploy-" + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.log')
        }
        Write-PDLog "Starting deployment $($config.DeploymentId); WhatIf=$dryRun"
        $installed = @(Get-Printer -ErrorAction Stop)
        $beforeReport = @($installed | Select-Object Name,Type,DriverName,PortName,Location)
        $cleanup = @(Get-PDCleanupCandidates -Installed $installed -Config $config -Managed @($records.Values))
        # Resolve all collisions and port conflicts BEFORE driver changes or cleanup.
        foreach ($p in @($config.Printers)) {
            $existing = Get-PDInstalledPrinter $p.Name
            $owned = $records.ContainsKey($p.Name) -and $existing -and
                $records[$p.Name].PortName -eq $existing.PortName -and $records[$p.Name].DriverName -eq $existing.DriverName
            if ($existing -and -not $owned) {
                $sameTcp = $p.Kind -eq 'Type4' -and $existing.DriverName -eq $p.DriverName -and
                    $existing.PortName -eq (Get-PDPortName $p) -and (Test-PDPort (Get-PDTcpPort $existing.PortName) $p)
                if (-not $sameTcp) { throw "Printer '$($p.Name)' exists outside this tool's management. Rename it or the configured queue before deploying." }
            }
            if ($p.Kind -eq 'Type4') {
                $portName = Get-PDPortName $p
                $port = @(Get-PrinterPort -ErrorAction Stop | Where-Object { $_.Name -eq $portName })
                if ($port.Count -and -not (Test-PDPort (Get-PDTcpPort $portName) $p)) { throw "Existing port '$portName' has different settings. Resolve the conflict before deploying." }
            }
        }
        # Register all required drivers BEFORE removing old queues. A bad/signed-blocked package aborts cleanup.
        foreach ($p in @($config.Printers | Where-Object { $_.Kind -eq 'Type4' } | Sort-Object DriverName -Unique)) {
            if ($PSCmdlet.ShouldProcess($p.DriverName, 'Ensure Type 4 driver is installed')) { Install-PDType4Driver $p $root }
        }
        if (-not $dryRun) {
            # Inventory for review/recovery; this is not an automatic full printer-settings backup.
            $installed | Select-Object Name, Type, DriverName, PortName, Location, Comment, Shared, ShareName |
                Export-Clixml -LiteralPath (Join-Path $stateRoot ("inventory-" + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.xml'))
        }
        $failures = New-Object 'System.Collections.Generic.List[string]'
        foreach ($old in $cleanup) {
            try {
                if ($PSCmdlet.ShouldProcess($old.Name, 'Remove legacy or stale managed printer before installation')) {
                    Remove-Printer -InputObject $old -ErrorAction Stop
                    $records.Remove($old.Name)
                    Save-PDState $records $statePath $config.DeploymentId -CompletedRemovals $receipts.ToArray()
                    Write-PDLog "Removed old printer: $($old.Name)"
                }
            } catch { $failures.Add("Cleanup '$($old.Name)': $($_.Exception.Message)"); Write-PDLog $failures[$failures.Count - 1] 'ERROR' }
        }
        $identity = Get-PDClientIdentity -Scope Machine
        $removalResults = @(Invoke-PDSelectedRemovals -Config $config -Identity $identity -Records $records -Receipts $receipts -StatePath $statePath -WhatIf:$dryRun)
        foreach ($result in $removalResults) {
            Write-PDLog "Client removal '$($result.Name)': $($result.Status). $($result.Message)"
            if ($result.Status -in @('Failed','Changed')) { $failures.Add("Client removal '$($result.Name)': $($result.Message)") }
        }
        foreach ($p in @($config.Printers)) {
            try {
                $existing = Get-PDInstalledPrinter $p.Name
                $fingerprint = Get-PDPrinterFingerprint $p
                $same = $existing -and $records.ContainsKey($p.Name) -and $records[$p.Name].Fingerprint -eq $fingerprint -and
                    $records[$p.Name].PortName -eq $existing.PortName -and $records[$p.Name].DriverName -eq $existing.DriverName
                if ($same) {
                    if ($PSCmdlet.ShouldProcess($p.Name, 'Update printer location and comment')) {
                        if ($existing.Location -ne $p.Location -or $existing.Comment -ne $p.Comment) {
                            Set-Printer -InputObject $existing -Location $p.Location -Comment $p.Comment -ErrorAction Stop
                        }
                    }
                    Write-PDLog "Already configured: $($p.Name)"; continue
                }
                if (-not $PSCmdlet.ShouldProcess($p.Name, "Install or reconcile $($p.Kind) printer at $($p.Address)")) { continue }
                if ($p.Kind -eq 'Type4') {
                    $portName = Get-PDPortName $p
                    if (-not (Get-PDTcpPort $portName)) {
                        # SNMP is opt-in on Add-PrinterPort. Omit it for a plain RAW port.
                        Add-PrinterPort -Name $portName -PrinterHostAddress $p.Address -PortNumber $p.PortNumber -ErrorAction Stop | Out-Null
                        if (-not (Test-PDPort (Get-PDTcpPort $portName) $p)) { throw 'New TCP/IP port did not have the expected RAW/SNMP settings.' }
                    }
                    if ($existing) {
                        Set-Printer -InputObject $existing -DriverName $p.DriverName -PortName $portName -Location $p.Location -Comment $p.Comment -ErrorAction Stop
                    } else {
                        Add-Printer -Name $p.Name -DriverName $p.DriverName -PortName $portName -Location $p.Location -Comment $p.Comment -ErrorAction Stop
                    }
                } else {
                    # IPP has its own Add-Printer parameter set; DriverName cannot be passed alongside IppURL.
                    if ($existing) { Remove-Printer -InputObject $existing -ErrorAction Stop }
                    try {
                        Add-Printer -Name $p.Name -IppURL $p.Address -Location $p.Location -Comment $p.Comment -ErrorAction Stop
                        $created = Get-PDInstalledPrinter $p.Name
                        if (-not $created) { throw 'IPP discovery did not create the requested queue.' }
                        if ($created.DriverName -ne 'Microsoft IPP Class Driver') {
                            if (-not (Get-PDInstalledDriver 'Microsoft IPP Class Driver')) {
                                Add-PrinterDriver -Name 'Microsoft IPP Class Driver' -ErrorAction Stop
                            }
                            Set-Printer -InputObject $created -DriverName 'Microsoft IPP Class Driver' -ErrorAction Stop
                        }
                    } catch {
                        $installError = $_
                        # Best-effort restoration of the former queue using the retained port/driver.
                        $partial = Get-PDInstalledPrinter $p.Name
                        if ($partial) { Remove-Printer -InputObject $partial -ErrorAction Stop }
                        if ($existing) {
                            try { Add-Printer -Name $existing.Name -DriverName $existing.DriverName -PortName $existing.PortName -Location $existing.Location -Comment $existing.Comment -ErrorAction Stop }
                            catch { Write-PDLog "Could not restore $($p.Name): $($_.Exception.Message)" 'ERROR' }
                        }
                        throw $installError
                    }
                }
                $actual = Get-PDInstalledPrinter $p.Name
                $expectedDriver = if ($p.Kind -eq 'IPP') { 'Microsoft IPP Class Driver' } else { $p.DriverName }
                if (-not $actual -or $actual.DriverName -ne $expectedDriver) { throw 'Installed printer failed driver verification.' }
                $records[$p.Name] = [pscustomobject]@{ Name = $p.Name; Fingerprint = $fingerprint; PortName = $actual.PortName; DriverName = $actual.DriverName }
                Save-PDState $records $statePath $config.DeploymentId -CompletedRemovals $receipts.ToArray()
                Write-PDLog "Configured: $($p.Name)"
            } catch { $failures.Add("Printer '$($p.Name)': $($_.Exception.Message)"); Write-PDLog $failures[$failures.Count - 1] 'ERROR' }
        }
        if ($failures.Count) { throw ("Deployment completed with failures: " + ($failures -join '; ')) }
        $runResult = 'Success'
        Write-PDLog 'Deployment completed successfully.'
    } catch {
        $runError = $_.Exception.Message
        Write-PDLog $_.Exception.Message 'ERROR'
        throw
    } finally {
        try {
            if (-not $dryRun -and $reportConfig -and ($locked -or -not $mutex)) {
                try {
                    Complete-PDClientReporting -Config $reportConfig -Root $root -Identity (Get-PDClientIdentity -Scope Machine) `
                        -Before $beforeReport -Records $records -RemovalResults $removalResults -Result $runResult -ErrorMessage $runError -StartedAt $startedAt -LocalRoot $stateRoot
                } catch {
                    Write-PDLog "Client reporting failed: $($_.Exception.Message)" 'ERROR'
                    if (-not $runError) { throw }
                }
            }
        } finally {
            if ($locked) { $mutex.ReleaseMutex() }
            if ($mutex) { $mutex.Dispose() }
            $script:PDLogPath = $null
        }
    }
}

function Invoke-PDUserCleanup {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param([Parameter(Mandatory)][string]$ConfigPath)
    $script:PDLogPath = $null
    $config = Read-PDConfiguration $ConfigPath; Assert-PDConfiguration $config (Split-Path -Parent $ConfigPath)
    $dryRun = [bool]$WhatIfPreference; $before = @(); $beforeReport = @(); $results = @(); $errorMessage = ''; $result = 'Failed'
    $startedAt = (Get-Date).ToUniversalTime().ToString('o'); $identity = Get-PDClientIdentity -Scope UserConnection
    $localRoot = Join-Path $env:LOCALAPPDATA ('PrinterDeploymentTool\' + $config.DeploymentId)
    $statePath = Join-Path $localRoot 'user-removals.json'
    $receipts = New-Object 'System.Collections.Generic.List[string]'
    $mutex = New-Object Threading.Mutex($false, ('Global\PrinterDeploymentTool-User-' + $config.DeploymentId + '-' + $identity.UserSid))
    $locked = $false
    try {
        try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
        if (-not $locked) { throw 'Another user cleanup for this profile is running.' }
        Import-Module PrintManagement -ErrorAction Stop
        $before = @(Get-Printer -ErrorAction Stop)
        $beforeReport = @($before | Select-Object Name,Type,DriverName,PortName,Location)
        if (Test-Path -LiteralPath $statePath) {
            $state = Read-PDConfiguration $statePath
            if ($state.DeploymentId -ne $config.DeploymentId) { throw 'User removal receipts belong to another deployment.' }
            foreach ($id in @($state.CompletedRemovals)) { $receipts.Add([string]$id) }
        }
        if (-not $dryRun) { New-Item -ItemType Directory -Path $localRoot -Force | Out-Null }
        $failures = @()
        foreach ($p in @(Get-PDCleanupCandidates -Installed $before -Config $config -UserConnectionsOnly)) {
            try {
                if ($PSCmdlet.ShouldProcess($p.Name, 'Remove explicitly named connection in the current user profile')) { Remove-Printer -InputObject $p -ErrorAction Stop }
            } catch { $failures += $_.Exception.Message }
        }
        $results = @(Invoke-PDSelectedRemovals -Config $config -Identity $identity -Records @{} -Receipts $receipts -StatePath $statePath -WhatIf:$dryRun)
        $failures += @($results | Where-Object { $_.Status -in @('Failed','Changed') } | ForEach-Object { $_.Message })
        if ($failures.Count) { throw ($failures -join '; ') }
        $result = 'Success'
    } catch { $errorMessage = $_.Exception.Message; throw }
    finally {
        try {
            if (-not $dryRun -and $locked) {
                try { Complete-PDClientReporting -Config $config -Root (Split-Path -Parent $ConfigPath) -Identity $identity -Before $beforeReport -Records @{} -RemovalResults $results -Result $result -ErrorMessage $errorMessage -StartedAt $startedAt -LocalRoot $localRoot }
                catch { Write-Warning "User client reporting failed: $($_.Exception.Message)"; if (-not $errorMessage) { throw } }
            }
        } finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
    }
}

Export-ModuleMember -Function Invoke-PDDeployment, Invoke-PDUserCleanup
