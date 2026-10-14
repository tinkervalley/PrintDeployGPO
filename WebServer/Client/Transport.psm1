#requires -Version 5.1
Set-StrictMode -Version 2.0
function Assert-PDWServer {
    param([string]$Server)
    $uri=$null
    if (-not [uri]::TryCreate($Server,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -notin @('http','https') -or $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -ne '/') { throw 'Invalid PrintDeploy server URL.' }
    return $uri.GetLeftPart([UriPartial]::Authority)
}
function ConvertFrom-PDWEnvelope {
    param($Envelope,[string]$PublicKey,[string]$Nonce,[string]$DeploymentId)
    $bytes=[Convert]::FromBase64String($Envelope.Payload); $signature=[Convert]::FromBase64String($Envelope.Signature)
    if ($bytes.Length -gt 4MB -or $signature.Length -gt 1024) { throw 'Signed response exceeds size limits.' }
    $rsa=New-Object Security.Cryptography.RSACryptoServiceProvider
    try { $rsa.PersistKeyInCsp=$false; $rsa.FromXmlString($PublicKey); if (-not $rsa.VerifyData($bytes,'SHA256',$signature)) { throw 'PrintDeploy response signature is invalid.' } } finally { $rsa.Dispose() }
    $value=[Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
    if ($value.SchemaVersion -ne 1 -or [string]$value.DeploymentId -cne $DeploymentId -or [string]$value.Nonce -cne $Nonce) { throw 'Signed response does not match this deployment/request.' }
    $issued=if ($value.IssuedAt -is [datetime] -or $value.IssuedAt -is [datetimeoffset]) { [datetimeoffset]$value.IssuedAt } else { [datetimeoffset]::Parse([string]$value.IssuedAt) }
    if ([Math]::Abs(([datetimeoffset]::UtcNow-$issued).TotalMinutes) -gt 15) { throw 'Signed response has expired. Check the computer clock.' }
    return $value
}
function Get-PDWResponse {
    param([string]$Server,[string]$Path,[string]$PublicKey,[string]$Nonce,[string]$DeploymentId)
    $base=Assert-PDWServer $Server
    $response=Invoke-WebRequest -UseBasicParsing -Uri ($base+$Path) -TimeoutSec 60 -MaximumRedirection 0
    if ([Text.Encoding]::UTF8.GetByteCount([string]$response.Content) -gt 6MB) { throw 'Server response exceeds size limits.' }
    ConvertFrom-PDWEnvelope ($response.Content | ConvertFrom-Json) $PublicKey $Nonce $DeploymentId
}
function Assert-PDWRelativePath {
    param([string]$Path)
    if (-not $Path -or $Path.Length -gt 220 -or $Path -match '(^[\/]|[:*?"<>|\x00-\x1f])' -or @($Path.Replace('\','/').Split('/') | Where-Object { -not $_ -or $_ -in @('.','..') -or $_ -match '[. ]$|^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)' }).Count) { throw 'Unsafe download path.' }
}
function Initialize-PDWCache {
    param([string]$Root,[switch]$UserMode)
    if ($env:OS -ne 'Windows_NT') { throw 'PrintDeploy clients require Windows.' }
    $current=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $trusted=if ($UserMode) { @($current,'S-1-5-18','S-1-5-32-544') } else { @('S-1-5-18','S-1-5-32-544') }
    foreach ($path in @((Split-Path -Parent $Root),$Root)) {
        if (Test-Path -LiteralPath $path) {
            if ((Get-Item -LiteralPath $path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked client cache is not allowed.' }
            $owner=(Get-Acl -LiteralPath $path).GetOwner([Security.Principal.SecurityIdentifier]).Value
            if ($owner -notin $trusted) { throw 'Client cache has an untrusted owner.' }
        }
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        $acl=New-Object Security.AccessControl.DirectorySecurity; $acl.SetAccessRuleProtection($true,$false)
        $owner=if ($UserMode) { $current } else { 'S-1-5-32-544' }; $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier($owner)))
        foreach ($sid in $trusted) { $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))) }
        Set-Acl -LiteralPath $path -AclObject $acl
    }
}
function Get-PDWClientId {
    param([string]$DeploymentId,[switch]$UserMode)
    $path='HKLM:\SOFTWARE\PrintDeployWeb\'+$DeploymentId
    $value=Get-ItemProperty -LiteralPath $path -Name ClientId -ErrorAction SilentlyContinue
    if ($value) { $id=[guid]::Empty; if ([guid]::TryParse([string]$value.ClientId,[ref]$id) -and $id -ne [guid]::Empty) { return $id.ToString() } }
    if ($UserMode) { throw 'The computer startup script must run once before user reporting.' }
    $id=[guid]::NewGuid().ToString(); New-Item -Path $path -Force | Out-Null; New-ItemProperty -LiteralPath $path -Name ClientId -Value $id -PropertyType String -Force | Out-Null; return $id
}
function Save-PDWFile {
    param([string]$Server,[string]$Endpoint,[string]$Path,[string]$Hash,[long]$Size)
    if ($Hash -notmatch '^[0-9a-f]{64}$' -or $Size -lt 0 -or $Size -gt 256MB) { throw 'Invalid download metadata.' }
    if (Test-Path -LiteralPath $Path) { if ((Get-Item -LiteralPath $Path).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked download target.' }; if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ieq $Hash) { return } }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $temp=$Path+'.'+[guid]::NewGuid().ToString('N')+'.tmp'
    try {
        Invoke-WebRequest -UseBasicParsing -Uri ((Assert-PDWServer $Server)+$Endpoint) -OutFile $temp -TimeoutSec 300 -MaximumRedirection 0
        if ((Get-Item -LiteralPath $temp).Length -ne $Size -or (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash -ine $Hash) { throw 'Downloaded file failed size/hash verification.' }
        Move-Item -LiteralPath $temp -Destination $Path -Force
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}
function Update-PDWFiles {
    param([string]$Server,[string]$Root,$Manifest)
    if ($Manifest.Files -isnot [array] -or $Manifest.Files.Count -gt 32) { throw 'Invalid client file manifest.' }
    $allowed=@('engine/PrinterDeployment.ps1','engine/Modules/PrinterDeployment.Core.psm1','engine/Modules/PrinterDeployment.Clients.psm1','engine/Modules/PrinterDeployment.Deploy.psm1','client/Transport.psm1','client/Invoke-PrintDeployWeb.ps1')
    $seen=@{}
    foreach ($file in $Manifest.Files) {
        Assert-PDWRelativePath $file.Path
        if ($file.Path -cnotin $allowed -or $seen.ContainsKey($file.Path)) { throw 'Unexpected or duplicate client file.' }; $seen[$file.Path]=$true
        Save-PDWFile $Server ('/client/files/'+$file.Hash) (Join-Path $Root $file.Path.Replace('/',[IO.Path]::DirectorySeparatorChar)) $file.Hash ([long]$file.Size)
    }
    if ($seen.Count -ne $allowed.Count) { throw 'Client manifest is incomplete.' }
}
function Expand-PDWPackage {
    param([string]$Archive,[string]$Destination)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip=[IO.Compression.ZipFile]::OpenRead($Archive); $seen=@{}; [long]$total=0
    try {
        if ($zip.Entries.Count -gt 10000) { throw 'Too many package files.' }
        foreach ($entry in $zip.Entries) {
            $directory=$entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\'); $name=$entry.FullName.TrimEnd('/','\'); if (-not $name) { continue }
            Assert-PDWRelativePath $name; $name=$name.Replace('\','/')
            if ($seen.ContainsKey($name) -or (($entry.ExternalAttributes -shr 16) -band 0xF000) -eq 0xA000 -or ($entry.ExternalAttributes -band 0x400)) { throw 'Duplicate names or links in package.' }; $seen[$name]=$true
            $total+=$entry.Length; if ($total -gt 1GB -or $entry.Length -gt 256MB) { throw 'Package exceeds extracted size limits.' }
            $path=Join-Path $Destination $name.Replace('/',[IO.Path]::DirectorySeparatorChar)
            if ($directory) { New-Item -ItemType Directory -Path $path -Force | Out-Null }
            else {
                New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
                $entryInput=$entry.Open(); $output=[IO.File]::Open($path,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
                try { $entryInput.CopyTo($output); if ($output.Length -ne $entry.Length) { throw 'ZIP entry size mismatch.' } } finally { $entryInput.Dispose(); $output.Dispose() }
            }
        }
    } finally { $zip.Dispose() }
}
function Register-PDWTask {
    param([string]$Server,[string]$Root,[string]$DeploymentId,$Task)
    if ($Task.Name -cne ('PrintDeployWeb-'+$DeploymentId) -or $Task.Description -cne ('PrintDeploy Web; DeploymentId='+$DeploymentId) -or $Task.PollMinutes -lt 15 -or $Task.PollMinutes -gt 1440) { throw 'Unexpected task definition.' }
    Import-Module ScheduledTasks -ErrorAction Stop
    $existing=Get-ScheduledTask -TaskName $Task.Name -TaskPath '\' -ErrorAction SilentlyContinue
    if ($existing -and $existing.Description -ne $Task.Description) { throw 'Scheduled task belongs to another application.' }
    $script=Join-Path $Root 'client\Invoke-PrintDeployWeb.ps1'
    $action=New-ScheduledTaskAction -Execute (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe') -Argument ('-NoProfile -NonInteractive -File "'+$script+'" -SettingsPath "'+(Join-Path $Root 'settings.json')+'"')
    $startup=New-ScheduledTaskTrigger -AtStartup; $startup.Delay='PT1M'
    $repeat=New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes $Task.PollMinutes)
    $principal=New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 1)
    Register-ScheduledTask -TaskName $Task.Name -TaskPath '\' -Description $Task.Description -Action $action -Principal $principal -Trigger @($startup,$repeat) -Settings $settings -Force | Out-Null
}
Export-ModuleMember -Function *-PDW*
