#Requires -Version 5.1
<#
.SYNOPSIS
  Soft memory governor for Windows HappyMonkey hosts.
  Safe reclaim only: never kills Cursor, Node MCP hosts, or OpenBot.
#>
[CmdletBinding()]
param(
  [int]$CriticalAvailMb = 3072,
  [switch]$DryRun,
  [switch]$PruneBuilder
)

$ErrorActionPreference = 'Continue'
$logDir = Join-Path $env:LOCALAPPDATA 'happymonkey\logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$logFile = Join-Path $logDir 'memory-governor.log'

function Write-GovLog([string]$Message) {
  $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'), $Message
  Add-Content -Path $logFile -Value $line
  Write-Output $line
}

function Get-AvailMb {
  $os = Get-CimInstance Win32_OperatingSystem
  return [int][math]::Round($os.FreePhysicalMemory / 1024.0)
}

function Invoke-Docker([string[]]$DockerArgs) {
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-GovLog 'docker not installed — skip'
    return
  }
  if ($DryRun) {
    Write-GovLog ("DRYRUN docker " + ($DockerArgs -join ' '))
    return
  }
  & docker @DockerArgs 2>&1 | ForEach-Object { Write-GovLog ("docker: $_") }
}

$avail = Get-AvailMb
Write-GovLog ("start avail_mb=$avail critical_threshold=$CriticalAvailMb dry_run=$DryRun host=$env:COMPUTERNAME")

$leaks = @()
if (Get-Command docker -ErrorAction SilentlyContinue) {
  $leaks = @(docker ps -a --format '{{.Names}}' 2>$null | Where-Object {
    $_ -match '-wpcli-run-' -or $_ -match '-run-[a-f0-9]{8,}$'
  })
}
if ($leaks.Count -gt 0) {
  Write-GovLog ("reclaim leak containers: $($leaks -join ', ')")
  Invoke-Docker (@('stop') + $leaks)
  Invoke-Docker (@('rm', '-f') + $leaks)
} else {
  Write-GovLog 'no leak one-shot containers'
}

if (Get-Command docker -ErrorAction SilentlyContinue) {
  if ($DryRun) {
    Write-GovLog 'DRYRUN docker container prune -f'
  } else {
    $pruneOut = docker container prune -f 2>&1 | Out-String
    Write-GovLog ("container_prune: " + $pruneOut.Trim())
  }
}

$parkable = @(
  'agent-voice-pocket-tts',
  'qwen3-asr-server-qwen3-asr-1',
  'ellismediation-wordpress-1',
  'ellismediation-db-1'
)

$avail = Get-AvailMb
if ($avail -le $CriticalAvailMb -and (Get-Command docker -ErrorAction SilentlyContinue)) {
  Write-GovLog "pressure low avail_mb=$avail — parking idle heavy containers"
  $running = @(docker ps --format '{{.Names}}' 2>$null)
  foreach ($name in $parkable) {
    if ($running -contains $name) {
      Write-GovLog "park $name"
      Invoke-Docker @('stop', $name)
    }
  }
} else {
  Write-GovLog "pressure ok avail_mb=$avail — skip idle park"
}

if ($PruneBuilder -and (Get-Command docker -ErrorAction SilentlyContinue)) {
  if ($DryRun) {
    Write-GovLog 'DRYRUN docker builder prune -f --filter until=168h'
  } else {
    $b = docker builder prune -f --filter 'until=168h' 2>&1 | Out-String
    Write-GovLog ("builder_prune: " + $b.Trim())
  }
}

$availEnd = Get-AvailMb
$vmm = Get-Process vmmemWSL -ErrorAction SilentlyContinue
$vmmMb = if ($vmm) { [int][math]::Round($vmm.WorkingSet64 / 1MB) } else { 0 }
Write-GovLog "done avail_mb=$availEnd vmmemWSL_ws_mb=$vmmMb log=$logFile"
