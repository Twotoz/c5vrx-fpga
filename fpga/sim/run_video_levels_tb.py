"""Triversity: video levels and gain through fades (issue #12).

A synthetic NTSC signal in demodulator codes (sync tip, porch, a dark grey
scene with a few bright bars, serrated vertical sync) drives the RTL vid_sync.
Scenarios (fades start around a field's vertical sync, where the gain is
computed):

  darkfade  10 ms near the sync tip (Keep lock off / on): the porch - tip
            collapses while the line lock is still high, the #12 gain spike
  fade10    10 ms of mid-scale noise with clicks (Keep lock off / on)
  fades     four 3 ms fades 8 ms apart
  lowline   one active line forced to the sync tip level
  dark      a clean dark scene: the gain must not move
  deviate   a real drop of the depth to 40 % (lower VTX deviation): the gain
            must follow it
  vtxoff    80 ms of RF noise only, then the VTX (Keep lock off / on): levels
            learnt from noise must not keep the real sync out (#15); locked
            within a field, the gain at its nominal value after 3 fields

Checks: k8 stays below 1.25 x its clean value, is back within 3 % 1.5 fields
after a fade and locked, follows a real depth change, and does not move on
clean pictures; the forced-low line is concealed (repeated from the line
before) and no clean line is. Prints black / saturated pixels on the shown
lines and the concealed lines from the fade on.
--rtl <file> runs another vid_sync.v (e.g. the one before #12) for comparison.

    python fpga/sim/run_video_levels_tb.py
"""
import multiprocessing as mp, os, subprocess, sys, tempfile
from pathlib import Path
import numpy as np
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import rtl as rtl_  # noqa: E402

FS = 40e6
L = 2542.222                       # samples a line (63.5556 us)
TIP, PORCH, WHITE = 16, 22, 37     # codes: -40, 0, +100 IRE
FIELD = 262.5 * L


