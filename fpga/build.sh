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
# HDMI: the placement that routes (tools/fit.py: seed 1, placer density 0.8; at 85 % LUT not every seed does)
[ "${HDMI:-0}" = 1 ] && PNR_OPTS="${PNR_OPTS---seed 1 --placer-heap-beta 0.8}"
OUT="triversity"; [ "${HQDVR:-0}" = 1 ] && OUT="triversity_hqdvr"; [ "${TRIDVR:-0}" = 1 ] && OUT="triversity_dvr"; [ "${HDMI:-0}" = 1 ] && OUT="${OUT}_hdmi"
"$YOSYS" -q -l "$B/yosys.log" -p "read_verilog $DEF $INC $SRC; synth_gowin -family gw2a ${SYNTH_OPTS--nodsp} -top tri_top -json $B/triversity.json"
"$NEXTPNR" -q -l "$B/nextpnr.log" --json "$B/triversity.json" --write "$B/triversity_pnr.json" \
  --device GW2AR-LV18QN88C8/I7 --vopt family=GW2A-18C ${PNR_OPTS-} --vopt cst="$CST" --freq 40 --timing-allow-fail --report "$B/report.json"
gowin_pack -d GW2A-18C -o "$B/$OUT.fs" "$B/triversity_pnr.json"
grep -E "LUT4|DFF|BSRAM|MULT|Max frequency" "$B/nextpnr.log" | sort -u | head -20 || true
echo "bitstream: $B/$OUT.fs"
