"""C5VRX by Twotoz and the C5VRX contributors: bit-exact integer model of the
three-branch ("Tripleversity") FPGA combiner/demodulator (fpga/rtl/mrc3_core.v).

The arithmetic of mrc_model.py (two branches) extended to C5 A plus up to
two more C5s, each delivering 3-bit I and Q: the top three bits of its
4-bit MODEM_DIAG lane (ultrafine {9,6,5}, fine {9,7,6}, coarse {9,8,7}; the
C5 keeps its 4-bit lane internally and STRONG LANE stays on; the FPGA only
sees the angle and adapts its weights to the scale). Raw sample per C5: six
bits {I2 I1 I0 Q2 Q1 Q0}, two's complement per component (v = -4..3); the
cell centre is c = 4 v + 2 (-14..14, units of half an ultrafine cell).

Per sample n, per branch k:
  p      = cI^2 + cQ^2
  m2acc += p   - (m2acc >> 6) ;  m4acc += p^2 - (m4acc >> 6)
  every 128 samples: w_k = max(1, (G[rq - 256] * ISQ[m2acc >> 6]) >> 8),
  rq = clamp((m4acc << 14) // m2acc^2, 256, 511), applied one period later
For each branch k = B, C (relative to A):
  x_k   += cA * conj(c_k) - (x_k >> 7)
  theta_k = CORDIC angle of x_k >> 4 (2^-8 turn), after every 16th sample,
            used from the end of the next block
  c_k'   = c_k * (C + jS)[theta_k]
Combine and demodulate:
  z    = wA cA 64 + wB cB' + wC cC'      (absent branches: weight 0)
A C5 sending a marker (fpga_link.h) is invalid for those samples: weight 0,
its moments hold, and a tracker holds while its branch or C5 A is invalid.
  phi  = CORDIC angle of z >> 6 (10 steps); dphi = phi - phi[n-1] (wrap)
  code = clamp((dphi * 168 + 1651507 + 32768) >> 16, 0, 63)
"""
import numpy as np
from numba import njit

import mrc_model as m2model

M_SHIFT, X_SHIFT, W_PERIOD, W_APPLY, TH_BLOCK = 6, 7, 128, 127, 16
Z_SHIFT, X_SHIFT_TH = 6, 4
G, ISQ, COS, SIN, ATAN = m2model.G, m2model.ISQ, m2model.COS, m2model.SIN, m2model.ATAN
cordic_angle = m2model.cordic_angle


@njit(cache=True)
def _cell(v3):
    v = (v3 & 7)
    v = v - 8 if v >= 4 else v
    return 4 * v + 2


@njit(cache=True)
def _run(raw, en, valid, G, ISQ, COS, SIN, ATAN, out, phis):
    nb, n = raw.shape
    m2 = np.zeros(3, np.int64)
    m4 = np.zeros(3, np.int64)
    w = np.ones(3, np.int64)
    pend = np.ones(3, np.int64)
    have_pend = False
    xr = np.zeros(3, np.int64)
    xi = np.zeros(3, np.int64)
    th_cur = np.zeros(3, np.int64)
    th_pend = np.zeros(3, np.int64)
    phi_prev = 0
    ci = np.zeros(3, np.int64)
    cq = np.zeros(3, np.int64)
    for k in range(n):
        for b in range(3):
            r = raw[b, k] if b < nb else 0
            ci[b] = _cell(r >> 3)
            cq[b] = _cell(r)
        wa = w[0] if valid[0, k] else 0
        zi = wa * ci[0] * 64
        zq = wa * cq[0] * 64
        for b in range(1, 3):
            c = COS[th_cur[b]]
            s = SIN[th_cur[b]]
            ri = ci[b] * c - cq[b] * s
            rq_ = ci[b] * s + cq[b] * c
            wb = w[b] if (en[b] and valid[b, k]) else 0
            zi += wb * ri
            zq += wb * rq_
        phi = cordic_angle(zi >> Z_SHIFT, zq >> Z_SHIFT, ATAN)
        phis[k] = phi
        d = (phi - phi_prev) & 0xFFFF
        if d >= 32768:
            d -= 65536
        phi_prev = phi
        code = (d * 168 + 1651507 + 32768) >> 16
        out[k] = 0 if code < 0 else (63 if code > 63 else code)
        # state updates
        for b in range(3):
            if not valid[b, k]:
                continue   # a marker on this C5: its moments hold
            p = ci[b] * ci[b] + cq[b] * cq[b]
            m2[b] += p - (m2[b] >> M_SHIFT)
            m4[b] += p * p - (m4[b] >> M_SHIFT)
        for b in range(1, 3):
            if not (valid[0, k] and valid[b, k]):
                continue   # no reference or no branch: the tracker holds
            pr = ci[0] * ci[b] + cq[0] * cq[b]
            pq = cq[0] * ci[b] - ci[0] * cq[b]
            xr[b] += pr - (xr[b] >> X_SHIFT)
            xi[b] += pq - (xi[b] >> X_SHIFT)
        if (k & (TH_BLOCK - 1)) == TH_BLOCK - 1:
            for b in range(1, 3):
                th_cur[b] = th_pend[b]
                th_pend[b] = (cordic_angle(xr[b] >> X_SHIFT_TH, xi[b] >> X_SHIFT_TH, ATAN) + 128) >> 8 & 255
        if (k & (W_PERIOD - 1)) == W_APPLY and have_pend:
            for b in range(3):
                w[b] = pend[b]
        if (k & (W_PERIOD - 1)) == W_PERIOD - 1:
            have_pend = True
            for b in range(3):
                den = m2[b] * m2[b]
                if den == 0:
                    pend[b] = 1
                    continue
                rq = (m4[b] << 14) // den
                rq = 511 if rq > 511 else (256 if rq < 256 else rq)
                mi = m2[b] >> M_SHIFT
                mi = 511 if mi > 511 else mi
                v = (G[rq - 256] * ISQ[mi]) >> 8
                pend[b] = v if v > 1 else 1


