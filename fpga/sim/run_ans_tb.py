"""Triversity: the adaptive noise suppression of rtl/video/vid_sync.v (menu
Signal: Noise filter) against model/chroma_model.ans, bit-exact per clock,
on three C5s at several C/N (the level then steps 0 -> 3).

    python sim/run_ans_tb.py
"""
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE.parent / 'model'))
import rtl as rtl_  # noqa: E402
import chroma_model as C  # noqa: E402


def main():
    ok = True
    with tempfile.TemporaryDirectory() as t:
        t = Path(t)
        subprocess.run(['iverilog', '-g2012', *rtl_.inc(), '-o', str(t / 'tb'), str(HERE / 'tb_vsync.v'),
                        *rtl_.src('vid_sync.v')], check=True)
        ire, _ = C.source("NTSC", C.test_picture(240), fields=2)
        n = 640000
        for cn in (20, 8, 2, -3):
            codes = C.chain('NTSC', ire[:n + 2000], cn)[:n]
            (t / 'code.hex').write_text('\n'.join(f'{c:02x}' for c in codes) + '\n')
            subprocess.run(['vvp', '-n', str(t / 'tb'), f'+n={n}', '+ans=1'], cwd=t, check=True, capture_output=True)
            rows = (t / 'ans.txt').read_text().split('\n')
            k0 = max(i for i, r in enumerate(rows[:n // 2]) if 'x' in r or 'z' in r) + 5   # all known from here
            d = np.array([[int(v) for v in r.split()] for r in rows[k0:] if r.strip()], np.int64)
            hc, y, ny, lev, yacc, nacc, nln = d.T
            yd = [int(rows[k0 - j].split()[1]) for j in range(1, 5)]
            m, ml = C.ans(y, hc, (yd, int(nacc[0]), int(nln[0]), int(lev[0]), int(yacc[0])))
            bad = int(np.count_nonzero(m != ny) + np.count_nonzero(ml != lev))
            print(f'cn {cn:3d}: levels {sorted(set(lev.tolist()))}, final {lev[-1]}, mismatches {bad} of {len(y)}')
            ok &= bad == 0
    print('PASS' if ok else 'FAIL')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
