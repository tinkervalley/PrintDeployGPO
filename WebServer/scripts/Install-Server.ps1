#requires -Version 5.1
#requires -RunAsAdministrator
[CmdletBinding(SupportsShouldProcess)]
param([Parameter(Mandatory)][string]$ApplicationDirectory,[Parameter(Mandatory)][string]$PublicUrl,[int]$Port=3000,[string]$DataDirectory=(Join-Path $env:ProgramData 'PrintDeployWebServer'),[string]$HttpsCertificateThumbprint='',[string]$AdminGroupSid='',[string]$DomainController='')
$ErrorActionPreference='Stop'
function Set-PDWServerDirectory {
    param([string]$Path,[bool]$ServiceWrite)
    if (Test-Path -LiteralPath $Path) {
        if ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked service directories are not allowed.' }
        $owner=(Get-Acl -LiteralPath $Path).GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($owner -notin @('S-1-5-18','S-1-5-32-544',[Security.Principal.WindowsIdentity]::GetCurrent().User.Value)) { throw 'Service directory has an unexpected owner.' }
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $acl=New-Object Security.AccessControl.DirectorySecurity; $acl.SetAccessRuleProtection($true,$false); $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    foreach ($sid in @('S-1-5-18','S-1-5-32-544','S-1-5-20')) {
        $rights=if ($sid -eq 'S-1-5-20' -and -not $ServiceWrite) { 'ReadAndExecute' } else { 'FullControl' }
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule((New-Object Security.Principal.SecurityIdentifier($sid)),$rights,'ContainerInherit,ObjectInherit','None','Allow')))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
if ($env:OS -ne 'Windows_NT') { throw 'Install this service on a domain-joined Windows server.' }
$base=[uri]$PublicUrl
if ($base.Scheme -notin @('http','https') -or $base.UserInfo -or $base.Query -or $base.Fragment -or $base.AbsolutePath -ne '/' -or $base.Port -ne $Port) { throw 'PublicUrl must use the configured port and contain no path or credentials.' }
if ($Port -lt 1 -or $Port -gt 65535 -or ($base.Scheme -eq 'https' -and -not $HttpsCertificateThumbprint)) { throw 'Invalid port or missing HTTPS certificate thumbprint.' }
$application=[IO.Path]::GetFullPath($ApplicationDirectory); $data=[IO.Path]::GetFullPath($DataDirectory)
if ($application.StartsWith('\\') -or $data.StartsWith('\\')) { throw 'Application and data must be on local server storage, not SMB.' }
$exe=Join-Path $application 'PrintDeploy.Web.exe'; if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw 'Publish the self-contained Windows server build first.' }
if (-not $PSCmdlet.ShouldProcess('PrintDeployWeb','Install/update NetworkService service and Domain-profile firewall rule')) { return }
$existing=Get-CimInstance Win32_Service -Filter "Name='PrintDeployWeb'"
if ($existing -and $existing.PathName.Trim('"') -ne $exe) { throw 'A PrintDeployWeb service already belongs to another installation.' }
if ($existing) { Stop-Service PrintDeployWeb -Force; (Get-Service PrintDeployWeb).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(30)) }
Set-PDWServerDirectory $application $false; Set-PDWServerDirectory $data $true
[pscustomobject]@{ PrintDeploy=[pscustomobject]@{ Port=$Port; PublicUrl=$base.GetLeftPart([UriPartial]::Authority); DataDirectory=$data; HttpsCertificateThumbprint=$HttpsCertificateThumbprint; AdminGroupSid=$AdminGroupSid; DomainController=$DomainController; DevelopmentMode=$false } } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $application 'appsettings.Local.json') -Encoding UTF8
if (-not $existing) {
    $result=Invoke-CimMethod -ClassName Win32_Service -MethodName Create -Arguments @{ Name='PrintDeployWeb'; DisplayName='PrintDeploy Web Server'; PathName='"'+$exe+'"'; StartMode='Automatic'; StartName='NT AUTHORITY\NetworkService'; StartPassword='' }
    if ($result.ReturnValue -ne 0) { throw "Service creation failed: $($result.ReturnValue)" }
}
if (Get-NetFirewallRule -Name 'PrintDeployWeb' -ErrorAction SilentlyContinue) { Remove-NetFirewallRule -Name 'PrintDeployWeb' }
New-NetFirewallRule -Name 'PrintDeployWeb' -DisplayName 'PrintDeploy Web Server' -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -Profile Domain | Out-Null
Start-Service PrintDeployWeb
Write-Output ('PrintDeploy Web installed at '+$base.GetLeftPart([UriPartial]::Authority)+'. Data is local at '+$data+'.')
Write-Output 'For Kerberos with a DNS alias, register HTTP/<server-name> on this server computer account. HTTPS private-key access must be granted to NETWORK SERVICE when configured.'
