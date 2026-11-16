#Requires -Version 5.1
<#
.SYNOPSIS
  Start Resource Sentinel HTTP (LAN) for peer placement probes.
#>
[CmdletBinding()]
param(
  [string]$HostId = $env:RESOURCE_SENTINEL_HOST_ID,
  [string]$Peers = $env:RESOURCE_SENTINEL_PEERS,
  [string]$BindHost = '0.0.0.0',
  [int]$Port = 8800,
  [string]$SentinelRoot = ''
)

$ErrorActionPreference = 'Stop'

if (-not $SentinelRoot) {
  $candidates = @()
  if ($env:RESOURCE_SENTINEL_ROOT) { $candidates += $env:RESOURCE_SENTINEL_ROOT }
  $candidates += (Join-Path $env:USERPROFILE 'happymonkey\Resource-Sentinel-MCP')
  foreach ($c in $candidates) {
    if ($c -and (Test-Path (Join-Path $c 'src\resource_sentinel\server.py'))) {
      $SentinelRoot = $c
      break
    }
  }
}
if (-not $SentinelRoot) {
  throw 'Resource-Sentinel-MCP checkout not found'
}

if (-not $HostId) {
  $HostId = $env:COMPUTERNAME.ToLowerInvariant()
}

$stateDir = Join-Path $env:LOCALAPPDATA 'happymonkey\resource-sentinel'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$db = Join-Path $stateDir 'resource-sentinel.db'
$logDir = Join-Path $env:LOCALAPPDATA 'happymonkey\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$log = Join-Path $logDir 'sentinel-http.log'

# Avoid duplicate listeners
$existing = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($existing) {
  Write-Output "port $Port already listening — skip start"
  exit 0
}

$env:RESOURCE_SENTINEL_HOST_ID = $HostId
$env:RESOURCE_SENTINEL_DB = $db
if ($Peers) { $env:RESOURCE_SENTINEL_PEERS = $Peers }

$uv = Get-Command uv -ErrorAction SilentlyContinue
if (-not $uv) { throw 'uv not found on PATH' }

$args = @(
  'run', 'uvicorn', 'resource_sentinel.server:app',
  '--app-dir', 'src',
  '--host', $BindHost,
  '--port', "$Port"
)

$logOut = Join-Path $logDir 'sentinel-http.out.log'
$logErr = Join-Path $logDir 'sentinel-http.err.log'
# Prefer Scheduled Task so the process survives SSH/logoff of the starter shell.
$taskName = "HappyMonkey-SentinelHTTP-Run-$HostId"
$argLine = "-NoProfile -ExecutionPolicy Bypass -Command `" `$env:RESOURCE_SENTINEL_HOST_ID='$HostId'; `$env:RESOURCE_SENTINEL_DB='$db'; `$env:RESOURCE_SENTINEL_PEERS='$Peers'; Set-Location '$SentinelRoot'; & '$($uv.Source)' $($args -join ' ') *>> '$logOut' `""
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null
Write-Output "starting sentinel via task $taskName host_id=$HostId peers=$Peers bind=${BindHost}:$Port"
Start-ScheduledTask -TaskName $taskName
Write-Output "out=$logOut err=$logErr"

# Firewall (best-effort; may need elevation)
try {
  $rule = "ResourceSentinelHTTP-$Port"
  if (-not (Get-NetFirewallRule -DisplayName $rule -ErrorAction SilentlyContinue)) {
    New-NetFirewallRule -DisplayName $rule -Direction Inbound -Protocol TCP -LocalPort $Port -Action Allow -Profile Private | Out-Null
    Write-Output "firewall rule created: $rule"
  }
} catch {
  Write-Output "firewall note: $($_.Exception.Message)"
}
