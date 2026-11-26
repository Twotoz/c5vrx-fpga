// A live, asynchronous line source, a 10 ms fade, spurious field toggles
// and a real standard change. Count output clocks and complete active rows.
`timescale 1ps/1fs
module tb_hdmi_cadence;
    parameter signed PPM = 200;
    localparam real SOURCE_HALF = 12500.0 / (1.0 + PPM / 1.0e6);
    reg clk = 0, src = 0, rst = 1, good = 1, pal = 0;
    reg line_tog = 0, field_tog = 0;
    reg [7:0] line = 0;
    reg [15:0] pixel = 0;
    wire [10:0] addr;
    wire de, hs, vs;
    wire [4:0] r, b;
    wire [5:0] g;
    always #18518.519 clk = ~clk;
    always #SOURCE_HALF src = ~src;
    lcd_out dut (.clk(clk), .rst(rst), .line_tog_a(line_tog),
                 .line_info_a({good, line}), .field_tog_a(field_tog),
                 .locked_a(good), .pal_a(pal), .hmode(2'd0), .boot(1'b0),
                 .lb_addr(addr), .lb_data(pixel), .osd_addr(), .osd_cell(12'd0),
                 .lcd_de(de), .lcd_hs(hs), .lcd_vs(vs), .lcd_r(r), .lcd_g(g), .lcd_b(b),
                 .px_r(), .px_g(), .px_b());
    reg [15:0] bank [0:1];
    integer srccount = 0, source_clocks = 0, became_fresh = 0, first_pixel = 0;
    integer pix = 0, last_v = 0, last_h = 0, rows = 0, width = 0, frames = 0, pal_frames = 0;
    reg prev_v = 1, prev_h = 1, prev_de = 0, frame_pal = 0;
    initial begin bank[0] = 0; bank[1] = 0; end
    always @(posedge clk) pixel <= bank[addr[10]];
    always @(posedge src) begin
        source_clocks <= source_clocks + 1;
        if (srccount == (pal ? 2559 : 2541)) begin
            srccount <= 0;
            line <= line + 1'b1; line_tog <= ~line_tog;
            bank[~line[0]] <= good ? (became_fresh != 0 ? 16'hf800 : 16'h001f) : 16'd0;
        end else srccount <= srccount + 1;
    end
    always @(negedge clk) if (!rst) begin
        pix = pix + 1;
        if (prev_h && !hs) begin
            if (last_h != 0 && pix - last_h != 858 && pix - last_h != 864)
                $fatal(1, "truncated output line, clocks=%0d", pix - last_h);
            last_h = pix;
        end
        if (prev_v && !vs) begin
            if (last_v != 0) begin
                if (pix - last_v != (frame_pal ? 540000 : 450450) || rows != (frame_pal ? 576 : 480))
                    $fatal(1, "bad raster clocks=%0d rows=%0d pal=%b", pix - last_v, rows, frame_pal);
                frames = frames + 1;
                if (frame_pal) pal_frames = pal_frames + 1;
            end
            frame_pal = dut.pal_out; last_v = pix; rows = 0;
        end
        if (de) begin
            width = width + 1;
            if (r != 0 && became_fresh != 0 && first_pixel == 0) first_pixel = pix;
        end
        if (prev_de && !de) begin
            if (width != 720) $fatal(1, "truncated active row");
            rows = rows + 1; width = 0;
        end
        prev_h = hs; prev_v = vs; prev_de = de;
    end
    initial begin
        repeat (5) @(negedge clk); rst = 0;
        repeat (690000) @(negedge clk);
        good = 0; field_tog = ~field_tog;
        repeat (270000) @(negedge clk);  // 10 ms
        good = 1; became_fresh = pix; field_tog = ~field_tog;
        repeat (690000) @(negedge clk);
        pal = 1;
        repeat (1750000) @(negedge clk);
        if (first_pixel == 0 || first_pixel - became_fresh > 5000 || frames < 5 || pal_frames < 2)
            $fatal(1, "recovery or test coverage failed, first=%0d elapsed=%0d frames=%0d PAL=%0d",
                   first_pixel, first_pixel - became_fresh, frames, pal_frames);
        $display("HDMI cadence PASS: %0d full frames, %0d PAL, source %+0d ppm, fresh pixels after %0d output clocks",
                 frames, pal_frames, PPM, first_pixel - became_fresh);
        $finish;
    end
endmodule
