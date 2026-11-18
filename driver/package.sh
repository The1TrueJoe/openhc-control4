#!/usr/bin/env bash
# Assemble the driver in build/ and zip it into a .c4z: the navigator half is
# control4-navigator-sink-lib's driver.lua as-is, with io.lua and audio.lua
# appended. CI then builds the released .c4z from build/ with Control4's driver
# packager (openhc.c4zproj), which also stamps the version and modified date.
set -euo pipefail
cd "$(dirname "$0")"
nav=../navigator/lib/driver/driver.lua
mqtt=../control4-lua-mqtt/mqtt.lua
for f in "$nav" "$mqtt"; do
  [ -f "$f" ] || { echo "submodule missing ($f): git submodule update --init --recursive" >&2; exit 1; }
done
rm -rf build && mkdir -p build/www
# control4-lua-mqtt (global C4MQTT) must precede io.lua, which uses it.
cat "$nav" "$mqtt" io.lua audio.lua > build/driver.lua
cp driver.xml openhc.c4zproj build/ && cp -R www/. build/www/
out="$(pwd)/openhc.c4z"
rm -f "$out"
(cd build && zip -r -X "$out" driver.xml driver.lua www >/dev/null)
echo "built $out"; unzip -l "$out"
