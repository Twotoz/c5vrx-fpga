"""C5VRX by Twotoz and the C5VRX contributors: the Rescue PLL (menu Signal >
Rescue) against the normal discriminator, with the receiver as built
(model/mrc3_model.py, bit-exact with rtl/rx/mrc3_core.v: sim/run_tb3.py).

Signal: four NTSC fields of the colour test scene (model/chroma_model.py)
through the C5 channel model (model/eval3.py: own LO per C5, independent noise,
optional Rayleigh fading at 300 Hz, 250 us AGC), one C5 or three. Measured on
the last two fields (Auto has settled) with research/sim.py's goggle model:
picture lock (0..1) / SINAD dB, and for Auto the share of time the PLL is in use.

    python sim/perf_rescue.py [--jobs=N]
"""
import multiprocessing as mp
import sys
from pathlib import Path

import numpy as np
from scipy import signal as sg

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'model'))
import eval3  # noqa: E402
import mrc3_model as M  # noqa: E402
import chroma_model as C  # noqa: E402

E = eval3.E
MODES = ('Off', 'Auto', 'On')
CONDS = [(cn, 0) for cn in (-4, -2, 0, 3, 6, 9, 14, 20)] + [(cn, 300) for cn in (-2, 0, 3, 6)]


def job(a):
    nb, cn, fd, seed = a
    ire, region = C.source('NTSC', C.test_picture(240), fields=4, seed=seed)
    rng = np.random.default_rng(seed)
    src = sg.lfilter(sg.firwin(81, 6e6, fs=80e6), 1, np.repeat(ire, 2))
    z80 = sg.sosfilt(E.sim.CHAN, np.exp(2j * np.pi * np.cumsum(E.sim.PORCH_HZ + 0.7 * src / 140 * E.sim.DEV_PP) / 80e6))
    z80 /= np.sqrt(np.mean(abs(z80) ** 2))
    ys = [eval3.branch_y(z80, cn, rng, fd) for _ in range(nb)]
    raws = [M.to_raw3(y[0]) for y in ys]
    clean = [M.to_raw3(y[1]) for y in ys]
    k0 = len(ire) // 2
    c = dict(truth=sg.sosfilt(E.sim.GOGGLE, ire)[k0:], region=region[k0:], standard='NTSC')
    out = {}
    ref_off, ref_on = M.run(clean, disc=True), M.run(clean, disc=True, rescue=2)
    for m, name in enumerate(MODES):
        codes, act = M.run(raws, disc=True, rescue=m, return_act=True)
        ref = np.where(act == 1, ref_on, ref_off).astype(np.uint8)    # calibration: the demodulator in use, clean
        r = E.sim.measure(c, codes[k0:], ref[k0:])
        out[name] = (r['picture'], r['sinad'], float(np.mean(act[k0:])))
    lag = [E.sim.calibrate(E.sim.video_out(x[k0:]), c['truth'], c['region'])[0] for x in (ref_off, ref_on)]
    out['lag'] = lag[1] - lag[0]
    return a[:3], out


def main():
    jobs = [(nb, cn, fd, 400 + 11 * s + cn + (50 if fd else 0)) for nb in (1, 3) for cn, fd in CONDS for s in range(2)]
    procs = int(next((a.split('=')[1] for a in sys.argv if a.startswith('--jobs=')), 3))
    with mp.Pool(procs) as p:
        res = p.map(job, jobs)
    for nb in (1, 3):
        print(f'\n{nb} C5' + ('s (Triversity)' if nb == 3 else '') + ': picture lock / SINAD dB per Rescue setting, Auto: share of time on the PLL')
        print(f"{'fade':>4s} {'C/N':>4s}" + ''.join(f'{m:>13s}' for m in MODES) + '   PLL in use')
        for cn, fd in CONDS:
            rs = [r for a, r in res if a == (nb, cn, fd)]
            print(f'{fd:4d} {cn:4d}' + ''.join(f"{np.mean([r[m][0] for r in rs]):.2f}/{np.mean([r[m][1] for r in rs]):5.1f}".rjust(13) for m in MODES)
                  + f"   {np.mean([r['Auto'][2] for r in rs]):6.0%}")
    print('\nPLL output against the discriminator, clean signal: delay', sorted({r['lag'] for _, r in res}), 'samples of 25 ns')


if __name__ == '__main__':
    main()
