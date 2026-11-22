"""Triversity: what the Signal page's sync switches do, on rtl/video/vid_sync.v
(Icarus Verilog, sim/tb_vsync.v) fed with the demodulator codes of three C5s
(model/chroma_model.chain: channel model, combiner and discriminator,
bit-exact with the RTL), NTSC colour test scene.

Adaptive sync: line-start jitter (ns RMS, against a straight line fitted over
each 64 locked lines) with the switch off / on, per C/N.

Keep lock: 6 dB C/N, six fields with three 10 ms sync dropouts (the codes
replaced by noise: the antenna shadowed), off / on: lines that show the
"no lock" free-run screen.

    python sim/sync_perf.py
"""
import multiprocessing as mp
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE.parent / 'model'))
import rtl as rtl_  # noqa: E402
import chroma_model as C  # noqa: E402

TB = HERE.parent / 'build' / 'sync_perf_tb'
LINE = 40e6 / 15734.264             # NTSC line, 40 MHz clocks
GAP = 400_000                       # 10 ms


def vsync(codes, keep, adapt):
    with tempfile.TemporaryDirectory(dir=HERE.parent / 'build') as t:
        t = Path(t)
        (t / 'code.hex').write_text('\n'.join(f'{c:02x}' for c in codes) + '\n')
        subprocess.run(['vvp', '-n', str(TB), f'+n={len(codes)}', f'+keep={keep}', f'+adapt={adapt}'],
                       cwd=t, check=True, capture_output=True)
        return np.loadtxt(t / 'ls.txt', dtype=np.int64, ndmin=2)     # k, pal, locked, vline per line start


def chain(cn, fields, seed):
    ire, _ = C.source('NTSC', C.test_picture(240), fields=fields, seed=seed)
    n = int(fields * 262.5 * LINE) - 2000
    return C.chain('NTSC', ire[:n + 2000], cn, seed=seed)[:n].copy()


def jitter(ls, lo=150):
    k = ls[lo:, 0].astype(float); lk = ls[lo:, 2] == 1
    res = []
    for s in range(0, len(k) - 64, 64):
        if lk[s:s + 64].all():
            x = np.arange(64)
            res.append(k[s:s + 64] - np.polyval(np.polyfit(x, k[s:s + 64], 1), x))
    return float(np.sqrt(np.mean(np.concatenate(res) ** 2)) * 25.0) if res else float('nan')


def job_adapt(args):
    cn, adapt = args
    return args, jitter(vsync(chain(cn, 2, 3), 0, adapt))


def job_keep(keep):
    codes = chain(6, 6, 5)
    rng = np.random.default_rng(9)
    starts = (900_000, 1_900_000, 2_900_000)
    for a in starts:
        codes[a:a + GAP] = rng.integers(0, 64, GAP)
    ls = vsync(codes, keep, 0)
    k, lk = ls[:, 0], ls[:, 2] == 1
    first = int(np.argmax(lk))                                  # the first lock
    nolock = int(np.count_nonzero(~lk[first:]))
    return keep, nolock


def main():
    subprocess.run(['iverilog', '-g2012', *rtl_.inc(), '-o', str(TB), str(HERE / 'tb_vsync.v'), *rtl_.src('vid_sync.v')], check=True)
    with mp.Pool(int(next((a.split('=')[1] for a in sys.argv if a.startswith('--jobs=')), 2))) as p:
        ra = dict(p.map(job_adapt, [(cn, a) for cn in (0, 3, 6, 12) for a in (0, 1)]))
        rk = p.map(job_keep, (0, 1))
    print('Adaptive sync: line-start jitter, ns RMS (locked lines)')
    for cn in (0, 3, 6, 12):
        print(f'  C/N {cn:3d} dB:  off {ra[(cn, 0)]:6.1f}   on {ra[(cn, 1)]:6.1f}')
    print('Keep lock: 6 dB C/N, three 10 ms sync dropouts')
    for keep, nolock in rk:
        print(f'  {"on " if keep else "off"}: {nolock:5d} lines on the no-lock screen')


if __name__ == '__main__':
    main()
