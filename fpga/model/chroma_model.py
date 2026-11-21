"""Triversity: colour decoding from the demodulator codes (prototype and
reference for rtl/video/chroma.v).

Source: an RGB picture as NTSC or PAL composite (BT.470 geometry and burst
from C5VRX's research/sim.py raster), through the C5 channel model for three
C5s, the combiner and discriminator model (bit-exact with the RTL) and the
RTL vid_sync, whose line starts the decoder uses, as the RTL will.

Decoder, all at 40 MHz on the held 20 MS/s codes:
  - NCO at the subcarrier, sin/cos table
  - burst: I/Q sums over the burst gate, angle against the -U axis; NTSC: the
    error; PAL: the angle of the mean of two successive bursts (their +-45
    degrees cancel), the V switch from this burst against that mean; the NCO
    phase follows by a fraction of it each line
  - U, V: code x sin / cos, two boxcars of two subcarrier periods
  - saturation from the burst amplitude (burst = 20 IRE), colour killer
    below a minimum burst
  - luma: the code minus the remodulated chroma, then a short boxcar
  - U and V averaged with the line before (PAL: V of that line inverted;
    NTSC too, against the chroma noise)

    python fpga/model/chroma_model.py [NTSC|PAL] [cn_db]   -> fpga/build/colour_<std>.png
"""
import subprocess, sys, tempfile
from pathlib import Path
import numpy as np
from scipy import signal as sg
from PIL import Image
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE.parent / 'sim'))
import eval_model as E   # noqa: E402
import eval3, mrc3_model  # noqa: E402
import rtl as rtl_  # noqa: E402
S = E.sim
FS = 40e6
FSC = {'NTSC': 3579545.454545, 'PAL': 4433618.75}


