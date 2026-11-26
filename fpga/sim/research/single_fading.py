"""One C5 (Single) under Rayleigh fading: main against this branch, from IQ to the
displayed lines. The same faded IQ goes through
  demod   main's mrc3_model (old Rescue Auto, 13 ms window) or this branch's
          (look-ahead Rescue Auto), both the menu default (Rescue Auto)
  video   main's vid_sync.v + chroma.v or this branch's (level / gain
          qualification, line concealment, sync deglitch), Keep lock off,
          default LCD build (spatial concealment)
and each combination is scored against a noise-free run of the same vid_sync
on the same signal, line by line (the line's mean luma as displayed: a
concealed line shows the line before):
  damaged   displayed lines off by more than 16 / 255 in mean luma
  black     displayed lines with more than half their pixels black (RGB 0)
  unlocked  lines without video lock
  k8        the gain range (clean value in brackets)

    python fpga/sim/research/single_fading.py [jobs] [--base origin/main]

Needs git (the base revision's files are taken with git show). Simulation only.
"""
import multiprocessing as mp, subprocess, sys, tempfile, importlib.util
from pathlib import Path
import numpy as np
from scipy import signal as sg
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE.parent))
import iq_harness as H  # noqa: E402
import run_video_levels_tb as V  # noqa: E402
import rtl as rtl_  # noqa: E402

BASE = sys.argv[sys.argv.index('--base') + 1] if '--base' in sys.argv else 'origin/main'
FIELDS = 6.5
SCORE_FROM = 4.0 * V.FIELD             # the gain and lock have settled by field 4
CONDS = [(cn, fd) for cn in (10, 16) for fd in (30, 100, 300)]
SEEDS = 2
WORK = Path(tempfile.mkdtemp(prefix='single_fading_'))

TB = r'''
`timescale 1ns/1ps
module tb;
    reg clk = 0, rst = 1; always #12.5 clk = ~clk;
    reg [5:0] mem [0:6000000]; reg [5:0] code = 0; integer n, k, fl;
    wire wr_en, locked; wire [10:0] wr_addr; wire [15:0] wr_data; wire [7:0] wr_gray; wire [8:0] line_info;
    vid_sync u_vs (.clk(clk), .rst(rst), .code(code), .keep_lock(1'b0), .adapt(1'b0), .ans(1'b0),
                   .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data), .wr_gray(wr_gray), .line_info(line_info), .locked(locked));
    integer nwr = 0, nblk = 0, gsum = 0;
    initial begin
        if (!$value$plusargs("n=%d", n)) n = 1000;
        $readmemh("code.hex", mem); fl = $fopen("ln.txt", "w");
        #100 rst = 0;
        for (k = 0; k < n; k = k + 1) begin @(posedge clk); code <= mem[k]; end
        $fclose(fl); $finish;
    end
    always @(posedge clk) begin
        if (!rst && u_vs.hc == 12'd1) begin
            $fwrite(fl, "%0d %0d %0d %0d %0d %0d %0d\n", k, locked, u_vs.k8, line_info[8], nwr, nblk, gsum);
            nwr = 0; nblk = 0; gsum = 0;
        end
        if (wr_en) begin nwr = nwr + 1; gsum = gsum + wr_gray; if (wr_data == 16'h0) nblk = nblk + 1; end
    end
endmodule
'''


def git_show(path, dst):
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(subprocess.run(['git', '-C', str(ROOT), 'show', f'{BASE}:{path}'], check=True,
                                  capture_output=True, text=True).stdout)
    return dst


def build():
    """Two simulators (base / this branch vid_sync) and the base demodulator model."""
    (WORK / 'tb.v').write_text(TB)
    sims = {}
    rx = [str(p) for p in rtl_.src('mul_dsp.v', 'cordic_iter.v', 'addsub.v')]
    base_vs = [git_show('fpga/rtl/video/vid_sync.v', WORK / 'base' / 'vid_sync.v'),
               git_show('fpga/rtl/video/chroma.v', WORK / 'base' / 'chroma.v')]
    for name, srcs in (('base', [str(p) for p in base_vs] + rx), ('new', rtl_.src('vid_sync.v'))):
        out = WORK / f'sim_{name}'
        subprocess.run(['iverilog', '-g2012', *rtl_.inc(), '-s', 'tb', '-o', str(out), str(WORK / 'tb.v'), *srcs], check=True)
        sims[name] = out
    for f in ('mrc3_model.py', 'mrc_model.py'):
        git_show(f'fpga/model/{f}', WORK / 'base_model' / f)
    return sims


def base_model():
    sys.path.insert(0, str(WORK / 'base_model'))
    spec = importlib.util.spec_from_file_location('mrc3_base', WORK / 'base_model' / 'mrc3_model.py')
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    sys.path.pop(0)
    return m


def source():
    """The NTSC test raster (run_video_levels_tb.ntsc) as FM IQ at 80 MHz."""
    n = int(FIELDS * V.FIELD)
    v = V.ntsc(n)                                           # codes, noise-free
    ire = (v - V.PORCH) / (V.PORCH - V.TIP) * 40.0
    src = np.roll(sg.lfilter(H.SRC_LP, 1, np.repeat(ire, 2)), -40)
    z80 = np.exp(2j * np.pi * np.cumsum(H.PORCH_HZ + 0.7 * src / 140 * H.DEV_PP) / H.F80)
    z80 = sg.sosfilt(H.CHAN, z80)
    return z80 / np.sqrt(np.mean(abs(z80) ** 2))


