"""Triversity: where the RTL lives, for the testbench runners.

    import rtl; iverilog(..., *rtl.inc(), *rtl.src('vid_sync.v', 'lcd_out.v'))
"""
from pathlib import Path
RTL = Path(__file__).resolve().parent.parent / 'rtl'


DEPS = {'lcd_out.v': ['mul_dsp.v'], 'vid_sync.v': ['chroma.v'], 'chroma.v': ['mul_dsp.v', 'cordic_iter.v', 'addsub.v'], 'jpeg_enc.v': ['addsub.v', 'mul_dsp.v'],
        'cordic_angle.v': ['addsub.v'], 'cordic_iter.v': ['addsub.v'], 'align_bc.v': ['addsub.v']}


def src(*names):
    """Paths of the named RTL files (and the modules they instantiate), wherever
    they sit under fpga/rtl."""
    out, todo, seen = [], list(names), set()
    while todo:
        n = todo.pop(0)
        if n in seen:
            continue
        seen.add(n)
        todo += DEPS.get(n, [])
        hits = list(RTL.rglob(n))
        assert len(hits) == 1, f'{n}: {hits}'
        out.append(str(hits[0]))
    return out


def inc():
    """-I options for every RTL directory (generated .vh tables)."""
    return [f'-I{d}' for d in sorted({p.parent for p in RTL.rglob('*.v*')})]
