// The active area stays at the same scanline even without a source row zero.
`timescale 1ns/1ps
module tb_lcd_physical_frame;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;
    wire de, hs, vs;
    lcd_out dut (.clk(clk), .rst(rst), .line_tog_a(1'b0), .line_info_a(9'd0),
                 .field_tog_a(1'b0), .locked_a(1'b1), .pal_a(1'b0), .hmode(2'd0),
                 .boot(1'b0), .lb_data(16'd0), .osd_cell(12'd0),
                 .lcd_de(de), .lcd_hs(hs), .lcd_vs(vs));

    integer scanlines = 0, active_lines = 0;
    reg prev_hs = 1, prev_vs = 1, prev_de = 0, armed = 0;
    always @(negedge clk) if (!rst) begin
        if (prev_vs && !vs) begin
            if (armed) begin
                if (scanlines != 525 || active_lines != 480)
                    $fatal(1, "frame had %0d scanlines and %0d active lines", scanlines, active_lines);
                $display("PASS: 525 scanlines, 480 active lines and fixed active start");
                $finish;
            end
            armed = 1;
            scanlines = 0;
            active_lines = 0;
        end
        if (prev_hs && !hs) scanlines = scanlines + 1;
        if (!prev_de && de) begin
            if (armed && active_lines == 0 && scanlines != 24)
                $fatal(1, "active video started at scanline %0d (expected 23)", scanlines - 1);
            active_lines = active_lines + 1;
        end
        prev_hs = hs;
        prev_vs = vs;
        prev_de = de;
    end
    initial begin
        repeat (4) @(negedge clk);
        #1 rst = 0;
        repeat (1500000) @(negedge clk);
        $fatal(1, "no complete LCD frame");
    end
endmodule
