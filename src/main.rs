//! Resource Sentinel tray companion for Windows HappyMonkey hosts.
//!
//! MVP: tooltip with local pressure + peer reachability, reclaim via governor script,
//! ensure local HTTP Sentinel is up, open logs.

#![windows_subsystem = "windows"]

use anyhow::{Context, Result};
use serde::Deserialize;
use std::path::PathBuf;
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tray_icon::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tray_icon::{Icon, TrayIconBuilder};
use winit::application::ApplicationHandler;
use winit::event::WindowEvent;
use winit::event_loop::{ActiveEventLoop, EventLoop};
use winit::window::WindowId;

const LOCAL: &str = "http://127.0.0.1:8800";

#[derive(Debug, Deserialize)]
struct Healthz {
    #[allow(dead_code)]
    status: String,
    host_id: String,
}

#[derive(Debug, Deserialize)]
struct Peer {
    host_id: String,
    free_memory_mb: i64,
    pressure: String,
    reachable: bool,
}

#[derive(Default)]
struct Status {
    tip: String,
}

fn install_root() -> PathBuf {
    dirs_fallback()
}

fn dirs_fallback() -> PathBuf {
    std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
        .join("happymonkey")
        .join("sentinel-tray")
}

fn logs_dir() -> PathBuf {
    std::env::var_os("LOCALAPPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
        .join("happymonkey")
        .join("logs")
}

fn host_id() -> String {
    std::env::var("RESOURCE_SENTINEL_HOST_ID").unwrap_or_else(|_| {
        hostname::get()
            .ok()
            .and_then(|h| h.into_string().ok())
            .unwrap_or_else(|| "desktop".into())
            .to_lowercase()
    })
}

fn peers_env() -> String {
    std::env::var("RESOURCE_SENTINEL_PEERS").unwrap_or_default()
}

fn refresh_status() -> String {
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs(2))
        .build()
        .ok();
    let Some(client) = client else {
        return "sentinel-tray: http client error".into();
    };

    let health = client
        .get(format!("{LOCAL}/healthz"))
        .send()
        .and_then(|r| r.error_for_status())
        .and_then(|r| r.json::<Healthz>());

    let peers = client
        .get(format!("{LOCAL}/api/peers"))
        .send()
        .and_then(|r| r.error_for_status())
        .and_then(|r| r.json::<Vec<Peer>>())
        .unwrap_or_default();

    match health {
        Ok(h) => {
            let peer_bits: Vec<String> = peers
                .iter()
                .map(|p| {
                    if p.reachable {
                        format!("{} {} {}MB", p.host_id, p.pressure, p.free_memory_mb)
                    } else {
                        format!("{} DOWN", p.host_id)
                    }
                })
                .collect();
            format!(
                "Sentinel {} ok | peers: {}",
                h.host_id,
                if peer_bits.is_empty() {
                    "none".into()
                } else {
                    peer_bits.join("; ")
                }
            )
        }
        Err(_) => "Sentinel HTTP DOWN — use Start Sentinel".into(),
    }
}

fn run_governor() -> Result<()> {
    let script = install_root().join("hm-memory-governor.ps1");
    Command::new("powershell")
        .args([
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            script.to_str().context("governor path")?,
            "-PruneBuilder",
        ])
        .status()
        .context("governor")?;
    Ok(())
}

fn start_sentinel() -> Result<()> {
    let script = install_root().join("start-sentinel-http.ps1");
    Command::new("powershell")
        .args([
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            script.to_str().context("start script path")?,
            "-HostId",
            &host_id(),
            "-Peers",
            &peers_env(),
        ])
        .status()
        .context("start sentinel")?;
    Ok(())
}

