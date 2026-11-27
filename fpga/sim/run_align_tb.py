"""Check two- and three-receiver alignment with delays on either side of A.
Repeat with independent carrier offsets.

    python fpga/sim/run_align_tb.py [noise LSB]
"""
import re, subprocess, sys, tempfile
from pathlib import Path
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import rtl as rtl_  # noqa: E402


def main():
    noise = sys.argv[1] if len(sys.argv) > 1 else '0.25'
    for cfo in ((0, 0), (180_000, -265_000)):
        check(noise, *cfo)
    print('PASS')


def check(noise, cfo_b, cfo_c):
    with tempfile.TemporaryDirectory() as t:
        t = Path(t)
        subprocess.run(['iverilog', '-g2012', f'-Ptb_align.NOISE={noise}',
                        f'-Ptb_align.CFO_B={cfo_b}', f'-Ptb_align.CFO_C={cfo_c}',
                        *rtl_.inc(), '-o', str(t / 'tb'),
                        str(HERE / 'tb_align.v'), *rtl_.src('align_b.v', 'align_bc.v', 'mul_dsp.v')], check=True)
        out = subprocess.run(['vvp', '-n', str(t / 'tb')], cwd=t, capture_output=True, text=True, check=True).stdout
    m = re.search(r'RESULT (.*)', out)
    if not m:
        print(out[-2000:]); sys.exit(1)
    v = {k: int(x) for k, x in (kv.split('=') for kv in m.group(1).split())}
    n = v['n']
    pct = lambda x: 100.0 * x / n
    print(f'CFO B={cfo_b} Hz C={cfo_c} Hz')
    if not cfo_b and not cfo_c:
        matches = [pct(v[k]) for k in ('old_b', 'old_c', 'new_b', 'new_c')]
        print('IQ words matching A within one sample (%):', ', '.join(f'{p:.1f}' for p in matches))
        assert min(matches) >= 45, matches
    print(f"both enabled: separate {pct(v['old_en']):.1f}%, shared {pct(v['new_en']):.1f}%")
    assert min(pct(v['old_en']), pct(v['new_en'])) >= 99, v
    assert all(0 < v[k] < 160_000 for k in ('lock_ob', 'lock_oc', 'lock_nb', 'lock_nc')), v


if __name__ == '__main__':
    main()
