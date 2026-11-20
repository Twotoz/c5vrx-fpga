"""Triversity: the OSD in simulation, pixel for pixel. tb_osd.v drives the
menu with the buttons and C5 markers, lcd_out draws it over a field that went
through the receive chain (data/osd_video.png, make_osd_video.py);
every captured LCD frame must equal fpga/gen/gen_osd.py's render() of the
state the scenario reached (RGB565). Writes the frames to fpga/build/osd_*.png
and, with --docs, the menu screenshots for the README to docs/.

    python fpga/sim/run_osd_tb.py [--docs]
"""
import subprocess, sys, tempfile
from pathlib import Path
import numpy as np
from PIL import Image
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE.parent / 'gen'))
import rtl as rtl_  # noqa: E402
import gen_osd as G  # noqa: E402

BASE = dict(open=True, page=1, cursor=0, edit=False, toast=False, channel=8, locked=True, pal=False, scanning=False,
            scan_ch=0, dvr=True, dvr_state=2, rec_s=83, age=[0, 0, 4095], sig=[78, 55, 0], cn=[1184, 1121, 0],
            gain=[54, 61, 0], flags=[1, 1, 0], gain_model=0, afc=True, bright=7, cal_ms=0, mode=2)
SHOTS = [('menu', {}), ('menu_edit', dict(edit=True)), ('menu_mode', dict(cursor=1, edit=True, mode=1)), ('menu_scan', dict(cursor=2, scanning=True, scan_ch=22)),
         ('receivers', dict(page=2)), ('settings', dict(page=3, cursor=2)), ('live', dict(open=False)),
         ('live_channel', dict(open=False, channel=9, toast=True)), ('no_signal', dict(open=False, channel=9, toast=True, locked=False))]
DOCS = ['menu', 'menu_edit', 'menu_mode', 'receivers', 'settings', 'live']


def picture():
    """240 x 800: data/osd_video.png, a field through the real receive chain (make_osd_video.py)."""
    return np.asarray(Image.open(HERE / 'data' / 'osd_video.png').convert('L')).astype(int)


def main():
    docs = '--docs' in sys.argv
    pic = picture()
    g, ps = G.glyphs(), G.pages()
    out = HERE.parent / 'build'; out.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory() as t:
        t = Path(t)
        (t / 'video.hex').write_text('\n'.join(f'{v:02x}' for v in pic.ravel()) + '\n')
        subprocess.run(['iverilog', '-g2012', *rtl_.inc(), '-o', str(t / 'tb'), str(HERE / 'tb_osd.v'),
                        *rtl_.src('menu.v', 'lcd_out.v')], check=True)
        r = subprocess.run(['vvp', '-n', str(t / 'tb')], cwd=t, capture_output=True, text=True)
        print(r.stdout.strip().splitlines()[-1] if r.stdout.strip() else r.stderr[-2000:])
        frames = [np.array([int(v, 16) for v in (t / f'shot_{k}.hex').read_text().split()]) for k in range(len(SHOTS))]
    ok = True
    for (name, d), fr in zip(SHOTS, frames):
        st = dict(BASE, **d)
        video = [[pic[y // 2][x] if st['locked'] else 0 for x in range(800)] for y in range(480)]
        want = np.asarray(G.render(g, G.fill(ps, st), video)).astype(int)
        want565 = (want[..., 0] >> 3) << 11 | (want[..., 1] >> 2) << 5 | want[..., 2] >> 3
        got = fr.reshape(480, 800) if fr.size == 480 * 800 else None
        rgb = None
        if got is not None:
            rgb = np.stack([(got >> 11 & 31) << 3 | (got >> 13 & 7), (got >> 5 & 63) << 2 | (got >> 9 & 3),
                            (got & 31) << 3 | (got >> 2 & 7)], -1).astype(np.uint8)
            Image.fromarray(rgb).save(out / f'osd_{name}.png')
            if docs and name in DOCS:
                Image.fromarray(rgb).save(HERE.parent.parent / 'docs' / f'osd_{name}.png')
        bad = -1 if got is None else int((got != want565).sum())
        ok &= bad == 0
        print(f'{name:13s} {"OK" if bad == 0 else f"{bad} pixels differ" if bad > 0 else f"frame size {fr.size}"}')
        if bad > 0:
            ys, xs = np.nonzero(got != want565)
            print('   first at', ys[0], xs[0], hex(got[ys[0], xs[0]]), hex(want565[ys[0], xs[0]]))
    print('PASS' if ok else 'FAIL')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
