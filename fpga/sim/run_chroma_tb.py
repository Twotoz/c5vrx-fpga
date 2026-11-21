"""Triversity: rtl/video/chroma.v bit-exact against chroma_model.hw_decode on
codes through the receive chain (colour test picture, three C5s at 20 dB C/N)
and the RTL vid_sync's line counter. Compares Y, U, V every clock of a field's picture area.

    python fpga/sim/run_chroma_tb.py [NTSC|PAL]       (needs C5VRX's research/)
"""
import subprocess, sys, tempfile
from pathlib import Path
import numpy as np
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE.parent / 'model'))
import rtl as rtl_  # noqa: E402
import chroma_model as C  # noqa: E402
LAT = 6


def main():
    std = sys.argv[1] if len(sys.argv) > 1 else 'NTSC'
    cache = HERE.parent / 'build' / f'colour_codes_{std}_20.npz'
    if not cache.exists():
        subprocess.run([sys.executable, str(HERE.parent / 'model' / 'chroma_model.py'), std, '20'], check=True)
    z = np.load(cache)
    codes, hc, pal = z['codes'], z['hc'], z['pal']
    n = len(codes)
    k0, k1 = n - 700000, n - 400000
    Y, U, V = C.hw_decode(codes, hc, pal)
    with tempfile.TemporaryDirectory() as t:
        t = Path(t)
        (t / 'code.hex').write_text('\n'.join(f'{c:02x}' for c in codes) + '\n')
        (t / 'hcpal.hex').write_text('\n'.join(f'{(p << 12) | h:04x}' for h, p in zip(hc, pal)) + '\n')
        subprocess.run(['iverilog', '-g2012', *rtl_.inc(), '-o', str(t / 'tb'), str(HERE / 'tb_chroma.v'),
                        *rtl_.src('chroma.v')], check=True)
        subprocess.run(['vvp', '-n', str(t / 'tb'), f'+n={k1 + LAT + 2}', f'+k0={k0}', f'+k1={k1 + LAT + 1}'],
                       cwd=t, check=True, capture_output=True)
        o = np.loadtxt(t / 'out.txt', dtype=np.int64)
    k = o[:, 0] - LAT
    m = (k >= k0) & (k < k1)
    m &= (hc[np.clip(k, 0, n - 1)] >= 360)      # the picture part of the line (the saturation
                                                # divider settles after the burst, before it)
    sv = lambda x: np.where(x >= 512, x - 1024, x)
    got = np.stack([o[m, 1], sv(o[m, 2]), sv(o[m, 3])], 1)
    want = np.stack([Y[k[m]], U[k[m]], V[k[m]]], 1)
    bad = np.nonzero((got != want).any(1))[0]
    print(f'{std}: {m.sum()} clocks, {len(bad)} differ')
    if len(bad):
        j = bad[0]
        print('first at clock', k[m][j], 'hc', hc[k[m][j]], 'rtl', got[j], 'model', want[j])
    print('PASS' if not len(bad) else 'FAIL')
    sys.exit(0 if not len(bad) else 1)


if __name__ == '__main__':
    main()