# Click-suppressed 50 ns discriminator on the combined angle (eval_disc.py,
# the D32-R2 rule on 1024 sectors), in exact integers for the RTL:
#   every second sample k (k even): token t = ((phi + 32768) >> 6) & 1023,
#   d = wrap(t - s) in -512..511; inside the video window (-312 <= d <= 384,
#   about -110..+135 degrees per 50 ns) the state takes the whole step, outside
#   it (d * 179) >> 8 (0.7 of it); code = clamp((105 * step + 32896) // 1280,
#   0, 63) (-6..+9 MHz over 0..63), output for samples k+2 and k+3.
DISC_WL, DISC_WH = -312, 384


@njit(cache=True)
def disc50(phis, out):
    n = len(phis)
    s = ((phis[0] + 32768) >> 6) & 1023
    for k in range(0, n - 3, 2):
        t = ((phis[k] + 32768) >> 6) & 1023
        d = ((t - s + 512) & 1023) - 512
        step = d if (d >= DISC_WL and d <= DISC_WH) else (d * 179) >> 8
        c = (105 * step + 32896) // 1280
        c = 0 if c < 0 else (63 if c > 63 else c)
        out[k + 2] = c
        out[k + 3] = c
        s = (s + step) & 1023


# Rescue PLL (menu Signal > Rescue): a second-order phase-locked loop on the
# same combined angle, a threshold-extending demodulator for very weak signals
# (sim/perf_rescue.py). Per sample k, on the top 12 bits of phi (2^-12 turn):
#   e   = wrap12(p - th)                         p = phi >> 4
#   fo  = (F >> 7) + (e >> 2)                    kp = 1/4
#   F   = F + e, saturating at 17 bits            ki = 1/128
#   th  = (th + fo) & 0xFFF
#   code = disc50's code for d = (fo + fo[k-1]) >> 2 (the same table), output at k+2
# th, F and fo[-1] start at 0. Mode 0 off, 1 auto, 2 on.
# Auto (look-ahead): per sample pair j disc50's step is a click when it is out of
# its window; pair j's two outputs (k+2, k+3) are the PLL's when pairs
# j - RS_W + 1 .. j + RS_W hold at least RS_K clicks, else the discriminator's
# (sim/fading: a fade's clicks cluster; the PLL is better through them, the
# discriminator elsewhere). The RTL delays its output by RS_W pairs for this.
# And steady clicks (a very weak signal: the PLL is better there between the
# clicks too): the pairs are counted in sub-windows of 2^RS_SSH (pair j in
# sub-window j >> RS_SSH); at the end of every 64th sub-window the PLL is
# switched on for all pairs when at least RS_T of those 64 held a click, else
# off. Pair j's output uses the switch as it stands after pair j + RS_W.
RS_W, RS_K, RS_SSH, RS_T = 1024, 2, 12, 48