def ntsc(n, dark=False, depth=None, rng=None):
    """n samples of interlaced NTSC (codes, float). depth(k): scale of the
    signal about the porch (1 = nominal)."""
    k = np.arange(n, dtype=np.float64)
    half = np.floor(k / (L / 2)).astype(np.int64)       # half-line index
    hx = k - half * (L / 2)                              # samples into the half-line
    hf = half % 1050                                     # frame of 1050 half-lines
    us = hx / 40.0
    # vertical interval: 6 equalizing, 6 broad, 6 equalizing half-lines from
    # half-line 0 (field 1) and 525 (field 2)
    vh = np.where(hf >= 525, hf - 525, hf)
    eq = (vh < 6) | ((vh >= 12) & (vh < 18))
    br = (vh >= 6) & (vh < 12)
    line_start = (hf % 2) == 0
    line = vh // 2                                       # line in the field (approx.)
    blank = line < 21
    # active picture: from 10.9 us of the line to its end
    lx = np.where(line_start, us, us + L / 80.0)        # us into the full line
    pic = (lx - 10.9) / 52.6
    if dark:
        lev = np.full(n, 0.12)
        lev = np.where((pic > 0.3) & (pic < 0.35), 0.0, lev)       # true black bar
        lev = np.where((pic > 0.6) & (pic < 0.65), 0.35, lev)
    else:
        lev = 0.2 + 0.6 * pic
        lev = np.where(((line // 30) % 3 == 0) & (pic > 0.5) & (pic < 0.7), 1.0, lev)
    v = PORCH + lev * (WHITE - PORCH)
    v = np.where(blank | (lx < 10.9), PORCH, v)
    sync = np.zeros(n, bool)
    sync |= eq & (us < 2.3)
    sync |= br & (us < L / 80.0 - 4.7)
    sync |= ~eq & ~br & line_start & (us < 4.7)
    v = np.where(sync, TIP, v)
    if depth is not None:
        v = PORCH + (v - PORCH) * depth(k)
    if rng is not None:
        v = v + rng.normal(0, 0.8, n)
    return v


def fade(v, rng, start, length):
    """A noise fade: the signal sinks into mid-scale noise with clicks (sin^2 envelope)."""
    k = np.arange(len(v))
    x = (k - start) / length
    a = np.where((x > 0) & (x < 1), np.sin(np.pi * np.clip(x, 0, 1)) ** 2, 0.0)
    noise = rng.normal(0, 12, len(v))
    clicks = (rng.random(len(v)) < 0.004) * rng.choice([-30, 30], len(v))
    return (1 - a) * v + a * (27 + noise + clicks)


def dark_fade(v, rng, start, length):
    """A fade whose codes sit near the sync tip (0.3 ms ramps): the slicer sees one long
    pulse, the measured porch - tip collapses while the line lock is still high."""
    k = np.arange(len(v))
    a = np.clip(np.minimum((k - start) / 12000, (start + length - k) / 12000), 0, 1)
    return (1 - a) * v + a * (TIP + 1 + rng.normal(0, 2.5, len(v)))


def lowline(v, at_line):
    k = np.arange(len(v))
    s = int(at_line * L)
    m = (k >= s + int(10.9 * 40)) & (k < s + int(L))
    v = v.copy(); v[m] = TIP
    return v


def run(tb, codes, keep):
    with tempfile.TemporaryDirectory() as t:
        t = Path(t)
        (t / 'code.hex').write_text('\n'.join(f'{c:02x}' for c in codes) + '\n')
        subprocess.run(['vvp', '-n', str(tb), f'+n={len(codes)}', f'+keep={keep}'], cwd=t, check=True,
                       stdout=subprocess.DEVNULL)
        return np.loadtxt(t / 'lv.txt', dtype=np.int64, ndmin=2)


EVENT = 5 * FIELD                  # fades and changes from here; the gain has settled by field 4
FIELDS = 7.9
DEVIATE = 0.4                      # a real drop of the depth (below half: the slow path)
# (name, keep lock)
RUNS = [('darkfade', 0), ('darkfade', 1), ('fade10', 0), ('fade10', 1),
        ('fades', 0), ('lowline', 0), ('dark', 0), ('deviate', 0), ('vtxoff', 0), ('vtxoff', 1)]
VTX_OFF = int(0.080 * FS)          # vtxoff: RF noise only before the VTX appears
K8_NOMINAL = 26112 / ((PORCH - TIP) * 8)
SCENARIOS = sorted({r[0] for r in RUNS})


def scenario(name):
    rng = np.random.default_rng(12)
    n = int(FIELDS * FIELD)
    if name == 'vtxoff':
        n = VTX_OFF + int(5 * FIELD)
    depth = (lambda k: np.where(k < EVENT, 1.0, DEVIATE)) if name == 'deviate' else None
    v = ntsc(n, dark=name == 'dark', depth=depth, rng=rng)
    end = None
    if name == 'darkfade':                     # deep from 3 lines before the field's vertical sync
        s, ln = int(EVENT - 3 * L), int(0.010 * FS); v = dark_fade(v, rng, s, ln); end = s + ln
    elif name == 'fade10':
        s, ln = int(EVENT - 0.25 * FIELD), int(0.010 * FS); v = fade(v, rng, s, ln); end = s + ln
    elif name == 'fades':
        for i in range(4):
            s, ln = int(EVENT - 0.5 * FIELD) + i * int(0.008 * FS), int(0.003 * FS)
            v = fade(v, rng, s, ln); end = s + ln
    elif name == 'vtxoff':                     # noise only (as the fade's), then the VTX
        v[:VTX_OFF] = 27 + rng.normal(0, 12, VTX_OFF) + (rng.random(VTX_OFF) < 0.004) * rng.choice([-30, 30], VTX_OFF)
    elif name == 'lowline':
        v = lowline(v, EVENT / L + 100)
    return np.clip(np.round(v), 0, 63).astype(int), end


def job(a):
    tb, name, keep = a
    codes, end = scenario(name)
    return name, keep, end, run(tb, codes, keep)


def check(name, keep, end, a):
    smp, lk, k8 = a[:, 0], a[:, 2], a[:, 3]
    if name == 'vtxoff':
        # the levels learnt from noise must not keep the real sync out (issue #15)
        on = smp >= VTX_OFF
        first = smp[on & (lk == 1)]
        acq = (first[0] - VTX_OFF) / FIELD if len(first) else float('inf')
        tail = smp > VTX_OFF + 3 * FIELD
        fail = []
        if acq > 1.0:
            fail.append(f'locked {acq:.2f} fields after the VTX came on')
        if (lk[tail] == 0).any():
            fail.append('unlocked 3 fields after the VTX came on')
        if np.abs(k8[tail] - K8_NOMINAL).max() > 0.04 * K8_NOMINAL:
            fail.append(f'k8 {k8[tail].min()}..{k8[tail].max()} vs ~{K8_NOMINAL:.0f} 3 fields after the VTX came on')
        sh = (a[:, 9] == 1) & (a[:, 6] > 0)
        print(f'{name:>8s} {keep:4d} {"-":>9s} {int(k8[on].min()):6d}..{int(k8[on].max()):<6d} {acq:12.2f} '
              f'{int(a[on & sh, 7].sum()):9d} {int(a[on & sh, 8].sum()):7d} {int((on & ~sh & (a[:, 6] > 0)).sum()):9d} '
              f'{int((lk[on] == 0).sum()):9d}', flush=True)
        return [f'{name} keep{keep}: {f}' for f in fail]
    pre = (smp > 4 * FIELD) & (smp < EVENT - 0.6 * FIELD)
    k8c = int(np.median(k8[pre]))
    after = smp >= EVENT - 0.6 * FIELD
    kmin, kmax = int(k8[after].min()), int(k8[after].max())
    shown = (a[:, 9] == 1) & (a[:, 6] > 0)
    blk, sat = int(a[after & shown, 7].sum()), int(a[after & shown, 8].sum())
    conc = int((after & (a[:, 9] == 0) & (a[:, 6] > 0)).sum())
    fail, rec = [], '-'
    if end is not None:
        if kmax > 1.25 * k8c:
            fail.append(f'k8 {kmax} > 1.25 x {k8c}')
        moved = np.nonzero((smp > end) & (np.abs(k8 - k8c) > 0.03 * k8c))[0]
        rec = f'{(smp[moved[-1]] - end) / FIELD:.1f}' if len(moved) else '0'
        tail = smp > end + 1.5 * FIELD
        if (np.abs(k8[tail] - k8c) > 0.03 * k8c).any():
            fail.append(f'k8 {k8[tail][-1]} not back at {k8c} 1.5 fields after the fade')
        if (lk[tail] == 0).any():
            fail.append('unlocked 1.5 fields after the fade')
    elif name == 'deviate':
        want = k8c / DEVIATE
        rec = str(int(k8[-1]))
        if abs(k8[-1] - want) > 0.05 * want:
            fail.append(f'k8 {k8[-1]} did not follow the depth (want ~{want:.0f})')
    if name == 'lowline' and conc != 1:
        fail.append(f'{conc} lines concealed, want the forced line only')
    if name in ('dark', 'deviate') and conc:
        fail.append(f'{conc} clean lines concealed')
    if end is None and name != 'deviate':
        if kmax > 1.03 * k8c or kmin < 0.97 * k8c:
            fail.append(f'k8 moved without a fade ({kmin}..{kmax} vs {k8c})')
        if (lk[after] == 0).any():
            fail.append('lost lock')
    unl = int((lk[after] == 0).sum())
    print(f'{name:>8s} {keep:4d} {k8c:9d} {kmin:6d}..{kmax:<6d} {rec:>12s} {blk:9d} {sat:7d} {conc:9d} {unl:9d}', flush=True)
    return [f'{name} keep{keep}: {f}' for f in fail]


def main():
    # --rtl <vid_sync.v>: another vid_sync (e.g. the one before #12) for a comparison
    srcs = rtl_.src('vid_sync.v')
    if '--rtl' in sys.argv:
        srcs[0] = sys.argv[sys.argv.index('--rtl') + 1]
    only = [a for a in sys.argv[1:] if a in SCENARIOS]
    tb = Path(tempfile.mkdtemp()) / 'tb'
    subprocess.run(['iverilog', '-g2012', *rtl_.inc(), '-o', str(tb), str(HERE / 'tb_video_levels.v'), *srcs], check=True)
    runs = [(str(tb), n, k) for n, k in RUNS if not only or n in only]
    print(f"{'scenario':>8s} keep  k8 clean   k8 min..max  recov fields  black px  sat px  concealed  unlocked")
    fail = []
    with mp.Pool(min(len(runs), os.cpu_count() or 1)) as p:
        for name, keep, end, a in p.imap(job, runs):
            fail += check(name, keep, end, a)
    if fail:
        print('FAIL\n  ' + '\n  '.join(fail))
        sys.exit(1)
    print('PASS: the video gain holds through fades and follows real level changes')


if __name__ == '__main__':
    main()
