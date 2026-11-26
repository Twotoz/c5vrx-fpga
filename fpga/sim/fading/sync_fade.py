"""Sync under Rayleigh fading, one C5: the share of lines without lock (after the first
lock) in rtl/video/vid_sync.v (bit-exact RTL, iverilog), Keep lock off / on, on the
plain discriminator codes and on the amplitude-gated codes (fade_study.gate_hold).
usage: python sync_fade.py <triversity/fpga> [jobs]"""
import multiprocessing as mp, subprocess, sys, tempfile
from pathlib import Path
import numpy as np
from scipy import signal as sg
FPGA = Path(sys.argv[1]); JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 4
sys.path.insert(0, str(FPGA / 'model')); sys.path.insert(0, str(FPGA / 'sim'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import eval3, mrc3_model as M, chroma_model as C, rtl as rtl_
from fade_study import amp2, gate_hold
E = eval3.E
TB = Path(__file__).resolve().parent / 'sync_fade_tb'
FIELDS = 8


def codes_for(cn, fd, seed):
    ire, _ = C.source('NTSC', C.test_picture(240), fields=FIELDS, seed=seed)
    src = sg.lfilter(sg.firwin(81, 6e6, fs=80e6), 1, np.repeat(ire, 2))
    S = E.sim
    z80 = sg.sosfilt(S.CHAN, np.exp(2j * np.pi * np.cumsum(S.PORCH_HZ + 0.7 * src / 140 * S.DEV_PP) / 80e6))
    z80 /= np.sqrt(np.mean(abs(z80) ** 2))
    y = eval3.branch_y(z80, cn, np.random.default_rng(seed), fd)
    raw = M.to_raw3(y[0])
    codes = M.run([raw], disc=True, rescue=1).astype(int)
    return codes, gate_hold(codes, amp2(raw), 8)


def vsync(codes, keep):
    with tempfile.TemporaryDirectory() as t:
        t = Path(t)
        (t / 'code.hex').write_text('\n'.join(f'{c:02x}' for c in codes) + '\n')
        subprocess.run(['vvp', '-n', str(TB), f'+n={len(codes)}', f'+keep={keep}', '+adapt=0'],
                       cwd=t, check=True, capture_output=True)
        return np.loadtxt(t / 'ls.txt', dtype=np.int64, ndmin=2)


def job(a):
    cn, fd, seed = a
    plain, gated = codes_for(cn, fd, seed)
    out = {}
    for name, codes in (('plain', plain), ('gated', gated)):
        for keep in (0, 1):
            ls = vsync(codes, keep)
            lk = ls[:, 2] == 1
            first = int(np.argmax(lk)) if lk.any() else len(lk)
            out[f'{name} keep{keep}'] = float(np.mean(~lk[first:])) if first < len(lk) else 1.0
    return (cn, fd), out


def main():
    subprocess.run(['iverilog', '-g2012', *rtl_.inc(), '-o', str(TB), str(FPGA / 'sim' / 'tb_vsync.v'), *rtl_.src('vid_sync.v')], check=True)
    jobs = [(cn, fd, 700 + 3 * s + cn + fd) for fd in (30, 100, 300) for cn in (6, 10, 14) for s in range(2)]
    with mp.Pool(JOBS) as p:
        res = p.map(job, jobs)
    names = list(res[0][1].keys())
    print('one C5, Rayleigh fading, Rescue Auto: share of lines without lock (after the first lock)')
    print(f"{'fd':>4s} {'C/N':>4s}" + ''.join(f'{n:>14s}' for n in names))
    for fd in (30, 100, 300):
        for cn in (6, 10, 14):
            rs = [r for k, r in res if k == (cn, fd)]
            print(f'{fd:4d} {cn:4d}' + ''.join(f"{np.mean([r[n] for r in rs]):14.1%}" for n in names))


if __name__ == '__main__':
    main()
