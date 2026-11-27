// Triversity: the menu's stored settings (menu.v, c5/main/fpga_link.h).
// Marker 7 loads Keep lock, Adaptive sync, Noise filter, Logo, Aspect, Mode and
// Brightness once and arms the 'S' / 'T' link frames (s_set); a marker 7
// without stored settings only arms them; a second marker 7 is ignored.
// Marker 8 loads the Direct Gain model and AFC without arming 'G' / 'A'.
// python fpga/sim/run_menu_settings_tb.py
`timescale 1ns/1ps
module tb_menu_settings;
    reg clk = 0; always #14.815 clk = ~clk;
    reg rst = 1, mk_tog = 0; reg [1:0] mk_src = 2'd0; reg [15:0] mk_pl = 16'd0;
    wire [7:0] menu_s; wire [2:0] menu_t, gain_model; wire s_set, g_set, a_set, afc, klock, async_on, nfilt; wire [1:0] mode;
    menu #(.CLK_HZ(1000000)) u (.clk(clk), .rst(rst), .mk_tog_a(mk_tog), .mk_src_a(mk_src), .mk_pl_a(mk_pl), .s1_n(1'b1), .s2_n(1'b1),
        .locked_a(1'b1), .pal_a(1'b0), .sync_q_a(16'd0), .dvr_state_a(2'd0), .wide_a(1'b0),
        .osd_we(), .osd_waddr(), .osd_wdata(), .dvr(), .lg(), .mode(mode), .hmode(), .channel(), .link_on(),
        .g_set(g_set), .a_set(a_set), .gain_model(gain_model), .afc(afc), .f_seq(), .klock(klock), .async_on(async_on),
        .nfilt(nfilt), .menu_s(menu_s), .menu_t(menu_t), .s_set(s_set), .hz90(), .boot(), .bl_pwm());
    task mark; input [1:0] src; input [15:0] pl; begin
        @(negedge clk); mk_src = src; mk_pl = pl; repeat (4) @(negedge clk); mk_tog = ~mk_tog; repeat (20) @(negedge clk);
    end endtask
    integer errs = 0;
    task want; input cond; input [8*48-1:0] what; begin
        if (!cond) begin errs = errs + 1; $display("FAIL %0s: s=%h t=%0d s_set=%b model=%0d afc=%b g_set=%b", what, menu_s, menu_t, s_set, gain_model, afc, g_set); end
    end endtask
    initial begin
        repeat (10) @(negedge clk); rst = 0; repeat (10) @(negedge clk);
        want(menu_s == 8'hBF && menu_t == 3'd7 && !s_set, "defaults, frames not armed");
        // stored: mode 1 (Diversity), aspect 0 (4:3), logo 0, noise filter 1, adaptive 0, keep lock 1; brightness 3
        mark(2'd1, {4'd7, 1'b1, 3'd3, 2'd1, 2'd0, 1'b0, 1'b1, 1'b0, 1'b1});
        want(menu_s == 8'b01_00_0101 && menu_t == 3'd3 && s_set, "marker 7 loaded and armed");
        want(klock && !async_on && nfilt && mode == 2'd1, "the switches follow");
        mark(2'd0, {4'd7, 1'b1, 3'd7, 8'hFF});
        want(menu_s == 8'b01_00_0101 && menu_t == 3'd3, "a second marker 7 is ignored");
        // Ultra, AFC off: shown, 'G' / 'A' not armed (the C5 already has them)
        mark(2'd0, {4'd8, 9'd0, 1'b0, 2'd1});
        want(gain_model == 3'd5 && !afc && !g_set && !a_set, "marker 8 loaded, G / A not armed");
        mark(2'd0, {4'd8, 9'd0, 1'b1, 2'd2});
        want(gain_model == 3'd5 && !afc, "a second marker 8 is ignored");
        // a fresh C5 (nothing stored): marker 7 without bit 11 only arms the frames
        rst = 1; repeat (5) @(negedge clk); rst = 0; repeat (10) @(negedge clk);
        mark(2'd2, {4'd7, 1'b0, 3'd0, 8'h00});
        want(menu_s == 8'hBF && menu_t == 3'd7 && s_set, "nothing stored: defaults kept, armed");
        if (errs == 0) $display("PASS"); else $display("FAIL (%0d)", errs);
        $finish;
    end
endmodule
