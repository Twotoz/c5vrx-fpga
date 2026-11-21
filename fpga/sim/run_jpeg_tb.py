"""Triversity HQ DVR: rtl/io/jpeg_enc.v bit-exact against model/jpeg_model.py.
A 720 x H field (data/osd_video.png, through the receive chain) as JPEG
blocks in MCU order; the record bytes must be identical, and decodable.

    python fpga/sim/run_jpeg_tb.py [qi] [rows of MCUs, default all] [--stall] [--pal]
"""
import io, subprocess, sys, tempfile
from pathlib import Path
import numpy as np
from PIL import Image
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE.parent / 'model'))
import rtl as rtl_  # noqa: E402
import jpeg_model as J  # noqa: E402


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    qi = int(args[0]) if args else 3
    pal = '--pal' in sys.argv
    h = 288 if pal else 240
    rows = int(args[1]) if len(args) > 1 else h // 16
    src = Image.open(HERE / 'data' / 'osd_video.png').convert('RGB').resize((720, h), Image.BILINEAR)
    Y, Cb, Cr = J.to_ycbcr420(np.asarray(src))
    Y, Cb, Cr = Y[:rows * 16], Cb[:rows * 8], Cr[:rows * 8]
    lines, nb = [], 0
    for my in range(rows):
        for mx in range(45):
            for by, bx in ((0, 0), (0, 8), (8, 0), (8, 8)):
                lines.append('00'); lines += [f'{Y[my * 16 + by + r, mx * 16 + bx + c]:02x}' for r in range(8) for c in range(8)]; nb += 1
            for ci, P in ((1, Cb), (2, Cr)):
                lines.append(f'{ci:02x}'); lines += [f'{P[my * 8 + r, mx * 8 + c]:02x}' for r in range(8) for c in range(8)]; nb += 1
    want = J.record_prefix(0x1234, int(pal), 1, qi) + J.encode_field(Y, Cb, Cr, qi)
    if rows * 16 != h:            # the RTL header says the full height
        hs, L, hpos = J.header_rom()
        w = bytearray(want); w[8 + hpos:8 + hpos + 2] = (rows * 16).to_bytes(2, 'big'); want = bytes(w)
    with tempfile.TemporaryDirectory() as t:
        t = Path(t)
        (t / 'blocks.hex').write_text('\n'.join(lines) + '\n')
        subprocess.run(['iverilog', '-g2012', *rtl_.inc(), '-o', str(t / 'tb'), str(HERE / 'tb_jpeg.v'),
                        *rtl_.src('jpeg_enc.v', 'mul_dsp.v')], check=True)
        r = subprocess.run(['vvp', '-n', str(t / 'tb'), f'+nb={nb}', f'+qi={qi}', f'+pal={int(pal)}',
                            f'+stall={int("--stall" in sys.argv)}'], cwd=t, capture_output=True, text=True)
        print('\n'.join(l for l in r.stdout.splitlines() if l.startswith('cycles')) or r.stderr[-1500:])
        got = bytes(int(x, 16) for x in (t / 'out.hex').read_text().split())
    if rows * 16 == h:
        got_h = got
    else:
        g = bytearray(got); hs, L, hpos = J.header_rom(); g[8 + hpos:8 + hpos + 2] = (rows * 16).to_bytes(2, 'big'); got_h = bytes(g)
    same = got_h == want
    first = next((i for i in range(min(len(got_h), len(want))) if got_h[i] != want[i]), None)
    print(f'{len(got)} bytes (model {len(want)}), {"identical" if same else f"first difference at byte {first}"}')
    if same:
        Image.open(io.BytesIO(got_h[8:])).load()
        print('decodes')
    print('PASS' if same else 'FAIL')
    sys.exit(0 if same else 1)


if __name__ == '__main__':
    main()
