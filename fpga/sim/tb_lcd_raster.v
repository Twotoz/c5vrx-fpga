// The LCD must keep complete lines and a full active frame during source changes.
`timescale 1ns/1ps
module tb_lcd_raster;
    reg clk = 0;
    always #5 clk = ~clk;

    reg rst = 1, line_tog = 0, field_tog = 0, locked = 0, pal = 0;
    reg [8:0] line_info = 0;
    wire de, hs, vs;
    lcd_out dut (.clk(clk), .rst(rst), .line_tog_a(line_tog), .line_info_a(line_info),
                 .field_tog_a(field_tog), .locked_a(locked), .pal_a(pal), .hmode(2'd1),
                 .boot(1'b0), .lb_data(16'hf800), .osd_cell(12'd0),
                 .lcd_de(de), .lcd_hs(hs), .lcd_vs(vs));

    integer cycles = 0, frame_count = 0, active_lines = 0, active_pixels = 0;
    integer last_hs = 0, last_active = 0;
    reg prev_de = 0, prev_hs = 1, prev_vs = 1;
    reg in_frame = 0;
    always @(negedge clk) if (!rst) begin
        cycles = cycles + 1;
        if (prev_hs && !hs) begin
            if (last_hs != 0 && (cycles - last_hs < 1064 || cycles - last_hs > 1088))
                $fatal(1, "LCD line length %0d", cycles - last_hs);
            last_hs = cycles;
        end
        if (prev_vs && !vs) begin
            if (in_frame && active_lines != 480)
                $fatal(1, "frame had %0d active rows", active_lines);
            if (in_frame) frame_count = frame_count + 1;
            in_frame = 1;
            active_lines = 0;
        end
        if (de) active_pixels = active_pixels + 1;
        if (prev_de && !de) begin
            if (active_pixels != 800) $fatal(1, "line had %0d active pixels", active_pixels);
            if (active_lines != 0 && cycles - last_active > 1088)
                $fatal(1, "gap inside the active frame");
            active_pixels = 0;
            active_lines = active_lines + 1;
            last_active = cycles;
        end
        prev_de = de;
        prev_hs = hs;
        prev_vs = vs;
    end

    integer n;
    initial begin
        repeat (4) @(negedge clk);
        #1 rst = 0;
        for (n = 0; n < 1700; n = n + 1) begin
            // Source edges can be early, late, missing, or imply a different standard.
            repeat ((n % 31 == 0) ? 783 : ((n % 11 == 0) ? 2290 : 2145)) @(negedge clk);
            #1 line_tog = ~line_tog;
            line_info = {(n % 7 != 0), n[7:0]};
            if (n % 263 == 0 || n % 43 == 0) field_tog = ~field_tog;
            if (n == 120 || n == 670 || n == 1200) locked = ~locked;
            if (n == 370 || n == 1050) pal = ~pal;
        end
        if (frame_count < 4) $fatal(1, "too few complete frames");
        $display("PASS: %0d complete 800x480 frames through lock and standard changes", frame_count);
        $finish;
    end
endmodule
