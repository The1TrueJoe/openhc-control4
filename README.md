# openhc-control4

Makes an [openHC](https://github.com/The1TrueJoe/openHC) controller a Control4
controller again. One Control4 driver puts the box back in your project:

- **the on-screen navigator**: the room's remote drives a 10-ft UI that WebKit
  draws on the box's own video output, showing your real project;
- **the IO**: the box's relays, contacts, IR outputs and serial ports appear as
  ordinary Control4 connections, to bind like a controller's own.

Director still runs on your Control4 controller. The openHC box becomes a
device in that project, the way a secondary controller is one.

| Controller | Navigator on screen | IO |
|---|:---:|:---:|
| HC-800 | ✅ (component out, cog on Mesa i915) | ✅ |
| EA-1 / EA-3 | ✅ (HDMI, WPE on the SGX545) | ✅ |
| HC-250 | ⏳ openHC has no on-screen view (`wpe`) or persistent `/data` on it yet | ✅ 1 relay, 1 contact, 5 IR, 2 serial (driver only) |
| CA-1, IO Extender | no video output | ✅ whatever iod serves (driver only) |

"Driver only" means nothing goes on the box: the driver reaches openHC's iod
directly. The flasher's Control4 option still saves the driver for these boards.
They don't announce themselves over SDDP, so in Composer you identify the
**openHC Controller** connection on the Network tab with the box's address.

## How it fits together

```
 C4 remote ─▶ Director (your Control4 controller)
                │  runs the openHC Controller driver (openhc.c4z)
                │
                ├── nav keys + a Director REST token, NDJSON on :9010 ──┐
                │                                                       ▼
                │                       openHC box: c4nav (control4-fake-navigator's backend)
                │                         reads rooms/devices/now-playing from Director's
                │                         REST API with that token, serves the UI on :8090
                │                                                       ▼
                │                       WPE WebKit (openHC's on-screen view) ─▶ HDMI / component
                │
                └── relays / contacts / IR / serial, MQTT on :1883 ──▶ openHC iod ─▶ the IO
```

The UI is fed from the driver: it mints the REST token on the Director
controller and hands it over, so the box needs no credentials, `.env` or SSH
to the controller. The IO half talks to openHC's iod over its normal MQTT
topics, so it needs nothing installed on the box, and it works on boards with
no screen.

## What's in here

| Path | What |
|---|---|
| `driver/` | the Control4 driver. `driver.lua` is control4-navigator-sink-lib's navigator driver, unchanged; `io.lua` adds the IO and is appended to it by `package.sh` |
| `navigator/` | submodule: [control4-fake-navigator](https://github.com/The1TrueJoe/control4-fake-navigator) (UI + backend), which carries [control4-navigator-sink-lib](https://github.com/The1TrueJoe/control4-navigator-sink-lib) |
| `box/init` | the box side's start/stop script, at `/data/extensions/control4/init` |
| `tools/` | box helpers: `c4sddp` announces the box over Control4's SDDP so Composer finds it; `c4zones` writes the audio client's zones from openHC's outputs |
| `.github/workflows/build.yml` | builds `openhc.c4z` and `openhc-control4.tar.gz`; attaches both to a release |

## What it needs from openHC

An image with the `wpe` feature (the on-screen view, `S95ohc-display`),
`iomcu`/iod for the IO, and `S96ohc-extensions`, which starts what is in
`/data/extensions` at boot. `/data` survives a reboot on every board, including
the HC-800, whose root is a RAM initramfs.

## Install

**With the openHC flasher** (recommended): find the controller, check it, pick
the release, and leave **Make it a Control4 controller again** ticked on the
Install screen. When openHC is in, the flasher waits for the box to come back
(by MAC, since its DHCP address usually changes), installs this, points the
on-screen view at the navigator, and saves `openhc.c4z` to your Downloads.

From the command line, the same:

```bash
ohc-flash install <ip> --images openhc-<board>-<version>.zip --control4
```

On a box already running openHC:

```bash
ohc-flash control4 <ip>
```

**In Composer Pro:**

1. Driver → Add Driver… → `openhc.c4z`.
2. Add the openHC box from the discovered devices. The box announces itself
   over SDDP (`c4sddp`), so Composer pairs it with the driver and fills in its
   address. Without discovery, identify the **openHC Controller** connection on
   the Network tab like any IP device.
3. Bind **HDMI (Audio/Video)** to the TV's input. The Onscreen Navigator binds
   itself, so the room's C4/menu button now opens the UI on that TV.
4. Bind the IO connections your box has. The driver lists every board's IO, so
   some connections won't exist on yours; leave those unbound. If iod has
   `IOD_TOKEN` set, put it in **IO Token**.

The driver's **Documentation** tab is a setup guide and shows the box's own
dashboard (settings, IO, the display, updates). The **openHC Web UI** property
links to the same page. **Link Status**, **Token Status** and **IO Status**
report on the navigator link, the project token and the IO link.

## Digital audio

Control4's Digital Media plays to the box like it does to a Control4
controller, one stream per audio output. The box runs
[control4-audio-client](https://github.com/The1TrueJoe/control4-audio-client),
an open implementation of Control4 OS3's audio client.

- **Outputs come from openHC, not from here.** openHC's audiod already knows
  the board's outputs and makes each one a shared, mixable ALSA PCM
  (`ohc_analog1`, `ohc_hdmi`, …). `c4zones` reads them from audiod's API and
  gives the client one zone per output. Nothing in this repository lists a
  board's audio hardware.
- **Ports line up with the driver.** Director numbers a device's audio outputs
  `6200 + index`. The driver declares Audio Output 1–3 (4000–4002) and then
  HDMI (4072), so the box's non-HDMI outputs take 6200–6202 in audiod's order,
  and HDMI takes 6203. Bind the outputs your box has.
- **HDMI plays alongside the navigator.** The HDMI zone plays into `ohc_hdmi`,
  a dmix, and openHC's WebKit is built without multimedia, so it never holds
  the device.
- **One volume.** Room volume and mute drive audiod's per-output level (the
  same level its AirPlay/Spotify sliders and web UI set) over the driver's MQTT
  link, and the client's zones stay at 100. Mute is level 0 with the level
  remembered.

| Connection | Binding | Client port | Box output |
|---|---|---|---|
| Digital Audio Client (input) | 3003 | 6100 (control) | |
| Audio Output 1–3 | 4000–4002 | 6200–6202 | audiod's non-HDMI outputs, in order |
| HDMI (Audio/Video) | 4072 | 6203 | `ohc_hdmi` |

It needs the `gstreamer` feature in the openHC image. Without it, or on a board
with no named outputs, the box simply runs no audio client.

**Not yet confirmed on hardware:** whether Director streams to a driver that
declares this shape, which proxy commands carry volume for a controller's own
outputs ("Last IO Command" shows them), and which UDP port the RTP arrives on.
The client's own README and PROTOCOL.md cover the rest.

## IO mapping

| Connection | Binding | iod |
|---|---|---|
| Serial 1–4 | 1–4 | `serial/0–3` |
| IR Output 1–8 | 11–18 | `ir/0–7` |
| Relay 1–4 | 21–24 | `relay/0–3` (`OPEN`/`CLOSE`/`TOGGLE`/`TRIGGER`) |
| Contact 1–4 | 31–34 | `contact/0–3` |

Relay and contact state are reported to Director as `CLOSED`/`OPENED`. iod
retains them, so a reconnect brings Director up to date without polling.

**Not yet confirmed on hardware:** the exact commands Director sends an IR
output or serial port that a driver provides. The driver passes on any
Pronto-looking parameter (IR) or `DATA` (serial), and **Last IO Command** shows
what actually arrived. Serial received from a device does not reach Director
yet; that waits on the same capture.

## Build

CI does it. By hand:

```bash
git submodule update --init --recursive
driver/package.sh && (cd driver && lua test.lua)    # openhc.c4z + the IO self-check
```

```bash
cd tools && cargo test && cargo build --release --target x86_64-unknown-linux-musl
```

```bash
cd navigator/backend && CC_x86_64_unknown_linux_musl=musl-gcc cargo build --release --target x86_64-unknown-linux-musl
```

```bash
cd navigator/frontend && npm ci && npm run build
```

## Security

The Director token the driver sends is a credential for the whole project,
sent over plain TCP on your LAN. The box's UI listens on `127.0.0.1` only. Set
**Send Project Token** to `No` to keep the token on the controller, and give the
box its own `C4_HOST`/`C4_TOKEN` in `/data/extensions/control4/c4nav.conf`
instead.

## Not yet confirmed on hardware

- Composer pairing the SDDP-discovered box with the driver through
  `<search_types>` (`openhc:device`). The announcement itself is checked: the
  flasher's discovery lists it alongside real Control4 devices.
- The dashboard framed inside Composer's Documentation tab. The **openHC Web UI**
  link is the fallback.
- A DriverWorks driver reaching `127.0.0.1:3000` to mint the project token.