fn ensure_deploy_scripts() {
    let root = install_root();
    let _ = std::fs::create_dir_all(&root);
    // Prefer repo deploy copy when developing next to source.
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            for name in ["hm-memory-governor.ps1", "start-sentinel-http.ps1"] {
                let cand = dir.join("deploy").join("windows").join(name);
                if cand.exists() {
                    let _ = std::fs::copy(&cand, root.join(name));
                }
            }
        }
    }
}

struct App {
    status: Arc<Mutex<Status>>,
    tray: Option<tray_icon::TrayIcon>,
    item_reclaim: MenuItem,
    item_start: MenuItem,
    item_refresh: MenuItem,
    item_logs: MenuItem,
    item_quit: MenuItem,
}

impl ApplicationHandler for App {
    fn resumed(&mut self, _event_loop: &ActiveEventLoop) {}

    fn window_event(&mut self, _event_loop: &ActiveEventLoop, _id: WindowId, _event: WindowEvent) {}

    fn about_to_wait(&mut self, event_loop: &ActiveEventLoop) {
        while let Ok(event) = MenuEvent::receiver().try_recv() {
            if event.id == self.item_quit.id() {
                event_loop.exit();
            } else if event.id == self.item_reclaim.id() {
                let _ = run_governor();
                self.update_tip();
            } else if event.id == self.item_start.id() {
                let _ = start_sentinel();
                self.update_tip();
            } else if event.id == self.item_refresh.id() {
                self.update_tip();
            } else if event.id == self.item_logs.id() {
                let _ = open::that(logs_dir());
            }
        }
    }
}

impl App {
    fn update_tip(&mut self) {
        let tip = refresh_status();
        if let Ok(mut s) = self.status.lock() {
            s.tip = tip.clone();
        }
        if let Some(tray) = &self.tray {
            let _ = tray.set_tooltip(Some(tip));
        }
    }
}

fn tiny_icon() -> Result<Icon> {
    // 16x16 solid teal RGBA
    let mut rgba = Vec::with_capacity(16 * 16 * 4);
    for _ in 0..(16 * 16) {
        rgba.extend_from_slice(&[0x14, 0xB8, 0xA6, 0xFF]);
    }
    Icon::from_rgba(rgba, 16, 16).context("icon")
}

fn main() -> Result<()> {
    ensure_deploy_scripts();

    let status = Arc::new(Mutex::new(Status {
        tip: "sentinel-tray starting…".into(),
    }));

    let item_reclaim = MenuItem::new("Reclaim memory now", true, None);
    let item_start = MenuItem::new("Start Sentinel HTTP", true, None);
    let item_refresh = MenuItem::new("Refresh status", true, None);
    let item_logs = MenuItem::new("Open logs", true, None);
    let item_quit = MenuItem::new("Quit", true, None);

    let menu = Menu::new();
    menu.append(&item_reclaim)?;
    menu.append(&item_start)?;
    menu.append(&item_refresh)?;
    menu.append(&PredefinedMenuItem::separator())?;
    menu.append(&item_logs)?;
    menu.append(&PredefinedMenuItem::separator())?;
    menu.append(&item_quit)?;

    let icon = tiny_icon()?;
    let tray = TrayIconBuilder::new()
        .with_menu(Box::new(menu))
        .with_tooltip("sentinel-tray")
        .with_icon(icon)
        .build()?;

    let mut app = App {
        status,
        tray: Some(tray),
        item_reclaim,
        item_start,
        item_refresh,
        item_logs,
        item_quit,
    };
    app.update_tip();

    // Keep local HTTP up when possible.
    let _ = start_sentinel();
    app.update_tip();

    let event_loop = EventLoop::new()?;
    event_loop.run_app(&mut app)?;
    Ok(())
}

// Minimal hostname helper without extra crate if unavailable.
mod hostname {
    use std::ffi::OsString;
    pub fn get() -> std::io::Result<OsString> {
        std::env::var_os("COMPUTERNAME")
            .or_else(|| std::env::var_os("HOSTNAME"))
            .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::NotFound, "no hostname"))
    }
}
