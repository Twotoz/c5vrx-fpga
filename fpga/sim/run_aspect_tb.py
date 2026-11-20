"""Triversity: vid_sync's aspect detection (menu Aspect Auto) end to end.
CGMS-A on NTSC lines 20/283 and WSS on PAL line 23/336 (waveforms as the
standards describe them) in C5VRX's research/sim.py raster, three C5s at
20 dB C/N, the combiner and discriminator model, the RTL vid_sync: wide must
follow the flag. Needs C5VRX's research/ (next to this repo or $C5VRX_RESEARCH).

    python fpga/sim/run_aspect_tb.py
"""
import subprocess, sys, tempfile
from pathlib import Path
import numpy as np
from scipy import signal as sg
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE.parent / 'model'))
import rtl as rtl_  # noqa: E402
import eval_model as E   # noqa: E402
import eval3, mrc3_model  # noqa: E402
S = E.sim


def crc6(bits):
    """CGMS-A CRC: X^6 + X + 1, preset to ones, over the 14 data bits."""
    c = 0x3f
    for d in bits:
        fb = d ^ (c >> 5)
        c = ((c << 1) & 0x3f) ^ (0b000011 if fb else 0)
    return [(c >> (5 - k)) & 1 for k in range(6)]


def cgms(ire, start, wide):
    """IEC 61880: from 11.2 us, 2.235 us bits: start 1 0, 14 data bits (bit 1 = aspect), CRC-6."""
    data = [1 if wide else 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0]
    bits = [1, 0] + data + crc6(data)
    for k, b in enumerate(bits):
        a = start + int(round(448 + 89.4 * k))
        ire[a:a + 89] = 70 if b else 0


def cgms_bad(ire, start):
    """16:9 with one CRC bit flipped: must be ignored."""
    cgms(ire, start, True)
    a = start + int(round(448 + 89.4 * 21))
    ire[a:a + 89] = 70 - ire[a]


def wss(ire, start, code):
    """EN 300 294: from 11.0 us, 200 ns elements: run-in, start code, group 1 (biphase 1 = 111000)."""
    el = '11111000111000111000111000111' + '000111100011110000011111'
    for b in code:
        el += '111000' if b == '1' else '000111'
    el += '000111' * 10
    for k, e in enumerate(el):
        a = start + 440 + 8 * k
        ire[a:a + 8] = 70 if e == '1' else 0


def run(std, inject, cn=20.0, fields=8):
    ire, region = S.raster(std, 5, fields)
    pal = std == 'PAL'
    fh, eq = (625, 5) if pal else (525, 6)
    for h in range(fh * fields):
        pos = (h + (eq if pal else 0)) % fh
        if pos in ((49, 50) if pal else (38, 39)):
            inject(ire, S.half_sample(std, h))
    src = sg.lfilter(sg.firwin(81, 6e6, fs=80e6), 1, np.repeat(ire, 2))
    z80 = sg.sosfilt(S.CHAN, np.exp(2j * np.pi * np.cumsum(S.PORCH_HZ + 0.7 * src / 140 * S.DEV_PP) / 80e6))
    z80 /= np.sqrt(np.mean(abs(z80) ** 2))
    rng = np.random.default_rng(7)
    ys = [eval3.branch_y(z80, cn, rng, 0) for _ in range(3)]
    codes = mrc3_model.run([mrc3_model.to_raw3(y[0]) for y in ys], disc=True)
    with tempfile.TemporaryDirectory() as t:
        t = Path(t)
        (t / 'code.hex').write_text('\n'.join(f'{c:02x}' for c in codes) + '\n')
        subprocess.run(['iverilog', '-g2012', *rtl_.inc(), '-o', str(t / 'tb'), str(HERE / 'tb_vsync.v'),
                        *rtl_.src('vid_sync.v')], check=True)
        r = subprocess.run(['vvp', '-n', str(t / 'tb'), f'+n={len(codes)}'], cwd=t, check=True, capture_output=True, text=True)
    line = [l for l in r.stdout.splitlines() if l.startswith('wide')][0]
    return int(line.split()[1])


def main():
    cases = [('NTSC CGMS 16:9', 'NTSC', lambda i, s: cgms(i, s, True), 1),
             ('NTSC CGMS 4:3', 'NTSC', lambda i, s: cgms(i, s, False), 0),
             ('NTSC no code', 'NTSC', lambda i, s: None, 0),
             ('NTSC bad CRC', 'NTSC', lambda i, s: cgms_bad(i, s), 0),
             ('PAL WSS 16:9', 'PAL', lambda i, s: wss(i, s, '1110'), 1),
             ('PAL WSS 4:3', 'PAL', lambda i, s: wss(i, s, '0001'), 0)]
    ok = True
    for name, std, inj, want in cases:
        got = run(std, inj)
        ok &= got == want
        print(f'{name:16s} wide={got} {"OK" if got == want else "WRONG"}')
    print('PASS' if ok else 'FAIL')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
