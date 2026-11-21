"""C5VRX by Twotoz and the C5VRX contributors: picture performance of the
Triversity receiver as built, per Signal page switch.

Signal: one NTSC frame per case through the C5 channel model (model/eval3.py:
own LO per C5, independent noise, optional Rayleigh fading at 300 Hz, 250 us
AGC), three C5s with 3-bit I/Q. Receiver: model/mrc3_model.py (combiner,
tracker, weights, discriminator, Weak branch, Anti-fold, Spike filter;
bit-exact with rtl/rx/mrc3_core.v, sim/run_tb3.py) and for the Noise filter
the luma path of chroma.v + vid_sync.v (model/chroma_model.py hw_decode and
ans, bit-exact with the RTL: run_chroma_tb.py, run_ans_tb.py).

Table 1, picture lock (0..1) / SINAD dB with research/sim.py's goggle model:
one C5 alone, and Triversity with the switches off, each on, all on, for
  - equal:  all three at the same C/N
  - C dead: C5 C without signal (antenna off)
  - C weak: C5 C 10 dB below A and B
  - C fold: C5 C's phase flips 180 degrees every 20 us (multipath)
Table 2, luma SINAD dB on the receiver's own luma (against the source
picture low-passed to 3 MHz), Noise filter off / on, three equal C5s.

    python sim/perf_vrx.py [--quick]
"""
import multiprocessing as mp
import sys
from pathlib import Path

import numpy as np
from scipy import signal as sg

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE.parent / 'model'))
import eval3  # noqa: E402
import mrc3_model  # noqa: E402

E = eval3.E
SW = {'off': {}, 'weak': dict(wbranch=True), 'afold': dict(afold=True), 'spike': dict(spike=True),
      'all': dict(wbranch=True, afold=True, spike=True)}
CASES = ('equal', 'C dead', 'C weak', 'C fold')


def channel(seed, cn, fd, case, n=None):
    rng = np.random.default_rng(seed)
    ire, region = E.sim.raster('NTSC', seed + 7, 1)
    if n:
        ire, region = ire[:n], region[:n]
    src = sg.lfilter(sg.firwin(81, 6e6, fs=80e6), 1, np.repeat(ire, 2))
    z80 = sg.sosfilt(E.sim.CHAN, np.exp(2j * np.pi * np.cumsum(E.sim.PORCH_HZ + 0.7 * src / 140 * E.sim.DEV_PP) / 80e6))
    z80 /= np.sqrt(np.mean(abs(z80) ** 2))
    ys = []
    for b in range(3):
        c_ = cn
        z = z80
        if b == 2 and case == 'C dead':
            c_ = -60
        elif b == 2 and case == 'C weak':
            c_ = cn - 10
        elif b == 2 and case == 'C fold':
            z = z80 * np.where((np.arange(len(z80)) // 1600) % 2, -1, 1)
        ys.append(eval3.branch_y(z, c_, rng, fd))
    return ys, ire, region


def table1(args):
    case, cn, fd, seed = args
    ys, ire, region = channel(seed, cn, fd, case)
    raws = [mrc3_model.to_raw3(y[0]) for y in ys]
    clean = [mrc3_model.to_raw3(y[1]) for y in ys]
    c = dict(truth=sg.sosfilt(E.sim.GOGGLE, ire), region=region, standard='NTSC')
    out = {'1 C5': E.sim.measure(c, mrc3_model.run(raws[:1], disc=True), mrc3_model.run(clean[:1], disc=True))}
    cc = mrc3_model.run(clean, disc=True)
    for name, kw in SW.items():
        out[name] = E.sim.measure(c, mrc3_model.run(raws, disc=True, **kw), cc)
    return args, {k: (v['picture'], v['sinad']) for k, v in out.items()}


def luma_sinad(y, truth, region, lo=3000):
    n = len(y)
    yy = y[lo:n - lo] - y.mean(); tt = truth[lo:n - lo] - truth.mean()
    xc = sg.correlate(yy, tt, 'full', method='fft'); l0 = int(np.argmax(xc)) - (len(tt) - 1)
    best = -99.0
    for lag in range(l0 - 2, l0 + 3):
        a = y[lo + lag:n - lo - 40 + lag]; t = truth[lo:n - lo - 40]; m = region[lo:n - lo - 40] == 1
        A = np.c_[a[m], np.ones(m.sum())]
        e = A @ np.linalg.lstsq(A, t[m], rcond=None)[0] - t[m]
        best = max(best, float(10 * np.log10(np.var(t[m]) / np.mean(e ** 2))))
    return best


def table2(args):
    import chroma_model as C
    cn, seed = args
    n = 600000
    ys, ire, region = channel(seed, cn, 0, 'equal', n)
    codes = np.asarray(mrc3_model.run([mrc3_model.to_raw3(y[0]) for y in ys], disc=True), np.int64)
    _, hc, pal = C.line_starts(codes)
    Y, _, _ = C.hw_decode(codes, hc, pal)
    Yf, lev = C.ans(Y, hc)
    truth = sg.filtfilt(sg.firwin(121, 3.0e6, fs=40e6), 1, ire)
    k0 = 400000   # after the level has settled (one step per 64 lines)
    return args, (luma_sinad(Y[k0:].astype(float), truth[k0:], region[k0:]),
                  luma_sinad(Yf[k0:].astype(float), truth[k0:], region[k0:]), int(lev[-1]))


def main():
    quick = '--quick' in sys.argv
    seeds = (71,) if quick else (71, 72, 73)
    cns = (-2, 0, 3, 6, 9, 14)
    jobs = [(case, cn, fd, s * 100 + cn + 7 * i) for i, case in enumerate(CASES) for fd in (0, 300) for cn in cns for s in seeds]
    procs = int(next((a.split('=')[1] for a in sys.argv if a.startswith('--jobs=')), 3))
    with mp.Pool(procs) as p:
        r1 = p.map(table1, jobs)
        r2 = p.map(table2, [(cn, s * 100 + cn) for cn in cns for s in seeds[:2]])
    names = ['1 C5'] + list(SW)
    print('Table 1: picture lock / SINAD dB (goggle model), mean of', len(seeds), 'frames')
    print(f"{'case':8s} {'fade':>4s} {'C/N':>4s}" + ''.join(f'{n:>12s}' for n in names))
    for case in CASES:
        for fd in (0, 300):
            for cn in cns:
                rs = [r for a, r in r1 if a[0] == case and a[1] == cn and a[2] == fd]
                print(f'{case:8s} {fd:4d} {cn:4d}' + ''.join(
                    f"{np.mean([r[n][0] for r in rs]):5.2f}/{np.mean([r[n][1] for r in rs]):5.1f}".rjust(12) for n in names))
    print('\nTable 2: receiver luma SINAD dB, three equal C5s, Noise filter off / on (level)')
    for cn in cns:
        rs = [r for a, r in r2 if a[0] == cn]
        print(f'C/N {cn:3d}:  off {np.mean([r[0] for r in rs]):5.1f}   on {np.mean([r[1] for r in rs]):5.1f}'
              f'   (+{np.mean([r[1] - r[0] for r in rs]):.1f} dB, level {[r[2] for r in rs]})')


if __name__ == '__main__':
    main()
