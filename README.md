# sentinel-tray

Windows companion for [Resource Sentinel](https://github.com/HappyMonkeyAI) — tray UI, soft memory governor, and LAN HTTP supervision so peer hosts can advertise free RAM / pressure for agent placement **without SSH**.

**License:** MIT © Stephen Phillips and HappyMonkeyAI

## What it does

| Piece | Role |
|-------|------|
| **Resource Sentinel HTTP** | Local `:8800` service for snapshots, leases, and peer probes |
| **Memory governor** | Soft Docker reclaim + idle park when free RAM is low |
| **Tray app** | Status tooltip, one-click reclaim, start Sentinel, open logs |

## Quick install (Windows)

```powershell
# Build the tray (optional if you already have sentinel-tray.exe)
cargo build --release

cd deploy\windows
.\install-tray.ps1 -HostId my-desktop -Peers "http://192.168.1.10:8800,http://192.168.1.11:8800" -StartNow
```

Or host stack only (no tray binary):

```powershell
.\install-host.ps1 -HostId my-desktop -Peers "http://192.168.1.10:8800"
```

`install-host.ps1` will:

1. Cap WSL via `~\.wslconfig` (10GB) — takes effect after `wsl --shutdown`
2. Schedule the memory governor every 15 minutes
3. Start Resource Sentinel HTTP on `0.0.0.0:8800` at logon

### Environment

| Variable | Purpose |
|----------|---------|
| `RESOURCE_SENTINEL_HOST_ID` | Stable host id in `/healthz` and placement |
| `RESOURCE_SENTINEL_PEERS` | Comma-separated peer base URLs, e.g. `http://192.168.1.10:8800` |
| `RESOURCE_SENTINEL_ROOT` | Optional path to a Resource-Sentinel-MCP checkout |

Requires [`uv`](https://github.com/astral-sh/uv) and a local [Resource-Sentinel-MCP](https://github.com/HappyMonkeyAI) checkout under `%USERPROFILE%\happymonkey\Resource-Sentinel-MCP` (or set `RESOURCE_SENTINEL_ROOT`).

## Tray

```powershell
cargo run --release
# or after install-tray.ps1:
& "$env:LOCALAPPDATA\happymonkey\sentinel-tray\sentinel-tray.exe"
```

Menu: **Reclaim memory** · **Start Sentinel HTTP** · **Refresh** · **Open logs** · **Quit**

Logs: `%LOCALAPPDATA%\happymonkey\logs\`

## Networking notes

- Open inbound TCP **8800** on Private profiles (`deploy\windows\fix-lan-firewall.ps1`, run elevated once if needed).
- If LAN `:8800` is filtered between hosts but SSH works, use the SSH HTTP proxy:

```powershell
.\deploy\windows\hm-sentinel-ssh-proxy.ps1 -SshHost my-peer-host
# listens on http://127.0.0.1:18801 — add that URL to RESOURCE_SENTINEL_PEERS
```

## Verify

```powershell
curl.exe http://127.0.0.1:8800/healthz
curl.exe http://127.0.0.1:8800/api/peers
curl.exe "http://127.0.0.1:8800/api/placement-recommendation?estimated_memory_mb=2048&cpu_weight=20"
```
