// Triversity: video path testbench. Demodulator codes (code.hex, 40 MS/s)
// -> vid_sync -> linebuf -> lcd_out, with the menu rendering the OSD; every
// LCD pixel with DE is written to lcd.txt as "frame row col r g b".
`timescale 1ns/1ps
module tb_video;
    reg clk_a = 0, clk_l = 0, rst = 1;
    always #12.5 clk_a = ~clk_a;
    always #14.815 clk_l = ~clk_l;          // 33.75 MHz
    reg [5:0] mem [0:4000000];
    reg [5:0] code = 0;
    wire wr_en, line_tog, field_tog, pal, locked; wire [10:0] wr_addr; wire [7:0] wr_data; wire [8:0] line_info; wire [15:0] sync_q;
    vid_sync u_vs (.clk(clk_a), .rst(rst), .code(code), .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
                   .line_tog(line_tog), .line_info(line_info), .field_tog(field_tog), .pal(pal), .locked(locked), .sync_q(sync_q));
    wire [10:0] lb_raddr; wire [7:0] lb_rdata;
    linebuf u_lb (.wclk(clk_a), .we(wr_en), .waddr(wr_addr), .wdata(wr_data), .rclk(clk_l), .raddr(lb_raddr), .rdata(lb_rdata));
    reg [7:0] osd [0:2047]; wire osd_we; wire [10:0] osd_waddr, osd_raddr; wire [7:0] osd_wdata; reg [7:0] osd_rdata;
    integer i; initial for (i = 0; i < 2048; i = i + 1) osd[i] = 0;
    always @(posedge clk_l) begin if (osd_we) osd[osd_waddr] <= osd_wdata; osd_rdata <= osd[osd_raddr]; end
    wire bl;
    menu #(.CLK_HZ(33750000)) u_menu (.clk(clk_l), .rst(rst), .mk_tog_a(1'b0), .mk_src_a(2'd3), .mk_pl_a(16'd0), .s2_n(1'b1),
        .locked_a(locked), .pal_a(pal), .sync_q_a(sync_q), .osd_we(osd_we), .osd_waddr(osd_waddr), .osd_wdata(osd_wdata),
        .dvr(), .channel(), .link_on(), .g_set(), .a_set(), .gain_model(), .afc(), .f_seq(), .bl_pwm(bl));
    wire de, hs, vs; wire [4:0] r, b; wire [5:0] g;
    lcd_out u_lcd (.clk(clk_l), .rst(rst), .line_tog_a(line_tog), .line_info_a(line_info), .field_tog_a(field_tog),
        .locked_a(locked), .pal_a(pal), .lb_addr(lb_raddr), .lb_data(lb_rdata), .osd_addr(osd_raddr), .osd_char(osd_rdata),
        .lcd_de(de), .lcd_hs(hs), .lcd_vs(vs), .lcd_r(r), .lcd_g(g), .lcd_b(b));
    integer n, k, f, frame = 0, row = 0, col = 0; reg de_p = 0;
    initial begin
        if (!$value$plusargs("n=%d", n)) n = 1000;
        $readmemh("code.hex", mem);
        f = $fopen("lcd.txt", "w");
        #100 rst = 0;
        for (k = 0; k < n; k = k + 1) begin @(posedge clk_a); code <= mem[k]; end
        $fclose(f); $finish;
    end
    always @(posedge clk_l) begin
        if (!vs) begin frame = frame + 1; row = 0; end
        if (de) begin $fwrite(f, "%0d %0d %0d %0d %0d %0d\n", frame, row, col, r, g, b); col = col + 1; end
        if (de_p && !de) begin row = row + 1; col = 0; end
        de_p = de;
    end
endmodule
