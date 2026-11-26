"""Triversity research harness (issues #13, #14): one composite test signal, the
C5 channel, 3-bit I/Q and the repository's bit-exact demodulators, scored the
same way for every algorithm. Self-contained: it does not need C5VRX's
research/sim.py, so its absolute numbers differ from the fading studies in
fpga/sim/fading (another raster, channel filter and score); compare algorithms
on the same signal only.

Signal (80 MHz complex baseband, 40 MS/s after the C5):
  NTSC or PAL lines with sync, colour burst, a luma ramp, multiburst packets at
  1 / 2 / 3 MHz (20 IRE), colour bars (chroma 40 IRE p-p at 0 / 120 / 240 deg)
  and a flat grey area; low-passed to 5 MHz, FM with the porch at 0 Hz and
  DEV_PP for 140 IRE (x 0.7 as eval_model).
Channel per C5: Rayleigh fading (sum of sinusoids, fd Hz) or none, an optional
  dropout (a span of zero signal), own LO phase / offset, AWGN in the channel
  filter at C/N, the 250 us block AGC to radius 6 cells and the 3-bit lane
  (mrc3_model.to_raw3).
Demodulated by mrc3_model (combiner, angle phi at 40 MS/s, discriminator,
  Rescue Auto), d3_model (causal D3) or a candidate working on the same phi.
Score (score()): codes -> vid_sync's luma (sum of 8 codes) against the same
  luma of the noise-free instantaneous frequency, best delay, least squares
  gain / offset, over the active picture:
  sinad    luma SINAD, dB
  detail   3 MHz multiburst amplitude / truth, dB (0: kept)
  chroma   colour-bar chroma SNR, dB (complex error at fsc against the truth)
  chphase  mean |phase error| of the bars, degrees
  badsync  share of lines whose sync tip is not clearly below the porch
"""
import numpy as np
from scipy import signal as sg
import sys
from pathlib import Path
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / 'model'))
import mrc3_model as M  # noqa: E402
import d3_model as D3  # noqa: E402

F80, FS = 80e6, 40e6
DEV_PP, PORCH_HZ = 8e6, 0.0
STD = {'NTSC': dict(L=63.5556e-6, fsc=3.579545e6, act0=10.9e-6),
       'PAL': dict(L=64.0e-6, fsc=4.43361875e6, act0=12.0e-6)}
CHAN = sg.butter(4, 9e6, fs=F80, output='sos')            # the C5's channel filter (assumed, +-9 MHz)
SRC_LP = sg.firwin(81, 5e6, fs=F80)
TICK = 0.0                                                  # porch in IRE


def picture(std, n_lines):
    """IRE at 80 MHz and a per-sample region map: 0 blank, 1 active, 2 multiburst 3 MHz,
    3 colour bars, 4 sync tip window, 5 porch window."""
    p = STD[std]
    L = int(round(p['L'] * F80))
    t = np.arange(L) / F80
    lines, regs = [], []
    for ln in range(n_lines):
        v = np.zeros(L); r = np.zeros(L, np.int8)
        sync = t < 4.7e-6
        v[sync] = -40
        r[(t > 1.0e-6) & (t < 3.6e-6)] = 4
        r[(t > 5.6e-6) & (t < 8.6e-6)] = 5
        burst = (t > 5.3e-6) & (t < 7.8e-6)
        ph = 2 * np.pi * p['fsc'] * (t + ln * p['L'])        # continuous subcarrier
        bph = np.pi if std == 'NTSC' else np.pi + (np.pi / 4 if ln % 2 else -np.pi / 4)
        v[burst] += 20 * np.sin(ph[burst] + bph)
        a0 = p['act0']
        x = (t - a0) / (p['L'] - a0 - 1.5e-6)                # 0..1 over the active line
        act = (x >= 0) & (x < 1)
        seg = ln % 4
        if seg == 0:                                         # ramp
            v[act] = 10 + 80 * x[act]
        elif seg == 1:                                       # multiburst 1 / 2 / 3 MHz around 50 IRE
            v[act] = 50
            for i, f in enumerate((1e6, 2e6, 3e6)):
                m = act & (x >= 0.05 + 0.3 * i) & (x < 0.3 + 0.3 * i)
                v[m] += 10 * np.sin(2 * np.pi * f * t[m])
                if f == 3e6:
                    r[m] = 2
        elif seg == 2:                                       # colour bars, 3 hues
            v[act] = 50
            for i, hue in enumerate((0.0, 2.0944, 4.18879)):
                m = act & (x >= 0.05 + 0.3 * i) & (x < 0.3 + 0.3 * i)
                vs = -1 if (std == 'PAL' and ln % 2) else 1
                v[m] += 20 * np.sin(ph[m] + vs * hue)
                r[m] = 3
        else:                                                # flat grey
            v[act] = 35
        r[act & (r == 0)] = 1
        lines.append(v); regs.append(r)
    return np.concatenate(lines), np.concatenate(regs), L


