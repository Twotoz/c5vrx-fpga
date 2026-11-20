"""Triversity: the video behind the OSD screenshots, through the real receive
chain. A scene (sky, tree line, fields, a track) as NTSC, the C5 channel
model of C5VRX's research/sim.py for three C5s at 13 dB C/N (12 dB: vid_sync does not lock yet), the combiner
and discriminator model (bit-exact with the RTL) and the RTL vid_sync; one
field of its line writes (240 x 800, 8-bit) goes to data/osd_video.png, the
picture run_osd_tb.py draws the menu on. The snow is the receiver's own.

    python fpga/sim/make_osd_video.py [cn_db]       (needs C5VRX's research/)
"""
import subprocess, sys, tempfile
from pathlib import Path
import numpy as np
from scipy import signal as sg
from scipy.ndimage import gaussian_filter
from PIL import Image
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE.parent / 'model'))
import rtl as rtl_  # noqa: E402
import eval_model as E   # noqa: E402
import eval3, mrc3_model  # noqa: E402


def scene():
    """240 x 800 IRE (0..100): sky, a tree line on the horizon, fields, a track."""
    rng = np.random.default_rng(11)
    y, x = np.mgrid[0:240, 0:800].astype(float)
    hor = 92 + 6 * np.sin(x / 150) + 3 * np.sin(x / 41)
    sky = 72 - 20 * (y / 100) + 4 * gaussian_filter(rng.normal(0, 1, (240, 800)), (6, 30)) * 3
    trees = hor - 7 - 9 * np.abs(gaussian_filter(rng.normal(0, 1, 800), 3)) * 3
    img = np.where(y < trees, sky, 18 + 10 * gaussian_filter(rng.normal(0, 1, (240, 800)), 1.5))
    d = np.clip((y - hor) / (240 - hor), 0, 1)                     # depth below the horizon
    field = 45 + 12 * np.sin((x - 400) / (6 + 60 * d) * (0.3 + d)) * (0.4 + d) \
        + 8 * gaussian_filter(rng.normal(0, 1, (240, 800)), (2, 4))
    field = np.where((x - 400) * (0.15 + d) > 120 * d, field - 12, field)      # two crops
    track = np.abs(x - (400 + (x * 0 + 1) * (60 - 380 * d))) < 6 + 70 * d
    img = np.where(y >= hor, np.where(track, 70 + 6 * gaussian_filter(rng.normal(0, 1, (240, 800)), 1), field), img)
    return np.clip(gaussian_filter(img, 0.7), 0, 100)


def main():
    cn = float(sys.argv[1]) if len(sys.argv) > 1 else 13.0
    fields = 8
    ire, region = E.sim.raster('NTSC', 5, fields)
    k = np.arange(len(ire))
    line = (k / 2542.2).astype(int)
    x = ((k - line * 2542.2) - 376) * 800 / 2104                   # vid_sync's HSTART / ACT
    v = line % 263 - 18
    sc = scene()
    pic = sc[np.clip(v, 0, 239), np.clip(x.astype(int), 0, 799)]
    ire = np.where(region == 1, pic, ire)
    src = sg.lfilter(sg.firwin(81, 4.2e6, fs=80e6), 1, np.repeat(ire, 2))
    z80 = sg.sosfilt(E.sim.CHAN, np.exp(2j * np.pi * np.cumsum(E.sim.PORCH_HZ + 0.7 * src / 140 * E.sim.DEV_PP) / 80e6))
    z80 /= np.sqrt(np.mean(abs(z80) ** 2))
    rng = np.random.default_rng(7)
    ys = [eval3.branch_y(z80, cn, rng, 0) for _ in range(3)]
    codes = mrc3_model.run([mrc3_model.to_raw3(y[0]) for y in ys], disc=True)
    with tempfile.TemporaryDirectory() as t:
        t = Path(t)
        (t / 'code.hex').write_text('\n'.join(f'{c:02x}' for c in codes) + '\n')
        subprocess.run(['iverilog', '-g2012', *rtl_.inc(), '-o', str(t / 'tb'), str(HERE / 'tb_vsync.v'),
                        *rtl_.src('vid_sync.v')], check=True)
        subprocess.run(['vvp', '-n', str(t / 'tb'), f'+n={len(codes)}'], cwd=t, check=True, stdout=subprocess.DEVNULL)
        a = np.loadtxt(t / 'vs.txt', dtype=np.int64, ndmin=2)
        print('writes', len(a))
    fld = sorted(set(a[:, 0]))
    best = max(fld[:-1], key=lambda f: (a[:, 0] == f).sum())       # the fullest complete field
    w = a[a[:, 0] == best]
    img = np.zeros((240, 800), np.uint8)
    img[w[:, 1], w[:, 2]] = w[:, 3]
    print('field', best, 'writes', len(w), 'of', 240 * 800)
    Image.fromarray(img).save(HERE / 'data' / 'osd_video.png')
    print('wrote', HERE / 'data' / 'osd_video.png')


if __name__ == '__main__':
    main()
