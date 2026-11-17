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
| HC-250 | ⏳ waiting on an openHC HC-250 board | ⏳ |
| CA-1, IO Extender | no video output | ✅ whatever iod serves (driver only, nothing on the box) |

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
| `box/` | what goes on the box besides the build: `S97c4nav` |
| `.github/workflows/build.yml` | builds `openhc.c4z` and `openhc-control4.tar.gz`; attaches both to a release |

## What it needs from openHC

An image with the `wpe` feature (the on-screen view, `S95ohc-display`) and
`iomcu`/iod for the IO. Every HC-800 and EA image has both.

## Install

On the box: the box side is a tarball rooted at `/`. The box's busybox `wget`
has no TLS, so push it from a computer:

```bash
curl -L https://github.com/The1TrueJoe/openhc-control4/releases/latest/download/openhc-control4.tar.gz | ssh root@<box> 'gunzip | tar xf - -C / && /etc/init.d/S97c4nav start && /etc/init.d/S97c4nav display'
```

`display` points the on-screen view at the navigator. The web UI's Display
setting does the same: `http://localhost:8090/`.

In Composer Pro:

1. Add `openhc.c4z` (from the same release) and set **Target IP Address** to the box.
2. Bind **HDMI (Audio/Video)** to the TV's input. The Onscreen Navigator binds
   itself, so the room's C4/menu button now opens the UI on that TV.
3. Bind the IO connections your box has. The IO connections cover every board,
   so some won't exist on yours. `curl http://<box>:7070/api/io` lists what the
   box has. If iod has `IOD_TOKEN` set, put it in **IO Token**.

The driver reports on itself in **Link Status** (navigator), **Token Status**
and **IO Status**.

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
cd navigator/backend && CC_x86_64_unknown_linux_musl=musl-gcc cargo build --release --target x86_64-unknown-linux-musl
```

```bash
cd navigator/frontend && npm ci && npm run build
```

## Security

The Director token the driver sends is a credential for the whole project,
sent over plain TCP on your LAN. The box's UI listens on `127.0.0.1` only. Set
**Send Project Token** to `No` to keep the token on the controller, and give the
box its own `C4_HOST`/`C4_TOKEN` in `/etc/openhc/c4nav.conf` instead.
