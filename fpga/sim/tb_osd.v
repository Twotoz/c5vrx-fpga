// Triversity: OSD testbench. menu.v + cell RAM + lcd_out.v with a synthetic
// genlocked video (RGB565 picture from video.hex, 240 rows of 800 pixels, every row
// shown twice) and C5 markers / buttons as the C5s send them. At each shot
// one whole LCD frame goes to shot_<n>.hex (RGB565 per pixel, 800 x 480);
// run_osd_tb.py compares it with fpga/gen/gen_osd.py's render().
`timescale 1ns/1ps
module tb_osd;
    wire [1:0] hm;
    reg clk = 0, rst = 1;
    always #14.815 clk = ~clk;                 // 33.75 MHz
    // ---- video source (as vid_sync + linebuf would deliver it) ----
    reg [15:0] pic [0:191999];
    reg [15:0] lb [0:2047];
    reg       line_tog = 0, field_tog = 0, locked = 1, pal = 0;
    reg [8:0] line_info = 0;
    reg [1:0] dvr_state = 2'd1;
    integer   vline = 0, vcnt = 0, i;
    always @(posedge clk) begin
        if (vcnt == 2144) begin
            vcnt <= 0;
            vline = vline == 261 ? 0 : vline + 1;
            if (vline == 0) field_tog <= ~field_tog;
            if (vline >= 18 && vline < 258) begin
                for (i = 0; i < 800; i = i + 1) lb[{vline[0] ^ 1'b0, 10'd0} + i] = pic[(vline - 18) * 800 + i];
                line_info <= {1'b1, 8'(vline - 18)};
            end else line_info <= 9'd0;
            line_tog <= ~line_tog;
        end else vcnt <= vcnt + 1;
    end
    // orow parity = (vline - 18)[0] = vline[0]: the half lcd_out reads
    wire [10:0] lb_raddr; reg [15:0] lb_rdata;
    always @(posedge clk) lb_rdata <= lb[lb_raddr];
    // ---- markers ----
    reg mk_tog = 0; reg [1:0] mk_src = 2'd3; reg [15:0] mk_pl = 0;
    task mark; input [1:0] src; input [15:0] pl; begin
        @(posedge clk) begin mk_src <= src; mk_pl <= pl; mk_tog <= ~mk_tog; end
        repeat (400) @(posedge clk);
    end endtask
    task press; input [4:0] b; begin mark(2'd0, {4'd1, 7'd0, b}); end endtask   // bit 0 UP, 1 SELECT, 2 DOWN, 4 long
    // ---- DUT ----
    reg [11:0] osd [0:2047];
    wire osd_we; wire [10:0] osd_waddr, osd_raddr; wire [11:0] osd_wdata; reg [11:0] osd_rdata;
    initial for (i = 0; i < 2048; i = i + 1) osd[i] = 0;
    always @(posedge clk) begin if (osd_we) osd[osd_waddr] <= osd_wdata; osd_rdata <= osd[osd_raddr]; end
    wire dvr; wire [1:0] mode;
    menu u_menu (.clk(clk), .rst(rst), .mk_tog_a(mk_tog), .mk_src_a(mk_src), .mk_pl_a(mk_pl), .s2_n(1'b1),
        .locked_a(locked), .pal_a(pal), .sync_q_a(16'd0), .dvr_state_a(dvr_state), .wide_a(1'b0),
        .osd_we(osd_we), .osd_waddr(osd_waddr), .osd_wdata(osd_wdata),
        .dvr(dvr), .mode(mode), .hmode(hm), .channel(), .link_on(), .g_set(), .a_set(), .gain_model(), .afc(), .f_seq(), .bl_pwm());
    wire de, hs, vs; wire [4:0] r, b; wire [5:0] g;
    lcd_out u_lcd (.clk(clk), .rst(rst), .line_tog_a(line_tog), .line_info_a(line_info), .field_tog_a(field_tog),
        .locked_a(locked), .pal_a(pal), .hmode(hm), .lb_addr(lb_raddr), .lb_data(lb_rdata), .osd_addr(osd_raddr), .osd_cell(osd_rdata),
        .lcd_de(de), .lcd_hs(hs), .lcd_vs(vs), .lcd_r(r), .lcd_g(g), .lcd_b(b));
    // ---- frame capture ----
    integer f, nshot = 0, row, col; reg cap = 0, de_p = 0, vs_p = 1, armed = 0;
    task shot; begin
        repeat (3000) @(posedge clk);            // renderer passes, state settled
        armed = 1; wait (!armed && !cap); nshot = nshot + 1;
    end endtask
    always @(posedge clk) begin
        if (armed && vs_p && !vs) begin
            armed = 0; cap = 1; row = 0; col = 0;
            f = $fopen($sformatf("shot_%0d.hex", nshot), "w");
        end
        if (cap && de) begin $fwrite(f, "%04x\n", {r, g, b}); col = col + 1; end
        if (cap && de_p && !de) begin row = row + 1; col = 0; if (row == 480) begin cap = 0; $fclose(f); end end
        de_p = de; vs_p = vs;
    end
    // ---- scenario (run_osd_tb.py SHOTS has the expected states) ----
    initial begin
        $readmemh("video.hex", pic);
        #100 rst = 0;
        repeat (100) @(posedge clk);
        mark(2'd0, {4'd5, 12'd8});                                   // C5 A: channel A1
        mark(2'd0, {4'd2, 12'd54}); mark(2'd0, {4'd3, 12'd1184}); mark(2'd0, {4'd4, 12'd1}); mark(2'd0, {4'd6, 12'd78});
        mark(2'd1, {4'd2, 12'd61}); mark(2'd1, {4'd3, 12'd1121}); mark(2'd1, {4'd4, 12'd1}); mark(2'd1, {4'd6, 12'd55});
        press(5'b00010);                                             // open
        press(5'b00100); press(5'b00100); press(5'b00100); press(5'b00010);   // Record: on
        dvr_state = 2'd2; repeat (20) @(posedge clk); u_menu.rec_m = 7'd1; u_menu.rec_s = 6'd23; u_menu.sec_ms = 10'd0;
        press(5'b00001); press(5'b00001); press(5'b00001);           // back to Channel
        shot;                                                        // 0 menu
        press(5'b00010); shot;                                       // 1 editing the channel
        press(5'b00010); press(5'b00100);                            // done; Mode
        press(5'b00010); press(5'b00100); shot;                      // 2 editing the mode: Diversity
        press(5'b00001); press(5'b00010); press(5'b00100);           // Triversity, done; Scan
        u_menu.scanning = 1'b1; u_menu.scan_ch = 6'd22; u_menu.scan_ms = 10'd0; u_menu.orig_ch = 6'd8;
        shot;                                                        // 3 scanning
        u_menu.scanning = 1'b0;
        press(5'b00100); press(5'b00100); press(5'b00010); shot;     // 4 receivers
        press(5'b00010); press(5'b00100); press(5'b00010);           // Back, Settings
        press(5'b00100); press(5'b00100); shot;                      // 5 settings, Aspect
        press(5'b00010); press(5'b00100); shot;                      // 6 editing Aspect: Stretch
        press(5'b00010);                                             // done
        press(5'b10010); shot;                                       // 7 closed: live view
        press(5'b00001); shot;                                       // 8 next channel (pill lit)
        locked = 0; repeat (20000) @(posedge clk); shot;             // 9 no signal
        $display("shots %0d", nshot);
        $finish;
    end
endmodule
