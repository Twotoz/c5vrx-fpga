`timescale 1ns/1ps
module tb_fade_failover;
    parameter FAILOVER = 1;
    reg clk = 0, rst = 1;
    reg [20:0] stimulus [0:524287], sample = 0;
    wire [7:0] a, b, c;
    wire en_b, en_c, alive_b, alive_c, ref_lost;
    wire [5:0] code;
    wire [2:0] valid = sample[20:18];
    integer k, n;
    always #12.5 clk = ~clk;

    function [7:0] nib;
        input [5:0] r;
        nib = {r[5:3], 1'b0, r[2:0], 1'b0};
    endfunction
    align_bc align (.clk_a(clk), .clk_b(clk), .clk_c(clk), .rst_a(rst),
                    .ref_lost(ref_lost), .raw_a(nib(sample[5:0])),
                    .raw_b_in(nib(sample[11:6])), .raw_c_in(nib(sample[17:12])),
                    .raw_a_d(a), .raw_b(b), .raw_c(c), .en_b(en_b), .en_c(en_c),
                    .b_alive(alive_b), .c_alive(alive_c), .lag_b(), .lag_c());
    mrc3_core #(.FAILOVER(FAILOVER)) dut (
        .clk(clk), .rst(rst), .raw_a({a[7:5], a[3:1]}),
        .raw_b({b[7:5], b[3:1]}), .raw_c({c[7:5], c[3:1]}),
        .en_b(en_b), .en_c(en_c), .avail_b(alive_b), .avail_c(alive_c),
        .va(valid[0]), .vb(valid[1]), .vc(valid[2]), .rmode(2'd1),
        .code(code), .ract(), .d3_degrade(), .ref_lost(ref_lost), .wts());
    initial begin
        if (!$value$plusargs("n=%d", n)) $fatal(1, "missing sample count");
        $readmemh("fade.hex", stimulus, 0, n - 1);
        repeat (4) @(negedge clk);
        rst = 0;
        for (k = 0; k < n; k = k + 1) begin
            sample = stimulus[k];
            @(negedge clk);
            $display("%03x", {en_c, en_b, dut.source4, code});
        end
        $finish;
    end
endmodule
