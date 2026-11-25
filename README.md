# openhc-control4

Keeps old Control4 controllers useful in a current Control4 system.

Control4 has left a lot of working hardware behind. The HC-250 can't run OS 3
at all. The HC-800 stops at OS 3.3. The EA series is reaching the end of its
support. The hardware still has its relays, contacts, IR, serial ports and
audio outputs, and still works.

This project puts those controllers back into a current Control4 project. They
run [openHC](https://github.com/The1TrueJoe/openHC) instead of Control4's OS,
and one Control4 driver, `openhc.c4z`, gives Director what they have:

- **IO:** relays, contacts, IR outputs and serial ports, as ordinary Control4
  connections.
- **Digital audio:** every Control4 source (TuneIn, My Music, AirPlay through
  ShairBridge, ...) plays on the box's audio outputs, managed by Director like
  a Control4 controller's own, using
  [control4-audio-client](https://github.com/The1TrueJoe/control4-audio-client).
- **On-screen navigator:** a 10-ft UI on the TV, driven by the room's remote and
  showing your project.

Director still runs on a supported Control4 controller. The openHC box joins
that project as a device.

## Boards

| Controller | Control4 OS limit | IO | Digital audio | Navigator on TV |
|---|---|---|---|---|
| HC-250 | can't reach OS 3 | 1 relay, 1 contact, 4 IR + blaster, 2 serial | not yet | not yet |
| HC-800 | OS 3.3 | 4 relays, 4 contacts, 6 IR, 2 serial | Analog 1, Analog 2, coax, HDMI | ✅ HDMI / component |
| EA-1 | support ending | 4 IR + blaster (2 shared with serial) | HDMI | ✅ HDMI |
| EA-3 | support ending | 1 relay, 1 contact, 6 IR + blaster (3 shared with serial) | analog, digital, HDMI | ✅ HDMI |
| CA-1 | | 1 serial (RS-232/485) | | |
| IO Extender (v1) | | 8 relays, 8 contacts, 8 IR, 4 serial | | |

The HC-250, CA-1 and IO Extender get their IO from the driver alone. Nothing is
installed on the box. The HC-250's audio and navigator wait on openHC support
for its display and storage.

## Install

1. Install openHC with the
   [openHC flasher](https://github.com/The1TrueJoe/openHC#the-flasher) and leave
   **Make it a Control4 controller again** ticked. The flasher sets the box up and
   saves `openhc.c4z` to your Downloads.
2. In Composer Pro, add the driver (Driver → Add Driver… → `openhc.c4z`).
3. Add the openHC box from the discovered devices. It fills in its own address.
   On the HC-250, CA-1 and IO Extender, enter the address on the Network tab
   instead.
4. Bind what the box has: HDMI to the TV for the navigator, and the relays,
   contacts, IR and serial ports like a controller's own.
5. The driver adds the box's audio as a second device, **"<name> Audio"**, in
   the same room, using Control4's own driver for that model (EA-1, EA-3, EA-5,
   HC-800; the Triad One on the HC-250, or on a controller whose OS no longer
   has the model's driver), and points it at the box. If the room has no audio
   yet, its first output becomes the room's Audio End-Point. Bind its outputs
   like any controller's: AUDIO OUT, DIGITAL AUDIO OUT, HDMI AUDIO OUT. Composer
   shows that device as offline (it looks for Control4's own services on the
   box); the audio plays regardless.

The driver lists every board's connections, so leave the ones your box doesn't
have unbound. Its Documentation tab shows the box's own openHC dashboard.

On a box already running openHC: `ohc-flash control4 <ip>`.

There are no releases yet, and the flasher downloads from the latest one. Until
there is one, take `openhc.c4z` and the box package from a CI run's artifacts.

The driver hands the box a token for your Control4 project, over plain TCP on
your LAN, so its navigator can show the project. Set **Send Project Token** to
No to keep the token on the controller.

## Not yet confirmed

- Digital audio on the EA-1, EA-5, HC-800 and HC-250. Director only streams to a
  device whose driver can report the audio client's address, and only
  Control4's compiled drivers can, so `child.lua` adds one: Control4's driver
  for the model, pointed at the box through Director's own identify call. On an
  EA-3, every output played radio and ShairBridge AirPlay with nothing per
  source. The other models' outputs follow the port numbering of their
  Control4 drivers (see `c4zones`), untested on hardware.
- Which commands Director sends for IR and serial, and for a controller's own
  output volume. The driver's **Last IO Command** property shows what arrives.

## Build

CI builds both parts on every push: `openhc.c4z`, with Control4's driver
packager, and `openhc-control4.tar.gz` for the box. Download them from the
latest run's artifacts. By hand:

```bash
git submodule update --init --recursive
driver/package.sh && (cd driver && lua test.lua)
```

| Path | What |
|---|---|
| `driver/` | the Control4 driver: the navigator (from control4-navigator-sink-lib), `io.lua`, `child.lua` (the audio device), `zigbee.lua` |
| `navigator/` | submodule: control4-fake-navigator, the on-screen UI and its backend |
| `audio-client/` | submodule: control4-audio-client |
| `tools/` | box helpers: `c4sddp` (discovery, with the [sddp](https://github.com/The1TrueJoe/sddp) crate) and `c4zones` (audio zones from openHC's outputs) |
| `box/init` | starts it all on the box, from `/data/extensions/control4` |
