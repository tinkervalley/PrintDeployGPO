Set-StrictMode -Version 2.0

function New-PDConfiguration {
    [pscustomobject][ordered]@{
        SchemaVersion = 1
        DeploymentId = [guid]::NewGuid().ToString()
        Architecture = 'x64'
        Cleanup = [pscustomobject]@{ RemoveStaleManaged = $false; LegacyPrinterNames = @(); CleanupUserConnections = $false }
        Printers = @()
        ClientRemovals = @()
    }
}

function Resolve-PDResource {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$RelativePath)
    if ([IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '[:*?]' -or
        $RelativePath -match '(^|[\\/])\.\.([\\/]|$)') { throw "Resource path must stay inside the deployment folder: $RelativePath" }
    $base = [IO.Path]::GetFullPath($Root).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    # Configurations use backslashes even when validation is run on macOS/Linux.
    $native = $RelativePath.Replace('\', [IO.Path]::DirectorySeparatorChar)
    $full = [IO.Path]::GetFullPath((Join-Path $base $native))
    if (-not $full.StartsWith($base + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Resource path escapes deployment folder: $RelativePath"
    }
    # Reject junctions/symlinks in any existing component, including the root.
    $itemPath = $full
    while ($itemPath -and $itemPath.Length -ge $base.Length) {
        if (Test-Path -LiteralPath $itemPath) {
            $item = Get-Item -LiteralPath $itemPath -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked resources are not supported: $itemPath" }
        }
        $itemPath = Split-Path -Parent $itemPath
    }
    $full
}

function Split-PDInfList {
    param([string]$Value)
    # Commas/semicolons inside quoted model names are literal characters.
    $quoted = $false; $buffer = ''; $parts = New-Object 'System.Collections.Generic.List[string]'
    for ($i = 0; $i -lt $Value.Length; $i++) {
        $c = $Value[$i]
        if ($c -eq '"') { $quoted = -not $quoted; $buffer += $c }
        elseif ($c -eq ',' -and -not $quoted) { $parts.Add($buffer.Trim()); $buffer = '' }
        else { $buffer += $c }
    }
    $parts.Add($buffer.Trim()); $parts.ToArray()
}

function Remove-PDInfComment {
    param([string]$Line)
    $quoted = $false
    for ($i = 0; $i -lt $Line.Length; $i++) {
        if ($Line[$i] -eq '"') { $quoted = -not $quoted }
        if ($Line[$i] -eq ';' -and -not $quoted) { return $Line.Substring(0, $i).Trim() }
    }
    $Line.Trim()
}

function Expand-PDInfString {
    param([string]$Value, [hashtable]$Strings)
    $result = $Value.Trim().Trim('"').Replace('""', '"')
    for ($pass = 0; $pass -lt 10 -and $result -match '%[^%]+%'; $pass++) {
        $previous = $result
        foreach ($match in [regex]::Matches($result, '%([^%]+)%')) {
            $key = $match.Groups[1].Value
            if (-not $Strings.ContainsKey($key)) { throw "Unresolved INF string: %$key%" }
            $result = $result.Replace($match.Value, [string]$Strings[$key])
        }
        if ($result -eq $previous) { break }
    }
    if ($result -match '%[^%]+%') { throw 'Recursive INF string reference.' }
    $result
}

function Get-PDInfModels {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [ValidateSet('x64', 'ARM64')][string]$Architecture = 'x64')
    $sections = @{}; $section = ''; $pending = ''
    # StreamReader detects UTF-16/UTF-8 BOMs; otherwise use Windows ANSI for vendor INFs.
    $reader = New-Object IO.StreamReader($Path, [Text.Encoding]::Default, $true)
    try { $content = $reader.ReadToEnd() } finally { $reader.Dispose() }
    foreach ($raw in ($content -split '\r?\n')) {
        $line = $pending + (Remove-PDInfComment $raw)
        if ($line.EndsWith('\')) { $pending = $line.Substring(0, $line.Length - 1); continue }
        $pending = ''
        if (-not $line) { continue }
        if ($line -match '^\[([^\]]+)\]$') {
            $section = $Matches[1]
            if (-not $sections.ContainsKey($section)) { $sections[$section] = New-Object 'System.Collections.Generic.List[string]' }
        } elseif ($section) { $sections[$section].Add($line) }
    }
    if (-not $sections.ContainsKey('Version') -or -not $sections.ContainsKey('Manufacturer')) { throw "Not a printer INF: $Path" }
    $version = @{}
    foreach ($line in $sections['Version']) {
        if ($line -match '^([^=]+)=(.*)$') { $version[$Matches[1].Trim()] = $Matches[2].Trim().Trim('"') }
    }
    if ($version['Class'] -ne 'Printer' -or $version['ClassVer'] -ne '4.0') { throw "Only Type 4 printer packages (Class=Printer, ClassVer=4.0) are supported: $Path" }
    $strings = @{}
    # Prefer neutral strings. Use en-US strings only to fill missing entries.
    foreach ($s in @('Strings.0409', 'Strings')) {
        if ($sections.ContainsKey($s)) {
            foreach ($line in $sections[$s]) {
                if ($line -match '^([^=]+)=(.*)$') { $strings[$Matches[1].Trim()] = $Matches[2].Trim().Trim('"').Replace('""', '"') }
            }
        }
    }
    $decoration = if ($Architecture -eq 'x64') { 'NTamd64' } else { 'NTarm64' }
    $modelSections = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in $sections['Manufacturer']) {
        if ($line -notmatch '^([^=]+)=(.*)$') { continue }
        $tokens = @(Split-PDInfList $Matches[2]); $base = Expand-PDInfString $tokens[0] $strings
        if ($tokens.Count -eq 1) { $modelSections.Add($base); continue }
        foreach ($suffix in $tokens[1..($tokens.Count - 1)]) {
            $suffix = $suffix.Trim().Trim('"')
            if ($suffix -match ('^' + $decoration + '(\.|$)') -or $suffix -eq 'NT') { $modelSections.Add("$base.$suffix") }
        }
    }
    $models = New-Object 'System.Collections.Generic.List[string]'
    foreach ($s in $modelSections) {
        if (-not $sections.ContainsKey($s)) { continue }
        foreach ($line in $sections[$s]) {
            if ($line -match '^((?:"(?:[^"]|"")*"|[^=])+?)\s*=(.+)$') {
                $name = Expand-PDInfString $Matches[1] $strings
                if ($name) { $models.Add($name) }
            }
        }
    }
    if ($models.Count -eq 0) { throw "No $Architecture driver names found in $Path. Localized-only INFs or unsupported layouts must be repackaged by the vendor." }
    @($models | Sort-Object -Unique)
}

function Read-PDConfiguration {
    param([Parameter(Mandatory)][string]$Path)
    Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Write-PDJson {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Path)
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        $Value | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temp -Encoding UTF8
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, [System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temp, $Path) }
    } finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}

