"""Triversity: colour in the README, through the real chain. The colour test
picture as NTSC and PAL composite, three C5s at a C/N, the combiner and
discriminator model (bit-exact with the RTL) and the RTL vid_sync with
chroma.v; one field of its RGB565 line writes next to the source picture.

    python fpga/sim/make_colour_docs.py [cn_db]     -> docs/colour_ntsc.png, docs/colour_pal.png
"""
import subprocess, sys, tempfile
from pathlib import Path
import numpy as np
from PIL import Image
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE.parent / 'model'))
import rtl as rtl_  # noqa: E402
import chroma_model as C  # noqa: E402


def rtl_field(codes, rows):
    """RTL vid_sync on the codes: the fullest complete field of RGB565 writes as 8-bit RGB."""
    with tempfile.TemporaryDirectory() as t:
        t = Path(t)
        (t / 'code.hex').write_text('\n'.join(f'{c:02x}' for c in codes) + '\n')
        subprocess.run(['iverilog', '-g2012', *rtl_.inc(), '-o', str(t / 'tb'), str(HERE / 'tb_vsync.v'),
                        *rtl_.src('vid_sync.v')], check=True)
        subprocess.run(['vvp', '-n', str(t / 'tb'), f'+n={len(codes)}'], cwd=t, check=True, stdout=subprocess.DEVNULL)
        a = np.loadtxt(t / 'vs.txt', dtype=np.int64, ndmin=2)
    fld = sorted(set(a[:, 0]))
    best = max(fld[:-1], key=lambda f: (a[:, 0] == f).sum())
    w = a[a[:, 0] == best]
    img = np.zeros((rows, 800, 3), np.uint8)
    p = w[:, 3]
    r, g, b = p >> 11, (p >> 5) & 63, p & 31
    img[w[:, 1], w[:, 2]] = np.stack([(r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2)], 1)
    return img


def main():
    cn = float(sys.argv[1]) if len(sys.argv) > 1 else 20.0
    docs = HERE.parent.parent / 'docs'
    for std in ('NTSC', 'PAL'):
        rgb = C.test_picture(240)                      # vid_sync gives 240 rows for both (PAL drops 1 in 6)
        ire, _ = C.source(std, C.test_picture(288 if std == 'PAL' else 240))
        img = rtl_field(C.chain(std, ire, cn), 240)
        both = np.concatenate([(rgb * 255).astype(np.uint8), np.full((240, 16, 3), 255, np.uint8), img], 1)
        Image.fromarray(np.repeat(both, 2, 0)).save(docs / f'colour_{std.lower()}.png')
        print('wrote', docs / f'colour_{std.lower()}.png')


if __name__ == '__main__':
    main()
