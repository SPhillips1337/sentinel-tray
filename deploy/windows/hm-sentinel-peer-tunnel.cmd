@echo off
REM LocalForward 18801 -> peer Resource Sentinel :8800 (when LAN :8800 is filtered).
REM Usage: hm-sentinel-peer-tunnel.cmd <ssh-host-alias>
if "%~1"=="" (
  echo Usage: %~nx0 ^<ssh-host-alias^>
  exit /b 2
)
curl.exe -fsS --max-time 2 http://127.0.0.1:18801/healthz >NUL 2>&1
if %ERRORLEVEL%==0 (
  echo peer sentinel tunnel already up
  exit /b 0
)
start "" /min ssh -o BatchMode=yes -o ServerAliveInterval=30 -N -L 18801:127.0.0.1:8800 %~1
ping -n 3 127.0.0.1 >NUL
curl.exe -fsS --max-time 3 http://127.0.0.1:18801/healthz
if %ERRORLEVEL%==0 (
  echo peer tunnel ready on 127.0.0.1:18801
  exit /b 0
)
echo failed to establish peer tunnel
exit /b 1
