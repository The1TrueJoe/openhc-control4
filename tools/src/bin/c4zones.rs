//! c4zones — write the audio client's zones from the box's own audio outputs.
//!
//! openHC's audiod already knows the outputs (from the kernel's PCMs) and
//! makes each a shared, mixable PCM `ohc_<id>`. This reads them from its API
//! (`GET 127.0.0.1:7072/api/audio`, `map.outputs`, in audiod's order with
//! HDMI last) and prints the client's config, one zone per output.
//!
//! Director streams to the box through Control4's own driver for that model
//! (the openHC driver adds it as the box's audio device), and that driver
//! numbers each output 6200 + the connection's offset: a room End-Point
//! 7000+n -> 6200+n, an output 4000+n -> 6200+n, HDMI 4070+n -> 6200+n.
//! The non-HDMI outputs come in the same order on every model, so they are
//! 6200.. in audiod's order. HDMI sits at a different id per model (EA-1
//! 7000/4072, EA-3 7002/4072, EA-5 7072, HC-800 7003/4073), so it answers on
//! every port one of those gives it that no other output owns. Port 6200 is
//! also the Triad One's one output (the fallback driver).
//!
//! Volume belongs to audiod (its per-output level), so every zone starts at 100.
//!
//! Exits 3, printing nothing, on a box with no named outputs: no client then.
//!
//! Usage: c4zones [audiod address, default 127.0.0.1:7072]

use serde_json::Value;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

const MAX_PLAIN: usize = 4; // the EA-5: two analog, two coax
/// HDMI's ports under each model's driver, besides 6200 + the plain outputs:
/// EA-1/EA-3 4072 and HC-800 4073 (through an amp), EA-5's End-Point 7072.
const HDMI_PORTS: [u16; 3] = [6202, 6203, 6272];

/// (port, label, pcm) per output that gets a zone.
fn zones(outputs: &[Value]) -> Vec<(u16, String, String)> {
    let mut v = vec![];
    let mut hdmi = None;
    for o in outputs {
        let (Some(id), Some(pcm)) = (o["id"].as_str(), o["pcm"].as_str()) else { continue };
        let label = o["label"].as_str().unwrap_or(id).to_string();
        if id == "hdmi" {
            hdmi = Some((label, pcm.to_string()));
        } else if v.len() < MAX_PLAIN {
            v.push((6200 + v.len() as u16, label, pcm.to_string()));
        } else {
            eprintln!("c4zones: no connection left for output {id}");
        }
    }
    if let Some((label, pcm)) = hdmi {
        let first = 6200 + v.len() as u16;
        for port in std::iter::once(first).chain(HDMI_PORTS) {
            if !v.iter().any(|z| z.0 == port) {
                v.push((port, label.clone(), pcm.clone()));
            }
        }
    }
    v.sort();
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

    fn ports(v: &str) -> Vec<(u16, String)> {
        let v: Value = serde_json::from_str(v).unwrap();
        zones(v.as_array().unwrap()).into_iter().map(|(p, _, pcm)| (p, pcm)).collect()
    }
    fn want(z: &[(u16, &str)]) -> Vec<(u16, String)> {
        z.iter().map(|(p, s)| (*p, s.to_string())).collect()
    }

    #[test]
    fn hc800_outputs_map_onto_its_driver() {
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
        // control4_hc800: End-Points 7000-7003, HDMI 4073 -> 6203; 6272 unused but harmless.
        assert_eq!(got, [(6200, "ohc_analog1"), (6201, "ohc_analog2"), (6202, "ohc_coax"), (6203, "ohc_hdmi"), (6272, "ohc_hdmi")]);
        let t = toml(&z);
        assert!(t.contains("latency_ms = 250") && t.contains("sddp = false") && t.contains("name = \"Coax (S/PDIF)\"") && t.contains("volume = 100"));
    }

    #[test]
    fn ea1_hdmi_on_its_end_point_and_its_output() {
        // control4_ea1: HDMI End-Point 7000 -> 6200, HDMI output 4072 -> 6202.
        assert_eq!(ports(r#"[{"id":"hdmi","pcm":"ohc_hdmi"}]"#),
            want(&[(6200, "ohc_hdmi"), (6202, "ohc_hdmi"), (6203, "ohc_hdmi"), (6272, "ohc_hdmi")]));
    }

    #[test]
    fn ea3_matches_the_stock_ea3() {
        // control4_ea3 (and a real EA-3's audioclient_config): 6200 analog, 6201 coax, 6202 HDMI.
        assert_eq!(ports(r#"[{"id":"analog","pcm":"ohc_analog"},{"id":"coax","pcm":"ohc_coax"},{"id":"hdmi","pcm":"ohc_hdmi"}]"#),
            want(&[(6200, "ohc_analog"), (6201, "ohc_coax"), (6202, "ohc_hdmi"), (6203, "ohc_hdmi"), (6272, "ohc_hdmi")]));
    }

    #[test]
    fn ea5_four_plain_outputs_and_hdmi_on_7072s_port() {
        // control4_ea5: End-Points 7000-7003 and 7072 (HDMI) -> 6272.
        let got = ports(r#"[{"id":"analog1","pcm":"a1"},{"id":"analog2","pcm":"a2"},{"id":"coax1","pcm":"c1"},{"id":"coax2","pcm":"c2"},{"id":"hdmi","pcm":"h"}]"#);
        assert_eq!(got, want(&[(6200, "a1"), (6201, "a2"), (6202, "c1"), (6203, "c2"), (6204, "h"), (6272, "h")]));
    }
}
