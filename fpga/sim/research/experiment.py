"""Issues #13 and #14: every candidate against the disc50 discriminator,
Rescue Auto and D3 on the same signals (iq_harness.py), several seeds.

    python fpga/sim/research/experiment.py [jobs]       -> results/compare.txt
    python fpga/sim/research/experiment.py quant [jobs] -> results/quant.txt

compare: rows = condition, columns = algorithm; mean over seeds of luma SINAD
(dB), and for each candidate its mean / worst delta against Rescue Auto, with
the 3 MHz detail and colour-bar chroma SNR deltas. Conditions: static C/N,
Rayleigh fading (fd 30 / 100 / 300 Hz), a short dropout and a 1 ms dropout on
one C5, 1 / 2 / 3 C5s, NTSC and PAL.

quant (#14 P3): a float angle discriminator over the same 50 ns, from 3-bit
or 4-bit I/Q at 40 or 80 MS/s, to separate sample rate and bit depth.
"""
import multiprocessing as mp, sys, zlib
from pathlib import Path
import numpy as np
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import iq_harness as H  # noqa: E402
import candidates as C  # noqa: E402

SEEDS = 6
LINES = 96
CONDS = [  # name, std, n C5, C/N, fd, dropout (start, length in 40 MS/s samples) on C5 A
    ('static 30', 'NTSC', 1, 30, 0, None),
    ('static 14', 'NTSC', 1, 14, 0, None),
    ('static 10', 'NTSC', 1, 10, 0, None),
    ('static 8', 'NTSC', 1, 8, 0, None),
    ('static 6', 'NTSC', 1, 6, 0, None),
    ('static 4', 'NTSC', 1, 4, 0, None),
    ('fd30 14', 'NTSC', 1, 14, 30, None),
    ('fd100 14', 'NTSC', 1, 14, 100, None),
    ('fd300 14', 'NTSC', 1, 14, 300, None),
    ('fd100 20', 'NTSC', 1, 20, 100, None),
    ('drop 50us 14', 'NTSC', 1, 14, 0, (60000, 2000)),
    ('drop 1ms 14', 'NTSC', 1, 14, 0, (60000, 40000)),
    ('PAL static 8', 'PAL', 1, 8, 0, None),
    ('PAL fd100 14', 'PAL', 1, 14, 100, None),
    ('2 C5 fd100 8', 'NTSC', 2, 8, 100, None),
    ('3 C5 fd100 4', 'NTSC', 3, 4, 100, None),
    ('3 C5 static 30', 'NTSC', 3, 30, 0, None),
]
BASE = ['disc', 'rescue', 'd3']


def box(x, n):
    """causal n-sample mean of codes (a bandwidth control), re-quantized"""
    return np.round(np.convolve(x, np.ones(n) / n, 'full')[:len(x)])


def algos(phi, b, amp, fsc):
    act = b.pop('_act')
    out = dict(b)
    out['disc+box4'] = box(b['disc'], 4)                       # control for lag4: the same filtering
    out['resc+box4'] = box(b['rescue'], 4)
    out['resc/lag4'] = np.where(act, b['rescue'], C.lag(phi, 4))   # lag4 as Rescue Auto's fast path
    out['resc/lag2'] = np.where(act, b['rescue'], C.lag(phi, 2))
    out['lag2'] = C.lag(phi, 2)
    out['lag4'] = C.lag(phi, 4)
    out['lag8'] = C.lag(phi, 8)
    out['lagpred4'] = C.lag_pred(phi, 4, 1.0)
    out['lagpred4s'] = C.lag_pred(phi, 4, 1 / 8)
    out['lagpred8s'] = C.lag_pred(phi, 8, 1 / 8)
    out['fuse4s/resc'] = C.fuse(phi, b['rescue'], 4, alpha=1 / 8)
    pll = C.gated_pll(phi, amp, gate=False)
    gp = C.gated_pll(phi, amp) if amp is not None else pll
    out['pll'] = pll
    out['gatedpll'] = gp
    out['split pll/disc'] = C.split(pll, b['disc'], fsc)
    out['split gpll/disc'] = C.split(gp, b['disc'], fsc)
    out['split resc/disc'] = C.split(b['rescue'], b['disc'], fsc)   # control: filtering alone
    return out


def job(a):
    cond, seed = a
    name, std, nc, cn, fd, drop = cond
    z, tr, reg, Lh = H.source(std, LINES)
    rng = np.random.default_rng(1000 * seed + zlib.crc32(name.encode()) % 997)
    raws = [H.branch(z, cn, rng, fd, drop if i == 0 else None) for i in range(nc)]
    b, phi = H.baselines(raws)
    amp = np.abs(H.cells(raws[0])) ** 2 if nc == 1 else None     # gate on C5 A's energy (1 C5)
    fsc = H.STD[std]['fsc']
    res = {k: H.score(c, tr, reg, Lh) for k, c in algos(phi, b, amp, fsc).items()}
    return name, seed, res


