# openhc-control4

Keeps old Control4 controllers useful in a current Control4 system.

Control4 has left a lot of working hardware behind. The HC-250 can't run OS 3
at all. The HC-800 stops at OS 3.3. The EA series is reaching the end of its
support. The hardware still has its relays, contacts, IR, serial ports and
audio outputs, and still works.

This project puts those controllers back into a current Control4 project. They
run [openHC](https://github.com/The1TrueJoe/openHC) instead of Control4's OS,
and a Control4 driver for each model, `openhc-<model>.c4z`, gives Director what
they have:

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
   [openHC flasher](https://github.com/The1TrueJoe/openHC#the-flasher). On the
   **What to install** screen, pick **Control4 controller**. The flasher
   downloads everything itself, sets up the box, and saves your model's driver,
   `openhc-<model>.c4z`, to your Downloads.
2. In Composer Pro, add the driver (Driver → Add Driver… → `openhc-<model>.c4z`).
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
   box). The audio plays anyway.

The driver's Documentation tab shows the box's own openHC dashboard.

On a box already running openHC: `ohc-flash control4 <ip>`.

The driver hands the box a token for your Control4 project, over plain TCP on
your LAN, so its navigator can show the project. Set **Send Project Token** to
No to keep the token on the controller.

To build it yourself or help out, see [CONTRIBUTING.md](CONTRIBUTING.md).
