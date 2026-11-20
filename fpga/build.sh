#!/usr/bin/env bash
# Triversity FPGA bitstream, open-source Gowin flow (Yosys, nextpnr-himbaechel, Apicula):
#   pip install apycula yowasp-yosys yowasp-nextpnr-himbaechel-gowin
#   fpga/build.sh            -> fpga/build/triversity.fs
#   openFPGALoader -b tangnano20k fpga/build/triversity.fs        (add -f to write flash)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; B="$HERE/build"; mkdir -p "$B"; cd "$HERE/rtl"
YOSYS="${YOSYS:-$(command -v yowasp-yosys || command -v yosys)}"
NEXTPNR="${NEXTPNR:-$(command -v yowasp-nextpnr-himbaechel-gowin || command -v nextpnr-himbaechel)}"
SRC="tri_top.v align_b.v marker_rx.v mrc3_core.v cordic_angle.v cordic_iter.v mul_dsp.v vid_sync.v linebuf.v lcd_out.v menu.v link_tx.v"
"$YOSYS" -q -l "$B/yosys.log" -p "read_verilog -I. $SRC; synth_gowin -family gw2a ${SYNTH_OPTS:--nodsp} -top tri_top -json $B/triversity.json"
"$NEXTPNR" -q -l "$B/nextpnr.log" --json "$B/triversity.json" --write "$B/triversity_pnr.json" \
  --device GW2AR-LV18QN88C8/I7 --vopt family=GW2A-18C --vopt cst="$HERE/tang_nano_20k.cst" --freq 40 --timing-allow-fail --report "$B/report.json"
gowin_pack -d GW2A-18C -o "$B/triversity.fs" "$B/triversity_pnr.json"
grep -E "LUT4|DFF|BSRAM|MULT|Max frequency" "$B/nextpnr.log" | sort -u | head -20
echo "bitstream: $B/triversity.fs"
