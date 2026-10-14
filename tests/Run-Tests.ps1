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
        foreach ($file in @(Get-ChildItem -LiteralPath $projectRoot -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1') })) {
            $tokens = $null; $errors = $null
            [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
            Assert-True (-not $errors) ("Syntax errors in $($file.Name): " + ($errors -join '; '))
        }
    }
    Test-Case 'Entry point resolves default config beside the script from another working folder' {
        $fixture=Join-Path $tempRoot 'Entry point with spaces'; $fixtureModules=Join-Path $fixture 'Modules'
        New-Item -ItemType Directory -Path $fixtureModules -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $projectRoot 'PrinterDeployment.ps1') -Destination $fixture
        Copy-Item -LiteralPath (Join-Path $projectRoot 'Modules/PrinterDeployment.Core.psm1') -Destination $fixtureModules
        Copy-Item -LiteralPath (Join-Path $projectRoot 'examples/printers.ipp.json') -Destination (Join-Path $fixture 'printers.json')
        $hostExecutable=(Get-Process -Id $PID).Path
        $entry=Join-Path $fixture 'PrinterDeployment.ps1'
        Push-Location $tempRoot
        try {
            $output=& $hostExecutable -NoProfile -ExecutionPolicy Bypass -File $entry -Mode Validate 2>&1
            Assert-True ($LASTEXITCODE -eq 0 -and ($output -join ' ') -match 'resources|packaged driver models are valid') ('Default path startup failed: ' + ($output -join ' '))
            $output=& $hostExecutable -NoProfile -ExecutionPolicy Bypass -File $entry -Mode Validate -ConfigPath (Join-Path $fixture 'printers.json') 2>&1
            Assert-True ($LASTEXITCODE -eq 0) ('Explicit path startup failed: ' + ($output -join ' '))
        } finally { Pop-Location }
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
    Test-Case 'Driver catalog combines x64 and ARM64 and reports support per selected model' {
        $catalog=@(Get-PDInfDriverCatalog $inf)
        Assert-True ($catalog.Count -eq 4) 'Architecture union omitted models.'
        Assert-True (@($catalog | Where-Object { $_.Name -eq 'ARM printer' })[0].Architectures[0] -eq 'ARM64') 'ARM-only model was incorrectly labelled.'
        $both=Join-Path $packagePath 'both.inf'
        (Get-Content $inf -Raw).Replace('"ARM printer"=Install,ARMHWID','%Model%=Install,ARMHWID') | Set-Content $both -Encoding Unicode
        $entry=@(Get-PDInfDriverCatalog $both | Where-Object { $_.Name -eq 'Test Printer v4' })[0]
        Assert-True ($entry.Architectures.Count -eq 2 -and 'x64' -in $entry.Architectures -and 'ARM64' -in $entry.Architectures) 'Dual architecture support was not detected.'
        $config=New-PDConfiguration; $printer=New-TestPrinter 'ARM queue' 'Type4'; $printer.Address='192.0.2.59'; $printer.PackagePath='Drivers\vendor'; $printer.InfPath='Drivers\vendor\printer.inf'; $printer.DriverName='ARM printer'; $config.Printers=@($printer)
        Assert-PDConfiguration $config $tempRoot
    }
    Test-Case 'IPP is architecture independent and packaged drivers match native INF models' {
        $printer=New-TestPrinter
        Assert-True (Test-PDPrinterArchitecture $printer $tempRoot ARM64) 'IPP incorrectly requires architecture-specific resources.'
        $printer.Kind='Type4'; $printer.InfPath='Drivers\vendor\printer.inf'; $printer.DriverName='Test Printer v4'
        Assert-True (Test-PDPrinterArchitecture $printer $tempRoot x64) 'x64 driver was not detected.'
        Assert-True (-not (Test-PDPrinterArchitecture $printer $tempRoot ARM64)) 'x64 model was offered to ARM64.'
        $printer.DriverName='ARM printer'; Assert-True (Test-PDPrinterArchitecture $printer $tempRoot ARM64) 'ARM64 driver was not detected.'
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
    Test-Case 'IPP host/protocol/subpath builds URLs with automatic ports and supports IPv6' {
        Assert-True ((New-PDIppAddress '192.0.2.55') -eq 'ipp://192.0.2.55:631/ipp') 'IPP defaults incorrect.'
        Assert-True ((New-PDIppAddress 'printer.example.com' ipps 'ipp/print') -eq 'ipps://printer.example.com:631/ipp/print') 'IPPS defaults or path normalization incorrect.'
        Assert-True ((New-PDIppAddress 'printer.example.com' ipps '/ipp/print' 443) -eq 'ipps://printer.example.com:443/ipp/print') 'Custom port lost.'
        Assert-True ((New-PDIppAddress '2001:db8::55') -eq 'ipp://[2001:db8::55]:631/ipp') 'IPv6 was not bracketed.'
        foreach ($address in @('ipp://printer.example.com:631/ipp','ipps://printer.example.com:443/ipp/print','https://printer.example.com/ipp/print?queue=1','ipp://[2001:db8::55]/ipp')) {
            $parts=Split-PDIppAddress $address
            $rebuilt=Split-PDIppAddress (New-PDIppAddress -HostName $parts.HostName -Protocol $parts.Protocol -Subpath $parts.Subpath -PortNumber $parts.PortNumber)
            Assert-True ($parts.Protocol -eq $rebuilt.Protocol -and $parts.HostName -eq $rebuilt.HostName -and $parts.PortNumber -eq $rebuilt.PortNumber -and $parts.Subpath -eq $rebuilt.Subpath) 'Saved IPP endpoint changed.'
        }
        foreach ($hostValue in @('ipp://printer.example.com','printer.example.com:631','printer.example.com/ipp','user@printer.example.com')) {
            Assert-Throws { New-PDIppAddress $hostValue } 'only the printer'
        }
        Assert-Throws { New-PDIppAddress 'printer.example.com' ipp '//other/ipp' } 'subpath'
        Assert-Throws { New-PDIppAddress 'printer.example.com' ipp '/ipp#fragment' } 'subpath'
    }
    Test-Case 'Type 3 INF validation is explicit and rejects Type 4 packages' {
        $type3Inf=Join-Path $packagePath 'type3-valid.inf'
        (Get-Content $inf -Raw).Replace('ClassVer=4.0 ; v4','') | Set-Content $type3Inf -Encoding Unicode
        $models=@(Get-PDInfModels $type3Inf x64 -DriverType 3)
        Assert-True ('Test Printer v4' -in $models) 'Type 3 model enumeration failed.'
        Assert-Throws { Get-PDInfModels $inf x64 -DriverType 3 } 'Type 3'
        $config=New-PDConfiguration; $printer=New-TestPrinter 'Legacy v3' 'Type3'
        $printer.Address='192.0.2.56'; $printer.PackagePath='Drivers\vendor'; $printer.InfPath='Drivers\vendor\type3-valid.inf'; $printer.DriverName='Test Printer v4'
        $config.Printers=@($printer); Assert-PDConfiguration $config $tempRoot
        $printer.Kind='Type4'; Assert-Throws { Assert-PDConfiguration $config $tempRoot } 'Only Type 4'
    }
    Test-Case 'Architecture overrides validate packages, types and schema without duplicating queue identity' {
        $config=New-PDConfiguration; $printer=New-TestPrinter 'Both architectures' 'Type4'; $printer.Address='192.0.2.60'
        $x64=[pscustomobject]@{ Kind='Type3'; PackagePath='Drivers\vendor'; InfPath='Drivers\vendor\type3-valid.inf'; DriverName='Test Printer v4' }
        $arm=[pscustomobject]@{ Kind='Type4'; PackagePath='Drivers\vendor'; InfPath='Drivers\vendor\printer.inf'; DriverName='ARM printer' }
        $printer | Add-Member -NotePropertyName DriverPackages -NotePropertyValue ([pscustomobject]@{ x64=$x64; ARM64=$arm }); $config.Printers=@($printer)
        Assert-Throws { Assert-PDConfiguration $config $tempRoot } 'schema 2'
        $config.SchemaVersion=2; Assert-PDConfiguration $config $tempRoot
        $resolved=Get-PDPrinterDriverForArchitecture $printer x64
        Assert-True ($resolved.Kind -eq 'Type3' -and $resolved.Name -eq $printer.Name -and $resolved.Address -eq $printer.Address -and $printer.Kind -eq 'Type4' -and $printer.DriverName -eq '') 'Native override changed the original queue definition.'
        Assert-True ((Test-PDPrinterArchitecture $printer $tempRoot x64) -and (Test-PDPrinterArchitecture $printer $tempRoot ARM64)) 'Separate native packages were not applicable.'
        $arm.DriverName='Test Printer v4'; Assert-Throws { Assert-PDConfiguration $config $tempRoot } 'ARM64 model support'; $arm.DriverName='ARM printer'
        $arm.InfPath='Drivers\..\escape.inf'; Assert-Throws { Assert-PDConfiguration $config $tempRoot } 'inside|escapes'; $arm.InfPath='Drivers\vendor\printer.inf'
        $printer.DriverPackages | Add-Member -NotePropertyName x86 -NotePropertyValue $x64; Assert-Throws { Assert-PDConfiguration $config $tempRoot } 'keys must'; $printer.DriverPackages.PSObject.Properties.Remove('x86')
        $printer.DriverPackages.PSObject.Properties.Remove('ARM64')
        Assert-True (-not (Test-PDPrinterArchitecture $printer $tempRoot ARM64)) 'An absent native package should be unsupported.'
        $printer.PackagePath=$arm.PackagePath; $printer.InfPath=$arm.InfPath; $printer.DriverName=$arm.DriverName
        Assert-PDConfiguration $config $tempRoot
        Assert-True ((Get-PDPrinterDriverForArchitecture $printer ARM64).DriverName -eq 'ARM printer' -and (Get-PDPrinterDriverForArchitecture $printer x64).Kind -eq 'Type3') 'Shared fallback or override precedence failed.'
        Write-PDJson $config (Join-Path $tempRoot 'variants.json'); Assert-PDConfiguration (Read-PDConfiguration (Join-Path $tempRoot 'variants.json')) $tempRoot
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
        foreach ($relative in @('PrinterDeployment.ps1','Launch-Configurator.cmd','README.md','printers.json','GPO-Setup.txt','Install-PrinterDeploymentTask.ps1','Report-UserPrinters.ps1',
            'Modules/PrinterDeployment.Core.psm1','Modules/PrinterDeployment.Deploy.psm1','Modules/PrinterDeployment.Gui.psm1','Modules/PrinterDeployment.Clients.psm1',
            'Templates/Install-PrinterDeploymentTask.ps1.template','Templates/Report-UserPrinters.ps1.template','Client Logs')) {
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
    Test-Case 'Generated user logon export forwards literal paths and creates no scheduled task' {
        $logonRoot='\\server\Software\Office''s Printers $(throw 42)'
        $generated=Get-PDUserLogonScript $logonRoot
        $tokens=$null; $errors=$null
        [void][Management.Automation.Language.Parser]::ParseInput($generated,[ref]$tokens,[ref]$errors)
        Assert-True (-not $errors) 'User logon export has syntax errors.'
        Assert-True ($generated -notmatch 'Register-ScheduledTask|ExecutionPolicy') 'User logon export adds a task or bypasses policy.'
        $fixture=Join-Path $tempRoot 'fake-host.ps1'
        '$global:PDLogonArgs = @($args); $global:LASTEXITCODE = 0' | Set-Content $fixture
        function Join-Path { param($Path,$ChildPath) $fixture }
        $originalWindir=$env:windir; $env:windir=$tempRoot
        try {
            . ([scriptblock]::Create($generated))
            Invoke-PDUserLogon
            Assert-True ($global:PDLogonArgs[3] -ceq ($logonRoot + '\PrinterDeployment.ps1')) 'Share path was interpolated or split.'
            Assert-True ($global:PDLogonArgs[5] -eq 'CleanupUser' -and $global:PDLogonArgs[7] -ceq ($logonRoot + '\printers.json')) 'Wrong user mode or configuration.'
            $WhatIf=$true; Invoke-PDUserLogon
            Assert-True ($global:PDLogonArgs[-1] -eq '-WhatIf') 'User logon preview was not forwarded.'
        } finally { $env:windir=$originalWindir; Remove-Variable PDLogonArgs -Scope Global -ErrorAction SilentlyContinue }
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
    Test-Case 'Combined computer inventory deduplicates local queues and keeps user removal identities' {
        $config=New-PDConfiguration
        $local=[pscustomobject]@{ Name='Local'; Type='Local'; DriverName='Class'; PortName='IPP'; Location='' }
        $connection=[pscustomobject]@{ Name='\\domain\printer'; Type='Connection'; DriverName='Legacy'; PortName='UNC'; Location='' }
        $machine=New-PDClientReport -Config $config -Identity ([pscustomobject]@{ ComputerName='PC001'; Scope='Machine'; UserSid=''; UserName='SYSTEM' }) -After @($local) -Result Success -StartedAt (Get-Date -Format o)
        $user1=New-PDClientReport -Config $config -Identity ([pscustomobject]@{ ComputerName='PC001'; Scope='UserConnection'; UserSid='S-1-5-21-1-2-3-1001'; UserName='DOMAIN\Alice' }) -After @($local,$connection) -Result Success -StartedAt (Get-Date -Format o)
        $user2=New-PDClientReport -Config $config -Identity ([pscustomobject]@{ ComputerName='PC001'; Scope='UserConnection'; UserSid='S-1-5-21-1-2-3-1002'; UserName='DOMAIN\Bob' }) -After @($local,$connection) -Result Success -StartedAt (Get-Date -Format o)
        $computers=@(Get-PDComputerInventory -Reports @($machine,$user1,$user2))
        Assert-True ($computers.Count -eq 1 -and $computers[0].UserReportCount -eq 2 -and $computers[0].Printers.Count -eq 3) 'Computer queues duplicated or users merged.'
        $entry=@($computers[0].Printers | Where-Object { $_.Owner -eq 'DOMAIN\Bob' })[0]
        Assert-True ($entry.CanRemove) 'User connection cannot be selected.'
        Set-PDClientRemovalSelection $config $entry.Report $entry.Printer $true
        Assert-True ($config.ClientRemovals[0].UserSid -eq $user2.UserSid -and $config.ClientRemovals[0].Scope -eq 'UserConnection') 'Selection lost its user identity.'
        Assert-True (@(Get-PDClientRemovalRequests $config $user1).Count -eq 0) 'Selection targeted another user.'
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
    Test-Case 'Packaged driver registration checks Type 3/4 versions, stages and verifies exact INF' {
        & $module {
            param($InfPath,$Root,[scriptblock]$Check,[scriptblock]$ExpectFailure)
            # Windows PowerShell modules cannot resolve test helpers in the calling script scope.
            Set-Item Function:Assert-True -Value $Check
            Set-Item Function:Assert-Throws -Value $ExpectFailure
            $script:PDLogPath=$null; $script:PDDriverMock=@{ Driver=$null; Stages=0; Registered=0; MajorVersion=3; StageCode=0; Inf=$InfPath }
            function script:Import-Module { [CmdletBinding()]param($Name) }
            function script:Get-PrinterDriver { [CmdletBinding()]param() if ($script:PDDriverMock.Driver) { $script:PDDriverMock.Driver } }
            function script:Invoke-PDDriverStaging { param($InfPath) $script:PDDriverMock.Stages++; [pscustomobject]@{ ExitCode=$script:PDDriverMock.StageCode; Output='Staged' } }
            function script:Get-WindowsDriver { [CmdletBinding()]param([switch]$Online,[switch]$All) [pscustomobject]@{ ClassName='Printer'; OriginalFileName=$script:PDDriverMock.Inf } }
            function script:Add-PrinterDriver { [CmdletBinding()]param($Name,$InfPath) $script:PDDriverMock.Registered++; $script:PDDriverMock.Driver=[pscustomobject]@{ Name=$Name; MajorVersion=$script:PDDriverMock.MajorVersion } }
            $printer=[pscustomobject]@{ Kind='Type3'; DriverName='Legacy'; InfPath='Drivers\vendor\type3-valid.inf' }
            Install-PDPackagedDriver $printer $Root
            Assert-True ($script:PDDriverMock.Stages -eq 1 -and $script:PDDriverMock.Registered -eq 1) 'Type 3 was not staged/registered.'
            Install-PDPackagedDriver $printer $Root
            Assert-True ($script:PDDriverMock.Stages -eq 1) 'Installed Type 3 staged again.'
            $printer.Kind='Type4'; Assert-Throws { Install-PDPackagedDriver $printer $Root } 'not a Type 4'
            $script:PDDriverMock.Driver=$null; $printer.Kind='Type3'; $script:PDDriverMock.MajorVersion=4
            Assert-Throws { Install-PDPackagedDriver $printer $Root } 'Type 3 driver registration failed'
            $script:PDDriverMock.Driver=$null; $script:PDDriverMock.StageCode=3010
            Assert-Throws { Install-PDPackagedDriver $printer $Root } 'requires a restart'
        } (Join-Path $packagePath 'type3-valid.inf') $tempRoot (Get-Command Assert-True).ScriptBlock (Get-Command Assert-Throws).ScriptBlock
    }
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
        function script:Install-PDPackagedDriver {
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
    Test-Case 'Type 3 TCP deployment uses packaged drivers and remains idempotent' {
        $config=New-PDConfiguration; $printer=New-TestPrinter 'Type 3 queue' 'Type3'
        $printer.Address='192.0.2.56'; $printer.PackagePath='Drivers\vendor'; $printer.InfPath='Drivers\vendor\type3-valid.inf'; $printer.DriverName='Legacy Type 3'
        (Get-Content (Join-Path $packagePath 'type3-valid.inf') -Raw).Replace('Test Printer v4','Legacy Type 3') | Set-Content (Join-Path $packagePath 'type3-deploy.inf') -Encoding Unicode
        $printer.InfPath='Drivers\vendor\type3-deploy.inf'; $config.Printers=@($printer); Write-PDJson $config $deploymentFile
        Invoke-PDDeployment $deploymentFile -RetryCount 1; Invoke-PDDeployment $deploymentFile -RetryCount 1
        Assert-True (@($global:PDMock.Printers | Where-Object { $_.Name -eq $printer.Name }).Count -eq 1) 'Type 3 queue duplicated.'
        Assert-True ('Driver:Legacy Type 3' -in $global:PDMock.Events) 'Type 3 driver registration skipped.'
    }
    Test-Case 'One queue deploys distinct x64 Type3 and ARM64 Type4 packages and reports the resolved driver' {
        $config=New-PDConfiguration; $config.SchemaVersion=2
        $printer=New-TestPrinter 'One native queue' 'Type4'; $printer.Address='192.0.2.60'
        $printer | Add-Member -NotePropertyName DriverPackages -NotePropertyValue ([pscustomobject]@{
            x64=[pscustomobject]@{ Kind='Type3'; PackagePath='Drivers\vendor'; InfPath='Drivers\vendor\type3-deploy.inf'; DriverName='Legacy Type 3' }
            ARM64=[pscustomobject]@{ Kind='Type4'; PackagePath='Drivers\vendor'; InfPath='Drivers\vendor\printer.inf'; DriverName='ARM printer' }
        }); $config.Printers=@($printer); Write-PDJson $config $deploymentFile
        $originalArch=$env:PROCESSOR_ARCHITECTURE; $originalWow=$env:PROCESSOR_ARCHITEW6432
        try {
            $env:PROCESSOR_ARCHITEW6432=''
            foreach ($architecture in @('AMD64','ARM64')) {
                $env:PROCESSOR_ARCHITECTURE=$architecture; $before=$global:PDMock.Events.Count
                $expected=if ($architecture -eq 'ARM64') { 'ARM printer' } else { 'Legacy Type 3' }
                Invoke-PDDeployment $deploymentFile -RetryCount 1; Invoke-PDDeployment $deploymentFile -RetryCount 1
                $queue=@($global:PDMock.Printers | Where-Object { $_.Name -eq $printer.Name })
                Assert-True ($queue.Count -eq 1 -and $queue[0].DriverName -eq $expected) 'Native driver selection duplicated the queue or used the wrong driver.'
                $events=@($global:PDMock.Events | Select-Object -Skip $before | Where-Object { $_ -like 'Driver:*' })
                Assert-True ($events.Count -gt 0 -and @($events | Where-Object { $_ -ne ('Driver:' + $expected) }).Count -eq 0) 'A non-native driver was staged.'
                $report=@(Get-PDClientReports $tempRoot $config.DeploymentId)[0]
                Assert-True ($report.Result -eq 'Success' -and $report.ConfiguredPrinters[0].Status -eq 'Installed') 'Report compared the installed queue with the wrong architecture driver.'
            }
            Assert-True (@($global:PDMock.Ports | Where-Object { $_.Name -eq (Get-PDPortName $printer) }).Count -eq 1) 'Architecture selection created duplicate TCP/IP ports.'
            Assert-True ($printer.DriverName -eq '' -and $printer.Kind -eq 'Type4') 'Deployment mutated the configuration.'
        } finally { $env:PROCESSOR_ARCHITECTURE=$originalArch; $env:PROCESSOR_ARCHITEW6432=$originalWow }
    }
    Test-Case 'One mixed configuration installs IPP on ARM64 and skips incompatible legacy drivers without stale cleanup' {
        $config=New-PDConfiguration; $config.Cleanup.RemoveStaleManaged=$true
        $ipp=New-TestPrinter 'Cross-platform IPP'; $legacy=New-TestPrinter 'Cross-platform legacy' 'Type3'
        $legacy.Address='192.0.2.57'; $legacy.PackagePath='Drivers\vendor'; $legacy.InfPath='Drivers\vendor\type3-deploy.inf'; $legacy.DriverName='Legacy Type 3'
        $config.Printers=@($ipp,$legacy); Write-PDJson $config $deploymentFile
        $originalArch=$env:PROCESSOR_ARCHITECTURE; $originalWowArch=$env:PROCESSOR_ARCHITEW6432
        try {
            $env:PROCESSOR_ARCHITECTURE='AMD64'; $env:PROCESSOR_ARCHITEW6432=''
            Invoke-PDDeployment $deploymentFile -RetryCount 1
            Assert-True ($legacy.Name -in $global:PDMock.Printers.Name) 'x64 legacy queue did not install.'
            $env:PROCESSOR_ARCHITECTURE='ARM64'
            $events=$global:PDMock.Events.Count
            Invoke-PDDeployment $deploymentFile -RetryCount 1
            $report=@(Get-PDClientReports $tempRoot $config.DeploymentId)[0]
            Assert-True ($report.Result -eq 'Success' -and @($report.ConfiguredPrinters | Where-Object { $_.Name -eq $ipp.Name -and $_.Status -eq 'Installed' }).Count -eq 1) 'IPP did not work on ARM64 with an x64 configuration.'
            Assert-True (@($report.ConfiguredPrinters | Where-Object { $_.Name -eq $legacy.Name -and $_.Status -eq 'Unsupported architecture' }).Count -eq 1) 'Unsupported legacy driver was not reported.'
            Assert-True ($legacy.Name -in $global:PDMock.Printers.Name) 'Stale cleanup removed a configured architecture-skipped queue.'
            Assert-True (@($global:PDMock.Events | Select-Object -Skip $events | Where-Object { $_ -like 'Driver:*' }).Count -eq 0) 'Unsupported driver was staged on ARM64.'
            $env:PROCESSOR_ARCHITECTURE='AMD64'; $env:PROCESSOR_ARCHITEW6432='ARM64'
            Assert-True ((Get-PDNativeArchitecture) -eq 'ARM64') 'Emulated host detection ignored native ARM64.'
        } finally { $env:PROCESSOR_ARCHITECTURE=$originalArch; $env:PROCESSOR_ARCHITEW6432=$originalWowArch }
    }
    Test-Case 'User inventory reports old UNC connections with legacy cleanup disabled' {
        $config=New-PDConfiguration; Write-PDJson $config $deploymentFile
        $connection=[pscustomobject]@{ Name='\\domain\printer'; Type='Connection'; DriverName='Legacy'; PortName='UNC'; Location=''; Comment='' }
        $global:PDMock.Printers += $connection
        $before=$global:PDMock.Events.Count; Invoke-PDUserCleanup $deploymentFile
        $report=@(Get-PDClientReports $tempRoot $config.DeploymentId)[0]
        Assert-True ($connection.Name -in $report.Printers.Name -and $global:PDMock.Events.Count -eq $before) 'User inventory removed or omitted the UNC connection.'
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
