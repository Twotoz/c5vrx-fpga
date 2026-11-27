"""Fading study 11: look-ahead Auto plus a steady-clicks switch: over 64 sub-windows of
2^12 pairs (13 ms), when at least T of them hold a click the PLL runs all the time
(a very weak signal: the PLL is better there even between the clicks); else the
look-ahead (fading at a good C/N: clicks in bursts).
usage: python fade_study11.py <triversity/fpga> [jobs]"""
import multiprocessing as mp, sys
from pathlib import Path
import numpy as np
from scipy import signal as sg
FPGA = Path(sys.argv[1]); JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 2
sys.path.insert(0, str(FPGA / 'model')); sys.path.insert(0, str(FPGA / 'sim'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import eval3, mrc3_model as M, chroma_model as C
from fade_study2 import rescue_g
E = eval3.E
TS = (16, 32, 48)


def pair_clicks(phis):
    t = ((phis[0::2].astype(np.int64) + 32768) >> 6) & 1023
    s = t[0]; cl = np.zeros(len(t), np.int64)
    for j in range(len(t)):
        d = ((t[j] - s + 512) & 1023) - 512
        c = not (M.DISC_WL <= d <= M.DISC_WH); cl[j] = c
        s = (s + (d if not c else (d * 179) >> 8)) & 1023
    return cl


def steady(cl, t):
    """per pair: the switch as set at the end of each 64 x 2^12-pair window (held)."""
    sub = 1 << 12; nsub = len(cl) // sub
    occ = cl[:nsub * sub].reshape(nsub, sub).max(1)
    on = np.zeros(len(cl), bool); st = False
    for i in range(nsub):
        if i % 64 == 63:
            st = occ[i - 63:i + 1].sum() >= t
        on[(i + 1) * sub:(i + 2) * sub] = st
    return on


def job(a):
    nb, cn, fd, seed = a
    ire, region = C.source('NTSC', C.test_picture(240), fields=4, seed=seed)
    src = sg.lfilter(sg.firwin(81, 6e6, fs=80e6), 1, np.repeat(ire, 2))
    S = E.sim
    z80 = sg.sosfilt(S.CHAN, np.exp(2j * np.pi * np.cumsum(S.PORCH_HZ + 0.7 * src / 140 * S.DEV_PP) / 80e6))
    z80 /= np.sqrt(np.mean(abs(z80) ** 2))
    rng = np.random.default_rng(seed)
    ys = [eval3.branch_y(z80, cn, rng, fd) for _ in range(nb)]
    raws = [M.to_raw3(y[0]) for y in ys]; clean = [M.to_raw3(y[1]) for y in ys]
    k0 = len(ire) // 2
    c = dict(truth=sg.sosfilt(E.sim.GOGGLE, ire)[k0:], region=region[k0:], standard='NTSC')
    ref = M.run(clean, disc=True)
    out = {}
    def score(name, codes):
        r = E.sim.measure(c, codes[k0:], ref[k0:]); out[name] = (r['picture'], r['sinad'])
    codes, phis = M.run(raws, disc=True, return_phi=True)
    old = codes.astype(np.int64).copy()
    rescue_g(phis.astype(np.int64), old, 1, 1 << 18, 100, 25, np.zeros(len(old), np.bool_))
    score('old_auto', old)
    la, act = M.run(raws, disc=True, rescue=1, return_act=True)
    score('la', la)
    pll = M.run(raws, disc=True, rescue=2).astype(np.int64)
    score('on', pll)
    cl = pair_clicks(phis)
    for t in TS:
        st = np.repeat(steady(cl, t), 2)[:len(la)]
        st = np.concatenate([st, np.zeros(len(la) - len(st), bool)])
        score(f'la+st{t}', np.where(st | act.astype(bool), pll, la.astype(np.int64)))
    return (nb, cn, fd), out


def main():
    grid = {1: (6, 10, 14, 20), 3: (0, 4, 8, 14)}
    jobs = [(nb, cn, fd, 900 + 7 * s + cn + fd + nb) for nb in (1, 3) for fd in (0, 30, 100, 300)
            for cn in grid[nb] for s in range(2 if fd else 1)]
    with mp.Pool(JOBS) as p:
        res = p.map(job, jobs)
    names = list(res[0][1].keys())
    for nb in (1, 3):
        print(f'{nb} C5 (fd 0 = static): picture lock / SINAD dB, against the clean discriminator')
        print(f"{'fd':>4s} {'C/N':>4s}" + ''.join(f'{n:>12s}' for n in names))
        for fd in (0, 30, 100, 300):
            for cn in grid[nb]:
                rs = [r for k, r in res if k == (nb, cn, fd)]
                print(f'{fd:4d} {cn:4d}' + ''.join(f"{np.mean([r[n][0] for r in rs]):.2f}/{np.mean([r[n][1] for r in rs]):4.1f}".rjust(12) for n in names), flush=True)


if __name__ == '__main__':
    main()
