#!/usr/bin/env bash
# Triversity C5 firmware host tests: the FPGA link protocol plus the C5VRX
# receiver tests (C5VRX by Twotoz and the C5VRX contributors, test/) for the
# modules this firmware keeps. Run from c5/test.
set -euo pipefail
CC="cc -O2 -std=c11 -Wall -Wextra -Werror -I../main"
M=../main
run() { "$@" | tail -1; }
$CC test_fpga_link.c -o /tmp/test_fpga_link && /tmp/test_fpga_link
for t in test_quiet test_profile test_diag test_afc test_afc_measure test_control_window test_cn_observation \
         test_calibration_noise test_sphase test_dco_slots test_dc_servo test_flightlog test_rx_state test_dc_trim \
         test_strong_lane test_afc_evidence; do
    $CC "$t.c" -lm -o "/tmp/$t"
    run "/tmp/$t"
done
$CC test_agc_table.c $M/arc_phy.c -o /tmp/test_agc_table && run /tmp/test_agc_table
$CC -DEXPECT_FADE_HOLD test_gain_fade.c $M/gain.c $M/arc_phy.c -lm -o /tmp/test_gain_fade && run /tmp/test_gain_fade
for t in test_gain_preset test_gain_v7 test_rx_level test_gain_measured; do
    $CC "$t.c" $M/gain.c $M/arc_phy.c -lm -o "/tmp/$t"
    run "/tmp/$t"
done
$CC test_keel_track.c $M/gain.c $M/arc_phy.c -lm -o /tmp/test_keel_track && /tmp/test_keel_track | grep -v "^S," | tail -1
$CC test_gain_track.c $M/gain.c $M/arc_phy.c -lm -o /tmp/test_gain_track && /tmp/test_gain_track | grep -v "^R," | tail -1
$CC test_agc_options.c $M/agc.c -lm -o /tmp/test_agc_options && run /tmp/test_agc_options
$CC test_agc_ultra.c $M/agc.c -lm -o /tmp/test_agc_ultra && run /tmp/test_agc_ultra
$CC test_agc_strong.c $M/agc.c $M/gain.c $M/arc_phy.c -lm -o /tmp/test_agc_strong && run /tmp/test_agc_strong
$CC test_fold_radius.c $M/agc.c -lm -o /tmp/test_fold_radius && run /tmp/test_fold_radius
echo "ALL HOST TESTS PASSED"
