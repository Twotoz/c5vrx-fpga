#!/usr/bin/env bash
# Triversity FPGA bitstream, open-source Gowin flow (Yosys, nextpnr-himbaechel, Apicula):
#   pip install apycula yowasp-yosys yowasp-nextpnr-himbaechel-gowin
#   fpga/build.sh            -> fpga/build/triversity.fs
#   PLACEMENT=3:0.8 fpga/build.sh  # exactly one seed and placer beta
#   openFPGALoader -b tangnano20k fpga/build/triversity.fs        (add -f to write flash)
set -euo pipefail
if [ -n "${PLACEMENT:-}" ] &&
   [[ "$PLACEMENT" != default && ! "$PLACEMENT" =~ ^[0-9]+(:0\.[0-9]+)?$ ]]; then
  echo "Invalid PLACEMENT: use default, a seed, or seed:beta (for example 3:0.8)" >&2
  exit 2
fi
if [ -n "${PLACEMENT:-}" ] && [ -n "${PNR_OPTS+x}" ]; then
  echo "Choose PLACEMENT or PNR_OPTS" >&2
  exit 2
fi
# -nodsp: only the explicit mul9 / mul18 instances use DSP blocks. Inferred ones
# would oversubscribe the 24 DSP macros (2 MULT18 or 4 MULT9 each) and the placer
# then finds no legal placement.
HERE="$(cd "$(dirname "$0")" && pwd)"; B="${BUILD_DIR:-$HERE/build}"; mkdir -p "$B"; cd "$HERE/rtl"
YOSYS="${YOSYS:-$(command -v yowasp-yosys || command -v yosys)}"
NEXTPNR="${NEXTPNR:-$(command -v yowasp-nextpnr-himbaechel-gowin || command -v nextpnr-himbaechel)}"
SRC="$(find . -name '*.v' | sort | tr '\n' ' ')"
INC="$(find . -type d | sort | sed 's/^/-I/' | tr '\n' ' ')"
DEF="-DTRI_HQDVR"                                  # default: Triversity + colour + full menu + HQ DVR (field buffers in the SDRAM)
[ "${NODVR:-0}" = 1 ] && DEF=""                    # NODVR=1: without the DVR
[ "${HQDVR:-0}" = 1 ] && DEF="-DTRI_HQDVR -DTRI_NO_C -DTRI_LIVEUI -DTRI_HMAPCALC"   # HQDVR=1: Diversity + HQ DVR, live view -> triversity_hqdvr.fs
[ "${TRIDVR:-0}" = 1 ] && DEF="-DTRI_HQDVR -DTRI_TRIDVR -DTRI_LIVEUI -DTRI_SEGFONT -DTRI_HMAPCALC"   # TRIDVR=1: compact 7-segment OSD variant -> triversity_dvr.fs
[ "${HDMI:-0}" = 1 ] && DEF="$DEF -DTRI_HDMI -DTRI_HMAPCALC"   # HDMI=1: the HDMI output instead of the LCD -> *_hdmi.fs
# LCDBUF=1 (with NODVR=1): the LCD on fixed timing from an SDRAM line buffer, ~3 ms behind the camera
if [ "${LCDBUF:-0}" = 1 ]; then
  [ "${NODVR:-0}" = 1 ] && [ "${HDMI:-0}" != 1 ] || { echo "LCDBUF=1 needs NODVR=1 and the LCD" >&2; exit 2; }
  DEF="$DEF -DTRI_LCDBUF"
fi
# HDMI90=1: HDMI at ~90 Hz from a field buffer in the SDRAM (no HQ DVR) -> triversity_hdmi90.fs
[ "${HDMI90:-0}" = 1 ] && { DEF="-DTRI_HDMI -DTRI_HDMI90 -DTRI_HMAPCALC"; HDMI=1; }
# DEBUG=1: the live status on the Tang Nano's USB serial (rtl/io/log_uart.v), for bench and test
# flights; not in the normal builds, which are full (the LCD live build no longer placed with it)
[ "${DEBUG:-0}" = 1 ] && [ "${HDMI90:-0}" != 1 ] && DEF="$DEF -DTRI_DEBUG"
# the start-up screen shows the build's git commit
VER="$(git -C "$HERE" rev-parse --short=7 HEAD 2>/dev/null || echo 0000000)"; DEF="$DEF -DTRI_VERSION=28'h$VER"
CST="$HERE/boards/tang_nano_20k.cst"; [ "${HDMI:-0}" = 1 ] && CST="$HERE/boards/tang_nano_20k_hdmi.cst"
# At ~85 % LUT not every placement routes (tools/fit.py): try placements (seed:placer density) in turn
# until one does. PNR_OPTS set: only that one.
TRIES="${TRIES:-default 3:0.8 1:0.8 1:0.7 5:0.8 6:0.8 7:0.8 8:0.8 2:0.7 3:0.7}"
[ "${HDMI:-0}" = 1 ] && TRIES="${TRIES_HDMI:-3:0.8 1:0.8 1:0.7 5:0.8 6:0.8 7:0.8 8:0.8 2:0.7 3:0.7 4:0.7}"
[ -n "${PLACEMENT:-}" ] && TRIES="$PLACEMENT"
[ -n "${PNR_OPTS+x}" ] && TRIES="opts"
OUT="triversity"; [ "${HQDVR:-0}" = 1 ] && OUT="triversity_hqdvr"; [ "${TRIDVR:-0}" = 1 ] && OUT="triversity_dvr"; [ "${HDMI:-0}" = 1 ] && OUT="${OUT}_hdmi"; [ "${HDMI90:-0}" = 1 ] && OUT="triversity_hdmi90"
"$YOSYS" -q -l "$B/yosys.log" -p "read_verilog $DEF $INC $SRC; synth_gowin -family gw2a ${SYNTH_OPTS--nodsp} -top tri_top -json $B/triversity.json"
ok=0
run_pnr=("$NEXTPNR")
if [ -n "${PNR_TIMEOUT:-}" ]; then run_pnr=(timeout --kill-after=15s "$PNR_TIMEOUT" "$NEXTPNR"); fi
for t in $TRIES; do
  case "$t" in
    default) p=();;
    opts) read -ra p <<< "$PNR_OPTS";;
    *:*) p=(--seed "${t%%:*}" --placer-heap-beta "${t##*:}");;
    *) p=(--seed "$t");;
  esac
  echo "place and route: ${t} ${p[*]}"
  if "${run_pnr[@]}" -q -l "$B/nextpnr.log" --json "$B/triversity.json" --write "$B/triversity_pnr.json" \
    --device GW2AR-LV18QN88C8/I7 --vopt family=GW2A-18C "${p[@]}" --vopt cst="$CST" --freq 40 --timing-allow-fail --report "$B/report.json"; then
    ok=1; break
  fi
  grep -m1 ERROR "$B/nextpnr.log" || true
done
[ "$ok" = 1 ] || { echo "no placement routed (tried: $TRIES)"; exit 1; }
gowin_pack -d GW2A-18C -o "$B/$OUT.fs" "$B/triversity_pnr.json"
{
  printf 'commit=%s\nplacement=%s\nnextpnr_args=%s\n' "$(git -C "$HERE" rev-parse HEAD)" "$t" "${p[*]}"
  "$YOSYS" -V
  "$NEXTPNR" --version
} > "$B/placement.txt" 2>&1
grep -E "LUT4|DFF|BSRAM|MULT|Max frequency" "$B/nextpnr.log" | sort -u | head -20 || true
echo "bitstream: $B/$OUT.fs"
