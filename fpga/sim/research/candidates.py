"""Candidate estimators on the combiner's angle phi (2^-16 turn, 40 MS/s), for
issues #13 (multi-timescale phase differences) and #14 (zubon2003-inspired
amplitude-gated PLL, separate luma / chroma). Float / integer prototypes on the
same phi as the baselines; each returns 6-bit codes with disc50's mapping.

#13
  lag(phi, L)           raw wrapped phase difference over L samples / L. A
                        2 pi slip that completes inside the L samples wraps
                        away (click cancellation), but a true change of more
                        than half a turn over L samples aliases:
                        |f| < FS / (2 L) (L = 4: 5 MHz, L = 8: 2.5 MHz).
  lag_pred(phi, L)      the same against a prediction: wrap(dphi_L - L f_hat)
                        + L f_hat, f_hat the estimate one sample before (a
                        tracker); unaliased around the predicted frequency.
  fuse(phi, L, ...)     the fast path (disc50) except where disc50's click
                        evidence (the D3 window) fires: lag_pred there.
#14
  gated_pll(phi, amp)   a second-order PLL (Rescue's gains) whose phase
                        correction is scaled by the sample's energy relative
                        to its moving mean (zubon2003's fm_demod.v idea):
                        weak samples coast.
  split(phi, ...)       luma from the PLL (low-passed), chroma band from the
                        discriminator (band-passed around fsc), summed.
"""
import numpy as np
from numba import njit
from scipy import signal as sg
import iq_harness as H


def wrap16(x):
    return ((np.asarray(x, np.int64) + 32768) & 65535) - 32768


def lag(phi, L):
    d = np.zeros(len(phi))
    d[L:] = wrap16(phi[L:] - phi[:-L]) / L
    return H.f_to_code(d)


@njit(cache=True)
def _lag_pred(phi, L, alpha):
    n = len(phi)
    f = np.zeros(n)
    fh = 0.0
    for k in range(L, n):
        raw = phi[k] - phi[k - L]
        inn = raw - L * fh
        inn = ((inn + 32768.0) % 65536.0) - 32768.0
        est = fh + inn / L
        f[k] = est
        fh = fh + alpha * (est - fh)       # alpha = 1: the last estimate
    return f


def lag_pred(phi, L, alpha=1.0):
    return H.f_to_code(_lag_pred(np.asarray(phi, np.float64), L, alpha))


@njit(cache=True)
def _clicks(phi):
    """disc50's out-of-window steps (per sample pair), as d3_model.evidence."""
    n = len(phi)
    cl = np.zeros(n, np.bool_)
    s = ((phi[0] + 32768) >> 6) & 1023
    for k in range(0, n - 1, 2):
        t = ((phi[k] + 32768) >> 6) & 1023
        d = ((t - s + 512) & 1023) - 512
        c = not (-312 <= d <= 384)
        step = d if not c else (d * 179) >> 8
        s = (s + step) & 1023
        cl[k] = c; cl[k + 1] = c
    return cl


def fuse(phi, fast, L=4, win=16, alpha=1.0):
    """fast: the fast-path codes (disc50 or Rescue Auto). Within +-win samples of a
    click the candidate L-sample predictive estimate is used instead."""
    cl = _clicks(np.asarray(phi, np.int64)).astype(float)
    near = np.convolve(cl, np.ones(2 * win + 1), 'same') > 0
    slow = lag_pred(phi, L, alpha)
    return np.where(near, slow, fast)


@njit(cache=True)
def _gated_pll(phi, amp, kp_sh, ki_sh, mean_sh, gfloor):
    n = len(phi)
    out = np.zeros(n)
    th = 0.0; F = 0.0; m = 0.0
    for k in range(n):
        m += (amp[k] - m) / (1 << mean_sh)
        g = amp[k] / m if m > 0 else 1.0
        g = min(1.0, max(gfloor, g))
        e = ((phi[k] - th + 32768.0) % 65536.0) - 32768.0
        e *= g
        fo = F / (1 << ki_sh) + e / (1 << kp_sh)
        F += e
        th = (th + fo) % 65536.0
        out[k] = fo
    return out


def gated_pll(phi, amp, gate=True, mean_sh=6, gfloor=0.0):
    """Rescue's loop gains (kp 1/4, ki 1/128 per 2^-12 turn: the same in 2^-16 units).
    gate=False: the plain PLL (Rescue On, float)."""
    a = np.asarray(amp, float) if gate else np.ones(len(phi))
    fo = _gated_pll(np.asarray(phi, np.float64), a, 2, 7, mean_sh, gfloor)
    return H.f_to_code((fo + np.concatenate([[0.0], fo[:-1]])) / 2)


def split(luma_codes, chroma_codes, fsc, ntaps=33):
    """Luma below ~2.5 MHz from luma_codes, the band around fsc from chroma_codes."""
    lp = sg.firwin(ntaps, 2.5e6, fs=H.FS)
    bp = sg.firwin(ntaps, [fsc - 1.0e6, fsc + 1.0e6], fs=H.FS, pass_zero=False)
    d = (ntaps - 1) // 2
    y = np.convolve(luma_codes - 25.0, lp, 'full')[d:d + len(luma_codes)] + 25.0
    c = np.convolve(chroma_codes - 25.0, bp, 'full')[d:d + len(chroma_codes)]
    return np.clip(np.round(y + c), 0, 63)
