"""Fading study 2, one C5: Rescue variants. The PLL of mrc3_model.rescue50, copied
here with an optional amplitude gate: while the C5's cell amplitude is in the inner
ring (deep fade) the PLL coasts (e = 0: its phase advances by F alone).
Variants: auto (13 ms window, as built), on, auto_fast (0.8 ms window, thresholds
scaled), on_coast, fast_coast.
usage: python fade_study2.py <triversity/fpga> [jobs]"""
import multiprocessing as mp, sys
from pathlib import Path
import numpy as np
from numba import njit
from scipy import signal as sg
FPGA = Path(sys.argv[1]); JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 4
sys.path.insert(0, str(FPGA / 'model')); sys.path.insert(0, str(FPGA / 'sim'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import eval3, mrc3_model as M, chroma_model as C
from fade_study import amp2
E = eval3.E
WL, WH = M.DISC_WL, M.DISC_WH


@njit(cache=True)
def rescue_g(phis, out, mode, win, ton, toff, gate):
    n = len(phis)
    s = ((phis[0] + 32768) >> 6) & 1023
    th = 0; F = 0; fop = 0
    on = mode >= 2
    cnt = 0; j = 0
    pll = np.zeros(n, np.int64)
    for k in range(n):
        e = (((phis[k] >> 4) - th + 2048) & 0xFFF) - 2048
        if gate[k]: e = 0                          # deep fade: coast
        fo = (F >> 7) + (e >> 2)
        F += e
        if F < -(1 << 16): F = -(1 << 16)
        if F > (1 << 16) - 1: F = (1 << 16) - 1
        th = (th + fo) & 0xFFF
        d = (fo + fop) >> 2
        step = d if (d >= WL and d <= WH) else (d * 179) >> 8
        c = (105 * step + 32896) // 1280
        pll[k] = 0 if c < 0 else (63 if c > 63 else c)
        fop = fo
    for k in range(0, n - 3, 2):
        t = ((phis[k] + 32768) >> 6) & 1023
        d = ((t - s + 512) & 1023) - 512
        cl = not (d >= WL and d <= WH)
        step = d if not cl else (d * 179) >> 8
        s = (s + step) & 1023
        if mode == 1:
            cnt = cnt + 1 if cl and cnt < 255 else cnt
            if j % win == win - 1:
                if cnt >= ton: on = True
                elif cnt < toff: on = False
                cnt = 0
        j += 1
        if on:
            out[k + 2] = pll[k]
            out[k + 3] = pll[k + 1]


def demod(raw, mode, win, ton, toff, gate_thr):
    codes, phis = M.run([raw], disc=True, return_phi=True)
    codes = codes.astype(np.int64).copy()
    a2 = amp2(raw)
    g = (a2 <= gate_thr) if gate_thr else np.zeros(len(raw), np.bool_)
    rescue_g(phis.astype(np.int64), codes, mode, win, ton, toff, g)
    return codes


VARIANTS = {                     # mode, window (pairs), on, off, gate
    'auto':       (1, 1 << 18, 100, 25, 0),
    'on':         (2, 1 << 18, 100, 25, 0),
    'auto_fast':  (1, 1 << 14, 7, 2, 0),
    'on_coast':   (2, 1 << 18, 100, 25, 8),
    'fast_coast': (1, 1 << 14, 7, 2, 8),
}


def job(a):
    cn, fd, seed = a
    ire, region = C.source('NTSC', C.test_picture(240), fields=4, seed=seed)
    src = sg.lfilter(sg.firwin(81, 6e6, fs=80e6), 1, np.repeat(ire, 2))
    S = E.sim
    z80 = sg.sosfilt(S.CHAN, np.exp(2j * np.pi * np.cumsum(S.PORCH_HZ + 0.7 * src / 140 * S.DEV_PP) / 80e6))
    z80 /= np.sqrt(np.mean(abs(z80) ** 2))
    k0 = len(ire) // 2
    c = dict(truth=sg.sosfilt(E.sim.GOGGLE, ire)[k0:], region=region[k0:], standard='NTSC')
    out = {}
    for agc in (250.0, 50.0, 10.0):
        y = eval3.branch_y(z80, cn, np.random.default_rng(seed), fd, agc_us=agc)
        raw = M.to_raw3(y[0]); clean = M.to_raw3(y[1])
        ref_off = M.run([clean], disc=True)
        codes = demod(raw, 1, 1 << 18, 100, 25, 0)
        r = E.sim.measure(c, codes[k0:], ref_off[k0:]); out[f'agc{int(agc)}'] = (r['picture'], r['sinad'])
    y = eval3.branch_y(z80, cn, np.random.default_rng(seed), 0)          # no fading: the ceiling
    raw = M.to_raw3(y[0]); clean = M.to_raw3(y[1])
    codes = demod(raw, 1, 1 << 18, 100, 25, 0)
    r = E.sim.measure(c, codes[k0:], M.run([clean], disc=True)[k0:]); out['static'] = (r['picture'], r['sinad'])
    return (cn, fd), out


def main():
    jobs = [(cn, fd, 900 + 7 * s + cn + fd) for fd in (100, 300) for cn in (6, 10, 14, 20) for s in range(2)]
    with mp.Pool(JOBS) as p:
        res = p.map(job, jobs)
    names = list(res[0][1].keys())
    print('one C5, Rayleigh fading: picture lock / SINAD dB')
    print(f"{'fd':>4s} {'C/N':>4s}" + ''.join(f'{n:>14s}' for n in names))
    for fd in (100, 300):
        for cn in (6, 10, 14, 20):
            rs = [r for k, r in res if k == (cn, fd)]
            print(f'{fd:4d} {cn:4d}' + ''.join(f"{np.mean([r[n][0] for r in rs]):.2f}/{np.mean([r[n][1] for r in rs]):5.1f}".rjust(14) for n in names))


if __name__ == '__main__':
    main()
