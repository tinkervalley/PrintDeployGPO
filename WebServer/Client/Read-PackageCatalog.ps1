#requires -Version 5.1
param([string]$Root,[ValidateSet(3,4)][int]$DriverType,[string]$CoreModule)
$ErrorActionPreference='Stop'
try {
    Import-Module $CoreModule -Force
    $base=[IO.Path]::GetFullPath($Root).TrimEnd('\','/')
    $infs=@(Get-ChildItem -LiteralPath $base -Recurse -Filter '*.inf' -File)
    if ($infs.Count -gt 256) { throw 'Too many INF files.' }
    $result=@(foreach ($inf in $infs) {
        if ($inf.Length -gt 4MB) { throw 'INF exceeds size limit.' }
        try {
            $models=@(Get-PDInfDriverCatalog $inf.FullName -DriverType $DriverType)
            if ($models.Count) { [pscustomobject]@{ Path=$inf.FullName.Substring($base.Length+1).Replace('\','/'); DriverType=$DriverType; Models=$models } }
        } catch { # A complete vendor ZIP can contain other driver classes/types.
            if ($_.Exception.Message -notmatch 'Class|Type 3|Type 4|model|architecture') { throw }
        }
    })
    ConvertTo-Json -InputObject @($result) -Depth 12 -Compress
    exit 0
} catch { Write-Error $_; exit 1 }
