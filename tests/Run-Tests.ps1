#requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$projectRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $projectRoot 'Modules/PrinterDeployment.Core.psm1') -Force
Import-Module (Join-Path $projectRoot 'Modules/PrinterDeployment.Clients.psm1') -Force
$script:Passed = 0
function Assert-True { param($Condition, [string]$Message) if (-not $Condition) { throw $Message } }
function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    $caught = $null
    try { & $Action } catch { $caught = $_ }
    if (-not $caught) { throw 'Expected an exception.' }
    if ($Pattern -and $caught.Exception.Message -notmatch $Pattern) { throw "Unexpected error: $($caught.Exception.Message)" }
}
function Test-Case {
    param([string]$Name, [scriptblock]$Action)
    & $Action
    $script:Passed++; Write-Host "PASS $Name"
}
function New-TestPrinter {
    param([string]$Name = 'Office', [string]$Kind = 'IPP')
    [pscustomobject]@{
        Name = $Name; Kind = $Kind; Address = 'ipp://printer.example.com:631/ipp/print'
        PortNumber = 9100; Location = 'Office'; Comment = 'Managed by IT'
        PackagePath = ''; InfPath = ''; DriverName = ''
    }
}
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('pdt-tests-' + [guid]::NewGuid().ToString('N'))
$originalProgramData = $env:ProgramData; $originalArchitecture = $env:PROCESSOR_ARCHITECTURE
$originalLocalAppData = $env:LOCALAPPDATA
try {
    New-Item -Path $tempRoot -ItemType Directory | Out-Null
    $packagePath = Join-Path $tempRoot 'Drivers/vendor'
    New-Item -Path $packagePath -ItemType Directory -Force | Out-Null
    $inf = Join-Path $packagePath 'printer.inf'
    @'
[Version]
Signature="$Windows NT$"
Class=Printer
ClassVer=4.0 ; v4
[Manufacturer]
%Vendor%=Models,NTamd64,NTamd64.10.0,NTarm64,NTx86
[Models.NTamd64]
%Model%=Install,HWID
"Printer; with comma, and equals = sign"=Install,HWID2 ; real comment
[Models.NTamd64.10.0]
"OS decorated model"=Install,HWID3
[Models.NTarm64]
"ARM printer"=Install,ARMHWID
[Models.NTx86]
"x86 printer"=Install,X86HWID
[Strings.0409]
Vendor="Test Vendor"
Model="English fallback"
[Strings]
Vendor="Test Vendor"
Model="Test Printer v4"
'@ | Set-Content -LiteralPath $inf -Encoding Unicode
    Test-Case 'All PowerShell files parse' {
        foreach ($file in @(Get-ChildItem -LiteralPath $projectRoot -Recurse -Include '*.ps1','*.psm1')) {
            $tokens = $null; $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            Assert-True (-not $errors) ("Syntax errors in $($file.Name): " + ($errors -join '; '))
        }
    }
    Test-Case 'UTF-16 Type 4 INF, strings, comments and architecture filtering' {
        $models = @(Get-PDInfModels $inf x64)
        Assert-True ($models.Count -eq 3) 'Expected three x64 models.'
        Assert-True ('Test Printer v4' -in $models) 'String expansion failed.'
        Assert-True ('Printer; with comma, and equals = sign' -in $models) 'Quoted model punctuation was lost.'
        Assert-True ('OS decorated model' -in $models) 'Decorated section missing.'
        Assert-True ('ARM printer' -notin $models -and 'x86 printer' -notin $models) 'Wrong architecture leaked.'
        $arm = @(Get-PDInfModels $inf ARM64)
        Assert-True ($arm.Count -eq 1 -and $arm[0] -eq 'ARM printer') 'ARM64 filtering failed.'
    }
    Test-Case 'Type 3 and unresolved INF strings rejected' {
        $bad = Join-Path $packagePath 'type3.inf'
        (Get-Content $inf -Raw).Replace('ClassVer=4.0','ClassVer=3.0') | Set-Content $bad
        Assert-Throws { Get-PDInfModels $bad } 'Only Type 4'
        (Get-Content $inf -Raw).Replace('%Model%=Install','%Missing%=Install') | Set-Content $bad
        Assert-Throws { Get-PDInfModels $bad } 'Unresolved INF string'
    }
    Test-Case 'Absolute paths, sibling escapes, traversal and ADS rejected' {
        foreach ($path in @('../outside.inf','Drivers/../../outside.inf','Drivers\..\outside.inf','/tmp/outside.inf','C:\outside.inf','Drivers/a.inf:stream')) {
            Assert-Throws { Resolve-PDResource $tempRoot $path } 'inside|escapes'
        }
        Assert-True ((Resolve-PDResource $tempRoot 'Drivers\vendor\printer.inf') -eq $inf) 'Relative Windows paths did not resolve.'
    }
    Test-Case 'Valid IPP example and atomic JSON round-trip' {
        $example = Read-PDConfiguration (Join-Path $projectRoot 'examples/printers.ipp.json')
        Assert-PDConfiguration $example $tempRoot
        $configFile = Join-Path $tempRoot 'roundtrip.json'
        Write-PDJson $example $configFile
        $example.Printers[0].Location = 'Updated location'; Write-PDJson $example $configFile
        $read = Read-PDConfiguration $configFile
        Assert-PDConfiguration $read $tempRoot
        Assert-True ($read.Printers[0].Location -eq 'Updated location') 'Atomic replacement lost update.'
    }
    Test-Case 'Invalid URL, duplicate names, flags, names and wildcards rejected' {
        $c = New-PDConfiguration; $p = New-TestPrinter; $c.Printers = @($p)
        $p.Address = 'printer.example.com'; Assert-Throws { Assert-PDConfiguration $c $tempRoot } 'full IPP URL'
        $p.Address = 'ipp://user:password@printer.example.com/ipp/print'; Assert-Throws { Assert-PDConfiguration $c $tempRoot } 'full IPP URL'
        $p.Address = 'ipp://printer.example.com/ipp/print'; $c.Printers = @($p, (New-TestPrinter 'office'))
        Assert-Throws { Assert-PDConfiguration $c $tempRoot } 'Duplicate'
        $c.Printers = @($p); $c.Cleanup.LegacyPrinterNames = @('Office'); Assert-Throws { Assert-PDConfiguration $c $tempRoot } 'cannot delete'
        $c.Cleanup.LegacyPrinterNames = @('Old*'); Assert-Throws { Assert-PDConfiguration $c $tempRoot } 'exact printer names'
        $c.Cleanup.LegacyPrinterNames = @(); $c.Cleanup.RemoveStaleManaged = 'false'; Assert-Throws { Assert-PDConfiguration $c $tempRoot } 'booleans'
    }
    Test-Case 'Type 4 package, model name, path containment and port validation' {
        $c = New-PDConfiguration; $p = New-TestPrinter 'Legacy' 'Type4'
        $p.Address = '192.0.2.55'; $p.PackagePath = 'Drivers\vendor'; $p.InfPath = 'Drivers\vendor\printer.inf'; $p.DriverName = 'Test Printer v4'
        $c.Printers = @($p); Assert-PDConfiguration $c $tempRoot
        $p.DriverName = 'Wrong model'; Assert-Throws { Assert-PDConfiguration $c $tempRoot } 'not in the selected INF'
        $p.DriverName = 'Test Printer v4'; $p.PortNumber = 70000; Assert-Throws { Assert-PDConfiguration $c $tempRoot } '1-65535'
        $p.PortNumber = 9100; $p.InfPath = 'Drivers\other\printer.inf'; Assert-Throws { Assert-PDConfiguration $c $tempRoot } 'Missing package or INF'
    }
    Test-Case 'Cleanup preserves desired, virtual, unrelated and changed-ownership queues' {
        $c = New-PDConfiguration; $c.Printers = @((New-TestPrinter 'Office')); $c.Cleanup.RemoveStaleManaged = $true
        $c.Cleanup.LegacyPrinterNames = @('Old Copy', '\\oldserver\queue')
        $queues = @(
            [pscustomobject]@{ Name='Office'; Type='Local'; DriverName='IPP'; PortName='office' },
            [pscustomobject]@{ Name='Microsoft Print to PDF'; Type='Local'; DriverName='PDF'; PortName='PORTPROMPT:' },
            [pscustomobject]@{ Name='Old Copy'; Type='Local'; DriverName='v4'; PortName='IP_old' },
            [pscustomobject]@{ Name='Stale'; Type='Local'; DriverName='v4'; PortName='IP_stale' },
            [pscustomobject]@{ Name='Repurposed'; Type='Local'; DriverName='new'; PortName='new' },
            [pscustomobject]@{ Name='\\oldserver\queue'; Type='Connection'; DriverName='v3'; PortName='UNC' }
        )
        $managed = @(
            [pscustomobject]@{ Name='Stale'; DriverName='v4'; PortName='IP_stale' },
            [pscustomobject]@{ Name='Repurposed'; DriverName='old'; PortName='old' }
        )
        $found = @(Get-PDCleanupCandidates $queues $c $managed)
        Assert-True ($found.Count -eq 2 -and 'Old Copy' -in $found.Name -and 'Stale' -in $found.Name) 'Cleanup selected an unexpected queue.'
        Assert-True (@(Get-PDCleanupCandidates $queues $c -UserConnectionsOnly).Count -eq 0) 'User cleanup must be disabled by default.'
        $c.Cleanup.CleanupUserConnections = $true
        $found = @(Get-PDCleanupCandidates $queues $c -UserConnectionsOnly)
        Assert-True ($found.Count -eq 1 -and $found[0].Type -eq 'Connection') 'User cleanup selected a machine queue.'
    }
    Test-Case 'Port identity ignores queue name and includes endpoint/port' {
        $p = New-TestPrinter 'One' 'Type4'; $p.Address = 'PRINTER.example.com'; $p.DriverName = 'Test Printer v4'
        $first = Get-PDPortName $p; $p.Name = 'Two'; $p.Address = 'printer.example.com'
        Assert-True ($first -eq (Get-PDPortName $p)) 'Equivalent endpoints got different ports.'
        $p.PortNumber = 9101; Assert-True ($first -ne (Get-PDPortName $p)) 'TCP port is missing from identity.'
    }
    Import-Module (Join-Path $projectRoot 'Modules/PrinterDeployment.Gui.psm1') -Force
    Test-Case 'Publishing produces a complete relocatable bundle' {
        $bundleRoot = Join-Path $tempRoot 'Published'
        New-Item -Path $bundleRoot -ItemType Directory | Out-Null
        $publishConfig = New-PDConfiguration; $publishConfig.Printers = @((New-TestPrinter))
        Publish-PDBundle $publishConfig $bundleRoot $projectRoot
        foreach ($relative in @('PrinterDeployment.ps1','Launch-Configurator.cmd','README.md','printers.json','GPO-Setup.txt','Install-PrinterDeploymentTask.ps1',
            'Modules/PrinterDeployment.Core.psm1','Modules/PrinterDeployment.Deploy.psm1','Modules/PrinterDeployment.Gui.psm1','Modules/PrinterDeployment.Clients.psm1','Client Logs')) {
            Assert-True (Test-Path -LiteralPath (Join-Path $bundleRoot $relative)) "Bundle missing $relative"
        }
        $published = Read-PDConfiguration (Join-Path $bundleRoot 'printers.json'); Assert-PDConfiguration $published $bundleRoot
        Assert-True ($published.DeploymentId -eq $publishConfig.DeploymentId) 'Publishing changed deployment identity.'
        Publish-PDBundle $publishConfig $bundleRoot $projectRoot
    }
    Test-Case 'Generated startup script parses, registers SYSTEM task and updates without duplicates' {
        $startupRoot = '\\server\Software\Office''s Printers $(throw 42)'
        $startupId = [guid]::NewGuid().ToString()
        $generated = Get-PDStartupScript -Root $startupRoot -DeploymentId $startupId
        $tokens = $null; $errors = $null
        [void][Management.Automation.Language.Parser]::ParseInput($generated, [ref]$tokens, [ref]$errors)
        Assert-True (-not $errors) 'Generated startup script has syntax errors.'
        $taskMock = @{ Tasks=@{}; Registrations=0 }
        . ([scriptblock]::Create($generated))
        function Assert-PDTaskHost { }
        function Import-Module { [CmdletBinding()]param([string]$Name) }
        function Get-ScheduledTask {
            [CmdletBinding()]param([string]$TaskName,[string]$TaskPath)
            if ($taskMock.Tasks.ContainsKey($TaskName)) { $taskMock.Tasks[$TaskName] }
        }
        function New-ScheduledTaskAction { param($Execute,$Argument) [pscustomobject]@{ Execute=$Execute; Arguments=$Argument } }
        function New-ScheduledTaskPrincipal { param($UserId,$LogonType,$RunLevel) [pscustomobject]@{ UserId=$UserId; LogonType=$LogonType; RunLevel=$RunLevel } }
        function New-ScheduledTaskTrigger {
            param([switch]$AtStartup,[switch]$Daily,[switch]$Once,$At)
            $kind = if ($AtStartup) { 'Boot' } elseif ($Daily) { 'Daily' } else { 'Once' }
            [pscustomobject]@{ Kind=$kind; Delay=''; At=$At }
        }
        function New-ScheduledTaskSettingsSet {
            param([switch]$StartWhenAvailable,$MultipleInstances,$RestartCount,$RestartInterval,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries,$ExecutionTimeLimit)
            [pscustomobject]@{ MultipleInstances=$MultipleInstances; RestartCount=$RestartCount; RestartInterval=$RestartInterval; StartWhenAvailable=[bool]$StartWhenAvailable }
        }
        function Register-ScheduledTask {
            [CmdletBinding()]param($TaskName,$TaskPath,$Action,$Principal,$Trigger,$Settings,$Description,[switch]$Force)
            $taskMock.Registrations++
            $taskMock.Tasks[$TaskName] = [pscustomobject]@{ Description=$Description; Action=$Action; Principal=$Principal; Triggers=$Trigger; Settings=$Settings }
        }
        $originalWindir = $env:windir; $env:windir = $tempRoot
        try {
            Invoke-PDTaskRegistration -WhatIf
            Assert-True ($taskMock.Registrations -eq 0) 'Startup WhatIf registered a task.'
            Invoke-PDTaskRegistration; Invoke-PDTaskRegistration
            Assert-True ($taskMock.Tasks.Count -eq 1 -and $taskMock.Registrations -eq 2) 'Startup made duplicate tasks.'
            $task = $taskMock.Tasks['PrinterDeploymentTool-' + $startupId]
            Assert-True ($task.Principal.UserId -eq 'S-1-5-18' -and $task.Principal.LogonType -eq 'ServiceAccount' -and $task.Principal.RunLevel -eq 'Highest') 'Wrong task identity or privileges.'
            Assert-True ($task.Triggers.Count -eq 3 -and $task.Triggers[0].Delay -eq 'PT1M') 'Boot/initial/daily triggers missing.'
            Assert-True ($task.Settings.MultipleInstances -eq 'IgnoreNew' -and $task.Settings.RestartCount -eq 3 -and $task.Settings.RestartInterval.TotalMinutes -eq 5) 'Retry settings incorrect.'
            $expectedPath = $startupRoot + '\PrinterDeployment.ps1'
            Assert-True ($task.Action.Arguments.Contains('"' + $expectedPath + '"')) 'Share path was changed or unquoted.'
            Assert-True ($task.Action.Arguments -notmatch 'ExecutionPolicy') 'Bootstrap bypasses execution policy.'
            $task.Description = 'Unrelated task'
            Assert-Throws { Invoke-PDTaskRegistration } 'outside this tool'
            Assert-True ($taskMock.Registrations -eq 2) 'Startup overwrote an unrelated task.'
        } finally { $env:windir = $originalWindir }
    }
    Test-Case 'Publishing and resource validation reject linked folders' {
        $linkRoot = Join-Path $tempRoot 'LinkedBundle'; $outside = Join-Path $tempRoot 'Outside'
        New-Item -Path $linkRoot,$outside -ItemType Directory | Out-Null
        $linkType = if ($env:OS -eq 'Windows_NT') { 'Junction' } else { 'SymbolicLink' }
        New-Item -Path (Join-Path $linkRoot 'Modules') -ItemType $linkType -Target $outside | Out-Null
        $publishConfig = New-PDConfiguration
        Assert-Throws { Publish-PDBundle $publishConfig $linkRoot $projectRoot } 'Linked resources'
        Assert-True (@(Get-ChildItem -LiteralPath $outside).Count -eq 0) 'Publishing followed a link outside the deployment.'
        Assert-Throws { Resolve-PDResource $linkRoot 'Modules/file.psm1' } 'Linked resources'
    }
    Test-Case 'Client selections produce validated scoped requests, preserve IDs and can be cleared' {
        $selectionConfig=New-PDConfiguration; $selectionConfig.Printers=@((New-TestPrinter 'Desired'))
        $report=[pscustomobject]@{ ComputerName='PC001'; Scope='Machine'; UserSid=''; DeploymentId=$selectionConfig.DeploymentId }
        $extra=[pscustomobject]@{ Name='Old Printer'; Type='Local'; DriverName='Old Driver'; PortName='IP_old' }
        Set-PDClientRemovalSelection $selectionConfig $report $extra $true
        Assert-PDConfiguration $selectionConfig $tempRoot
        $id=$selectionConfig.ClientRemovals[0].Id
        Set-PDClientRemovalSelection $selectionConfig $report $extra $true
        Assert-True ($selectionConfig.ClientRemovals.Count -eq 1 -and $selectionConfig.ClientRemovals[0].Id -eq $id) 'Checkbox toggling duplicated or reissued a request.'
        Assert-True (@(Get-PDClientRemovalRequests $selectionConfig ([pscustomobject]@{ ComputerName='PC002'; Scope='Machine'; UserSid='' })).Count -eq 0) 'Request targeted another client.'
        $extra.Name='Desired'; Assert-Throws { Set-PDClientRemovalSelection $selectionConfig $report $extra $true } 'desired configuration'
        $extra.Name='Old Printer'; Set-PDClientRemovalSelection $selectionConfig $report $extra $false
        Assert-True ($selectionConfig.ClientRemovals.Count -eq 0) 'Clearing selection did not clear request.'
        $report.Scope='UserConnection'; $report.UserSid='S-1-5-21-100-100-100-1100'
        Assert-Throws { Set-PDClientRemovalSelection $selectionConfig $report $extra $true } 'only remove user connections'
        $extra.Type='Connection'; Set-PDClientRemovalSelection $selectionConfig $report $extra $true
        Assert-PDConfiguration $selectionConfig $tempRoot
        $selectionConfig.ClientRemovals[0].ComputerName='*'; Assert-Throws { Assert-PDConfiguration $selectionConfig $tempRoot } 'exact computer name'
    }
    Test-Case 'Configuration revision survives JSON date normalization on removal requests' {
        $hashConfig=New-PDConfiguration
        $report=[pscustomobject]@{ ComputerName='PC001'; Scope='Machine'; UserSid=''; DeploymentId=$hashConfig.DeploymentId }
        $extra=[pscustomobject]@{ Name='Old Printer'; Type='Local'; DriverName='Old Driver'; PortName='IP_old' }
        Set-PDClientRemovalSelection $hashConfig $report $extra $true
        $path=Join-Path $tempRoot 'hash.json'; Write-PDJson $hashConfig $path
        Assert-True ((Get-PDConfigurationHash $hashConfig) -eq (Get-PDConfigurationHash (Read-PDConfiguration $path))) 'Saved/read requests changed the configuration revision.'
    }
    Test-Case 'Report round-trip includes inventories, errors and filters unrelated or malformed reports' {
        $reportRoot=Join-Path $tempRoot 'ReportTests'; New-Item -ItemType Directory -Path $reportRoot | Out-Null
        $reportConfig=New-PDConfiguration
        $identity=[pscustomobject]@{ ComputerName='PC001'; Scope='Machine'; UserSid=''; UserName='SYSTEM' }
        $extra=[pscustomobject]@{ Name='Old Printer'; Type='Local'; DriverName='Old Driver'; PortName='IP_old'; Location='' }
        $report=New-PDClientReport -Config $reportConfig -Identity $identity -Before @($extra) -After @($extra) -Result Failed -ErrorMessage 'Driver installation failed' -StartedAt (Get-Date -Format o)
        Write-PDClientReport $reportRoot $report
        $reports=@(Get-PDClientReports $reportRoot $reportConfig.DeploymentId)
        Assert-True ($reports.Count -eq 1 -and $reports[0].Printers.Count -eq 1 -and $reports[0].Before.Count -eq 1 -and $reports[0].ErrorMessage -eq 'Driver installation failed') 'Report fields were lost.'
        Assert-True (@(Get-PDClientReports $reportRoot ([guid]::NewGuid().ToString())).Count -eq 0) 'Unrelated reports leaked into deployment view.'
        $broken=Join-Path $reportRoot 'Client Logs/BROKEN'; New-Item -ItemType Directory -Path $broken | Out-Null
        '{ invalid json' | Set-Content (Join-Path $broken 'latest.json')
        Assert-True (@(Get-PDClientReports $reportRoot $reportConfig.DeploymentId -WarningAction SilentlyContinue).Count -eq 1) 'Corrupt report prevented reading valid reports.'
        Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $reportRoot 'Client Logs/PC001') -Filter '*.json').Count -eq 2) 'Run history and latest snapshot not written.'
    }
    Test-Case 'Missing desired queue prevents a successful final report' {
        $reportConfig=New-PDConfiguration; $reportConfig.Printers=@((New-TestPrinter))
        $identity=[pscustomobject]@{ ComputerName='PC001'; Scope='Machine'; UserSid=''; UserName='SYSTEM' }
        $report=New-PDClientReport -Config $reportConfig -Identity $identity -Result Success -StartedAt (Get-Date -Format o)
        Assert-True ($report.Result -eq 'Failed' -and $report.ConfiguredPrinters[0].Status -eq 'Missing') 'Missing desired queue was reported as successful.'
    }

    # Mock external Windows dependencies in the deployment module. Real configuration,
    # planning, reconciliation, state persistence and cleanup logic remain in use.
    Import-Module (Join-Path $projectRoot 'Modules/PrinterDeployment.Deploy.psm1') -Force
    $module = Get-Module PrinterDeployment.Deploy
    $global:PDMock = @{ Printers = @(); Ports = @(); Events = (New-Object 'System.Collections.Generic.List[string]'); DriverFailure = $false; IppFailure = $false; ComputerName='PC001'; UserSid='S-1-5-21-100-100-100-1100'; UploadFailure=$false }
    & $module {
        function script:Import-Module { [CmdletBinding()]param([string]$Name) }
        function script:Assert-PDAdministrator { }
        function script:Get-PDClientIdentity {
            param([string]$Scope)
            $sid=if ($Scope -eq 'Machine') { '' } else { $global:PDMock.UserSid }
            [pscustomobject]@{ ComputerName=$global:PDMock.ComputerName; Scope=$Scope; UserSid=$sid; UserName='Test identity' }
        }
        function script:Write-PDClientReport {
            param([string]$Root,$Report)
            if ($global:PDMock.UploadFailure) { throw 'Mock report upload denied' }
            & (Get-Module PrinterDeployment.Clients) { param($Root,$Report) Write-PDClientReport -Root $Root -Report $Report } $Root $Report
        }
        function script:Initialize-PDStateFolder {
            param([string]$Path,[switch]$ReadOnly)
            if (-not $ReadOnly) { New-Item -ItemType Directory -Path $Path -Force -WhatIf:$false | Out-Null }
        }
        function script:Get-Service { [CmdletBinding()]param([string]$Name) [pscustomobject]@{ Status='Running' } }
        function script:Get-Printer { [CmdletBinding()]param() $global:PDMock.Printers }
        function script:Get-PrinterPort { [CmdletBinding()]param() $global:PDMock.Ports }
        function script:Get-CimInstance { [CmdletBinding()]param([string]$ClassName) $global:PDMock.Ports }
        function script:Install-PDType4Driver {
            param($Printer,[string]$Root)
            $global:PDMock.Events.Add('Driver:' + $Printer.DriverName)
            if ($global:PDMock.DriverFailure) { throw 'Mock driver staging failure' }
        }
        function script:Add-Printer {
            [CmdletBinding()]param([string]$Name,[string]$IppURL,[string]$DriverName,[string]$PortName,[string]$Location,[string]$Comment)
            $global:PDMock.Events.Add('Add:' + $Name)
            if ($IppURL) {
                if ($global:PDMock.IppFailure) { throw 'Mock IPP unavailable' }
                $DriverName = 'Microsoft IPP Class Driver'; $PortName = 'IPP_' + $Name
            }
            $global:PDMock.Printers += [pscustomobject]@{ Name=$Name; Type='Local'; DriverName=$DriverName; PortName=$PortName; Location=$Location; Comment=$Comment }
        }
        function script:Remove-Printer {
            [CmdletBinding()]param($InputObject)
            $global:PDMock.Events.Add('Remove:' + $InputObject.Name)
            $global:PDMock.Printers = @($global:PDMock.Printers | Where-Object { $_.Name -ne $InputObject.Name })
        }
        function script:Set-Printer {
            [CmdletBinding()]param($InputObject,[string]$DriverName,[string]$PortName,[string]$Location,[string]$Comment)
            $global:PDMock.Events.Add('Set:' + $InputObject.Name)
            foreach ($key in @('DriverName','PortName','Location','Comment')) { if ($PSBoundParameters.ContainsKey($key)) { $InputObject.$key = $PSBoundParameters[$key] } }
        }
        function script:Add-PrinterPort {
            [CmdletBinding()]param([string]$Name,[string]$PrinterHostAddress,[int]$PortNumber,[int]$SNMP)
            $global:PDMock.Events.Add('Port:' + $Name)
            $global:PDMock.Ports += [pscustomobject]@{ Name=$Name; HostAddress=$PrinterHostAddress; PortNumber=$PortNumber; Protocol=1; SNMPEnabled=$false }
        }
    }
    $env:ProgramData = Join-Path $tempRoot 'ProgramData'; $env:PROCESSOR_ARCHITECTURE = 'AMD64'
    $env:LOCALAPPDATA = Join-Path $tempRoot 'LocalAppData'
    $deploymentFile = Join-Path $tempRoot 'printers.json'
    $c = New-PDConfiguration; $c.Printers = @((New-TestPrinter)); Write-PDJson $c $deploymentFile
    Test-Case 'WhatIf causes no printer changes and no local state or logs' {
        Invoke-PDDeployment -ConfigPath $deploymentFile -WhatIf -RetryCount 1
        Assert-True ($global:PDMock.Events.Count -eq 0) 'WhatIf called a mutation.'
        Assert-True (-not (Test-Path $env:ProgramData)) 'WhatIf wrote local files.'
    }
    Test-Case 'IPP installation records ownership and repeated runs create no duplicates' {
        Invoke-PDDeployment -ConfigPath $deploymentFile -RetryCount 1
        Invoke-PDDeployment -ConfigPath $deploymentFile -RetryCount 1
        Assert-True ($global:PDMock.Printers.Count -eq 1) 'Repeated deployment made duplicates.'
        Assert-True (@($global:PDMock.Events | Where-Object { $_ -eq 'Add:Office' }).Count -eq 1) 'IPP discovery ran again unnecessarily.'
        $state = Read-PDConfiguration (Join-Path $env:ProgramData ("PrinterDeploymentTool/" + $c.DeploymentId + '/state.json'))
        Assert-True ($state.Printers.Count -eq 1 -and $state.Printers[0].DriverName -eq 'Microsoft IPP Class Driver') 'Ownership state missing.'
        $reports=@(Get-PDClientReports $tempRoot $c.DeploymentId)
        Assert-True ($reports.Count -eq 1 -and $reports[0].Result -eq 'Success' -and $reports[0].ConfiguredPrinters[0].Status -eq 'Installed') 'Successful deployment was not reported.'
    }
    Test-Case 'IPP URL changes reconcile a managed queue and preserve a single queue' {
        $c.Printers[0].Address = 'ipp://new.example.com/ipp/print'; Write-PDJson $c $deploymentFile
        Invoke-PDDeployment -ConfigPath $deploymentFile -RetryCount 1
        Assert-True ($global:PDMock.Printers.Count -eq 1) 'IPP reconciliation duplicated queues.'
        Assert-True ('Remove:Office' -in $global:PDMock.Events) 'Old IPP queue was not reconciled.'
    }
    Test-Case 'Failed IPP URL replacement attempts restoration and reports failure' {
        $c.Printers[0].Address = 'ipp://unavailable.example.com/ipp/print'; Write-PDJson $c $deploymentFile
        $global:PDMock.IppFailure = $true
        Assert-Throws { Invoke-PDDeployment -ConfigPath $deploymentFile -RetryCount 1 } 'Mock IPP unavailable'
        $global:PDMock.IppFailure = $false
        Assert-True ($global:PDMock.Printers.Count -eq 1) 'Prior IPP queue was not restored.'
        $reports=@(Get-PDClientReports $tempRoot $c.DeploymentId)
        Assert-True ($reports[0].Result -eq 'Failed' -and $reports[0].ErrorMessage -match 'Mock IPP unavailable') 'Failed deployment was not reported.'
    }
    Test-Case 'Foreign same-name queue aborts before cleanup' {
        $foreign = New-PDConfiguration; $foreign.Printers = @((New-TestPrinter)); $foreign.Cleanup.LegacyPrinterNames = @('Old Copy')
        $global:PDMock.Printers += [pscustomobject]@{ Name='Old Copy'; Type='Local'; DriverName='v4'; PortName='Old'; Location=''; Comment='' }
        Write-PDJson $foreign $deploymentFile
        $count = $global:PDMock.Events.Count
        Assert-Throws { Invoke-PDDeployment -ConfigPath $deploymentFile -RetryCount 1 } 'outside this tool'
        Assert-True ($count -eq $global:PDMock.Events.Count -and 'Old Copy' -in $global:PDMock.Printers.Name) 'Collision caused mutation.'
    }
    Test-Case 'Invalid configuration fails before any cleanup or install command' {
        $invalid = New-PDConfiguration; $p = New-TestPrinter 'Broken'; $p.Address = 'invalid'; $invalid.Printers = @($p)
        $invalid.Cleanup.LegacyPrinterNames = @('Old Copy'); Write-PDJson $invalid $deploymentFile
        $count = $global:PDMock.Events.Count
        Assert-Throws { Invoke-PDDeployment -ConfigPath $deploymentFile -RetryCount 1 } 'full IPP URL'
        Assert-True ($count -eq $global:PDMock.Events.Count -and 'Old Copy' -in $global:PDMock.Printers.Name) 'Invalid configuration caused changes.'
    }
    Test-Case 'Driver failure aborts legacy cleanup; success installs Type4 and reuses its port' {
        $typeConfig = New-PDConfiguration; $p = New-TestPrinter 'TCP Printer' 'Type4'; $p.Address = '192.0.2.55'
        $p.PackagePath = 'Drivers\vendor'; $p.InfPath = 'Drivers\vendor\printer.inf'; $p.DriverName = 'Test Printer v4'
        $typeConfig.Printers = @($p); $typeConfig.Cleanup.LegacyPrinterNames = @('Old Copy'); Write-PDJson $typeConfig $deploymentFile
        $global:PDMock.Ports = @([pscustomobject]@{ Name=(Get-PDPortName $p); HostAddress='192.0.2.99'; PortNumber=9100; Protocol=1; SNMPEnabled=$false })
        $before = $global:PDMock.Events.Count
        Assert-Throws { Invoke-PDDeployment -ConfigPath $deploymentFile -RetryCount 1 } 'different settings'
        Assert-True ($before -eq $global:PDMock.Events.Count) 'Conflicting port caused a driver/queue mutation.'
        $global:PDMock.Ports = @()
        $global:PDMock.DriverFailure = $true
        Assert-Throws { Invoke-PDDeployment -ConfigPath $deploymentFile -RetryCount 1 } 'Mock driver staging failure'
        Assert-True ('Old Copy' -in $global:PDMock.Printers.Name) 'Legacy queue was removed before driver staging succeeded.'
        $global:PDMock.DriverFailure = $false
        Invoke-PDDeployment -ConfigPath $deploymentFile -RetryCount 1
        Invoke-PDDeployment -ConfigPath $deploymentFile -RetryCount 1
        Assert-True ('Old Copy' -notin $global:PDMock.Printers.Name) 'Legacy queue was not removed.'
        Assert-True ($global:PDMock.Ports.Count -eq 1) 'Repeated deployment duplicated ports.'
        Assert-True (@($global:PDMock.Printers | Where-Object { $_.Name -eq 'TCP Printer' }).Count -eq 1) 'Repeated Type4 deployment duplicated queue.'
        $typeConfig.Printers = @(); $typeConfig.Cleanup.RemoveStaleManaged = $true; Write-PDJson $typeConfig $deploymentFile
        Invoke-PDDeployment -ConfigPath $deploymentFile -RetryCount 1
        Assert-True ('TCP Printer' -notin $global:PDMock.Printers.Name -and 'Office' -in $global:PDMock.Printers.Name) 'Stale cleanup affected another deployment.'
    }
    Test-Case 'User cleanup removes only opted-in exact connection names' {
        $userConfig = New-PDConfiguration; $userConfig.Cleanup.CleanupUserConnections = $true
        $userConfig.Cleanup.LegacyPrinterNames = @('\\oldserver\queue','Office'); Write-PDJson $userConfig $deploymentFile
        $global:PDMock.Printers += [pscustomobject]@{ Name='\\oldserver\queue'; Type='Connection'; DriverName='v3'; PortName='UNC'; Location=''; Comment='' }
        Invoke-PDUserCleanup $deploymentFile -WhatIf
        Assert-True ('\\oldserver\queue' -in $global:PDMock.Printers.Name) 'User WhatIf changed queues.'
        Invoke-PDUserCleanup $deploymentFile
        Assert-True ('\\oldserver\queue' -notin $global:PDMock.Printers.Name -and 'Office' -in $global:PDMock.Printers.Name) 'User cleanup removed a machine queue.'
    }
    Test-Case 'Selected machine removals are scoped, fingerprint checked and applied once' {
        $cleanupConfig=New-PDConfiguration
        $extra=[pscustomobject]@{ Name='Extra Copy'; Type='Local'; DriverName='Old Driver'; PortName='IP_extra'; Location=''; Comment='' }
        $global:PDMock.Printers += $extra
        $identity=[pscustomobject]@{ ComputerName='PC002'; Scope='Machine'; UserSid=''; DeploymentId=$cleanupConfig.DeploymentId }
        Set-PDClientRemovalSelection $cleanupConfig $identity $extra $true
        Write-PDJson $cleanupConfig $deploymentFile
        Invoke-PDDeployment $deploymentFile -RetryCount 1
        Assert-True ('Extra Copy' -in $global:PDMock.Printers.Name) 'Request removed a queue on the wrong computer.'
        $cleanupConfig.ClientRemovals=@(); $identity.ComputerName='PC001'; Set-PDClientRemovalSelection $cleanupConfig $identity $extra $true
        Write-PDJson $cleanupConfig $deploymentFile
        Invoke-PDDeployment $deploymentFile -RetryCount 1 -WhatIf
        Assert-True ('Extra Copy' -in $global:PDMock.Printers.Name) 'WhatIf applied a client removal.'
        $extra.PortName='IP_changed'
        Assert-Throws { Invoke-PDDeployment $deploymentFile -RetryCount 1 } 'no longer matches'
        Assert-True ('Extra Copy' -in $global:PDMock.Printers.Name) 'Changed queue was removed.'
        $extra.PortName='IP_extra'
        Invoke-PDDeployment $deploymentFile -RetryCount 1
        Assert-True ('Extra Copy' -notin $global:PDMock.Printers.Name) 'Selected queue was not removed.'
        $report=@(Get-PDClientReports $tempRoot $cleanupConfig.DeploymentId)[0]
        Assert-True ($report.RemovalResults[0].Status -eq 'Removed' -and 'Extra Copy' -in $report.Before.Name) 'Removal result or before inventory missing.'
        $global:PDMock.Printers += $extra
        Invoke-PDDeployment $deploymentFile -RetryCount 1
        Assert-True ('Extra Copy' -in $global:PDMock.Printers.Name) 'Completed one-shot request deleted a later queue.'
        $report=@(Get-PDClientReports $tempRoot $cleanupConfig.DeploymentId)[0]
        Assert-True ($report.RemovalResults[0].Status -eq 'Completed') 'Completed request not reported.'
    }
    Test-Case 'User removal requests apply only in the selected user profile and publish user inventory' {
        $cleanupConfig=New-PDConfiguration
        $extra=[pscustomobject]@{ Name='\\oldserver\selected'; Type='Connection'; DriverName='Old Driver'; PortName='UNC'; Location=''; Comment='' }
        $global:PDMock.Printers += $extra
        $identity=[pscustomobject]@{ ComputerName='PC001'; Scope='UserConnection'; UserSid='S-1-5-21-100-100-100-1200'; DeploymentId=$cleanupConfig.DeploymentId }
        Set-PDClientRemovalSelection $cleanupConfig $identity $extra $true
        Write-PDJson $cleanupConfig $deploymentFile
        Invoke-PDUserCleanup $deploymentFile
        Assert-True ($extra.Name -in $global:PDMock.Printers.Name) 'Wrong user request applied.'
        $global:PDMock.UserSid=$identity.UserSid
        Invoke-PDUserCleanup $deploymentFile
        Assert-True ($extra.Name -notin $global:PDMock.Printers.Name) 'Selected user connection not removed.'
        $reports=@(Get-PDClientReports $tempRoot $cleanupConfig.DeploymentId)
        Assert-True ($reports.Count -eq 2 -and @($reports | Where-Object { $_.RemovalResults.Count -eq 1 -and $_.RemovalResults[0].Status -eq 'Removed' }).Count -eq 1) 'Per-user inventories were overwritten or not reported.'
        $global:PDMock.Printers += $extra
        Invoke-PDUserCleanup $deploymentFile
        Assert-True ($extra.Name -in $global:PDMock.Printers.Name) 'User one-shot request removed a re-created connection.'
    }
    Test-Case 'Upload failure keeps a local report, returns failure, and preserves an earlier deployment error' {
        $uploadConfig=New-PDConfiguration; Write-PDJson $uploadConfig $deploymentFile
        $global:PDMock.UploadFailure=$true
        try {
            Assert-Throws { Invoke-PDDeployment $deploymentFile -RetryCount 1 } 'Mock report upload denied'
            $local=Read-PDConfiguration (Join-Path $env:ProgramData ('PrinterDeploymentTool/' + $uploadConfig.DeploymentId + '/last-report.json'))
            Assert-True ($local.Result -eq 'Success' -and $local.Printers.Count -gt 0) 'Local report was lost when upload failed.'
            $uploadConfig.Printers=@((New-TestPrinter 'Office')); Write-PDJson $uploadConfig $deploymentFile
            Assert-Throws { Invoke-PDDeployment $deploymentFile -RetryCount 1 } 'outside this tool'
            $local=Read-PDConfiguration (Join-Path $env:ProgramData ('PrinterDeploymentTool/' + $uploadConfig.DeploymentId + '/last-report.json'))
            Assert-True ($local.Result -eq 'Failed' -and $local.ErrorMessage -match 'outside this tool') 'Original failure not retained in local report.'
        } finally { $global:PDMock.UploadFailure=$false }
    }
    Write-Host "All $script:Passed tests passed. Windows integration and GUI pilot still required."
} finally {
    $env:ProgramData = $originalProgramData; $env:PROCESSOR_ARCHITECTURE = $originalArchitecture
    $env:LOCALAPPDATA = $originalLocalAppData
    Remove-Variable PDMock -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
