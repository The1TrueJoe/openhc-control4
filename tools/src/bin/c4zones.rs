//! c4zones — write the audio client's zones from the box's own audio outputs.
//!
//! openHC's audiod already knows the outputs (from the kernel's PCMs) and
//! makes each a shared, mixable PCM `ohc_<id>`. This reads them from its API
//! (`GET 127.0.0.1:7072/api/audio`, `map.outputs`, in audiod's order with
//! HDMI last) and prints the client's config, one zone per output, mapped the
//! way the driver's connections are laid out:
//!
//!   non-HDMI outputs, in order   Audio Output 1..3 (4000..4002)   ports 6200..6202
//!   HDMI                         HDMI (Audio/Video) (4072)        port  6203
//!
//! (Director numbers a device's audio outputs 6200 + their index, and 4072
//! comes after 4000..4002.) Port 6200 is also where the box's Triad One
//! identity plays (that driver has one output), so a board with no plain
//! output (HDMI only) gets its first output at 6200 as well. The driver's io.lua applies the same rule to
//! audiod's `state/audio/map`. Volume belongs to audiod (its per-output
//! level), so every zone starts at 100.
//!
//! Exits 3, printing nothing, on a box with no named outputs: no client then.
//!
//! Usage: c4zones [audiod address, default 127.0.0.1:7072]

use serde_json::Value;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

const MAX_PLAIN: usize = 3;
const HDMI_PORT: u16 = 6203;

/// (port, label, pcm) per output that gets a zone.
fn zones(outputs: &[Value]) -> Vec<(u16, String, String)> {
    let mut plain = 0;
    let mut v = vec![];
    for o in outputs {
        let (Some(id), Some(pcm)) = (o["id"].as_str(), o["pcm"].as_str()) else { continue };
        let label = o["label"].as_str().unwrap_or(id).to_string();
        let port = if id == "hdmi" {
            HDMI_PORT
        } else if plain < MAX_PLAIN {
            plain += 1;
            6199 + plain as u16
        } else {
            eprintln!("c4zones: no connection left for output {id}");
            continue;
        };
        v.push((port, label, pcm.to_string()));
    }
    v.sort();
    if let Some(first) = v.first().cloned().filter(|z| z.0 != 6200) {
        v.insert(0, (6200, first.1, first.2));
    }
    v
}

fn toml(zones: &[(u16, String, String)]) -> String {
    let q = |s: &str| s.replace('\\', "\\\\").replace('"', "\\\"");
    let mut s = String::from(
        "# Written by openhc-control4's c4zones from audiod's outputs; regenerated at every start.\n\
         control = \"0.0.0.0:6100\"\napi = \"127.0.0.1:6180\"\nsddp = false\n\
         # Jitter buffer: Control4's 1200 ms default put AirPlay video ~1 s out of sync\n\
         # and kept playing after pause; 250 ms is ample on a wired LAN with RTX on.\n\
         latency_ms = 250\n",
    );
    for (port, label, pcm) in zones {
        s += &format!("\n[[zone]]\nport = {port}\nname = \"{}\"\ndevice = \"{}\"\nvolume = 100\n", q(label), q(pcm));
    }
    s
}

fn get(addr: &str) -> std::io::Result<Value> {
    let mut c = TcpStream::connect(addr)?;
    c.set_read_timeout(Some(Duration::from_secs(5)))?;
    c.write_all(b"GET /api/audio HTTP/1.0\r\nHost: localhost\r\n\r\n")?;
    let mut raw = String::new();
    c.read_to_string(&mut raw)?;
    let body = raw.split_once("\r\n\r\n").map_or("", |(_, b)| b);
    serde_json::from_str(body).map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))
}

fn main() {
    let addr = std::env::args().nth(1).unwrap_or_else(|| "127.0.0.1:7072".into());
    // audiod starts before the extensions, but give it a moment on a slow boot.
    let mut audio = None;
    for _ in 0..30 {
        match get(&addr) {
            Ok(v) => { audio = Some(v); break }
            Err(_) => std::thread::sleep(Duration::from_secs(2)),
        }
    }
    let Some(audio) = audio else {
        eprintln!("c4zones: audiod did not answer on {addr}");
        std::process::exit(2);
    };
    let outputs = audio["map"]["outputs"].as_array().cloned().unwrap_or_default();
    let z = zones(&outputs);
    if z.is_empty() {
        eprintln!("c4zones: this board has no named audio outputs");
        std::process::exit(3);
    }
    print!("{}", toml(&z));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hc800_outputs_map_onto_the_driver_connections() {
        // audiod's order (HDMI last); knobs carry id/label too and must not confuse it.
        let v: Value = serde_json::from_str(
            r#"{"map":{"outputs":[
              {"id":"analog1","label":"Analog 1","device":"hw:CARD=Intel,DEV=0","pcm":"ohc_analog1","tone":[{"id":"bass","label":"Bass","min":-12,"max":12,"unit":"dB"}]},
              {"id":"analog2","label":"Analog 2","device":"hw:CARD=Intel,DEV=2","pcm":"ohc_analog2","swap":true},
              {"id":"coax","label":"Coax (S/PDIF)","device":"hw:CARD=Intel,DEV=1","pcm":"ohc_coax"},
              {"id":"hdmi","label":"HDMI","device":"hw:CARD=Intel,DEV=3","pcm":"ohc_hdmi"}],
              "inputs":[{"id":"linein","label":"Line In","device":"hw:0","pcm":"ohc_in_linein"}]}}"#,
        )
        .unwrap();
        let z = zones(v["map"]["outputs"].as_array().unwrap());
        let got: Vec<(u16, &str)> = z.iter().map(|(p, _, pcm)| (*p, pcm.as_str())).collect();
        assert_eq!(got, [(6200, "ohc_analog1"), (6201, "ohc_analog2"), (6202, "ohc_coax"), (6203, "ohc_hdmi")]);
        let t = toml(&z);
        assert!(t.contains("latency_ms = 250") && t.contains("sddp = false") && t.contains("name = \"Coax (S/PDIF)\"") && t.contains("volume = 100"));
    }

    #[test]
    fn hdmi_only_board_still_lands_on_4072s_port() {
        let v: Value = serde_json::from_str(r#"[{"id":"hdmi","label":"HDMI","pcm":"ohc_hdmi"}]"#).unwrap();
        let z = zones(v.as_array().unwrap());
        assert_eq!(z.iter().map(|z| (z.0, z.2.as_str())).collect::<Vec<_>>(), [(6200, "ohc_hdmi"), (6203, "ohc_hdmi")]);
    }
}
