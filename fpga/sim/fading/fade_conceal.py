"""Fading study 5, one C5: temporal concealment. Per source line the discriminator's
clicks are counted; a line with more than T clicks takes its codes from the same line
two frames earlier (code domain: the NTSC colour phase repeats after 2 frames; in RTL
this would be the previous field after the colour decoder). Scene: the static colour
test picture (best case) and a moving one (the picture shifted 2 px a field).
usage: python fade_conceal.py <triversity/fpga> [jobs]"""
import multiprocessing as mp, sys
from pathlib import Path
import numpy as np
from scipy import signal as sg
FPGA = Path(sys.argv[1]); JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 4
sys.path.insert(0, str(FPGA / 'model')); sys.path.insert(0, str(FPGA / 'sim'))
import eval3, mrc3_model as M, chroma_model as C
E = eval3.E
LINE = 40e6 / 15734.264            # samples a line
FRAME2 = int(round(2 * 525 * LINE))  # two frames
FIELDS = 8


def clicks(phis):
    t = ((phis.astype(np.int64) + 32768) >> 6) & 1023
    d = ((np.diff(t) + 512) & 1023) - 512
    c = np.zeros(len(phis), np.int64); c[1:] = ((d < M.DISC_WL // 2) | (d > M.DISC_WH // 2))
    return c


def conceal(codes, clk, thr):
    out = codes.copy()
    n = len(codes); nl = int(n / LINE)
    replaced = 0
    for l in range(nl):
        a, b = int(l * LINE), int((l + 1) * LINE)
        if a >= FRAME2 and clk[a:b].sum() > thr:
            out[a:b] = out[a - FRAME2:b - FRAME2]; replaced += 1
    return out, replaced / max(nl, 1)


def job(a):
    cn, fd, seed, moving = a
    rgb = C.test_picture(240)
    ire, region = C.source('NTSC', rgb, fields=FIELDS, seed=seed)
    if moving:                              # pan: 2 px a field (approx: delay the line content)
        L = int(round(LINE)); fl = int(round(262.5 * LINE))
        for f in range(1, FIELDS):
            seg = ire[f * fl:(f + 1) * fl].copy()
            ire[f * fl:(f + 1) * fl] = np.roll(seg, 2 * f * 3)        # ~3 samples a pixel
    src = sg.lfilter(sg.firwin(81, 6e6, fs=80e6), 1, np.repeat(ire, 2))
    S = E.sim
    z80 = sg.sosfilt(S.CHAN, np.exp(2j * np.pi * np.cumsum(S.PORCH_HZ + 0.7 * src / 140 * S.DEV_PP) / 80e6))
    z80 /= np.sqrt(np.mean(abs(z80) ** 2))
    y = eval3.branch_y(z80, cn, np.random.default_rng(seed), fd)
    raw = M.to_raw3(y[0]); clean = M.to_raw3(y[1])
    codes, phis = M.run([raw], disc=True, rescue=1, return_phi=True)
    codes = codes.astype(np.int64)
    ref = M.run([clean], disc=True)
    k0 = FRAME2 + int(LINE * 20)            # score after two frames (concealment possible)
    c = dict(truth=sg.sosfilt(E.sim.GOGGLE, ire)[k0:], region=region[k0:], standard='NTSC')
    out = {}
    r = E.sim.measure(c, codes[k0:], ref[k0:]); out['auto'] = (r['picture'], r['sinad'], 0.0)
    clk = clicks(phis)
    for thr in (3, 10, 30):
        cc, frac = conceal(codes, clk, thr)
        r = E.sim.measure(c, cc[k0:], ref[k0:]); out[f'conceal{thr}'] = (r['picture'], r['sinad'], frac)
    return (cn, fd, moving), out


def main():
    jobs = [(cn, fd, 950 + 5 * s + cn + fd, mv) for mv in (0, 1) for fd in (30, 100, 300) for cn in (10, 14, 20) for s in range(2)]
    with mp.Pool(JOBS) as p:
        res = p.map(job, jobs)
    names = list(res[0][1].keys())
    for mv in (0, 1):
        print(('moving' if mv else 'static') + ' scene, one C5, Rayleigh fading: picture lock / SINAD dB (share of lines concealed)')
        print(f"{'fd':>4s} {'C/N':>4s}" + ''.join(f'{n:>22s}' for n in names))
        for fd in (30, 100, 300):
            for cn in (10, 14, 20):
                rs = [r for k, r in res if k == (cn, fd, mv)]
                print(f'{fd:4d} {cn:4d}' + ''.join(f"{np.mean([r[n][0] for r in rs]):.2f}/{np.mean([r[n][1] for r in rs]):5.1f} ({np.mean([r[n][2] for r in rs]):4.0%})".rjust(22) for n in names), flush=True)


if __name__ == '__main__':
    main()
