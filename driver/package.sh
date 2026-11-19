#!/usr/bin/env bash
# Build one .c4z per openHC model (openhc-ea3.c4z, openhc-hc800.c4z, …) from the
# single table in gen.py: per-model static AV + IO and its own SDDP type. The
# navigator half is control4-navigator-sink-lib's driver.lua as-is, with the
# model's geometry prelude + io.lua + audio.lua appended.
set -euo pipefail
cd "$(dirname "$0")"
for f in ../navigator/lib/driver/driver.lua control4-lua-mqtt/mqtt.lua; do
  [ -f "$f" ] || { echo "submodule missing ($f): git submodule update --init --recursive" >&2; exit 1; }
done
python3 gen.py
