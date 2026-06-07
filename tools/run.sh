#!/usr/bin/env bash
# Launch the Phase 0 image in MAME (Sprinter). Boots DSS from the system HDD;
# our floppy (distr/gopher.img) is mounted as drive A:. No ESP/network is
# needed for Phase 0 - the skeleton only uses DSS text + keyboard.
#
# In DSS, run:   A:  then  CD GOPHER  then  GOPHER   (press Esc to exit)
set -euo pipefail

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE_MAME_DIR="${RELEASE_MAME_DIR:-/Users/dmitry/dev/zx/sprinter/mame_images/mame_release_v306_25.05.2025}"
MAME_BIN="${MAME_BIN:-$RELEASE_MAME_DIR/mame}"
IMG_DIR="${IMG_DIR:-$RELEASE_MAME_DIR/IMG}"
FLOP="${1:-$PROJ/distr/gopher.img}"

cd "$RELEASE_MAME_DIR"
exec "$MAME_BIN" sprinter \
  -skip_gameinfo -window -nofilter \
  -beta:wd179x:0 525qd -beta:wd179x:1 35hd \
  -flop1 "$FLOP" \
  -hard1 "$IMG_DIR/sp_hdd_sys.chd" \
  -bios v3.06 \
  "${@:2}"
