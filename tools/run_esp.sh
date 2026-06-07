#!/usr/bin/env bash
# Launch the gopher browser in MAME with the Sprinter-WiFi (ESP) card attached.
# Mirrors the network kit's run_sprinter_esp.sh, but mounts our floppy as A:
# (flop1) and the network kit floppy as B: (flop2, for NETUP/NETCFG/NET.CFG).
#
# Networking requires an ESP bridge on the bitb socket (the user's usual
# Sprinter-WiFi MAME setup) and NETUP to have joined Wi-Fi:
#   1. In DSS:  B:           (switch to the network kit floppy)
#   2.          NETCFG /W    (write NET.CFG with your SSID/PASS, once)
#   3.          NETUP        (join Wi-Fi; publishes NET/NET_BAUD env)
#   4.          A:           (our floppy)
#   5.          CD GOPHER
#   6.          GOPHER       (Enter fetches gopher.floodgap.com:70)
set -euo pipefail

PROJ="$(cd "$(dirname "$0")/.." && pwd)"
RELEASE_MAME_DIR="${RELEASE_MAME_DIR:-/Users/dmitry/dev/zx/sprinter/mame_images/mame_release_v306_25.05.2025}"
MAME_BIN="${MAME_BIN:-$RELEASE_MAME_DIR/mame}"
IMG_DIR="${IMG_DIR:-$RELEASE_MAME_DIR/IMG}"
NETKIT_IMG="${NETKIT_IMG:-/Users/dmitry/dev/zx/sprinter/sprinter_wifi/network/distr/sprinter-net.img}"
FLOP="${1:-$PROJ/distr/gopher.img}"
SPRINTER_ESP_HOST="${SPRINTER_ESP_HOST:-127.0.0.1}"
SPRINTER_ESP_PORT="${SPRINTER_ESP_PORT:-25232}"

cd "$RELEASE_MAME_DIR"
exec "$MAME_BIN" sprinter \
  -skip_gameinfo -window -nofilter \
  -beta:wd179x:0 525qd -beta:wd179x:1 35hd \
  -flop1 "$FLOP" \
  -flop2 "$NETKIT_IMG" \
  -isa1 sprinter_esp \
  -isa1:sprinter_esp:esp null_modem \
  -bitb "socket.$SPRINTER_ESP_HOST:$SPRINTER_ESP_PORT" \
  -hard1 "$IMG_DIR/sp_hdd_sys.chd" \
  -bios v3.06 \
  "${@:2}"
