"""Triversity: rtl/io/log_uart.v, the live status over the Tang Nano's USB
serial. The testbench feeds markers and video status, decodes the 8N1 output
and checks the text lines (a fast clock: 10 clocks a bit).

    python fpga/sim/run_log_uart_tb.py
"""
import subprocess, sys, tempfile
from pathlib import Path
HERE = Path(__file__).resolve().parent
RTL = HERE.parent / 'rtl'
CLK = 1152000            # 10 clocks a bit at 115200
TB = r'''
`timescale 1ns/1ps
module tb;
    reg clk = 0, rst = 1; always #5 clk = ~clk;
    reg mk_tog = 0; reg [1:0] mk_src = 3; reg [15:0] mk_pl = 0;
    reg locked = 1, pal = 0; reg [6:0] fr = 59, fp = 2; reg [15:0] k8 = 555, sq = 1580;
    wire tx;
    log_uart #(.CLK_HZ(__CLK__)) u (.clk(clk), .rst(rst), .mk_tog_a(mk_tog), .mk_src_a(mk_src), .mk_pl_a(mk_pl),
        .locked_a(locked), .pal_a(pal), .fps_real_a(fr), .fps_pred_a(fp), .k8_a(k8), .sync_q_a(sq), .tx(tx));
    task mark; input [1:0] s; input [15:0] p; begin
        @(negedge clk); mk_src = s; mk_pl = p; repeat (4) @(negedge clk); mk_tog = ~mk_tog; repeat (20) @(negedge clk);
    end endtask
    // 8N1 receiver: start edge, then the middle of each bit
    integer f, b; reg [7:0] rxb;
    initial begin
        f = $fopen("out.txt", "w");
        forever begin
            @(negedge tx); repeat (15) @(posedge clk);
            for (b = 0; b < 8; b = b + 1) begin rxb[b] = tx; repeat (10) @(posedge clk); end
            if (tx !== 1'b1) $fwrite(f, "<framing>");
            $fwrite(f, "%c", rxb);
        end
    end
    initial begin
        repeat (20) @(negedge clk); rst = 0;
        mark(0, {4'd2, 12'd54}); mark(0, {4'd3, 12'd1184}); mark(0, {4'd4, 12'd33}); mark(0, {4'd6, 12'd78});
        mark(1, {4'd2, 12'd61}); mark(1, {4'd3, 12'd1121}); mark(1, {4'd4, 12'd17}); mark(1, {4'd6, 12'd55});
        repeat (__TICK__ * 2) @(negedge clk);                       // lines 2, 3
        // B: C/N unknown, coarse lane; A: C/N -5.0 dB, Native AGC; PAL, no lock
        mark(1, {4'd3, 12'd0}); mark(1, {4'd4, 12'd1});
        mark(0, {4'd3, 12'd950}); mark(0, {4'd4, 12'd129});
        locked = 0; pal = 1; fr = 0; fp = 50; k8 = 3264; sq = 0;
        repeat (__TICK__ * 2) @(negedge clk);
        $fclose(f); $finish;
    end
endmodule
'''


def main():
    with tempfile.TemporaryDirectory() as t:
        t = Path(t)
        (t / 'tb.v').write_text(TB.replace('__CLK__', str(CLK)).replace('__TICK__', str(CLK // 10)))
        subprocess.run(['iverilog', '-g2012', '-s', 'tb', '-o', str(t / 'sim'), str(t / 'tb.v'), str(RTL / 'io' / 'log_uart.v')], check=True)
        subprocess.run(['vvp', '-n', str(t / 'sim')], cwd=t, check=True, capture_output=True)
        lines = (t / 'out.txt').read_bytes().decode('ascii', 'replace').split('\r\n')   # CR LF as sent
    for l in lines:
        print(repr(l))
    # values are read as they are while a line goes out: the first lines may hold markers
    # that arrived during them; check the content and the clock of complete lines
    full = lines[:-1]
    want = ['lock=1 pal=0 fps=59/2 k8=555 q=1580 A=G54,+18.4,u,78 B=G61,+12.1,f,55 C=-',
            'lock=0 pal=1 fps=0/50 k8=3264 q=0 A=G54,-5.0,n,78 B=G61,?,c,55 C=-']
    ok = all(any(l.endswith(' ' + w) for l in full) for w in want)
    ok &= [l.split()[0] for l in full] == [f't=0.{k + 1}' for k in range(len(full))]
    ok &= len(full) >= 4 and all('<framing>' not in l for l in lines)
    print('PASS' if ok else 'FAIL')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
