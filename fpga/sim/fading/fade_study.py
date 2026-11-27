"""Fading study, one C5: Rayleigh fading (eval3 channel model) at several Doppler rates
and mean C/N. Receiver: mrc3_model (bit-exact with the RTL) with Rescue Off / Auto,
plus candidate post-discriminator fixes evaluated on the codes:
  gate_hold:  while the C5's 3-bit cell amplitude is in the inner ring (deep fade),
              hold the last good code instead of the discriminator's output.
Scored with research/sim.py's goggle model: picture lock / SINAD dB.
usage: python fade_study.py <triversity/fpga> [jobs]"""
import multiprocessing as mp, sys
from pathlib import Path
import numpy as np
from scipy import signal as sg
FPGA = Path(sys.argv[1]); JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 4
sys.path.insert(0, str(FPGA / 'model')); sys.path.insert(0, str(FPGA / 'sim'))
import eval3, mrc3_model as M, chroma_model as C
E = eval3.E

DOPPLER = (30, 100, 300)
CN = (6, 10, 14, 20)


def amp2(raw3):
    """|c|^2 of the 3-bit cells (c = 4 v + 2, v = -4..3)."""
    r = raw3.astype(int)
    def v(x):            # {sign, b2, b1} two's complement -4..3
        return np.where(x & 4, x - 8, x)
    ci = 4 * v((r >> 3) & 7) + 2; cq = 4 * v(r & 7) + 2
    return ci * ci + cq * cq


def gate_hold(codes, a2, thr, ext=2):
    """Hold the last code while a2 <= thr (and ext samples after)."""
    bad = a2 <= thr
    if ext:
        b = bad.copy()
        for s in range(1, ext + 1): b[s:] |= bad[:-s]
        bad = b
    out = codes.copy()
    for k in range(1, len(out)):
        if bad[k]: out[k] = out[k - 1]
    return out


def job(a):
    cn, fd, seed = a
    ire, region = C.source('NTSC', C.test_picture(240), fields=4, seed=seed)
    src = sg.lfilter(sg.firwin(81, 6e6, fs=80e6), 1, np.repeat(ire, 2))
    S = E.sim
    z80 = sg.sosfilt(S.CHAN, np.exp(2j * np.pi * np.cumsum(S.PORCH_HZ + 0.7 * src / 140 * S.DEV_PP) / 80e6))
    z80 /= np.sqrt(np.mean(abs(z80) ** 2))
    rng = np.random.default_rng(seed)
    y = eval3.branch_y(z80, cn, rng, fd)
    raw = M.to_raw3(y[0]); clean = M.to_raw3(y[1])
    k0 = len(ire) // 2
    c = dict(truth=sg.sosfilt(E.sim.GOGGLE, ire)[k0:], region=region[k0:], standard='NTSC')
    ref = M.run([clean], disc=True)
    out = {}
    for name, rs in (('off', 0), ('auto', 1)):
        codes = M.run([raw], disc=True, rescue=rs)
        r = E.sim.measure(c, codes[k0:], ref[k0:]); out[name] = (r['picture'], r['sinad'])
    codes = M.run([raw], disc=True, rescue=0)
    a2 = amp2(raw)
    for thr in (8, 40):
        g = gate_hold(codes, a2, thr)
        r = E.sim.measure(c, g[k0:], ref[k0:]); out[f'hold{thr}'] = (r['picture'], r['sinad'])
    return (cn, fd), out


def main():
    jobs = [(cn, fd, 900 + 7 * s + cn + fd) for fd in DOPPLER for cn in CN for s in range(2)]
    with mp.Pool(JOBS) as p:
        res = p.map(job, jobs)
    names = list(res[0][1].keys())
    print('one C5, Rayleigh fading: picture lock / SINAD dB')
    print(f"{'fd':>4s} {'C/N':>4s}" + ''.join(f'{n:>14s}' for n in names))
    for fd in DOPPLER:
        for cn in CN:
            rs = [r for k, r in res if k == (cn, fd)]
            print(f'{fd:4d} {cn:4d}' + ''.join(f"{np.mean([r[n][0] for r in rs]):.2f}/{np.mean([r[n][1] for r in rs]):5.1f}".rjust(14) for n in names))


if __name__ == '__main__':
    main()
