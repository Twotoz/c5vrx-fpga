"""Triversity: marker_rx.v against the C5 firmware's marker words
(c5/main/fpga_link.h): random IQ noise with markers whose words are
held 78..92 samples (the C5's esp_rom_delay_us jitter). Checks every payload,
that no marker sample reaches the combiner as valid, and that IQ outside the
marker windows (plus slack) stays valid. Exit 1 on failure."""
import subprocess, sys, tempfile
from pathlib import Path
import numpy as np
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import rtl as rtl_  # noqa: E402

def words(t, v):
    p = (t << 12) | v
    return [0x38, 0x07] + [((0x10 if k & 1 else 0x20) | ((p >> (12 - 4 * k)) & 15)) for k in range(4)]

def main():
    rng = np.random.default_rng(3)
    n = 60000
    raw = rng.integers(0, 64, n)
    marks = []
    k = 1000
    while k < n - 2000:
        t, v = int(rng.integers(1, 7)), int(rng.integers(0, 4096))
        start = k
        for w in words(t, v):
            h = int(rng.integers(78, 93))
            raw[k:k + h] = w
            k += h
        marks.append((start, k, (t << 12) | v))
        k += int(rng.integers(500, 3000))
    with tempfile.TemporaryDirectory() as tmp:
        w = Path(tmp)
        (w / 'in.hex').write_text('\n'.join(f'{x:02x}' for x in raw) + '\n')
        subprocess.run(['iverilog', '-g2012', '-o', str(w / 'tb'), str(HERE / 'tb_marker_rx.v'), *rtl_.src('marker_rx.v')], check=True)
        subprocess.run(['vvp', '-n', str(w / 'tb'), f'+n={n}'], cwd=w, check=True, stdout=subprocess.DEVNULL)
        rows = [l.split() for l in (w / 'out.hex').read_text().split('\n') if l]
    rd = np.array([int(r[0], 16) for r in rows]); vd = np.array([int(r[1]) for r in rows])
    ev = np.array([int(r[2]) for r in rows]); pl = np.array([int(r[3], 16) for r in rows])
    got = list(pl[ev == 1])
    ok = got == [m[2] for m in marks]
    print(f'payloads {len(got)}/{len(marks)} match={ok}')
    # delay: raw_d[k + L] == raw[k]
    L = next(L for L in range(100, 200) if np.array_equal(rd[L:L + 5000], raw[:5000]))
    inmark = np.zeros(n, bool)
    for s, e, _ in marks: inmark[s:e] = True
    v_in = vd[L:L + n]
    leak = int(np.count_nonzero(v_in[inmark] == 1))
    cover = np.zeros(n, bool)
    for s, e, _ in marks: cover[max(0, s - 64):e + 200] = True
    lost = int(np.count_nonzero(v_in[~cover] == 0))
    print(f'delay {L}, marker samples flagged valid {leak}, IQ samples outside marker+slack flagged invalid {lost}')
    ok = ok and leak == 0 and lost == 0
    print('PASS' if ok else 'FAIL'); sys.exit(0 if ok else 1)

if __name__ == '__main__':
    main()
