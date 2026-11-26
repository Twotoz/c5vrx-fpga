"""Triversity: the OSD in simulation, pixel for pixel. tb_osd.v drives the
menu with the buttons and C5 markers, lcd_out draws it over a field that went
through the receive chain (data/osd_video.png, make_osd_video.py);
every captured LCD frame must equal fpga/gen/gen_osd.py's render() of the
state the scenario reached (RGB565). Writes the frames to fpga/build/osd_*.png
and, with --docs, the menu screenshots for the README to docs/.

    python fpga/sim/run_osd_tb.py [--docs] [--hq | --tridvr]      (the HQ DVR builds' hq_ui.v)
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
            gain=[54, 61, 0], flags=[1, 1, 0], gain_model=0, afc=True, bright=7, cal_ms=0, mode=2,
            aspect=3, wide=False, logo=True)
SHOTS = [('boot', dict(boot=True, open=False, dvr_state=1)),
         ('boot_missing', dict(boot=True, open=False, dvr_state=1, boot_ms=1500, locked=False)), ('menu', {}), ('menu_edit', dict(edit=True)), ('menu_mode', dict(cursor=1, edit=True, mode=1)), ('menu_scan', dict(cursor=2, scanning=True, scan_ch=22)),
         ('receivers', dict(page=2)), ('settings', dict(page=3, cursor=2)),
         ('settings_aspect', dict(page=3, cursor=2, edit=True, aspect=2)),
         ('signal', dict(page=4, cursor=0, aspect=2, klock=True)), ('live', dict(open=False, aspect=2)),
         ('live_channel', dict(open=False, channel=9, toast=True, aspect=2)),
         ('no_signal', dict(open=False, channel=9, toast=True, locked=False, aspect=2))]
# the HQ DVR build's screen (hq_ui.v, --hq): the live view only
HQ_BASE = dict(BASE, open=False, mode=1, dvr=False, dvr_state=0, rec_s=0, age=[0, 0, 4095], sig=[78, 55, 0], aspect=3, hq=True)
HQ_SHOTS = [('hq_live', {}), ('hq_nocard', dict(dvr=True)), ('hq_rec', dict(dvr=True, dvr_state=2, rec_s=83)),
            ('hq_channel', dict(dvr=True, dvr_state=2, rec_s=83, channel=9, toast=True)),
            ('hq_single', dict(dvr=True, dvr_state=2, rec_s=83, channel=9, toast=True, mode=0)),
            ('hq_nosig', dict(dvr=True, dvr_state=2, rec_s=83, channel=9, toast=True, mode=0, locked=False))]
# the Triversity DVR build (--tridvr): hq_ui.v with 7-segment glyphs, Triversity first, no logo
TRI_BASE = dict(HQ_BASE, mode=2, logo=False)
TRI_SHOTS = [(n.replace('hq_', 'tri_').replace('single', 'diversity'), dict(d, mode=1) if 'mode' in d else d) for n, d in HQ_SHOTS]
DOCS = ['hq_rec', 'tri_rec', 'signal', 'menu', 'menu_edit', 'menu_mode', 'receivers', 'settings', 'settings_aspect', 'live']


def picture():
    """240 x 800 RGB565: data/osd_video.png, a field through the real receive chain (make_osd_video.py)."""
    a = np.asarray(Image.open(HERE / 'data' / 'osd_video.png').convert('RGB')).astype(int)
    return (a[..., 0] >> 3) << 11 | (a[..., 1] >> 2) << 5 | a[..., 2] >> 3


def widen(p):
    """RGB565 -> 8 bits a channel, as lcd_out."""
    r, g, b = p >> 11, (p >> 5) & 63, p & 31
    return ((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2))


def main():
    docs = '--docs' in sys.argv
    tri = '--tridvr' in sys.argv
    h90 = '--hdmi90' in sys.argv          # the 90 Hz HDMI build's menu (Settings: 90 Hz instead of Brightness)
    hdmi = '--hdmi' in sys.argv or h90          # the HDMI build's output: 720 x 480, the 800-wide reference cropped at x 40
    hq = '--hq' in sys.argv or tri
    shots, base = (TRI_SHOTS, TRI_BASE) if tri else (HQ_SHOTS, HQ_BASE) if hq else (SHOTS, BASE)
    pic = picture()
    # A constant source row isolates the OSD renderer from the differing
    # source/display epochs. Cadence tests exercise asynchronous video.
    pic = np.repeat(pic[[120], :], pic.shape[0], axis=0)
    g, ps = G.seg_glyphs() if tri else G.glyphs_vh(), G.pages(h90=h90)
    out = HERE.parent / 'build'; out.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory() as t:
        t = Path(t)
        (t / 'video.hex').write_text('\n'.join(f'{v:04x}' for v in pic.ravel()) + '\n')
        subprocess.run(['iverilog', '-g2012', *(['-DTRI_HQDVR', '-DTRI_LIVEUI', '-DTRI_HMAPCALC'] if hq else []), *(['-DTRI_TRIDVR', '-DTRI_SEGFONT'] if tri else []), *(['-DTRI_HDMI', '-DTRI_HMAPCALC'] if hdmi else []), *(['-DTRI_MENU_H90'] if h90 else []), *rtl_.inc(), '-o', str(t / 'tb'),
                        str(HERE / 'tb_osd.v'), *rtl_.src('hq_ui.v' if hq else 'menu.v', 'lcd_out.v')], check=True)
        r = subprocess.run(['vvp', '-n', str(t / 'tb')], cwd=t, capture_output=True, text=True)
        print(r.stdout.strip().splitlines()[-1] if r.stdout.strip() else r.stderr[-2000:])
        frames = [np.array([int(v, 16) for v in (t / f'shot_{k}.hex').read_text().split()]) for k in range(len(shots))]
    ok = True
    for (name, d), fr in zip(shots, frames):
        st = dict(base, **d)
        hm = G.hmaps()[0 if hdmi else G.hmode(st)]       # HDMI: the 720 samples as they are
        wid = [[widen(int(v)) for v in row] for row in pic]
        video = [[wid[y // 2][hm[x]] if st['locked'] and hm[x] is not None else 0 for x in range(800)] for y in range(480)]
        if st.get('boot'):                                # the start-up screen: the logo layer, the build
            st['build'] = 'HDMI' if hdmi else 'LCD'
            bv = G.boot_video()
            video = [[widen(int(bv[y][x])) for x in range(800)] for y in range(480)]
        want = np.asarray(G.render(g, G.fill(ps, st), video)).astype(int)
        if hdmi:
            want = want[:, 40:760]
        want565 = (want[..., 0] >> 3) << 11 | (want[..., 1] >> 2) << 5 | want[..., 2] >> 3
        W = 720 if hdmi else 800
        got = fr.reshape(480, W) if fr.size == 480 * W else None
        rgb = None
        if got is not None:
            rgb = np.stack([(got >> 11 & 31) << 3 | (got >> 13 & 7), (got >> 5 & 63) << 2 | (got >> 9 & 3),
                            (got & 31) << 3 | (got >> 2 & 7)], -1).astype(np.uint8)
            Image.fromarray(rgb).save(out / f'osd_{"hdmi_" if hdmi else ""}{name}.png')
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
