#requires -Version 5.1
[CmdletBinding()]
param([ValidateSet('win-x64','win-arm64')][string]$Runtime='win-x64',[string]$OutputDirectory=(Join-Path (Split-Path -Parent $PSScriptRoot) ('dist\'+$Runtime)))
$ErrorActionPreference='Stop'
$project=Join-Path (Split-Path -Parent $PSScriptRoot) 'Server\PrintDeploy.Web.csproj'
& dotnet publish $project -c Release -r $Runtime --self-contained true -o $OutputDirectory
if ($LASTEXITCODE -ne 0) { throw 'Server publish failed.' }
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'Install-Server.ps1') -Destination $OutputDirectory -Force
Write-Output ('Published '+$Runtime+' server to '+[IO.Path]::GetFullPath($OutputDirectory))
