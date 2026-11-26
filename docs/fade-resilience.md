# Fade recovery and experimental gain/demodulator modes

This work builds on PR #7 and addresses issues #6, #8 and #9. Signal → Demod /
Rescue defaults to Auto. Select **D3*** for a fixed-point, causal A/B candidate.
The full menu also has **Signal → Native AGC (EXP)**. The compact live UI builds
use Rescue Auto. Native gain ownership is available from the C5 USB console
with `N` when a full FPGA menu is unavailable.

## A-reference fade (#6)

The 40 MHz clock from A remains the sample clock. A healthy B or C can be
demodulated directly if A's IQ loses its carrier and the normal A-referenced
phase estimates are unreliable. Both timing aligners stop steering their FIFO
pointers during that interval, keep reading at 40 MS/s and recenter a FIFO if
it is near an edge. They rebuild the correlation window when A recovers.
Short A markers can still use aligned B/C. If the selected backup sends a
marker too, an eligible alternate branch can take over. In backup mode only
one branch contributes, and switching applies a phase offset from the
previous sample and step to reduce the discontinuity.

The additional evidence uses the envelope moment ratio already computed by
the weight engine, `q = 256 × E[|IQ|⁴] / E[|IQ|²]²`. A constant envelope
gives 256 and ideal complex Gaussian noise gives 512. Quantization and
clipping move these values. The hysteresis band is 360–400 and a steady
classification requires multiple updates, one per 128 samples (3.2 µs).
The energy floor rejects very small, apparently constant clouds. A strongly
clipped noise cloud or another constant-envelope carrier can mislead this
heuristic. A full clock outage on A stalls the design.

## Native AGC experiment (#8)

- The menu broadcasts the request to all C5s over the existing UART. A C5
  persists the owner choice and restarts Wi-Fi and the MCU. PHY boot in
  native mode follows the legacy C5VRX sequence: leave the vendor RF AGC
  configuration alone, clear forced gain and release FFT scale. Direct Gain is
  the fresh-install default. Toggling back restores the saved Direct policy.
- `?` beside the menu value means some reported receivers have not yet
  confirmed the requested owner. Receivers shows `NAT` on an applied native
  branch. USB `STATUS` includes the applied owner. Both directions use their
  existing wires. Switching reboots the participating modules and interrupts
  the picture. A continuously broadcasting FPGA setting takes precedence
  over a console change.
- In native mode, vendor DC calibration and the selected RX filters still
  apply. Gain-dependent DC trim/calibration, the firmware gain observer and
  C/N-calibrated AFC writes are suspended. The AFC can still observe stationary
  IQ and report sync/frequency evidence. A periodic status value cannot
  describe the native gain for each 25 ns sample.
- A 2–3 µs gain walk occupies 80–120 IQ samples. At intervals of 25–50 µs it can
  contaminate roughly 4–12% of a branch's stream. If walks were independent,
  that would imply 0.16–1.44% overlap for two branches and roughly
  0.006–0.173% for three. Synchronized walks could eliminate that benefit.
  No per-sample acquisition flag
  currently goes over the 6 IQ pins. Replacing the finest Q bit with a witness
  would change 3I+3Q into 3I+2Q and requires board-validated flag selection,
  lead/lag, and quantization tests. Legacy measurements give no universally
  verified choice of DIAG bit. This experiment can degrade video even with
  multiple receivers.

## Causal D3 experiment (#9)

D3 uses one 40 MS/s phase/frequency state. D32 phase innovation supplies click
evidence. Four saturating 512-pair buckets cover 1,536–2,047 prior pairs
(~38–51 µs), with the steady-click estimate from PR #7. The confidence changes
with ~1.6 µs attack and ~6.4 µs release time constants. As confidence drops,
the same estimator reduces direct phase correction and increases the
integrator contribution. It also restores intermediate 25 ns frequency
estimates during low confidence. With no valid selected IQ it coasts for at
most eight samples (200 ns), then outputs neutral until it can reseed. A
complete RF blackout without a validity witness may still produce noise.

In D3, the fast confidence level controls display luma smoothing with an
edge bypass at modest noise levels. Chroma uses a separate measure of burst
amplitude and phase consistency and fades colour over four bad lines. The
H/V sync logic still consumes demodulated composite video ahead of these
display filters. The causal path skips PR #7's 1,024-pair, 51.2 µs look-ahead.
Switching modes changes video timing by about one line. This is demodulator
buffer delay, separate from end-to-end display/DVR latency.

## Reproduce

Run the C5 host tests from `c5/test`. FPGA results can be rerun with:

```sh
python fpga/sim/run_d3_tb.py
python fpga/sim/run_fade_failover_tb.py
C5VRX_RESEARCH=/path/to/C5VRX/research python fpga/sim/fading/compare_d3.py
```

The 32 matched one-C5 trials (NTSC/PAL, static 30/6 dB and 30/100/300 Hz fading
at 14/20 dB) gave mean D3 minus Auto SINAD of +0.008 dB (−0.065 to +0.258 dB).
Over the 24 fading cases the mean was +0.016 dB. The largest sync-lock score
change was 0.17 percentage points. These scores compare the fixed-point
demodulator using the same synthetic IQ and goggle model. Display filtering,
moving scenes, corresponding PHY gain behavior and scope-measured latency
are outside these scores.

For board A/B, use the same VTX, attenuation waveform, antennas, frequency
and cables. Record one C5 with Rescue Off/Auto/On/D3, Keep lock Off/On, and
Direct/Native gain. Then fade A only while B/C stay healthy, swap the faded
branch and repeat with near-simultaneous outages. Record IQ, branch selection,
gain transitions, sync-lock fraction, luma SINAD and recovery time. Perform
the same board captures before choosing a new default or claiming RF
sensitivity/range gains.