def rayleigh(n, fd, rng, paths=16):
    t = np.arange(n) / F80
    h = np.zeros(n, complex)
    for _ in range(paths):
        a = rng.uniform(0, 2 * np.pi)
        h += np.exp(1j * (2 * np.pi * fd * np.cos(a) * t + rng.uniform(0, 2 * np.pi)))
    return h / np.sqrt(paths)


def source(std='NTSC', n_lines=96):
    ire, reg, L = picture(std, n_lines)
    src = sg.lfilter(SRC_LP, 1, ire)
    src = np.roll(src, -40)                                  # the FIR's delay
    freq = PORCH_HZ + 0.7 * src / 140 * DEV_PP
    z80 = np.exp(2j * np.pi * np.cumsum(freq) / F80)
    z80 = sg.sosfilt(CHAN, z80); z80 /= np.sqrt(np.mean(abs(z80) ** 2))
    truth = freq[::2]                                       # instantaneous frequency at 40 MS/s
    return z80, truth, reg[::2], L // 2


def branch(z80, cn, rng, fd=0.0, dropout=None, agc_us=250.0, bits=3):
    """One C5: fading, dropout (start, length in 40 MS/s samples), LO, AWGN, AGC, quantizer.
    Returns 6-bit raw samples (bits = 3) or the AGC'd complex samples (bits = None)."""
    n = len(z80)
    h = rayleigh(n, fd, rng) if fd else np.ones(n, complex)
    if dropout is not None:
        s0, ln = dropout
        h[2 * s0:2 * (s0 + ln)] = 0
    s = z80 * h * np.exp(1j * (rng.uniform(0, 2 * np.pi) + 2 * np.pi * rng.uniform(-10e3, 10e3) * np.arange(n) / F80))
    noise = sg.sosfilt(CHAN, (rng.normal(size=n) + 1j * rng.normal(size=n)) / np.sqrt(2))
    noise /= np.sqrt(np.mean(abs(noise) ** 2))
    r = 10 ** (cn / 10)
    y = ((s * np.sqrt(r) + noise) / np.sqrt(1 + r))[::2]
    blk = int(agc_us * 1e-6 * FS)
    g = np.empty(len(y))
    for k in range(0, len(y), blk):
        g[k:k + blk] = 6.0 / np.sqrt(max(np.mean(abs(y[k:k + blk]) ** 2), 1e-12))
    y = y * g
    if bits is None:
        return y
    return M.to_raw3(y)


def cells(raw):
    """Cell centres of a 6-bit sample (I, Q in half ultrafine cells, -14..14)."""
    def c(v):
        v = v & 7
        v = np.where(v >= 4, v - 8, v)
        return 4 * v + 2
    raw = np.asarray(raw, np.int64)
    return c(raw >> 3) + 1j * c(raw)


# ---- the code mapping (mrc3_model.disc50): frequency in 2^-16 turn per 25 ns -> code ----
def f_to_code(f16):
    step = np.asarray(f16, float) / 32.0                   # 1024ths of a turn per 50 ns
    return np.clip(np.floor((105 * step + 32896) / 1280), 0, 63)


def hz_to_code(hz):
    return f_to_code(hz / FS * 65536)


