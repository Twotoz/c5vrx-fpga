"""Triversity: rtl/rx/align_bc.v (one alignment engine shared by C5 B and C)
against two rtl/rx/align_b.v on the same FM streams with clock offsets,
delays and noise (tb_align.v). Over the time after the settle time the
shared engine must line its samples up with A's (within one sample, the
combiner's tolerance) as often as the two separate ones (within 1 percent),
keep both C5s enabled, and lock as fast.

    python fpga/sim/run_align_tb.py [noise LSB]
"""
import re, subprocess, sys, tempfile
from pathlib import Path
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import rtl as rtl_  # noqa: E402


def main():
    noise = sys.argv[1] if len(sys.argv) > 1 else '0.25'
    with tempfile.TemporaryDirectory() as t:
        t = Path(t)
        subprocess.run(['iverilog', '-g2012', f'-Ptb_align.NOISE={noise}', *rtl_.inc(), '-o', str(t / 'tb'),
                        str(HERE / 'tb_align.v'), *rtl_.src('align_b.v', 'align_bc.v', 'mul_dsp.v')], check=True)
        out = subprocess.run(['vvp', '-n', str(t / 'tb')], cwd=t, capture_output=True, text=True).stdout
    m = re.search(r'RESULT (.*)', out)
    if not m:
        print(out[-2000:]); sys.exit(1)
    v = {k: int(x) for k, x in (kv.split('=') for kv in m.group(1).split())}
    n = v['n']
    pct = lambda x: 100.0 * x / n
    print(f"samples equal to A's within one sample: old B {pct(v['old_b']):.1f} %  C {pct(v['old_c']):.1f} %   "
          f"shared B {pct(v['new_b']):.1f} %  C {pct(v['new_c']):.1f} %")
    print(f"both enabled: old {pct(v['old_en']):.1f} %  shared {pct(v['new_en']):.1f} %")
    print(f"first enable (us): old B {v['lock_ob'] / 40:.0f} C {v['lock_oc'] / 40:.0f}   shared B {v['lock_nb'] / 40:.0f} C {v['lock_nc'] / 40:.0f}")
    ok = (pct(v['new_b']) >= pct(v['old_b']) - 1 and pct(v['new_c']) >= pct(v['old_c']) - 1 and pct(v['new_en']) >= 99.0
          and 0 < v['lock_nb'] <= v['lock_ob'] * 1.1 and 0 < v['lock_nc'] <= v['lock_oc'] * 1.1)
    print('PASS' if ok else 'FAIL')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
