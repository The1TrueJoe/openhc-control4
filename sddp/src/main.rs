//! c4sddp — announce this openHC box over Control4's SDDP (udp/1902), so
//! Composer lists it under discovered devices, pairs it with the openHC
//! Controller driver (its `<search_types>` carry the same `Type`), and fills in
//! the driver's network connection: nobody types an IP.
//!
//! Sends `NOTIFY ALIVE` on start, every 5 minutes and whenever the address
//! changes, and answers `SEARCH` directly. The record's shape is the one real
//! devices send (see the flasher's `transport/src/sddp.rs` capture).
//!
//! Usage: c4sddp [model]

use std::net::{Ipv4Addr, SocketAddr, UdpSocket};
use std::time::{Duration, Instant};

const GROUP: Ipv4Addr = Ipv4Addr::new(239, 255, 255, 250);
const PORT: u16 = 1902;
/// Must match driver.xml `<search_types>`. Not "...controller...": the flasher
/// (and Composer) read that as a box running Director.
const TYPE: &str = "openhc:device";
const EVERY: Duration = Duration::from_secs(300);

fn record(first_line: &str, ip: Ipv4Addr, host: &str, model: &str) -> String {
    format!(
        "{first_line}\r\nFrom: \"{ip}:{PORT}\"\r\nHost: \"{host}\"\r\nMax-Age: 1800\r\n\
         Type: \"{TYPE}\"\r\nPrimary-Proxy: \"controller\"\r\nProxies: \"controller\"\r\n\
         Manufacturer: \"openHC\"\r\nModel: \"{model}\"\r\nDriver: \"openhc.c4z\"\r\n\
         Config-URL: \"http://{ip}/\"\r\n\r\n"
    )
}

/// The address the box reaches the group from — the one Composer should use.
fn my_ip() -> Option<Ipv4Addr> {
    let s = UdpSocket::bind((Ipv4Addr::UNSPECIFIED, 0)).ok()?;
    s.connect((GROUP, PORT)).ok()?;
    match s.local_addr().ok()? {
        SocketAddr::V4(a) if !a.ip().is_unspecified() => Some(*a.ip()),
        _ => None,
    }
}

fn main() {
    let model = std::env::args().nth(1).unwrap_or_else(|| "openHC".into());
    let host = std::fs::read_to_string("/proc/sys/kernel/hostname")
        .map(|h| h.trim().to_string())
        .unwrap_or_else(|_| "openhc".into());
    let sock = loop {
        match UdpSocket::bind((Ipv4Addr::UNSPECIFIED, PORT)) {
            Ok(s) => break s,
            Err(e) => {
                eprintln!("c4sddp: bind udp/{PORT}: {e}; retrying");
                std::thread::sleep(Duration::from_secs(10));
            }
        }
    };
    let _ = sock.set_multicast_ttl_v4(4);
    sock.set_read_timeout(Some(Duration::from_secs(5))).expect("read timeout");
    let (mut joined, mut last_ip, mut last_sent) = (false, None, None::<Instant>);
    let mut buf = [0u8; 1500];
    loop {
        let ip = my_ip();
        if let Some(ip) = ip {
            // The group can only be joined once an interface has an address.
            if !joined {
                joined = sock.join_multicast_v4(&GROUP, &Ipv4Addr::UNSPECIFIED).is_ok();
            }
            if last_ip != Some(ip) || last_sent.map_or(true, |t| t.elapsed() >= EVERY) {
                let msg = record("NOTIFY ALIVE SDDP/1.0", ip, &host, &model);
                if sock.send_to(msg.as_bytes(), (GROUP, PORT)).is_ok() {
                    last_sent = Some(Instant::now());
                    last_ip = Some(ip);
                }
            }
        }
        if let Ok((n, from)) = sock.recv_from(&mut buf) {
            let is_search = buf[..n].starts_with(b"SEARCH ");
            if let (true, Some(ip)) = (is_search, ip) {
                let _ = sock.send_to(record("SDDP/1.0 200 OK", ip, &host, &model).as_bytes(), from);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn record_matches_the_captured_shape() {
        let r = super::record("NOTIFY ALIVE SDDP/1.0", "10.0.0.5".parse().unwrap(), "openea3-000fff1f3565", "EA-3");
        assert!(r.starts_with("NOTIFY ALIVE SDDP/1.0\r\nFrom: \"10.0.0.5:1902\"\r\n"));
        for line in ["Type: \"openhc:device\"", "Driver: \"openhc.c4z\"", "Config-URL: \"http://10.0.0.5/\""] {
            assert!(r.contains(line), "{line}");
        }
        assert!(r.ends_with("\r\n\r\n"));
    }
}
