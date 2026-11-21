// Triversity: chroma.v alone on recorded codes and line counter; outputs of
// clocks K0..K1 to out.txt (run_chroma_tb.py compares with hw_decode).
`timescale 1ns/1ps
module tb_chroma;
    reg clk = 0, rst = 1;
    always #12.5 clk = ~clk;
    reg [5:0]  cm [0:6000000];
    reg [12:0] hp [0:6000000];
    reg [5:0]  code = 0; reg [11:0] hc = 12'd1; reg pal = 0;
    wire [9:0] y8u; wire signed [9:0] ug, vg;
    chroma u_c (.clk(clk), .rst(rst), .code(code), .hc(hc), .pal(pal), .y8u(y8u), .ug(ug), .vg(vg));
    integer n, k0, k1, f, cyc = 0;
    initial begin
        if (!$value$plusargs("n=%d", n)) n = 1000;
        if (!$value$plusargs("k0=%d", k0)) k0 = 0;
        if (!$value$plusargs("k1=%d", k1)) k1 = 1000;
        $readmemh("code.hex", cm); $readmemh("hcpal.hex", hp);
        f = $fopen("out.txt", "w");
        #100 rst = 0;
    end
    always @(posedge clk) if (!rst) begin
        code <= cm[cyc]; {pal, hc} <= hp[cyc]; cyc <= cyc + 1;
        // outputs now belong to the cycle with inputs cyc - 1
        if (cyc - 1 >= k0 && cyc - 1 < k1) $fwrite(f, "%0d %0d %0d %0d\n", cyc - 1, y8u, ug, vg);
        if (cyc == n) begin $fclose(f); $finish; end
    end
endmodule
