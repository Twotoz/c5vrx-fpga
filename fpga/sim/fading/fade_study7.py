"""Fading study 7, one C5: Auto Rescue on/off thresholds (clicks a 2^18-pair window).
usage: python fade_study7.py <triversity/fpga> [jobs]"""
import multiprocessing as mp, sys
from pathlib import Path
import numpy as np
from scipy import signal as sg
FPGA = Path(sys.argv[1]); JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 2
sys.path.insert(0, str(FPGA / 'model')); sys.path.insert(0, str(FPGA / 'sim'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import eval3, mrc3_model as M, chroma_model as C
from fade_study2 import demod
E = eval3.E
V = {'off': (0, 1 << 18, 0, 0, 0), 'auto100': (1, 1 << 18, 100, 25, 0), 'auto50': (1, 1 << 18, 50, 12, 0),
     'auto25': (1, 1 << 18, 25, 6, 0), 'auto12': (1, 1 << 18, 12, 3, 0), 'auto6': (1, 1 << 18, 6, 2, 0),
     'on': (2, 1 << 18, 0, 0, 0), 'on_coast': (2, 1 << 18, 0, 0, 8)}


def job(a):
    cn, fd, seed = a
    ire, region = C.source('NTSC', C.test_picture(240), fields=4, seed=seed)
    src = sg.lfilter(sg.firwin(81, 6e6, fs=80e6), 1, np.repeat(ire, 2))
    S = E.sim
    z80 = sg.sosfilt(S.CHAN, np.exp(2j * np.pi * np.cumsum(S.PORCH_HZ + 0.7 * src / 140 * S.DEV_PP) / 80e6))
    z80 /= np.sqrt(np.mean(abs(z80) ** 2))
    y = eval3.branch_y(z80, cn, np.random.default_rng(seed), fd)
    raw = M.to_raw3(y[0]); clean = M.to_raw3(y[1])
    k0 = len(ire) // 2
    c = dict(truth=sg.sosfilt(E.sim.GOGGLE, ire)[k0:], region=region[k0:], standard='NTSC')
    ref_off = M.run([clean], disc=True)
    out = {}
    for name, (mode, win, ton, toff, gt) in V.items():
        if mode == 0:
            codes = M.run([raw], disc=True).astype(np.int64)
        else:
            codes = demod(raw, mode, win, ton, toff, gt)
        r = E.sim.measure(c, codes[k0:], ref_off[k0:]); out[name] = (r['picture'], r['sinad'])
    return (cn, fd), out


def main():
    jobs = [(cn, fd, 900 + 7 * s + cn + fd) for fd in (0, 30, 100, 300) for cn in (6, 10, 14, 20) for s in range(2 if fd else 1)]
    with mp.Pool(JOBS) as p:
        res = p.map(job, jobs)
    names = list(V)
    print('one C5 (fd 0 = static): picture lock / SINAD dB, all scored against the clean discriminator')
    print(f"{'fd':>4s} {'C/N':>4s}" + ''.join(f'{n:>12s}' for n in names))
    for fd in (0, 30, 100, 300):
        for cn in (6, 10, 14, 20):
            rs = [r for k, r in res if k == (cn, fd)]
            print(f'{fd:4d} {cn:4d}' + ''.join(f"{np.mean([r[n][0] for r in rs]):.2f}/{np.mean([r[n][1] for r in rs]):4.1f}".rjust(12) for n in names), flush=True)


if __name__ == '__main__':
    main()
