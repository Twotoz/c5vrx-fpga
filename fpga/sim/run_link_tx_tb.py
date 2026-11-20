"""Triversity: link_tx in simulation. Runs tb_link_tx.v (channel 21, gain
model 2, calibration sequence 7, AFC not set), decodes the inverted 8N1 line
at the RTL's bit time and checks the frames against c5/main/fpga_link.h:
0xC5, tag, value, 0x79 ^ value ^ tag ^ 'C'.

    python fpga/sim/run_link_tx_tb.py
"""
import subprocess, sys, tempfile
from pathlib import Path
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import rtl as rtl_  # noqa: E402
BIT = 292                      # 33.75 MHz / 115200


def main():
    with tempfile.TemporaryDirectory() as t:
        subprocess.run(['iverilog', '-o', f'{t}/tb', str(HERE / 'tb_link_tx.v'), *rtl_.src('link_tx.v')], check=True)
        subprocess.run(['vvp', '-n', f'{t}/tb'], cwd=t, check=True, capture_output=True)
        line = [1 - int(x) for x in Path(t, 'lt.txt').read_text().split()]   # undo the inversion: idle high
    data, k = [], 0
    while k < len(line) - 10 * BIT:
        if line[k] == 0:                                  # start bit
            mid = k + BIT // 2
            assert line[mid] == 0, 'glitch'
            data.append(sum(line[mid + BIT * (i + 1)] << i for i in range(8)))
            assert line[mid + 9 * BIT] == 1, 'stop bit'
            k = mid + 9 * BIT
        else:
            k += 1
    frames, i = {}, 0
    while i + 4 <= len(data):
        if data[i] == 0xC5 and data[i + 3] == 0x79 ^ data[i + 2] ^ data[i + 1] ^ ord('C'):
            frames[chr(data[i + 1])] = data[i + 2]
            i += 4
        else:
            i += 1
    want = {'C': 21, 'G': 2, 'F': 7}
    print('frames', frames, 'bytes', len(data))
    ok = frames == want
    print('PASS' if ok else f'FAIL, want {want}')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
