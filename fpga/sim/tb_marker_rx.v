`timescale 1ns/1ps
module tb_marker_rx;
    reg clk = 0, rst = 1;
    reg [5:0] raw = 0;
    wire [5:0] raw_d; wire valid_d, ev; wire [15:0] payload, count;
    marker_rx dut (.clk(clk), .rst(rst), .raw(raw), .raw_d(raw_d), .valid_d(valid_d), .ev(ev), .payload(payload), .count(count));
    always #12.5 clk = ~clk;
    integer f, k, n, seed;
    reg [5:0] mem [0:200000];
    initial begin
        if (!$value$plusargs("n=%d", n)) n = 1000;
        $readmemh("in.hex", mem);
        f = $fopen("out.hex", "w");
        repeat (3) @(posedge clk); #1 rst = 0;
        for (k = 0; k < n + 300; k = k + 1) begin
            raw = k < n ? mem[k] : 6'd0;
            @(posedge clk); #1;
            $fwrite(f, "%02x %0d %0d %04x\n", raw_d, valid_d, ev, payload);
        end
        $fclose(f); $finish;
    end
endmodule
