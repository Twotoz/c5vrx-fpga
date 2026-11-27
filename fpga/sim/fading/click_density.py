"""Clicks a window (2^14 / 2^16 pairs) of the discriminator: very weak static signals
against fading at a good C/N, to separate where the PLL should run all the time.
usage: python click_density.py <triversity/fpga> [jobs]"""
import multiprocessing as mp, sys
from pathlib import Path
import numpy as np
from scipy import signal as sg
FPGA = Path(sys.argv[1]); JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 2
sys.path.insert(0, str(FPGA / 'model')); sys.path.insert(0, str(FPGA / 'sim'))
import eval3, mrc3_model as M, chroma_model as C
E = eval3.E
CASES = [(1, 6, 0), (1, 10, 0), (1, 14, 30), (1, 20, 100), (1, 20, 300), (1, 14, 100), (1, 10, 100),
         (3, 4, 0), (3, 4, 100), (3, 4, 300), (3, 8, 30), (3, 8, 300), (3, 14, 100)]


def job(a):
    nb, cn, fd = a
    ire, region = C.source('NTSC', C.test_picture(240), fields=4, seed=5)
    src = sg.lfilter(sg.firwin(81, 6e6, fs=80e6), 1, np.repeat(ire, 2))
    S = E.sim
    z80 = sg.sosfilt(S.CHAN, np.exp(2j * np.pi * np.cumsum(S.PORCH_HZ + 0.7 * src / 140 * S.DEV_PP) / 80e6))
    z80 /= np.sqrt(np.mean(abs(z80) ** 2))
    rng = np.random.default_rng(77 + cn + fd + nb)
    raws = [M.to_raw3(eval3.branch_y(z80, cn, rng, fd)[0]) for _ in range(nb)]
    _, phis = M.run(raws, disc=True, return_phi=True)
    t = ((phis[0::2].astype(np.int64) + 32768) >> 6) & 1023
    s = t[0]; cl = np.zeros(len(t), np.int64)
    for j in range(len(t)):
        d = ((t[j] - s + 512) & 1023) - 512
        c = not (M.DISC_WL <= d <= M.DISC_WH); cl[j] = c
        s = (s + (d if not c else (d * 179) >> 8)) & 1023
    out = {}
    for sh in (12, 14):
        w = 1 << sh; n = len(cl) // w
        cw = cl[:n * w].reshape(n, w).sum(1)
        out[sh] = (np.percentile(cw, 10), np.median(cw), np.percentile(cw, 90))
    return a, out


if __name__ == '__main__':
    with mp.Pool(JOBS) as p:
        for (nb, cn, fd), o in p.map(job, CASES):
            print(f'{nb} C5 {cn:3d} dB fd {fd:3d}: ' + '  '.join(f'2^{sh}: p10 {v[0]:.0f} med {v[1]:.0f} p90 {v[2]:.0f}' for sh, v in o.items()))
