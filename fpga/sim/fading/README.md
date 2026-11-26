# Fading with one C5

Studies of Rayleigh fading with a single C5, done in simulation. They use the
`eval3` channel model and `mrc3_model`, which is bit-exact with the RTL, and
score the picture with the goggle model (`eval_model.sim.measure`). Each result
is given as picture lock / SINAD in dB. The scripts need C5VRX `research/` on the
path (`C5VRX_RESEARCH`), like the other model tests:

    python fpga/sim/fading/fade_study9.py fpga 2      # 2 worker processes (memory)

## Findings

| study | what | result |
|---|---|---|
| `fade_study.py` | hold the last code during deep fades (amplitude gate) | no gain |
| `fade_agc.py` | C5 AGC speed (250 / 50 / 10 µs) | no gain (`results/fade_agc.txt`) |
| `fade_study2.py`, `fade_study6.py` | Rescue PLL always on, coasting in deep fades; fade-selected PLL by amplitude | gate never triggers: the 250 µs AGC keeps the amplitude up through fades (`results/fade6.txt`) |
| `fade_study3.py`, `fade_study4.py` | dropout compensation | no gain |
| `fade_study7.py` | Auto Rescue thresholds (100 … 6 clicks a 13 ms window) | ≤ 0.6 dB (`results/fade7.txt`) |
| `fade_conceal.py` | temporal concealment: a line with many clicks taken from the previous frame | static scene +0.3 … 1.3 dB, an upper bound (`results/conceal.txt`); the moving case there also moves the syncs, so its lock numbers are not valid |
| `fade_study8.py`, `fade_study9.py` | **look-ahead selection**: both outputs delayed, PLL where the discriminator has ≥ K clicks within ± W samples | **+0.5 … 1.7 dB under fading at 14 … 20 dB C/N, static unchanged** (`results/fade8.txt`) |

Under fading, the Rescue PLL is better than the discriminator through the fades,
but always-on it costs ~3 dB without fading (9.5 → 6.2 dB at 20 dB). Auto decides
over a 13 ms window, which is far longer than a fade burst. Delaying the codes by
about a line (one BSRAM) lets each sample choose with the clicks both before and
after it. With W = 1024 and K = 2 this comes close to an oracle that picks the
better output per 64 samples:

| fd / C/N | Auto | look-ahead w1024k2 | oracle64 |
|---|---|---|---|
| static / 20 | 9.5 | 9.5 | 9.0 |
| 30 Hz / 14 | 3.4 | 5.3 | 5.4 |
| 100 Hz / 14 | 4.6 | 5.8 | 5.7 |
| 100 Hz / 20 | 5.4 | 6.8 | 6.5 |
| 300 Hz / 20 | 5.3 | 7.0 | 6.8 |

## What is built (`mrc3_core.v`, Rescue Auto)

Look-ahead with W = 1024 pairs and K = 2. On top of that, a steady-clicks
switch: when 48 of the 64 sub-windows of 4096 pairs (13 ms) held a click, the
PLL runs all the time. On a very weak signal the PLL is better even between
the clicks, and without the switch that case lost up to 1 dB
(`fade_study10.py`, `fade_study11.py`, `click_density.py`). `mrc3_model.rescue50`
matches the RTL bit for bit (`run_tb3.py`). `results/fade10_final.txt`
compares old Auto with the new one (SINAD dB):

| | old Auto | new Auto |
|---|---|---|
| 1 C5, static 10 dB | 4.6 | 5.0 |
| 1 C5, 30 Hz / 14 dB | 4.8 | 6.3 |
| 1 C5, 100 Hz / 20 dB | 5.7 | 7.2 |
| 1 C5, 300 Hz / 20 dB | 5.0 | 6.8 |
| 3 C5s, 30 Hz / 8 dB | 3.3 | 4.7 |
| 3 C5s, 300 Hz / 8 dB | 5.7 | 6.4 |
| 3 C5s, static 4 dB | 5.0 | 5.0 |
| worst case anywhere | | -0.1 |

The rest of the loss against static (~3 dB) comes with having a single antenna;
antenna diversity (more C5s) is what removes it.