function Assert-PDConfiguration {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Root)
    if ($Config.SchemaVersion -ne 1) { throw 'Unsupported configuration schema.' }
    $id = [guid]::Empty
    if (-not [guid]::TryParse([string]$Config.DeploymentId, [ref]$id) -or $id -eq [guid]::Empty) { throw 'DeploymentId must be a non-empty GUID.' }
    if ($Config.Architecture -notin @('x64', 'ARM64')) { throw 'Architecture must be x64 or ARM64.' }
    if ($Config.Cleanup.RemoveStaleManaged -isnot [bool] -or $Config.Cleanup.CleanupUserConnections -isnot [bool]) { throw 'Cleanup flags must be booleans.' }
    if ($Config.Printers -isnot [array] -or $Config.Cleanup.LegacyPrinterNames -isnot [array]) { throw 'Printers and LegacyPrinterNames must be arrays.' }
    $names = @{}
    foreach ($p in @($Config.Printers)) {
        foreach ($field in @('Name','Kind','Address','Location','Comment','PackagePath','InfPath','DriverName')) {
            if ($p.$field -isnot [string]) { throw "Printer field '$field' must be a string." }
        }
        if ([string]::IsNullOrWhiteSpace($p.Name) -or $p.Name -match '[\x00-\x1f]' -or $p.Name.Length -gt 200) { throw 'Printer names must contain 1-200 printable characters.' }
        if ($names.ContainsKey($p.Name)) { throw "Duplicate printer name: $($p.Name)" }; $names[$p.Name] = $true
        if ($p.Kind -eq 'IPP') {
            $uri = $null
            if (-not [uri]::TryCreate($p.Address, [UriKind]::Absolute, [ref]$uri) -or
                $uri.Scheme -notin @('ipp','ipps','http','https') -or -not $uri.Host -or $uri.UserInfo -or $uri.Fragment) {
                throw "Enter a full IPP URL without credentials or fragments for $($p.Name)."
            }
        } elseif ($p.Kind -eq 'Type4') {
            if ([string]::IsNullOrWhiteSpace($p.Address) -or [uri]::CheckHostName($p.Address) -eq [UriHostNameType]::Unknown) { throw "Invalid TCP/IP host for $($p.Name)." }
            $port = 0
            if (-not [int]::TryParse([string]$p.PortNumber, [ref]$port) -or $port -lt 1 -or $port -gt 65535) { throw 'RAW TCP port must be 1-65535.' }
            if ([string]::IsNullOrWhiteSpace($p.DriverName)) { throw "Missing driver name for $($p.Name)." }
            if ($p.PackagePath -notmatch '^Drivers[\\/]') { throw 'Driver packages must be under Drivers in the deployment folder.' }
            $package = Resolve-PDResource $Root $p.PackagePath
            $inf = Resolve-PDResource $Root $p.InfPath
            if (-not (Test-Path -LiteralPath $package -PathType Container) -or -not (Test-Path -LiteralPath $inf -PathType Leaf)) { throw "Missing package or INF for $($p.Name)." }
            if (-not $inf.StartsWith($package.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetExtension($inf) -ne '.inf') { throw 'INF must be inside its driver package.' }
            if (@(Get-ChildItem -LiteralPath $package -Recurse -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) { throw 'Driver packages must not contain links or junctions.' }
            $models = @(Get-PDInfModels $inf $Config.Architecture)
            if ($p.DriverName -notin $models) { throw "Driver name is not in the selected INF: $($p.DriverName)" }
        } else { throw "Unknown printer kind: $($p.Kind)" }
    }
    foreach ($name in @($Config.Cleanup.LegacyPrinterNames)) {
        if ($name -isnot [string] -or [string]::IsNullOrWhiteSpace($name) -or $name -match '[\x00-\x1f*?\[\]]') { throw 'Legacy cleanup requires exact printer names, without wildcard characters.' }
        if ($names.ContainsKey($name)) { throw "Cleanup cannot delete a configured printer: $name" }
    }
    if ($Config.PSObject.Properties['ClientRemovals']) {
        if ($Config.ClientRemovals -isnot [array]) { throw 'ClientRemovals must be an array.' }
        $ids = @{}; $targets = @{}
        foreach ($request in @($Config.ClientRemovals)) {
            $requestId = [guid]::Empty
            if (-not [guid]::TryParse([string]$request.Id, [ref]$requestId) -or $requestId -eq [guid]::Empty -or $ids.ContainsKey($request.Id)) { throw 'Removal request IDs must be unique non-empty GUIDs.' }
            $ids[$request.Id] = $true
            if ($request.ComputerName -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,62}$') { throw 'Removal requests require an exact computer name.' }
            if ($request.Scope -notin @('Machine','UserConnection')) { throw 'Unknown client removal scope.' }
            if (($request.Scope -eq 'Machine' -and $request.UserSid -ne '') -or
                ($request.Scope -eq 'UserConnection' -and $request.UserSid -notmatch '^S-1-\d+(-\d+)+$')) { throw 'Invalid user identity for removal request.' }
            foreach ($field in @('Name','DriverName','PortName')) {
                if ($request.$field -isnot [string] -or [string]::IsNullOrWhiteSpace($request.$field) -or $request.$field -match '[\x00-\x1f]') { throw "Removal request field '$field' must be a printable string." }
            }
            if ($names.ContainsKey($request.Name)) { throw "Client cleanup cannot delete a configured printer: $($request.Name)" }
            $target = "$($request.ComputerName)|$($request.Scope)|$($request.UserSid)|$($request.Name)"
            if ($targets.ContainsKey($target)) { throw 'Duplicate client removal target.' }; $targets[$target] = $true
        }
    }
}

function Get-PDHash {
    param([string]$Value)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Get-PDPrinterFingerprint {
    param($Printer)
    if ($Printer.Kind -eq 'IPP') { return Get-PDHash ("IPP|" + $Printer.Address) }
    Get-PDHash ("Type4|$($Printer.Address.ToLowerInvariant())|$($Printer.PortNumber)|$($Printer.DriverName)")
}

function Get-PDPortName {
    param($Printer)
    'PDT_TCP_' + (Get-PDHash ("$($Printer.Address.ToLowerInvariant())|$($Printer.PortNumber)")).Substring(0, 16)
}

function Get-PDCleanupCandidates {
    param([object[]]$Installed, $Config, [object[]]$Managed = @(), [switch]$UserConnectionsOnly)
    $wanted = @($Config.Printers | ForEach-Object { $_.Name })
    foreach ($p in $Installed) {
        if ($p.Name -in $wanted) { continue }
        if ($UserConnectionsOnly) {
            if ($Config.Cleanup.CleanupUserConnections -and [string]$p.Type -eq 'Connection' -and $p.Name -in @($Config.Cleanup.LegacyPrinterNames)) { $p }
            continue
        }
        # A SYSTEM run cannot remove another user's connection. Handle these at user logon.
        if ([string]$p.Type -eq 'Connection') { continue }
        if ($p.Name -in @($Config.Cleanup.LegacyPrinterNames)) { $p; continue }
        if ($Config.Cleanup.RemoveStaleManaged) {
            $owned = @($Managed | Where-Object { $_.Name -eq $p.Name -and $_.PortName -eq $p.PortName -and $_.DriverName -eq $p.DriverName })
            if ($owned.Count) { $p }
        }
    }
}

Export-ModuleMember -Function *-PD*