def quant_job(a):
    cn, fd, seed = a
    z, tr, reg, Lh = H.source('NTSC', LINES)
    out = {}
    for fs80 in (False, True):
        for bits in (3, 4):
            rng = np.random.default_rng(seed)            # the same noise for every variant
            n = len(z)
            h = H.rayleigh(n, fd, rng) if fd else np.ones(n, complex)
            s = z * h * np.exp(1j * rng.uniform(0, 2 * np.pi))
            noise = H.sg.sosfilt(H.CHAN, (rng.normal(size=n) + 1j * rng.normal(size=n)) / np.sqrt(2))
            noise /= np.sqrt(np.mean(abs(noise) ** 2))
            r = 10 ** (cn / 10)
            y = (s * np.sqrt(r) + noise) / np.sqrt(1 + r)
            if not fs80:
                y = y[::2]
            fs = 80e6 if fs80 else 40e6
            blk = int(250e-6 * fs)
            g = np.empty(len(y))
            for k in range(0, len(y), blk):
                g[k:k + blk] = 6.0 / np.sqrt(max(np.mean(abs(y[k:k + blk]) ** 2), 1e-12))
            y = y * g
            # 3 bit: the top three bits of the 4-bit ultrafine lane (cells of 2 half-cells: v*4+2),
            # 4 bit: all four (cells of 1: v*2+1); both clipped to the same range
            step = 4.0 if bits == 3 else 2.0
            def qz(x):  # noqa: E306
                v = np.clip(np.floor(x * 16 / 32 * (4 / step)), -(2 ** (bits - 1)), 2 ** (bits - 1) - 1)
                return step * v + step / 2
            yq = qz(y.real) + 1j * qz(y.imag)
            ph = np.angle(yq) / (2 * np.pi)
            L = 4 if fs80 else 2                         # the same 50 ns
            d = np.zeros(len(ph))
            d[L:] = ((ph[L:] - ph[:-L] + 0.5) % 1.0) - 0.5
            f40 = d / L * fs                             # Hz
            if fs80:
                f40 = (f40[0::2] + f40[1::2]) / 2        # to 40 MS/s
            codes = H.hz_to_code(f40)
            out[f"{'80' if fs80 else '40'} MS/s {bits} bit"] = H.score(codes, tr, reg, Lh)['sinad']
    return (cn, fd), out


def main_quant(jobs):
    conds = [(cn, fd, s) for cn, fd in ((30, 0), (14, 0), (10, 0), (8, 0), (6, 0), (14, 100), (20, 300)) for s in range(SEEDS)]
    with mp.Pool(jobs) as p:
        res = p.map(quant_job, conds)
    names = list(res[0][1])
    lines = ['#14 P3: float angle discriminator over 50 ns, luma SINAD dB (mean over %d seeds)' % SEEDS,
             f"{'C/N':>4s} {'fd':>4s}" + ''.join(f'{n:>16s}' for n in names)]
    for key in dict.fromkeys(k for k, _ in res):
        rs = [r for k, r in res if k == key]
        lines.append(f'{key[0]:4d} {key[1]:4d}' + ''.join(f'{np.mean([r[n] for r in rs]):16.2f}' for n in names))
    txt = '\n'.join(lines)
    print(txt)
    (HERE / 'results' / 'quant.txt').write_text(txt + '\n')


def main(jobs):
    with mp.Pool(jobs) as p:
        res = p.map(job, [(c, s) for c in CONDS for s in range(SEEDS)])
    names = list(res[0][2])
    out = []
    out.append(f'luma SINAD, dB (mean of {SEEDS} seeds, {LINES} lines each)')
    out.append(f"{'condition':>16s}" + ''.join(f'{n[:11]:>12s}' for n in names))
    for c in CONDS:
        rs = [r for nm, _, r in res if nm == c[0]]
        out.append(f'{c[0]:>16s}' + ''.join(f"{np.mean([r[n]['sinad'] for r in rs]):12.2f}" for n in names))
    for metric, label in (('sinad', 'luma SINAD'), ('detail', '3 MHz detail'), ('chroma', 'chroma SNR')):
        out.append('')
        out.append(f'{label}: delta against Rescue Auto, dB: mean [worst seed]')
        out.append(f"{'condition':>16s}" + ''.join(f'{n[:15]:>17s}' for n in names if n != 'rescue'))
        for c in CONDS:
            rs = [r for nm, _, r in res if nm == c[0]]
            cells = []
            for n in names:
                if n == 'rescue':
                    continue
                d = np.array([r[n][metric] - r['rescue'][metric] for r in rs])
                cells.append(f'{d.mean():+7.2f} [{d.min():+6.2f}]')
            out.append(f'{c[0]:>16s}' + ''.join(f'{x:>17s}' for x in cells))
    out.append('')
    out.append('bad-sync lines (share, mean)')
    out.append(f"{'condition':>16s}" + ''.join(f'{n[:11]:>12s}' for n in names))
    for c in CONDS:
        rs = [r for nm, _, r in res if nm == c[0]]
        out.append(f'{c[0]:>16s}' + ''.join(f"{np.mean([r[n]['badsync'] for r in rs]):12.2f}" for n in names))
    txt = '\n'.join(out)
    print(txt)
    (HERE / 'results' / 'compare.txt').write_text(txt + '\n')


if __name__ == '__main__':
    args = [a for a in sys.argv[1:] if a != 'quant']
    jobs = int(args[0]) if args else 4
    (HERE / 'results').mkdir(exist_ok=True)
    if 'quant' in sys.argv:
        main_quant(jobs)
    else:
        main(jobs)
