#Requires -Version 5.1
<#
.SYNOPSIS
  Install sentinel-tray.exe + scripts and start at logon.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$HostId,

  [Parameter(Mandatory = $true)]
  [string]$Peers,

  [string]$ExeSource = '',
  [switch]$StartNow
)

$ErrorActionPreference = 'Stop'
$installRoot = Join-Path $env:LOCALAPPDATA 'happymonkey\sentinel-tray'
$deploySrc = Split-Path -Parent $MyInvocation.MyCommand.Path
New-Item -ItemType Directory -Force -Path $installRoot | Out-Null

if (-not $ExeSource) {
  $repoRoot = Split-Path -Parent (Split-Path -Parent $deploySrc)
  $cand = @(
    (Join-Path $repoRoot 'target\release\sentinel-tray.exe'),
    (Join-Path $repoRoot 'target\debug\sentinel-tray.exe')
  )
  $ExeSource = $cand | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $ExeSource -or -not (Test-Path $ExeSource)) {
  throw "sentinel-tray.exe not found. Build with: cargo build --release"
}

$exeDest = Join-Path $installRoot 'sentinel-tray.exe'
if ([IO.Path]::GetFullPath($ExeSource) -ne [IO.Path]::GetFullPath($exeDest)) {
  Copy-Item $ExeSource $exeDest -Force
}
foreach ($name in @(
  'hm-memory-governor.ps1',
  'start-sentinel-http.ps1',
  'install-host.ps1',
  'install-tray.ps1',
  'hm-sentinel-ssh-proxy.ps1',
  'fix-lan-firewall.ps1'
)) {
  $from = Join-Path $deploySrc $name
  $to = Join-Path $installRoot $name
  if ((Test-Path $from) -and ([IO.Path]::GetFullPath($from) -ne [IO.Path]::GetFullPath($to))) {
    Copy-Item $from $to -Force
  }
}

# Ensure host stack tasks exist
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $installRoot 'install-host.ps1') -HostId $HostId -Peers $Peers

# Startup shortcut
$startup = [Environment]::GetFolderPath('Startup')
$lnkPath = Join-Path $startup 'Sentinel Tray.lnk'
$w = New-Object -ComObject WScript.Shell
$lnk = $w.CreateShortcut($lnkPath)
$lnk.TargetPath = Join-Path $installRoot 'sentinel-tray.exe'
$lnk.WorkingDirectory = $installRoot
$lnk.WindowStyle = 7
$lnk.Description = "Resource Sentinel tray ($HostId)"
$lnk.Save()
Write-Output "startup shortcut: $lnkPath"

# User-level env for the tray process
[Environment]::SetEnvironmentVariable('RESOURCE_SENTINEL_HOST_ID', $HostId, 'User')
[Environment]::SetEnvironmentVariable('RESOURCE_SENTINEL_PEERS', $Peers, 'User')
$env:RESOURCE_SENTINEL_HOST_ID = $HostId
$env:RESOURCE_SENTINEL_PEERS = $Peers

if ($StartNow) {
  Get-Process sentinel-tray -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Process -FilePath (Join-Path $installRoot 'sentinel-tray.exe') -WorkingDirectory $installRoot
  Write-Output 'sentinel-tray started'
}

Write-Output "installed to $installRoot"
