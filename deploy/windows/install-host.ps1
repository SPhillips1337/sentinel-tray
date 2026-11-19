#Requires -Version 5.1
<#
.SYNOPSIS
  Install memory governor + Resource Sentinel HTTP for a Windows HappyMonkey host.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$HostId,

  [Parameter(Mandatory = $true)]
  [string]$Peers,

  [string]$InstallRoot = ''
)

$ErrorActionPreference = 'Stop'

if (-not $InstallRoot) {
  $InstallRoot = Join-Path $env:LOCALAPPDATA 'happymonkey\sentinel-tray'
}
$deploySrc = Split-Path -Parent $MyInvocation.MyCommand.Path
New-Item -ItemType Directory -Force -Path $InstallRoot | Out-Null
foreach ($name in @('hm-memory-governor.ps1', 'start-sentinel-http.ps1', 'install-host.ps1')) {
  $from = Join-Path $deploySrc $name
  $to = Join-Path $InstallRoot $name
  if ([IO.Path]::GetFullPath($from) -ne [IO.Path]::GetFullPath($to)) {
    Copy-Item $from $to -Force
  }
}

# WSL memory cap (does not shutdown WSL here)
$wslPath = Join-Path $env:USERPROFILE '.wslconfig'
$wslBody = @"
[general]
instanceIdleTimeout=-1

[wsl2]
networkingMode=nat
memory=10GB
processors=6
swap=4GB
localhostForwarding=true
vmIdleTimeout=-1
"@
Set-Content -Path $wslPath -Value $wslBody -Encoding ascii
Write-Output "wrote $wslPath (cap applies after wsl --shutdown)"

# Scheduled tasks — run powershell.exe directly (no cmd.exe flash) and keep Hidden.
$govArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$InstallRoot\hm-memory-governor.ps1`" -PruneBuilder"
$sentArgs = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$InstallRoot\start-sentinel-http.ps1`" -HostId $HostId -Peers `"$Peers`""

function Register-HmTask([string]$Name, [string]$Argument, [bool]$AtLogon, [int]$Minutes = 0) {
  Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction SilentlyContinue
  $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $Argument
  if ($AtLogon) {
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
  } else {
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
      -RepetitionInterval (New-TimeSpan -Minutes $Minutes) `
      -RepetitionDuration (New-TimeSpan -Days 3650)
  }
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew -Hidden
  $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
  Register-ScheduledTask -TaskName $Name -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
    -Description "HappyMonkey $Name (hidden)" | Out-Null
  Write-Output "registered task $Name (hidden)"
}

Register-HmTask 'HappyMonkey-MemoryGovernor' $govArgs $false 15
Register-HmTask 'HappyMonkey-SentinelHTTP' $sentArgs $true 0

# Start Sentinel now
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $InstallRoot 'start-sentinel-http.ps1') -HostId $HostId -Peers $Peers
Start-Sleep -Seconds 3
try {
  $h = Invoke-RestMethod -Uri 'http://127.0.0.1:8800/healthz' -TimeoutSec 5
  Write-Output ("healthz=" + ($h | ConvertTo-Json -Compress))
} catch {
  Write-Output "healthz pending: $($_.Exception.Message)"
}

Write-Output "install complete host_id=$HostId peers=$Peers root=$InstallRoot"
