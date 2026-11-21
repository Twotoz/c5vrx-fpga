"""Triversity: rtl/video/tmds_enc.v against model/tmds_model.py: random video
and blanking, symbol for symbol; every symbol decodes back to its input and
the running disparity stays within the DVI bound.

    python fpga/sim/run_tmds_tb.py
"""
import random, subprocess, sys, tempfile
from pathlib import Path
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE.parent / 'model'))
import rtl as rtl_  # noqa: E402
import tmds_model as T  # noqa: E402

TB = r'''
`timescale 1ns/1ps
module tb;
    reg clk = 0; always #5 clk = ~clk;
    reg [10:0] mem [0:N-1]; reg de = 0; reg [7:0] d = 0; reg [1:0] c = 0; wire [9:0] q;
    tmds_enc u (.clk(clk), .de(de), .d(d), .c(c), .q(q));
    integer i, f;
    initial begin
        $readmemh("in.hex", mem); f = $fopen("out.hex", "w");
        for (i = 0; i < N; i = i + 1) begin {de, c, d} = mem[i]; @(posedge clk); #1 $fwrite(f, "%03x\n", q); end
        $fclose(f); $finish;
    end
endmodule
'''


def main():
    rnd = random.Random(3)
    stream = []
    for _ in range(40):
        stream += [(1, rnd.choice([rnd.randrange(256), 0, 255, 0x10, 0xeb, 0x80]), 0) for _ in range(rnd.randrange(20, 200))]
        stream += [(0, 0, rnd.randrange(4)) for _ in range(rnd.randrange(4, 30))]
    want = T.encode(stream)
    with tempfile.TemporaryDirectory() as t:
        t = Path(t)
        (t / 'tb.v').write_text(TB.replace('N-1', str(len(stream) - 1)).replace('N;', f'{len(stream)};'))
        (t / 'in.hex').write_text('\n'.join(f'{de << 10 | c << 8 | d:03x}' for de, d, c in stream) + '\n')
        subprocess.run(['iverilog', '-g2012', '-o', str(t / 'sim'), str(t / 'tb.v'), *rtl_.src('tmds_enc.v')], check=True)
        subprocess.run(['vvp', '-n', str(t / 'sim')], cwd=t, check=True, capture_output=True)
        got = [int(x, 16) for x in (t / 'out.hex').read_text().split()]
    same = got == want
    back = all(T.decode(q) == (('d', d) if de else ('c', c)) for q, (de, d, c) in zip(want, stream))
    disp, worst = 0, 0
    for q, (de, d, c) in zip(want, stream):
        disp = disp + 2 * bin(q).count('1') - 10 if de else 0
        worst = max(worst, abs(disp))
    print(f'{len(stream)} symbols: RTL {"identical" if same else "DIFFERENT"} to the model, decode {"ok" if back else "FAIL"}, '
          f'worst running disparity {worst} (DVI: <= 10)')
    ok = same and back and worst <= 10
    print('PASS' if ok else 'FAIL')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
