#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$SettingsPath,[ValidateSet('Deploy','CleanupUser')][string]$Mode='Deploy')
$ErrorActionPreference='Stop'
Import-Module (Join-Path $PSScriptRoot 'Transport.psm1') -Force
$settings=Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json
$root=Split-Path -Parent $PSScriptRoot
$mutexName=if ($Mode -eq 'Deploy') { 'Global\PrintDeployWeb-Update-'+$settings.DeploymentId } else { 'Local\PrintDeployWeb-User-'+$settings.DeploymentId }
$mutex=New-Object Threading.Mutex($false,$mutexName); $locked=$false; $exitCode=1
try {
    try { $locked=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked=$true }; if (-not $locked) { throw 'Another PrintDeploy web run is active.' }
    $nonce=[guid]::NewGuid().ToString('N')
    $manifest=Get-PDWResponse $settings.Server ('/client/bootstrap?nonce='+$nonce) $settings.PublicKey $nonce $settings.DeploymentId
    Update-PDWFiles $settings.Server $root $manifest
    if ($Mode -eq 'Deploy' -and (-not $settings.PSObject.Properties['PollMinutes'] -or $settings.PollMinutes -ne $manifest.Task.PollMinutes)) {
        Register-PDWTask $settings.Server $root $settings.DeploymentId $manifest.Task
        if (-not $settings.PSObject.Properties['PollMinutes']) { $settings | Add-Member -NotePropertyName PollMinutes -NotePropertyValue $manifest.Task.PollMinutes } else { $settings.PollMinutes=$manifest.Task.PollMinutes }
        $settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $SettingsPath -Encoding UTF8
    }
    $nonce=[guid]::NewGuid().ToString('N')
    $url='/client/plan?computerName='+[uri]::EscapeDataString($env:COMPUTERNAME)+'&clientId='+$settings.ClientId+'&nonce='+$nonce
    $plan=Get-PDWResponse $settings.Server $url $settings.PublicKey $nonce $settings.DeploymentId
    if ($plan.ClientId -cne $settings.ClientId -or $plan.ComputerName -ine $env:COMPUTERNAME) { throw 'Signed plan is for another client.' }
    $bundle=Join-Path $root 'engine'
    foreach ($package in $plan.Packages) {
        $id=[guid]::Empty; if (-not [guid]::TryParse([string]$package.Id,[ref]$id) -or $id -eq [guid]::Empty) { throw 'Invalid package ID.' }
        $directory=Join-Path $bundle ('Drivers\'+$id.ToString()); $marker=Join-Path $directory '.package-sha256'
        if ((Test-Path -LiteralPath $marker) -and ((Get-Content -LiteralPath $marker -Raw).Trim() -ceq $package.Hash)) { continue }
        $archive=Join-Path $root ($id.ToString()+'.zip'); $staging=Join-Path $bundle ('Drivers\'+$id.ToString()+'.'+[guid]::NewGuid().ToString('N')+'.tmp')
        try {
            Save-PDWFile $settings.Server ('/client/packages/'+$id.ToString()+'/'+$package.Hash) $archive $package.Hash ([long]$package.Size)
            New-Item -ItemType Directory -Path $staging -Force | Out-Null; Expand-PDWPackage $archive $staging
            Set-Content -LiteralPath (Join-Path $staging '.package-sha256') -Value $package.Hash -Encoding ASCII
            if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }; Move-Item -LiteralPath $staging -Destination $directory
        } finally { if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }; if (Test-Path -LiteralPath $archive) { Remove-Item -LiteralPath $archive -Force } }
    }
    $config=Join-Path $bundle 'printers.json'; $plan.Configuration | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $config -Encoding UTF8
    $started=[datetime]::UtcNow
    & (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -File (Join-Path $bundle 'PrinterDeployment.ps1') -Mode $Mode -ConfigPath $config
    $exitCode=$LASTEXITCODE
    $scope=if ($Mode -eq 'Deploy') { $env:COMPUTERNAME } else {
        $sid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $sha=[Security.Cryptography.SHA256]::Create(); try { $hash=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($sid)))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
        $env:COMPUTERNAME+'--user-'+$hash.Substring(0,16)
    }
    $reportPath=Join-Path $bundle ('Client Logs\'+$scope+'\latest.json')
    if (-not (Test-Path -LiteralPath $reportPath) -or (Get-Item -LiteralPath $reportPath).LastWriteTimeUtc -lt $started.AddSeconds(-2)) { throw 'Deployment did not produce a fresh report; existing queues are retained.' }
    $report=Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    $body=[pscustomobject]@{ ClientId=$settings.ClientId; ComputerName=$env:COMPUTERNAME.ToUpperInvariant(); Report=$report } | ConvertTo-Json -Depth 20 -Compress
    Invoke-RestMethod -Uri ((Assert-PDWServer $settings.Server)+'/client/reports') -Method Post -ContentType 'application/json; charset=utf-8' -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 60 -MaximumRedirection 0 | Out-Null
} catch { Write-Error $_; $exitCode=1 }
finally { if ($locked) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
exit $exitCode
