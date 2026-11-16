#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Open Resource Sentinel :8800 on all profiles and mark active LAN NICs Private.
  Run elevated once on hosts whose Wi‑Fi/Ethernet is "Public" (blocks inbound 8800).
#>
$ErrorActionPreference = 'Stop'

netsh advfirewall firewall delete rule name='ResourceSentinelHTTP-8800' | Out-Null
netsh advfirewall firewall add rule name='ResourceSentinelHTTP-8800' dir=in action=allow protocol=TCP localport=8800 profile=any | Out-Null
Write-Output 'firewall rule ResourceSentinelHTTP-8800 -> allow TCP 8800 (any profile)'

Get-NetConnectionProfile | ForEach-Object {
  Write-Output ("was: {0} / {1} / {2}" -f $_.Name, $_.InterfaceAlias, $_.NetworkCategory)
  if ($_.NetworkCategory -ne 'Private') {
    Set-NetConnectionProfile -InterfaceIndex $_.InterfaceIndex -NetworkCategory Private
    Write-Output ("now: {0} -> Private" -f $_.InterfaceAlias)
  }
}

try {
  Invoke-RestMethod http://127.0.0.1:8800/healthz -TimeoutSec 3 | ConvertTo-Json -Compress
} catch {
  Write-Output "local healthz not up yet: $($_.Exception.Message)"
}
