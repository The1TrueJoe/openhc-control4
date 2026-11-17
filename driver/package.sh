#!/usr/bin/env bash
# Build the DriverWorks .c4z (a plain zip): the navigator half is
# control4-navigator-sink-lib's driver.lua as-is, with io.lua appended.
set -euo pipefail
cd "$(dirname "$0")"
nav=../navigator/lib/driver/driver.lua
[ -f "$nav" ] || { echo "navigator submodule missing: git submodule update --init --recursive" >&2; exit 1; }
rm -rf build && mkdir -p build/www
cat "$nav" io.lua > build/driver.lua
cp driver.xml build/ && cp -R www/. build/www/
out="$(pwd)/openhc.c4z"
rm -f "$out"
(cd build && zip -r -X "$out" driver.xml driver.lua www >/dev/null)
echo "built $out"; unzip -l "$out"
