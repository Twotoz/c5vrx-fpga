"""Triversity: the video path end to end in simulation. A test picture
(grey ramp, bars, a box) as NTSC through three simulated C5s (C5VRX's
research/sim.py channel, 3-bit IQ), the combiner and discriminator model
(mrc3_model, bit-exact with the RTL), then the RTL vid_sync -> linebuf ->
lcd_out with the menu's OSD. Writes build/video_<cn>.png of the last LCD frame.

    python fpga/sim/run_video_tb.py [cn_db]
"""
import subprocess, sys, tempfile
from pathlib import Path
import numpy as np
from scipy import signal as sg
from PIL import Image
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import rtl as rtl_  # noqa: E402
sys.path.insert(0, str(HERE.parent / 'model'))
import eval_model as E   # noqa: E402  (C5VRX research/sim.py on the path)
import eval3, mrc3_model  # noqa: E402

def picture(fields, seed=5):
    ire, region = E.sim.raster('NTSC', seed, fields)
    k = np.arange(len(ire))
    line = (k / 2542.2).astype(int)
    x = (k - (line * 2542.2)).astype(int) - 420          # from the start of the picture
    v = (line % 263)
    pic = np.clip(x / 2000 * 100, 0, 100)                 # ramp
    pic = np.where((x // 250) % 2 == 1, pic, 100 - pic)   # alternating bands
    box = (v > 90) & (v < 170) & (x > 700) & (x < 1300)
    pic = np.where(box, 100, pic)
    pic = np.where((v // 20) % 4 == 0, np.where((x // 120) % 2 == 0, 100, 0), pic)   # checker rows
    ire = np.where(region == 1, pic, ire)
    return ire

def main():
    cn = float(sys.argv[1]) if len(sys.argv) > 1 else 15.0
    fields = 4
    ire = picture(fields)
    src = sg.lfilter(sg.firwin(81, 6e6, fs=80e6), 1, np.repeat(ire, 2))
    z80 = sg.sosfilt(E.sim.CHAN, np.exp(2j * np.pi * np.cumsum(E.sim.PORCH_HZ + 0.7 * src / 140 * E.sim.DEV_PP) / 80e6))
    z80 /= np.sqrt(np.mean(abs(z80) ** 2))
    rng = np.random.default_rng(7)
    ys = [eval3.branch_y(z80, cn, rng, 0) for _ in range(3)]
    codes = mrc3_model.run([mrc3_model.to_raw3(y[0]) for y in ys], disc=True)
    out = HERE.parent / 'build'; out.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        w = Path(tmp)
        (w / 'code.hex').write_text('\n'.join(f'{c:02x}' for c in codes) + '\n')
        subprocess.run(['iverilog', '-g2012', *rtl_.inc(), '-o', str(w / 'tb'), str(HERE / 'tb_video.v'),
                        *rtl_.src('vid_sync.v', 'linebuf.v', 'lcd_out.v', 'menu.v')], check=True)
        subprocess.run(['vvp', '-n', str(w / 'tb'), f'+n={len(codes)}'], cwd=w, check=True, stdout=subprocess.DEVNULL)
        a = np.loadtxt(w / 'lcd.txt', dtype=np.int64)
    frames = np.unique(a[:, 0])
    print('frames', frames, 'rows per frame', [int(a[a[:, 0] == fr, 1].max()) + 1 for fr in frames])
    last = a[a[:, 0] == frames[-2]] if len(frames) > 2 else a[a[:, 0] == frames[-1]]
    img = np.zeros((480, 800, 3), np.uint8)
    rr, cc = last[:, 1], last[:, 2]
    m = (rr < 480) & (cc < 800)
    img[rr[m], cc[m]] = np.stack([last[m, 3] << 3, last[m, 4] << 2, last[m, 5] << 3], 1)
    p = out / f'video_{int(cn)}.png'
    Image.fromarray(img).save(p)
    print('wrote', p)

if __name__ == '__main__':
    main()
