#requires -Version 5.1
param([string]$FixtureDirectory)
$ErrorActionPreference='Stop'
Set-StrictMode -Version 2.0
$project=Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $project 'Client/Transport.psm1') -Force
$passed=0
function Check { param($Condition,[string]$Name) if (-not $Condition) { throw $Name }; $script:passed++; Write-Host "PASS $Name" }
function Reject { param([scriptblock]$Body,[string]$Name) try { & $Body } catch { $script:passed++; Write-Host "PASS $Name"; return }; throw "Expected rejection: $Name" }
foreach ($file in @(Get-ChildItem $project -Recurse -File | Where-Object { $_.Extension -in @('.ps1','.psm1') -or $_.Name -like '*.ps1.template' })) {
    $tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$errors)
    Check ($errors.Count -eq 0) ('PowerShell parses: '+$file.Name)
}
foreach ($path in @('../outside','C:\outside','folder/file:stream','folder/CON.inf','folder/../escape','/absolute','end./file')) { Reject { Assert-PDWRelativePath $path } ('Reject unsafe path '+$path) }
Check ((Assert-PDWServer 'http://localhost:3000') -eq 'http://localhost:3000') 'Default HTTP port accepted'
Reject { Assert-PDWServer 'http://user:password@localhost:3000' } 'Embedded credentials rejected'
Reject { Assert-PDWServer 'http://localhost:3000/other' } 'Unexpected server base path rejected'
$rsa=New-Object Security.Cryptography.RSACryptoServiceProvider(2048)
$temp=Join-Path ([IO.Path]::GetTempPath()) ('pd-web-ps-'+[guid]::NewGuid().ToString('N')); New-Item -ItemType Directory -Path $temp | Out-Null
try {
    $nonce=[guid]::NewGuid().ToString('N');$id=[guid]::NewGuid().ToString()
    $body=[pscustomobject]@{SchemaVersion=1;DeploymentId=$id;Nonce=$nonce;IssuedAt=[datetimeoffset]::UtcNow.ToString('o');Task=[pscustomobject]@{Name='PrintDeployWeb-'+$id;Description='PrintDeploy Web; DeploymentId='+$id;PollMinutes=60}}
    function Envelope { param($Value) $bytes=[Text.Encoding]::UTF8.GetBytes(($Value | ConvertTo-Json -Depth 10 -Compress)); [pscustomobject]@{Payload=[Convert]::ToBase64String($bytes);Signature=[Convert]::ToBase64String($rsa.SignData($bytes,'SHA256'))} }
    $envelope=Envelope $body; $result=ConvertFrom-PDWEnvelope $envelope $rsa.ToXmlString($false) $nonce $id
    Check ($result.Task.PollMinutes -eq 60) 'Signed response verifies and preserves task policy'
    Reject { ConvertFrom-PDWEnvelope $envelope $rsa.ToXmlString($false) ([guid]::NewGuid().ToString('N')) $id } 'A replayed nonce cannot be accepted'
    Reject { ConvertFrom-PDWEnvelope $envelope $rsa.ToXmlString($false) $nonce ([guid]::NewGuid().ToString()) } 'Another deployment cannot be accepted'
    $bytes=[Convert]::FromBase64String($envelope.Payload);$bytes[0]=$bytes[0] -bxor 1;$tampered=[pscustomobject]@{Payload=[Convert]::ToBase64String($bytes);Signature=$envelope.Signature}
    Reject { ConvertFrom-PDWEnvelope $tampered $rsa.ToXmlString($false) $nonce $id } 'Modified payload rejected before JSON processing'
    $body.IssuedAt=[datetimeoffset]::UtcNow.AddHours(-1).ToString('o');$expired=Envelope $body
    Reject { ConvertFrom-PDWEnvelope $expired $rsa.ToXmlString($false) $nonce $id } 'Old signed response rejected'
    if ($FixtureDirectory) {
        $startup=Join-Path $FixtureDirectory 'startup.ps1';$tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile($startup,[ref]$tokens,[ref]$errors);Check ($errors.Count -eq 0) 'Server-generated startup parses in Windows PowerShell'
        $fixture=Get-Content (Join-Path $FixtureDirectory 'bootstrap-fixture.json') -Raw | ConvertFrom-Json
        $actual=ConvertFrom-PDWEnvelope $fixture.Envelope $fixture.PublicKey $fixture.Nonce $fixture.DeploymentId
        Check ($actual.Files.Count -eq 6) 'Actual server envelope verifies with PowerShell and contains the complete client bundle'
    }
    if ($env:OS -eq 'Windows_NT') {
        $module=Get-Module Transport
        & $module {
            param($Task,$Root,$Id)
            function script:Import-Module { param($Name) }
            function script:Get-ScheduledTask { [CmdletBinding()]param($TaskName,$TaskPath) }
            function script:New-ScheduledTaskAction { param($Execute,$Argument) [pscustomobject]@{Execute=$Execute;Argument=$Argument} }
            function script:New-ScheduledTaskTrigger { param([switch]$AtStartup,[switch]$Once,$At,$RepetitionInterval) [pscustomobject]@{Delay='';AtStartup=[bool]$AtStartup;RepetitionInterval=$RepetitionInterval} }
            function script:New-ScheduledTaskPrincipal { param($UserId,$LogonType,$RunLevel) [pscustomobject]@{UserId=$UserId;LogonType=$LogonType} }
            function script:New-ScheduledTaskSettingsSet { param([switch]$StartWhenAvailable,$MultipleInstances,$RestartCount,$RestartInterval,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries,$ExecutionTimeLimit) @{} }
            function script:Register-ScheduledTask { param($TaskName,$TaskPath,$Description,$Action,$Principal,$Trigger,$Settings,[switch]$Force) $global:PDWTestTask=[pscustomobject]@{TaskName=$TaskName;Action=$Action;Principal=$Principal;Trigger=$Trigger} }
            Register-PDWTask 'http://localhost:3000' $Root $Id $Task
        } $result.Task $temp $id
        Check ($global:PDWTestTask.Principal.UserId -eq 'S-1-5-18' -and $global:PDWTestTask.Trigger.Count -eq 2 -and $global:PDWTestTask.Action.Argument -notmatch 'ExecutionPolicy') 'Task is SYSTEM, startup plus repeating trigger, and honors execution policy'
    }
    Write-Host "All $passed PowerShell web transport checks passed."
} finally { $rsa.PersistKeyInCsp=$false; $rsa.Dispose(); Remove-Item $temp -Recurse -Force }
