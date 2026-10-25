#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
#
# Assemble the deployable archive: the module, the scripts that run on the head unit, and
# the installer. This is what a release ships and what install.sh expects to be unpacked
# next to it. Run build/build-driver.sh first.
#
#     build/package.sh [version]
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
OUT=${OUT:-$REPO/out}
VERSION=${1:-${VERSION:-$(date +%Y.%m.%d)}}
NAME=cmu150-rtl8811au-$VERSION
STAGE=$OUT/$NAME

[ -f "$OUT/rtl8812au.ko" ] || { echo "!! $OUT/rtl8812au.ko missing -- run build/build-driver.sh first"; exit 1; }

mkdir -p "$STAGE"
cp -f "$OUT/rtl8812au.ko" "$STAGE/"
for f in install.sh load-wlan1.sh dongle.conf sm.conf.snippet; do
    cp -f "$REPO/install/$f" "$STAGE/"
done
cp -f "$REPO/docs/INSTALL.md" "$STAGE/"
cp -f "$REPO/LICENSE" "$STAGE/"
chmod 755 "$STAGE"/*.sh
chmod 644 "$STAGE"/*.ko "$STAGE"/*.conf "$STAGE"/*.snippet "$STAGE"/*.md "$STAGE/LICENSE"

( cd "$OUT" && tar czf "$NAME.tar.gz" "$NAME" )
( cd "$OUT" && sha256sum "$NAME.tar.gz" > "$NAME.tar.gz.sha256" )

echo "packaged $OUT/$NAME.tar.gz"
echo "  $(cat "$OUT/$NAME.tar.gz.sha256")"
tar tzf "$OUT/$NAME.tar.gz" | sed 's/^/  /'