def test_picture(h, w=800):
    """75 % colour bars over the top 40 %, then a scene with sky, grass, a red
    roof, a yellow field and a skin tone; RGB 0..1."""
    img = np.zeros((h, w, 3))
    bars = [(.75, .75, .75), (.75, .75, 0), (0, .75, .75), (0, .75, 0), (.75, 0, .75), (.75, 0, 0), (0, 0, .75)]
    top = int(h * .4)
    for k, c in enumerate(bars):
        img[:top, k * w // 7:(k + 1) * w // 7] = c
    y, x = np.mgrid[top:h, 0:w]
    yy = (y - top) / (h - top)
    img[top:] = np.stack([.35 + .2 * (1 - yy), .55 + .2 * (1 - yy), .95 - .1 * yy], -1)        # sky
    grass = yy > .45
    img[top:][grass] = np.stack([.15 + .1 * yy, .55 + .1 * yy, .12 + 0 * yy], -1)[grass]
    roof = (yy > .2) & (yy < .45) & (x > 120) & (x < 330) & (yy > .45 - (x - 120) / 600)
    img[top:][roof] = (.8, .15, .1)
    field = (yy > .6) & (x > 450) & (x < 760)
    img[top:][field] = (.9, .8, .1)
    skin = ((x - 600) ** 2 / 50 ** 2 + (yy - .35) ** 2 / .1 ** 2) < 1
    img[top:][skin] = (.95, .72, .58)
    return np.clip(img, 0, 1)


def source(std, rgb, fields=6, seed=5):
    """Composite IRE at 40 MHz with the picture's chroma, and the raster regions."""
    ire, region = S.raster(std, seed, fields)
    pal = std == 'PAL'
    fsc = FSC[std]
    lines = 625 if pal else 525
    h, w, _ = rgb.shape
    Y = .299 * rgb[..., 0] + .587 * rgb[..., 1] + .114 * rgb[..., 2]
    U = .492 * (rgb[..., 2] - Y)
    V = .877 * (rgb[..., 0] - Y)
    k = np.nonzero(region == 1)[0]
    hs = np.array([S.half_sample(std, i) for i in range(lines * fields + 1)])
    sync = np.array([region[min(x, len(region) - 1)] == 2 for x in hs])
    h0 = np.maximum.accumulate(np.where(sync, np.arange(len(hs)), 0))   # half-line where each line began
    hl = np.searchsorted(hs, k, side='right') - 1
    hl0 = h0[hl]
    pos = (hl0 + (5 if pal else 0)) % lines
    row = np.clip((pos // 2 - 21) * h // (288 if pal else 240), 0, h - 1)
    xx = np.clip(((k - hs[hl0] - 420) * w / (2060 if pal else 2042)).astype(int), 0, w - 1)
    rows = row
    t = k / FS
    s = np.where((hl0 // 2) & 1, 1.0, -1.0) if pal else 1.0  # PAL V switch, as raster()'s burst
    yy, uu, vv = Y[rows, xx], U[rows, xx], V[rows, xx]
    comp = 7.5 * (not pal) + (100 - 7.5 * (not pal)) * yy + 100 * (uu * np.sin(2 * np.pi * fsc * t) + s * vv * np.cos(2 * np.pi * fsc * t))
    ire = ire.copy()
    ire[k] = comp
    return ire, region


def chain(std, ire, cn, seed=7):
    """Codes of three C5s at cn dB through the combiner and discriminator model."""
    src = sg.lfilter(sg.firwin(81, 6e6, fs=80e6), 1, np.repeat(ire, 2))
    z80 = sg.sosfilt(S.CHAN, np.exp(2j * np.pi * np.cumsum(S.PORCH_HZ + 0.7 * src / 140 * S.DEV_PP) / 80e6))
    z80 /= np.sqrt(np.mean(abs(z80) ** 2))
    rng = np.random.default_rng(seed)
    ys = [eval3.branch_y(z80, cn, rng, 0) for _ in range(3)]
    return np.asarray(mrc3_model.run([mrc3_model.to_raw3(y[0]) for y in ys], disc=True), np.int64)


def line_starts(codes):
    """RTL vid_sync on the codes: (clock of hc = 0, pal, locked, vline) per line."""
    with tempfile.TemporaryDirectory() as t:
        t = Path(t)
        (t / 'code.hex').write_text('\n'.join(f'{c:02x}' for c in codes) + '\n')
        subprocess.run(['iverilog', '-g2012', *rtl_.inc(), '-o', str(t / 'tb'), str(HERE.parent / 'sim' / 'tb_vsync.v'),
                        *rtl_.src('vid_sync.v')], check=True)
        subprocess.run(['vvp', '-n', str(t / 'tb'), f'+n={len(codes)}'], cwd=t, check=True, capture_output=True)
        ls = np.loadtxt(t / 'ls.txt', dtype=np.int64, ndmin=2)
        jumps = np.loadtxt(t / 'hc.txt', dtype=np.int64, ndmin=2)
    hc = np.zeros(len(codes), np.int64); pal = np.zeros(len(codes), np.int64)
    for i, (k, h, p) in enumerate(jumps):
        k = max(k, 0)
        end = jumps[i + 1][0] if i + 1 < len(jumps) else len(codes)
        hc[k:end] = h + np.arange(end - k); pal[k:end] = p
    return ls, hc, pal


def decode(codes, ls, std, luma_len=3, gain=0.25, box_mult=2, vavg=True):
    """Float prototype: RGB lines (row index = vline) of the last full field."""
    pal = std == 'PAL'
    fsc = FSC[std]
    n_per = int(round(FS / fsc))                      # 11 NTSC, 9 PAL
    comp = codes.astype(float) - 32
    t = np.arange(len(comp))
    bs, be = (240, 300) if pal else (232, 300)        # burst gate, clocks after the sync edge
    hstart, act = (420, 2080) if pal else (376, 2104)
    ph = 0.0                                           # NCO phase (turns) at the line start
    amp = None
    out = {}
    prev_uv = None
    for i in range(len(ls) - 1):
        a, b = ls[i, 0], ls[i + 1, 0]
        if b - a < 2000 or not ls[i, 2]:
            continue
        n = np.arange(b - a)
        phi = 2 * np.pi * (ph + fsc / FS * n)
        c = comp[a:b]
        bi = np.sum(c[bs:be] * np.cos(phi[bs:be])); bq = np.sum(c[bs:be] * np.sin(phi[bs:be]))
        th = np.arctan2(bi, -bq)
        A = np.hypot(bi, bq) / ((be - bs) / 2)
        sw = 1.0
        if pal:
            sw = 1.0 if th > 0 else -1.0
            err = th - sw * np.pi / 4
        else:
            err = th
        err = (err + np.pi) % (2 * np.pi) - np.pi
        amp = A if amp is None else amp + (A - amp) / 8

        # demodulate with the corrected phase
        phi2 = phi - err
        u = 2 * c * np.sin(phi2); v = 2 * c * np.cos(phi2)
        box = np.ones(n_per * box_mult) / (n_per * box_mult)
        u = np.convolve(np.convolve(u, box, 'same'), box, 'same')
        v = np.convolve(np.convolve(v, box, 'same'), box, 'same')
        chroma = u * np.sin(phi2) + v * np.cos(phi2)
        yl = np.convolve(c - chroma, np.ones(luma_len) / luma_len, 'same')
        # levels: tip 40..103, porch 220..347 (vid_sync)
        tip = np.mean(c[40:104]); porch = np.mean(c[220:348])
        depth = max(porch - tip, 1)
        ire_y = (yl - porch) / depth * 40
        sat = 20 / max(amp, 1e-3)
        uu, vv = u * sat, v * sat * sw
        if (pal if vavg is None else vavg) and prev_uv is not None and len(prev_uv[0]) >= len(uu):
            uu = (uu + prev_uv[0][:len(uu)]) / 2; vv = (vv + prev_uv[1][:len(vv)]) / 2
        prev_uv = (u * sat, v * sat * sw)
        if amp < 1.0:
            uu = uu * 0; vv = vv * 0
        px = hstart + (np.arange(800) * act / 800).astype(int)
        px = px[px < len(yl)]
        Y_ = ire_y[px] / 100; U_ = uu[px] / 100; V_ = vv[px] / 100
        rgb = np.stack([Y_ + 1.140 * V_, Y_ - .395 * U_ - .581 * V_, Y_ + 2.032 * U_], -1)

        out[(i, int(ls[i, 3]))] = np.clip(rgb, 0, 1)
        ph = (ph + fsc / FS * (b - a)) % 1.0
        ph = (ph - gain * err / (2 * np.pi)) % 1.0
    return out


def field_image(lines, pal):
    """The last complete field's active lines (vline 18.. / 20..) as an image."""
    keys = sorted(lines)
    vstart, rows = (20, 288) if pal else (18, 240)
    # last field: lines after the last vline 0
    zero = [k for k in keys if k[1] == 0]
    start = zero[-2] if len(zero) > 1 else zero[-1]
    img = np.zeros((rows, 800, 3))
    for k in keys:
        if k[0] >= start[0] and vstart <= k[1] < vstart + rows and (len(zero) < 2 or k[0] < zero[-1][0]):
            r = lines[k]
            img[k[1] - vstart, :len(r)] = r
    return img


def main():
    std = sys.argv[1] if len(sys.argv) > 1 else 'NTSC'
    cn = float(sys.argv[2]) if len(sys.argv) > 2 else 20.0
    pal = std == 'PAL'
    rgb = test_picture(288 if pal else 240)
    cache = HERE.parent / 'build' / f'colour_codes_{std}_{cn:g}.npz'
    if cache.exists():
        z = np.load(cache); codes, ls, hc, palk = z['codes'], z['ls'], z['hc'], z['pal']
    else:
        ire, region = source(std, rgb)
        codes = chain(std, ire, cn)
        ls, hc, palk = line_starts(codes)
        cache.parent.mkdir(exist_ok=True); np.savez(cache, codes=codes, ls=ls, hc=hc, pal=palk)
    img = hw_image(codes, hc, palk, ls, std) if '--hw' in sys.argv else field_image(decode(codes, ls, std), pal)
    out = HERE.parent / 'build'; out.mkdir(exist_ok=True)
    tag = '_hw' if '--hw' in sys.argv else ''
    Image.fromarray((np.repeat(img, 2, 0) * 255).astype(np.uint8)).save(out / f'colour_{std}{tag}.png')
    Image.fromarray((np.repeat(rgb, 2, 0) * 255).astype(np.uint8)).save(out / f'colour_{std}_truth.png')
    print('wrote', out / f'colour_{std}.png')



# =====================================================================================
# Hardware model: bit-exact with rtl/video/chroma.v (per clock k: code c[k], hc[k], pal[k])
# =====================================================================================
import mrc_model as m2   # noqa: E402  (cordic_angle, ATAN: bit-exact with rtl/rx/cordic_angle.v)
INC_N = round(3579545.454545 / 40e6 * 2 ** 32)
INC_P = round(4433618.75 / 40e6 * 2 ** 32)
SIN = [round(127 * np.sin(2 * np.pi * a / 256)) for a in range(256)]
COS = [round(127 * np.cos(2 * np.pi * a / 256)) for a in range(256)]
BS, BE = 232, 296            # burst gate (NTSC); PAL 240..304
BS_P, BE_P = 240, 304
KILL = 600                   # burst amplitude below which colour is off
NB_N, NB_P = 22, 18          # chroma boxcar: two subcarrier periods (twice), narrower and less noisy
K_N = round(2 ** 16 * 816 / NB_N ** 2)            # G = K / A: saturation from the burst
K_P = round(2 ** 16 * 816 / NB_P ** 2 * 1.0607)   # x 1.0607 for max + min / 2 at +-45 degrees
M_N = round(65536 * 8192 / (16129 * NB_N ** 2))   # chroma remodulation scale
M_P = round(65536 * 8192 / (16129 * NB_P ** 2))
CORDIC_LAT = 11
EV = 24                      # the line's burst result is applied at hc = burst end + EV


def asr(x, s):
    return x >> s            # Python >> on ints is arithmetic


def sat(x, bits):
    lo, hi = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    return max(lo, min(hi, x))


def hw_decode(codes, hc, pal):
    """Per clock: Y8u (8-code-sum units, offset like vid_sync's y), Ug, Vg (gray
    units, V sign-corrected), kill; arrays over all clocks."""
    N = len(codes)
    c = codes.astype(np.int64) - 32
    Y8u = np.zeros(N, np.int64); Ug = np.zeros(N, np.int64); Vg = np.zeros(N, np.int64)
    ph = INC_P if pal[0] else INC_N      # the RTL steps once between reset and the first code
    fadj = 0
    A = 0; G = 0; sw = 1; kill = True
    BI = BQ = 0
    xq = yq = 0; amp = 0; theta_at = -1; theta = 0; xp = yp = 0; theta_avg = 0
    # streaming filter state
    hist_pu = [0] * 24; hist_pv = [0] * 24; hist_u1 = [0] * 24; hist_v1 = [0] * 24
    u1 = v1 = u2 = v2 = 0
    dl_c = [0] * 23; dl_s = [0] * 23; dl_co = [0] * 23
    hist_y = [0] * 4; ysum = 0
    prev_pal = None
    ATAN = m2.ATAN
    for k in range(N):
        p = bool(pal[k])
        if p != prev_pal:          # standard change: filters restart from zero
            hist_pu = [0] * 24; hist_pv = [0] * 24; hist_u1 = [0] * 24; hist_v1 = [0] * 24
            u1 = v1 = u2 = v2 = 0
            prev_pal = p
        n = NB_P if p else NB_N
        bs, be = (BS_P, BE_P) if p else (BS, BE)
        a = (ph >> 24) & 255
        s, co = SIN[a], COS[a]
        ck = int(c[k])
        pu, pv = ck * s, ck * co
        h = int(hc[k])
        # burst
        if h == 0:
            BI = BQ = 0
        elif bs <= h < be:
            BI += pv; BQ += pu
        if h == be:
            xq = sat(asr(-BQ, 2), 16); yq = sat(asr(BI, 2), 16)
            ax, ay = abs(xq), abs(yq)
            amp = max(ax, ay) + (min(ax, ay) >> 1)
            theta = m2.cordic_angle(xq, yq, ATAN); theta_at = k + CORDIC_LAT
            # PAL: the mean of this burst and the one before points along -U
            theta_avg = m2.cordic_angle(asr(xq + xp, 1), asr(yq + yp, 1), ATAN)
            xp, yp = xq, yq
        corr = 0
        if h == be + EV and theta_at <= k:
            t = theta - 65536 if theta >= 32768 else theta
            if p:                  # PLL on the two-burst mean; V switch: this burst against it
                ta = theta_avg - 65536 if theta_avg >= 32768 else theta_avg
                d = (theta - theta_avg) & 0xFFFF
                sw = 1 if 0 < d < 32768 else -1
                err = ta
            else:
                sw, err = 1, t
            corr = -(err << 14)
            fadj = sat(fadj - err, 21)
            A = A + asr(amp - A, 3)
            kill = A < KILL
            G = 0 if kill else (K_P if p else K_N) // A
        # chroma filters (boxcar n, twice)
        hist_pu = [pu] + hist_pu[:23]; hist_pv = [pv] + hist_pv[:23]
        u1 = u1 + pu - hist_pu[n]; v1 = v1 + pv - hist_pv[n]
        hist_u1 = [u1] + hist_u1[:23]; hist_v1 = [v1] + hist_v1[:23]
        u2 = u2 + u1 - hist_u1[n]; v2 = v2 + v1 - hist_v1[n]
        # delayed code and phase (D = n - 1)
        dl_c = [ck] + dl_c[:22]; dl_s = [s] + dl_s[:22]; dl_co = [co] + dl_co[:22]
        cd, sd, cod = dl_c[n - 1], dl_s[n - 1], dl_co[n - 1]
        chr_ = asr(u2, 4) * sd + asr(v2, 4) * cod
        ch16 = asr(sat(asr(chr_, 7), 18) * (M_P if p else M_N), 13)
        yc16 = 16 * cd - ch16
        hist_y = [yc16] + hist_y[:3]
        y4 = sum(hist_y)
        Y8u[k] = min(1023, max(0, asr(y4, 3) + 256))
        if kill:
            Ug[k] = Vg[k] = 0
        else:
            Ug[k] = sat(asr(sat(asr(u2, 2), 18) * G, 14), 10)
            Vg[k] = sat(asr(sat(asr(v2, 2), 18) * G, 14), 10) * sw
        ph = (ph + (INC_P if p else INC_N) + fadj + corr) & 0xFFFFFFFF
    return Y8u, Ug, Vg


def emit_tables():
    """rtl/video/chroma_tab.vh: the sin / cos table of chroma.v."""
    lines = ['// Generated by fpga/model/chroma_model.py emit_tables(); do not edit.', 'initial begin']
    lines += [f"    sin_t[{a}] = 8'h{SIN[a] & 255:02x}; cos_t[{a}] = 8'h{COS[a] & 255:02x};" for a in range(256)]
    lines.append('end')
    (HERE.parent / 'rtl' / 'video' / 'chroma_tab.vh').write_text('\n'.join(lines) + '\n')


def rgb565(Yg, U, V):
    """Pixel colour from gray-unit Y, U, V (shift-add matrix, as the RTL)."""
    R = Yg + V + asr(V, 3) + asr(V, 6)
    Gc = Yg - (asr(U, 2) + asr(U, 3) + asr(U, 6)) - (asr(V, 1) + asr(V, 4) + asr(V, 6))
    B = Yg + 2 * U + asr(U, 5)
    cl = lambda x: max(0, min(255, x))
    return (cl(R) >> 3) << 11 | (cl(Gc) >> 2) << 5 | (cl(B) >> 3)


def hw_image(codes, hc, pal, ls, std):
    """The last full field from hw_decode, sampled like vid_sync's pixels
    (levels measured from Y8u per line; PAL U/V averaged with the line before)."""
    Y8u, Ug, Vg = hw_decode(codes, hc, pal)
    p = std == 'PAL'
    hstart, act = (420, 2080) if p else (376, 2104)
    lines = {}
    prev = None
    for i in range(len(ls) - 1):
        a, b = ls[i, 0], ls[i + 1, 0]
        if b - a < 2000 or not ls[i, 2]:
            continue
        hh = hc[a:b]
        def at(h):
            j = np.nonzero(hh == h)[0]
            return a + (j[0] if len(j) else 0)
        porch = int(np.mean(Y8u[at(220):at(220) + 128])); tip = int(np.mean(Y8u[at(40):at(40) + 64]))
        k8 = 26112 // max(porch - tip, 8)
        idx = np.array([at(hstart + (x * act) // 800) for x in range(800)])
        U, V = Ug[idx], Vg[idx]
        if prev is not None:                              # U, V averaged with the line above (NTSC too)
            Uo, Vo = (U + prev[0]) >> 1, (V + prev[1]) >> 1
        else:
            Uo, Vo = U, V
        prev = (U, V)
        Yg = np.clip(((Y8u[idx] - porch) * k8) >> 8, -256, 511)
        px = [rgb565(int(y), int(u), int(v)) for y, u, v in zip(Yg, Uo, Vo)]
        px = np.array(px)
        lines[(i, int(ls[i, 3]))] = np.stack([(px >> 11) / 31, ((px >> 5) & 63) / 63, (px & 31) / 31], -1)
    return field_image(lines, p)


if __name__ == '__main__':
    main()
