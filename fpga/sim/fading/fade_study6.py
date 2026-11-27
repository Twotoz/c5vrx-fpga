"""Fading study 6, one C5: fade-selected Rescue. The Rescue PLL runs all the time
(coasting while the cell is in the inner ring, as on_coast); its output replaces the
discriminator only around fades: where the mean |c|^2 over M samples is below T,
extended by H samples on both sides. Elsewhere the plain discriminator (full detail).
usage: python fade_study6.py <triversity/fpga> [jobs]"""
import multiprocessing as mp, sys
from pathlib import Path
import numpy as np
from numba import njit
from scipy import signal as sg
FPGA = Path(sys.argv[1]); JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 2
sys.path.insert(0, str(FPGA / 'model')); sys.path.insert(0, str(FPGA / 'sim'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import eval3, mrc3_model as M, chroma_model as C
from fade_study import amp2
from fade_study2 import demod
E = eval3.E
WL, WH = M.DISC_WL, M.DISC_WH


@njit(cache=True)
def pll_run(phis, gate):
    n = len(phis)
    th = 0; F = 0; fop = 0
    pll = np.zeros(n, np.int64)
    for k in range(n):
        e = (((phis[k] >> 4) - th + 2048) & 0xFFF) - 2048
        if gate[k]: e = 0
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
    return pll


def selected(raw, m, t, h):
    codes, phis = M.run([raw], disc=True, return_phi=True)
    codes = codes.astype(np.int64).copy()
    a2 = amp2(raw)
    pll = pll_run(phis.astype(np.int64), a2 <= 8)
    mean = np.convolve(a2, np.ones(m) / m, 'same')
    sel = mean < t
    if h:
        sel = np.convolve(sel.astype(np.int64), np.ones(2 * h + 1, np.int64), 'same') > 0
    out = codes.copy()
    idx = np.nonzero(sel[:-2])[0]
    out[idx + 2] = pll[idx]
    return out, sel.mean()


SEL = {f'm{m}t{t}h{h}': (m, t, h) for m, t, h in
       [(16, 20, 16), (16, 30, 16), (16, 45, 16), (16, 30, 64), (64, 30, 32), (64, 45, 32)]}


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
    ref_off, ref_on = M.run([clean], disc=True), M.run([clean], disc=True, rescue=2)
    out = {}
    for name, (mode, gt) in dict(auto=(1, 0), on_coast=(2, 8)).items():
        codes = demod(raw, mode, 1 << 18, 100, 25, gt)
        r = E.sim.measure(c, codes[k0:], (ref_on if mode == 2 else ref_off)[k0:]); out[name] = (r['picture'], r['sinad'], 0)
    for name, (m, t, h) in SEL.items():
        codes, frac = selected(raw, m, t, h)
        r = E.sim.measure(c, codes[k0:], ref_off[k0:]); out[name] = (r['picture'], r['sinad'], frac)
    return (cn, fd), out


def main():
    jobs = [(cn, fd, 900 + 7 * s + cn + fd) for fd in (30, 100, 300) for cn in (6, 10, 14, 20) for s in range(2)]
    jobs += [(cn, 0, 900 + 7 * s + cn) for cn in (6, 10, 14, 20) for s in range(1)]
    with mp.Pool(JOBS) as p:
        res = p.map(job, jobs)
    names = list(res[0][1].keys())
    print('one C5, Rayleigh fading (fd 0 = static): picture lock / SINAD dB [share PLL]')
    print(f"{'fd':>4s} {'C/N':>4s}" + ''.join(f'{n:>17s}' for n in names))
    for fd in (0, 30, 100, 300):
        for cn in (6, 10, 14, 20):
            rs = [r for k, r in res if k == (cn, fd)]
            print(f'{fd:4d} {cn:4d}' + ''.join(f"{np.mean([r[n][0] for r in rs]):.2f}/{np.mean([r[n][1] for r in rs]):4.1f}[{np.mean([r[n][2] for r in rs]):3.0%}]".rjust(17) for n in names), flush=True)


if __name__ == '__main__':
    main()
