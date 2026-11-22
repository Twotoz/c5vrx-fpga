#!/usr/bin/env bash
# Triversity FPGA bitstream, open-source Gowin flow (Yosys, nextpnr-himbaechel, Apicula):
#   pip install apycula yowasp-yosys yowasp-nextpnr-himbaechel-gowin
#   fpga/build.sh            -> fpga/build/triversity.fs
#   openFPGALoader -b tangnano20k fpga/build/triversity.fs        (add -f to write flash)
set -euo pipefail
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
CST="$HERE/boards/tang_nano_20k.cst"; [ "${HDMI:-0}" = 1 ] && CST="$HERE/boards/tang_nano_20k_hdmi.cst"
# At ~85 % LUT not every placement routes (tools/fit.py): try placements (seed:placer density) in turn
# until one does. PNR_OPTS set: only that one.
TRIES="${TRIES:-default 3:0.8 1:0.8 1:0.7 5:0.8 6:0.8 7:0.8 8:0.8 2:0.7 3:0.7}"
[ "${HDMI:-0}" = 1 ] && TRIES="${TRIES_HDMI:-3:0.8 1:0.8 1:0.7 5:0.8 6:0.8 7:0.8 8:0.8 2:0.7 3:0.7 4:0.7}"
[ -n "${PNR_OPTS+x}" ] && TRIES="opts"
OUT="triversity"; [ "${HQDVR:-0}" = 1 ] && OUT="triversity_hqdvr"; [ "${TRIDVR:-0}" = 1 ] && OUT="triversity_dvr"; [ "${HDMI:-0}" = 1 ] && OUT="${OUT}_hdmi"
"$YOSYS" -q -l "$B/yosys.log" -p "read_verilog $DEF $INC $SRC; synth_gowin -family gw2a ${SYNTH_OPTS--nodsp} -top tri_top -json $B/triversity.json"
ok=0
for t in $TRIES; do
  case "$t" in default) P="";; opts) P="$PNR_OPTS";; *) P="--seed ${t%%:*} --placer-heap-beta ${t##*:}";; esac
  echo "place and route: ${P:-default placement}"
  if "$NEXTPNR" -q -l "$B/nextpnr.log" --json "$B/triversity.json" --write "$B/triversity_pnr.json" \
    --device GW2AR-LV18QN88C8/I7 --vopt family=GW2A-18C $P --vopt cst="$CST" --freq 40 --timing-allow-fail --report "$B/report.json"; then
    ok=1; break
  fi
  grep -m1 ERROR "$B/nextpnr.log" || true
done
[ "$ok" = 1 ] || { echo "no placement routed (tried: $TRIES)"; exit 1; }
gowin_pack -d GW2A-18C -o "$B/$OUT.fs" "$B/triversity_pnr.json"
grep -E "LUT4|DFF|BSRAM|MULT|Max frequency" "$B/nextpnr.log" | sort -u | head -20 || true
echo "bitstream: $B/$OUT.fs"
