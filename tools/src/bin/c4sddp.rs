//! c4sddp — announce this openHC box over Control4's SDDP (udp/1902), so
//! Composer lists it under discovered devices, pairs it with the openHC
//! Controller driver (its `<search_types>` carry the same `Type`), and fills in
//! the driver's network connection: nobody types an IP.
//!
//! The protocol is the shared `sddp` crate's `Announcer` (NOTIFY ALIVE on a
//! timer, answers SEARCH, NOTIFY OFFLINE when dropped). It fixes its address at
//! start, so this restarts it when the box's address changes (a new DHCP lease
//! after a reboot or a move to Wi-Fi), and waits while there is none.
//!
//! Usage: c4sddp <slug> [display-model]
//!
//! One SDDP Type per openHC model — `openhc:<slug>` (openhc:ea3, openhc:hc800,
//! openhc:iox, …) — matching that model's driver `<search_types>`. Control4
//! audio/video bindings cannot be added dynamically, so each model ships its own
//! driver with its real AV/IO, and announces its own Type. Not "...controller...":
//! the flasher (and Composer) read that as a box running Director.

use std::net::{Ipv4Addr, SocketAddr, UdpSocket};
use std::time::Duration;

const CHECK: Duration = Duration::from_secs(30);

/// The address the box reaches the SDDP group from — the one Composer should use.
fn my_ip() -> Option<Ipv4Addr> {
    let s = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).ok()?;
    s.connect((Ipv4Addr::new(239, 255, 255, 250), 1902)).ok()?;
    match s.local_addr().ok()? {
        SocketAddr::V4(a) if !a.ip().is_unspecified() => Some(*a.ip()),
        _ => None,
    }
}

async fn announce(ip: Ipv4Addr, host: &str, slug: &str, model: &str) -> std::io::Result<sddp::Announcer> {
    sddp::Announcer::builder(host, &format!("openhc:{slug}"))
        .interface(ip)
        .primary_proxy("controller")
        .proxies(["controller"])
        .manufacturer("openHC")
        .model(model)
        .driver(&format!("openhc-{slug}.c4z"))
        .config_url(format!("http://{ip}/"))
        .start()
        .await
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let slug = std::env::args().nth(1).unwrap_or_else(|| "device".into());
    let model = std::env::args().nth(2).unwrap_or_else(|| format!("openHC {slug}"));
    let host = std::fs::read_to_string("/proc/sys/kernel/hostname")
        .map(|h| h.trim().to_string())
        .unwrap_or_else(|_| "openhc".into());
    // (address, the announcer for it). Dropping an announcer says NOTIFY OFFLINE.
    let mut current: Option<(Ipv4Addr, sddp::Announcer)> = None;
    // Stopped by the box's init (SIGTERM) or by hand: say goodbye before exiting.
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .expect("SIGTERM handler");
    loop {
        let ip = my_ip();
        if current.as_ref().map(|(a, _)| *a) != ip {
            current = None;
            if let Some(ip) = ip {
                match announce(ip, &host, &slug, &model).await {
                    Ok(a) => current = Some((ip, a)),
                    Err(e) => eprintln!("c4sddp: announcing from {ip}: {e}"),
                }
            }
        }
        tokio::select! {
            _ = tokio::time::sleep(CHECK) => {}
            _ = term.recv() => break,
            _ = tokio::signal::ctrl_c() => break,
        }
    }
    if let Some((_, a)) = current {
        let _ = a.shutdown().await; // NOTIFY OFFLINE
    }
}
