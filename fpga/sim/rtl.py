"""Triversity: where the RTL lives, for the testbench runners.

    import rtl; iverilog(..., *rtl.inc(), *rtl.src('vid_sync.v', 'lcd_out.v'))
"""
from pathlib import Path
RTL = Path(__file__).resolve().parent.parent / 'rtl'


def src(*names):
    """Paths of the named RTL files, wherever they sit under fpga/rtl."""
    out = []
    for n in names:
        hits = list(RTL.rglob(n))
        assert len(hits) == 1, f'{n}: {hits}'
        out.append(str(hits[0]))
    return out


def inc():
    """-I options for every RTL directory (generated .vh tables)."""
    return [f'-I{d}' for d in sorted({p.parent for p in RTL.rglob('*.v*')})]
