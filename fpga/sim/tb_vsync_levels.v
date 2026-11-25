// The slicer must retain lock when the measured tip plus porch exceeds 511.
`timescale 1ns/1ps
module tb_vsync_levels;
    reg clk = 0, rst = 1;
    always #12.5 clk = ~clk;
    reg [5:0] code = 6'd25;
    wire locked;
    vid_sync dut (.clk(clk), .rst(rst), .code(code), .keep_lock(1'b0),
                  .adapt(1'b0), .ans(1'b0), .locked(locked));

    integer line, sample;
    initial begin
        repeat (64) @(negedge clk);
        rst = 0;
        for (line = 0; line < 64; line = line + 1) begin
            for (sample = 0; sample < 2542; sample = sample + 1) begin
                // Sync tip near 256 in the slicer's units, porch near 288.
                code = sample < 184 ? 6'd32 : sample < 360 ? 6'd36 : 6'd40;
                @(negedge clk);
            end
        end
        if (!locked || !dut.lev_n[4] || int'(dut.tip) + int'(dut.porch) < 512)
            $fatal(1, "high-level sync failed: locked=%b levels=%0d tip=%0d porch=%0d slice=%0d",
                   locked, dut.lev_n, dut.tip, dut.porch, dut.slice);
        $display("PASS: locked at tip=%0d porch=%0d slice=%0d", dut.tip, dut.porch, dut.slice);
        $finish;
    end
endmodule
