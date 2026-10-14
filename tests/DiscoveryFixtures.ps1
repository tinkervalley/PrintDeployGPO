# Synthetic DNS-SD advertisements only; no network calls.
function New-DiscoveryName {
    param([string]$Name)
    $query=[PrintDeployGPO.Discovery.DNS]::Query($Name,12)
    return ,([byte[]]$query[12..($query.Length-5)])
}
function New-DiscoveryRecord {
    param([string]$Name,[int]$Type,[byte[]]$Data)
    $owner=New-DiscoveryName $Name
    return ,([byte[]]($owner + @([byte]($Type -shr 8),[byte]($Type -band 255),0,1,0,0,0,120,[byte]($Data.Length -shr 8),[byte]($Data.Length -band 255)) + $Data))
}
function New-DiscoveryPacket {
    param([byte[][]]$Records)
    [byte[]]$packet=@(0,0,132,0,0,0,[byte]($Records.Count -shr 8),[byte]($Records.Count -band 255),0,0,0,0)
    foreach ($record in $Records) { $packet += $record }
    return ,$packet
}
function New-DiscoveryAdvertisement {
    param([string]$Service='_ipp._tcp.local.',[int]$Port=631,[string]$Path='ipp/print')
    $instance='Test\. Printer.'+$Service
    [byte[]]$srv=@(0,0,0,0,[byte]($Port -shr 8),[byte]($Port -band 255)) + (New-DiscoveryName 'printer.local.')
    [byte[]]$txt=@()
    foreach ($value in @(('rp='+$Path),'ty=Test model','note=Office')) { $bytes=[Text.Encoding]::UTF8.GetBytes($value); $txt += @([byte]$bytes.Length) + $bytes }
    New-DiscoveryPacket -Records @(
        (New-DiscoveryRecord $Service 12 (New-DiscoveryName $instance)),
        (New-DiscoveryRecord $instance 33 $srv),
        (New-DiscoveryRecord $instance 16 $txt),
        (New-DiscoveryRecord 'printer.local.' 1 ([byte[]]@(192,0,2,55)))
    )
}
