#Requires -Version 5.1
<#
.SYNOPSIS
  Local HTTP proxy that fetches a peer Resource Sentinel over SSH.
  Use when LAN :8800 to the peer is filtered but SSH works.
  Point peers at: http://127.0.0.1:18801
#>
param(
  [int]$ListenPort = 18801,
  [Parameter(Mandatory = $true)]
  [string]$SshHost
)

$ErrorActionPreference = 'Stop'
$prefix = "http://127.0.0.1:$ListenPort/"
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)
$listener.Start()
Write-Output "ssh-proxy listening on $prefix -> ${SshHost}:8800"

while ($true) {
  $ctx = $listener.GetContext()
  $path = $ctx.Request.Url.AbsolutePath
  if ([string]::IsNullOrWhiteSpace($path)) { $path = '/healthz' }
  $remote = "http://127.0.0.1:8800$path"
  if ($ctx.Request.Url.Query) { $remote += $ctx.Request.Url.Query }

  try {
    $body = & ssh -o BatchMode=yes -o ConnectTimeout=5 $SshHost "curl.exe -fsS --max-time 4 `"$remote`""
    $bytes = [Text.Encoding]::UTF8.GetBytes(($body | Out-String).Trim())
    $ctx.Response.StatusCode = 200
    $ctx.Response.ContentType = 'application/json'
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  } catch {
    $msg = @{ error = $_.Exception.Message; peer = $SshHost } | ConvertTo-Json -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($msg)
    $ctx.Response.StatusCode = 502
    $ctx.Response.ContentType = 'application/json'
    $ctx.Response.ContentLength64 = $bytes.Length
    $ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
  }
  $ctx.Response.Close()
}