@njit(cache=True)
def rescue50(phis, out, mode, w, kon, ssh, tst, act):
    n = len(phis)
    s = ((phis[0] + 32768) >> 6) & 1023
    th = 0; F = 0; fop = 0
    pll = np.zeros(n, np.int64)
    for k in range(n):
        e = (((phis[k] >> 4) - th + 2048) & 0xFFF) - 2048
        fo = (F >> 7) + (e >> 2)
        F += e
        if F < -(1 << 16): F = -(1 << 16)
        if F > (1 << 16) - 1: F = (1 << 16) - 1
        th = (th + fo) & 0xFFF
        d = (fo + fop) >> 2                       # -512 .. 511
        step = d if (d >= DISC_WL and d <= DISC_WH) else (d * 179) >> 8
        c = (105 * step + 32896) // 1280
        pll[k] = 0 if c < 0 else (63 if c > 63 else c)
        fop = fo
    npr = len(range(0, n - 3, 2))
    psum = np.zeros(npr + 1, np.int64)            # clicks before pair j
    for j in range(npr):
        k = 2 * j
        t = ((phis[k] + 32768) >> 6) & 1023
        d = ((t - s + 512) & 1023) - 512
        cl = not (d >= DISC_WL and d <= DISC_WH)
        step = d if not cl else (d * 179) >> 8
        s = (s + step) & 1023
        psum[j + 1] = psum[j] + (1 if cl else 0)
    st = np.zeros(npr, np.bool_)                   # the steady switch after pair j
    sub = 1 << ssh; on_ = False; nocc = 0; occ = 0
    for j in range(npr):
        occ |= psum[j + 1] - psum[j]
        if j % sub == sub - 1:
            nocc += occ; occ = 0
            if (j >> ssh) % 64 == 63:
                on_ = nocc >= tst; nocc = 0
        st[j] = on_
    for j in range(npr):
        k = 2 * j
        on = mode >= 2
        if mode == 1:
            on = psum[min(j + w + 1, npr)] - psum[max(j - w + 1, 0)] >= kon or st[min(j + w, npr - 1)]
        if on:
            out[k + 2] = pll[k]
            out[k + 3] = pll[k + 1]
        act[k + 2] = on
        act[k + 3] = on


def run(raws, enable=(True, True, True), return_phi=False, disc=False, valid=None,
        rescue=0, rw=RS_W, rk=RS_K, rss=RS_SSH, rt=RS_T, return_act=False):
    """raws: list of 1..3 arrays of 6-bit samples {I2..I0, Q2..Q0}, C5 A first.
    return_phi: also return the combined angle per sample (2^-16 turn).
    rescue (with disc): 0 off, 1 auto, 2 on; return_act: also the per-sample rescue flag."""
    raw = np.zeros((3, len(raws[0])), np.int64)
    for b, r in enumerate(raws):
        raw[b] = np.asarray(r, np.int64)
    en = np.array([1, int(enable[1] and len(raws) > 1), int(enable[2] and len(raws) > 2)], np.int64)
    out = np.zeros(raw.shape[1], np.int64)
    phis = np.zeros(raw.shape[1], np.int64)
    v = np.ones((3, raw.shape[1]), np.int64) if valid is None else np.asarray(valid, np.int64)
    _run(raw, en, v, G, ISQ, COS, SIN, ATAN, out, phis)
    if disc:
        out = np.zeros(raw.shape[1], np.int64)
        disc50(phis, out)
        act = np.zeros(raw.shape[1], np.int64)
        if rescue:
            rescue50(phis, out, rescue, rw, rk, rss, rt, act)
        if return_act:
            return (out.astype(np.uint8), phis, act) if return_phi else (out.astype(np.uint8), act)
    return (out.astype(np.uint8), phis) if return_phi else out.astype(np.uint8)


def to_raw3(y):
    """6-bit sample of a signal in ultrafine cells: the top three bits of the
    ultrafine nibble (sign, ADC6, ADC5) of each component."""
    def comp(x):
        adc = np.clip(np.floor(x * 16), -512, 511).astype(np.int64)
        return (((adc >> 5) & 3) | (4 * (adc < 0)))
    return ((comp(y.real) << 3) | comp(y.imag)).astype(np.uint8)