# ---- baselines ----
def baselines(raws):
    out = {}
    codes, phi = M.run(raws, disc=True, return_phi=True)
    out['disc'] = codes.astype(float)
    r, act = M.run(raws, disc=True, rescue=1, return_act=True)
    out['rescue'] = r.astype(float)
    out['_act'] = act.astype(bool)                     # where Rescue Auto runs its PLL (not scored)
    valid = np.ones(len(phi), np.bool_)
    clicks, steady = D3.evidence(phi, valid)
    out['d3'] = D3.estimate(phi, valid, clicks, steady)[0].astype(float)
    return out, phi


# ---- score ----
def _box8(x):
    return np.convolve(x, np.ones(8), 'full')[:len(x)]


def _iq_at(x, f, idx, n):
    """Complex amplitude of x at f over consecutive runs of idx (per run)."""
    t = np.arange(len(x)) / FS
    m = x * np.exp(-2j * np.pi * f * t)
    runs = np.split(idx, np.nonzero(np.diff(idx) != 1)[0] + 1)
    return np.array([m[r].mean() for r in runs if len(r) >= n])


def score(codes, truth_hz, reg, Lh, max_lag=48):
    tc = hz_to_code(truth_hz).astype(float)
    # unquantized truth for the luma
    tcf = (105 * (truth_hz / FS * 65536 / 32.0) + 32896) / 1280
    yo, yt = _box8(codes), _box8(tcf)
    act = np.nonzero((reg == 1) | (reg == 2) | (reg == 3))[0]
    act = act[(act > 200) & (act < len(codes) - 200)]
    best = None
    for lag in range(0, max_lag):
        a = yo[act + lag]; b = yt[act]
        c = np.corrcoef(a, b)[0, 1]
        if best is None or c > best[0]:
            best = (c, lag)
    lag = best[1]
    a = yo[act + lag]; b = yt[act]
    A = np.vstack([b, np.ones_like(b)]).T
    (gn, off), *_ = np.linalg.lstsq(A, a, rcond=None)
    err = a - (gn * b + off)
    sinad = 10 * np.log10(np.var(b) * gn ** 2 / np.mean(err ** 2))
    # 3 MHz detail and chroma, on the raw codes (no box filter), delay-aligned
    sh = lambda x: np.roll(x, -lag)  # noqa: E731
    c0 = sh(codes - codes.mean())
    t0 = tcf - tcf.mean()
    mb = np.nonzero(reg == 2)[0]
    d_o = np.abs(_iq_at(c0, 3e6, mb, 50)); d_t = np.abs(_iq_at(t0, 3e6, mb, 50))
    detail = 20 * np.log10(np.mean(d_o) / max(np.mean(d_t), 1e-9))
    cb = np.nonzero(reg == 3)[0]
    fsc = 3.579545e6 if Lh == int(round(63.5556e-6 * FS)) else 4.43361875e6
    co = _iq_at(c0, fsc, cb, 50); ct = _iq_at(t0, fsc, cb, 50)
    # common gain/phase of the chain removed (one complex factor), then per-bar error
    k = np.vdot(ct, co) / np.vdot(ct, ct)
    e = co / k - ct
    chroma = 10 * np.log10(np.mean(abs(ct) ** 2) / max(np.mean(abs(e) ** 2), 1e-12))
    chphase = float(np.degrees(np.mean(np.abs(np.angle((co / k) / ct)))))
    # sync: per line, tip window clearly (> half the true depth) below the porch window
    tip = reg == 4; por = reg == 5
    nl = len(codes) // Lh
    bad = 0; tot = 0
    depth = np.mean(tcf[por]) - np.mean(tcf[tip])
    for ln in range(2, nl - 1):
        s = slice(ln * Lh, (ln + 1) * Lh)
        ti = yo[s][tip[s]] / 8; pi = yo[s][por[s]] / 8
        if len(ti) == 0:
            continue
        tot += 1
        ti = np.roll(yo, -lag)[s][tip[s]] / 8; pi = np.roll(yo, -lag)[s][por[s]] / 8
        if np.median(pi) - np.median(ti) < 0.5 * depth * gn or np.mean(ti > np.median(pi) - 0.25 * depth * gn) > 0.25:
            bad += 1
    return dict(sinad=sinad, detail=detail, chroma=chroma, chphase=chphase, badsync=bad / max(tot, 1), lag=lag)
