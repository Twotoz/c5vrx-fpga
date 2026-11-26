// Receive field events from a full CVBS code trace, including held-over fields.
`timescale 1ns/1ps
module tb_cvbs_fields;
    reg clk = 0, rst = 1;
    reg [5:0] codes [0:6399999];
    reg [5:0] code = 25;
    reg keep;
    integer n, k;
    wire pal;
    always #12.5 clk = ~clk;
    vid_sync rx (.clk(clk), .rst(rst), .code(code), .keep_lock(keep), .adapt(1'b0),
                 .ans(1'b0), .pal(pal));
    initial begin
        if (!$value$plusargs("n=%d", n) || !$value$plusargs("keep=%d", k)) $fatal(1, "missing trace arguments");
        keep = k != 0;
        $readmemh("video.hex", codes, 0, n - 1);
        repeat (4) @(negedge clk);
        rst = 0;
        for (k = 0; k < n; k = k + 1) begin
            code = codes[k];
            #1;
            if (rx.field_event) $display("field %0d %0d %0d", k, pal, rx.field_accept);
            @(negedge clk);
        end
        $finish;
    end
endmodule
