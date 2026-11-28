# Contributing

## Build

CI builds both parts on every push: one driver per model,
`openhc-<model>.c4z`, with Control4's driver packager, and
`openhc-control4.tar.gz` for the box. Every push to main also replaces the
assets of the rolling [`dev`](https://github.com/The1TrueJoe/openhc-control4/releases/tag/dev) pre-release. The flasher
downloads from the latest published release.

By hand:

```bash
git submodule update --init --recursive
driver/package.sh && (cd driver && lua test.lua)
```

The box side is x86_64 musl (HC-800 and the EAs). See the `box` job in
`.github/workflows/build.yml` for the exact steps.

## Layout

| Path | What |
|---|---|
| `driver/` | the Control4 drivers: `gen.py` writes one per model from its table. The navigator (from control4-navigator-sink-lib), `io.lua`, `child.lua` (the audio device), `zigbee.lua` |
| `navigator/` | submodule: control4-fake-navigator, the on-screen UI and its backend |
| `audio-client/` | submodule: control4-audio-client |
| `zigbee/` | submodule: control4-zigbee, whose `c4zapd` runs the radio as a Control4 Zigbee access point |
| `tools/` | box helpers: `c4sddp` (discovery, with the [sddp](https://github.com/The1TrueJoe/sddp) crate) and `c4zones` (audio zones from openHC's outputs) |
| `box/init` | starts it all on the box, from `/data/extensions/control4` |

## On the box

The tarball unpacks to `/data/extensions/control4`. openHC's
`S96ohc-extensions` runs `init start` at boot.

`box/init` commands:

- `start`, `stop`, `restart`: the navigator, the SDDP announcer, the audio
  client, and `c4zapd` when Control4 Zigbee is on.
- `display`: point openHC's on-screen view at the navigator.
- `zigbee control4`: sets `OHC_ZIGBEE_STACK=none` in `/data/ohc/zigbee.env`,
  stops openHC's Zigbee services, puts Control4's EmberZNet 4.7.2 back on the
  EM357 (`zigbee --restore-stock`), writes `control4` to c4zapd's mode file
  (`OHC_C4ZIGBEE_STATE`, default `/data/ohc/c4zigbee.mode`) and starts c4zapd.
- `zigbee openhc`: stops c4zapd, removes the `none` line, writes `standard`,
  and starts openHC's Zigbee services again (S91 flashes openHC's firmware back).

Logs go to syslog (`logread`), tagged `c4nav`, `c4sddp`, `c4audio`, `c4zapd`.

## Digital audio

Director only streams to a device whose driver can report the audio client's
address, and only Control4's compiled drivers can. So `child.lua` adds one:
Control4's driver for the model, pointed at the box through Director's own
identify call. `c4zones` maps each model's outputs to the port numbering of
its Control4 driver.

## Control4 Zigbee

Director only registers a Zigbee access point for a device whose hardware
identity announces radio capability. The box does not announce that yet, so
Director never dials `c4zapd` on :7910. See control4-zigbee's README.
