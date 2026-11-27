"""Fading study 10: the built look-ahead Auto (mrc3_model.rescue50, bit-exact with
mrc3_core.v) (with the steady switch) against the old 13 ms Auto (fade_study2.rescue_g), with one and three
C5s (independent fading per C5).
usage: python fade_study10.py <triversity/fpga> [jobs]"""
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
LA = {'auto_new': (1024, 2)}


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
    score('off', codes)
    old = codes.astype(np.int64).copy()
    rescue_g(phis.astype(np.int64), old, 1, 1 << 18, 100, 25, np.zeros(len(old), np.bool_))
    score('old_auto', old)
    for name, (w, k) in LA.items():
        score(name, M.run(raws, disc=True, rescue=1, rw=w, rk=k))
    score('on', M.run(raws, disc=True, rescue=2))
    return (nb, cn, fd), out


def main():
    jobs = [(nb, cn, fd, 900 + 7 * s + cn + fd + nb) for nb in (1, 3) for fd in (0, 30, 100, 300)
            for cn in ((6, 10, 14, 20) if nb == 1 else (0, 4, 8, 14)) for s in range(2 if fd else 1)]
    with mp.Pool(JOBS) as p:
        res = p.map(job, jobs)
    names = list(res[0][1].keys())
    for nb in (1, 3):
        print(f'{nb} C5 (fd 0 = static): picture lock / SINAD dB, against the clean discriminator')
        print(f"{'fd':>4s} {'C/N':>4s}" + ''.join(f'{n:>12s}' for n in names))
        for fd in (0, 30, 100, 300):
            for cn in ((6, 10, 14, 20) if nb == 1 else (0, 4, 8, 14)):
                rs = [r for k, r in res if k == (nb, cn, fd)]
                print(f'{fd:4d} {cn:4d}' + ''.join(f"{np.mean([r[n][0] for r in rs]):.2f}/{np.mean([r[n][1] for r in rs]):4.1f}".rjust(12) for n in names), flush=True)


if __name__ == '__main__':
    main()