def vsim(sim, codes, tag):
    d = WORK / tag; d.mkdir(exist_ok=True)
    (d / 'code.hex').write_text('\n'.join(f'{c:02x}' for c in codes) + '\n')
    subprocess.run(['vvp', '-n', str(sim), f'+n={len(codes)}'], cwd=d, check=True, stdout=subprocess.DEVNULL)
    a = np.loadtxt(d / 'ln.txt', dtype=np.int64, ndmin=2)
    for f in d.iterdir(): f.unlink()
    d.rmdir()
    return a


def displayed(a):
    """Per line: start sample, locked, k8, displayed mean luma (a concealed / hidden
    line shows the newest shown line), displayed black flag; lines with pixels only."""
    out, last = [], None
    for k, lk, k8, show, nwr, nblk, gs in a:
        if nwr == 0:
            continue
        cur = (gs / nwr, nblk > nwr // 2)
        if show:
            last = cur
        disp = cur if show or last is None else last
        out.append((k, lk, k8, disp[0], disp[1]))
    return np.array(out, dtype=float)


def score(a, ref):
    d, r = displayed(a), displayed(ref)
    d = d[d[:, 0] >= SCORE_FROM]
    idx = np.clip(np.searchsorted(r[:, 0], d[:, 0]), 1, len(r) - 1)
    near = np.where(np.abs(r[idx - 1, 0] - d[:, 0]) < np.abs(r[idx, 0] - d[:, 0]), idx - 1, idx)
    ok = np.abs(r[near, 0] - d[:, 0]) < V.L / 2
    err = np.abs(d[:, 3] - r[near, 3])
    lines = a[a[:, 0] >= SCORE_FROM]
    return dict(damaged=float(np.mean(~ok | (err > 16))), black=float(np.mean(d[:, 4] > 0)),
                unlocked=float(np.mean(lines[:, 1] == 0)), k8min=int(lines[:, 2].min()), k8max=int(lines[:, 2].max()))


def job(a):
    cn, fd, seed, sims = a
    import mrc3_model as M_new
    M_base = base_model()
    z = source()
    rng = np.random.default_rng(seed * 7919 + cn * 101 + fd)
    raw = H.branch(z, cn, rng, fd)
    codes = {'old demod': M_base.run([raw], disc=True, rescue=1), 'new demod': M_new.run([raw], disc=True, rescue=1)}
    res = {}
    for dn, c in codes.items():
        for vn in ('base', 'new'):
            res[(dn, vn)] = vsim(sims[vn], c.astype(int), f'{cn}_{fd}_{seed}_{dn[:3]}_{vn}')
    return (cn, fd, seed), res


def main():
    jobs = int(next((x for x in sys.argv[1:] if x.isdigit()), 4))
    sims = build()
    # noise-free references: the clean codes through each vid_sync
    import mrc3_model as M_new
    z = source()
    clean = M_new.run([H.branch(z, 60, np.random.default_rng(1), 0)], disc=True, rescue=1).astype(int)
    refs = {vn: vsim(sims[vn], clean, f'ref_{vn}') for vn in ('base', 'new')}
    with mp.Pool(jobs) as p:
        res = p.map(job, [(cn, fd, s, sims) for cn, fd in CONDS for s in range(SEEDS)])
    combos = [('old demod', 'base', 'main'), ('new demod', 'new', 'this PR'),
              ('new demod', 'base', 'PR demod only'), ('old demod', 'new', 'PR video only')]
    lines = [f'One C5, Rayleigh fading, {SEEDS} seeds x {FIELDS - SCORE_FROM / V.FIELD:.1f} fields scored, '
             f'base {BASE}. Share of displayed lines (lower is better).',
             f"{'C/N':>4s} {'fd':>4s}  {'':14s} {'damaged':>8s} {'black':>7s} {'unlocked':>9s}   k8 range (clean "
             f"{int(np.median(refs['base'][:, 2]))} main / {int(np.median(refs['new'][:, 2]))} PR)"]
    tot = {c[2]: [] for c in combos}
    for cn, fd in CONDS:
        for dn, vn, label in combos:
            ss = [score(r[(dn, vn)], refs[vn]) for key, r in res if key[:2] == (cn, fd)]
            tot[label] += ss
            lines.append(f'{cn:4d} {fd:4d}  {label:14s} {np.mean([s["damaged"] for s in ss]):8.1%} '
                         f'{np.mean([s["black"] for s in ss]):7.1%} {np.mean([s["unlocked"] for s in ss]):9.1%}   '
                         f'{min(s["k8min"] for s in ss)}..{max(s["k8max"] for s in ss)}')
        lines.append('')
    lines.append('all conditions:')
    for label, ss in tot.items():
        lines.append(f'           {label:14s} {np.mean([s["damaged"] for s in ss]):8.1%} '
                     f'{np.mean([s["black"] for s in ss]):7.1%} {np.mean([s["unlocked"] for s in ss]):9.1%}')
    txt = '\n'.join(lines)
    print(txt)
    (HERE / 'results' / 'single_fading.txt').write_text(txt + '\n')


if __name__ == '__main__':
    main()
