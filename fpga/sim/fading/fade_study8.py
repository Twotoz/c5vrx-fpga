"""Fading study 8, one C5: look-ahead selection between the discriminator and the
Rescue PLL. Both outputs are delayed (a line of BSRAM); per sample the PLL is used
when the discriminator's clicks within +-W samples are >= K (symmetric window: the
future is known through the delay). Oracle: per block of 64 the output closer to the
clean reference (upper bound, not buildable).
usage: python fade_study8.py <triversity/fpga> [jobs]"""
import multiprocessing as mp, sys
from pathlib import Path
import numpy as np
from scipy import signal as sg
FPGA = Path(sys.argv[1]); JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 2
sys.path.insert(0, str(FPGA / 'model')); sys.path.insert(0, str(FPGA / 'sim'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import eval3, mrc3_model as M, chroma_model as C
from fade_study6 import pll_run
E = eval3.E
WL, WH = M.DISC_WL, M.DISC_WH
SEL = [(16, 1), (64, 1), (64, 2), (256, 1), (256, 3), (1024, 2), (1024, 6)]


def clicks(phis):
    t = ((phis.astype(np.int64) + 32768) >> 6) & 1023
    d = ((np.diff(t) + 512) & 1023) - 512
    c = np.zeros(len(phis), np.int64); c[1:] = ~((d >= WL) & (d <= WH))
    return c


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
    ref = M.run([clean], disc=True).astype(np.int64)
    disc, phis = M.run([raw], disc=True, return_phi=True)
    disc = disc.astype(np.int64)
    auto = M.run([raw], disc=True, rescue=1).astype(np.int64)
    pll = disc.copy(); p = pll_run(phis.astype(np.int64), np.zeros(len(raw), np.bool_)); pll[2:] = p[:-2]
    out = {}
    def score(name, codes, frac):
        r = E.sim.measure(c, codes[k0:], ref[k0:]); out[name] = (r['picture'], r['sinad'], frac)
    score('auto', auto, 0); score('disc', disc, 0); score('pll', pll, 1)
    cl = clicks(phis)
    for w, k in SEL:
        n = np.convolve(cl, np.ones(2 * w + 1, np.int64), 'same')
        sel = n >= k
        score(f'w{w}k{k}', np.where(sel, pll, disc), sel.mean())
    b = 64; nb = len(ref) // b
    ed = ((disc[:nb * b] - ref[:nb * b]) ** 2).reshape(nb, b).sum(1)
    ep = ((pll[:nb * b] - ref[:nb * b]) ** 2).reshape(nb, b).sum(1)
    sel = np.repeat(ep < ed, b); o = disc.copy(); o[:nb * b] = np.where(sel, pll[:nb * b], disc[:nb * b])
    score('oracle64', o, sel.mean())
    return (cn, fd), out


def main():
    jobs = [(cn, fd, 900 + 7 * s + cn + fd) for fd in (0, 30, 100, 300) for cn in (6, 10, 14, 20) for s in range(2 if fd else 1)]
    with mp.Pool(JOBS) as p:
        res = p.map(job, jobs)
    names = list(res[0][1].keys())
    print('one C5 (fd 0 = static): picture lock / SINAD dB [share PLL], against the clean discriminator')
    print(f"{'fd':>4s} {'C/N':>4s}" + ''.join(f'{n:>16s}' for n in names))
    for fd in (0, 30, 100, 300):
        for cn in (6, 10, 14, 20):
            rs = [r for k, r in res if k == (cn, fd)]
            print(f'{fd:4d} {cn:4d}' + ''.join(f"{np.mean([r[n][0] for r in rs]):.2f}/{np.mean([r[n][1] for r in rs]):4.1f}[{np.mean([r[n][2] for r in rs]):3.0%}]".rjust(16) for n in names), flush=True)


if __name__ == '__main__':
    main()
