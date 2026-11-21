// Triversity: vid_sync alone; every pixel write as "field orow px data" to
// vs.txt (make_osd_video.py).
`timescale 1ns/1ps
module tb_vsync;
    reg clk = 0, rst = 1;
    always #12.5 clk = ~clk;
    reg [5:0] mem [0:6000000];
    reg [5:0] code = 0;
    reg ans_on = 0; integer ansd = 0, fa;
    wire wr_en, line_tog, field_tog, pal, locked; wire [10:0] wr_addr; wire [15:0] wr_data; wire [7:0] wr_gray; wire [8:0] line_info; wire [15:0] sync_q;
    vid_sync u_vs (.clk(clk), .rst(rst), .keep_lock(1'b0), .adapt(1'b0), .ans_lev(), .ans(ans_on), .code(code), .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data), .wr_gray(wr_gray),
                   .line_tog(line_tog), .line_info(line_info), .field_tog(field_tog), .pal(pal), .locked(locked), .sync_q(sync_q));
    integer n, k, f, fl, fh, fld = 0; reg ft = 0; reg [11:0] hcp = 0; reg pp = 0;
    initial begin
        if (!$value$plusargs("n=%d", n)) n = 1000;
        $readmemh("code.hex", mem);
        if ($value$plusargs("ans=%d", ansd)) ans_on = ansd != 0;   // +ans=1: noise filter on, every clock to ans.txt
        if (ansd) fa = $fopen("ans.txt", "w");
        f = $fopen("vs.txt", "w"); fl = $fopen("ls.txt", "w"); fh = $fopen("hc.txt", "w");
        #100 rst = 0;
        for (k = 0; k < n; k = k + 1) begin @(posedge clk); code <= mem[k]; end
        $display("wide %0d pal %0d locked %0d", u_vs.wide, u_vs.pal, u_vs.locked);
        $fclose(f); $fclose(fl); $fclose(fh); $finish;
    end
    always @(posedge clk) begin
        // hc and pal of the code mem[k - 1] (both sampled before this edge): jumps only
        if (!rst && (u_vs.hc != hcp + 12'd1 || u_vs.pal != pp)) $fwrite(fh, "%0d %0d %0d\n", k - 1, u_vs.hc, u_vs.pal);
        hcp <= u_vs.hc; pp <= u_vs.pal;
        if (ansd && !rst) $fwrite(fa, "%0d %0d %0d %0d %0d %0d %0d\n", u_vs.hc, u_vs.cy8u, u_vs.ny, u_vs.nlev, u_vs.yacc, u_vs.nacc, u_vs.nln);
        if (!rst && u_vs.hc == 12'd0) $fwrite(fl, "%0d %0d %0d %0d\n", k, u_vs.pal, u_vs.locked, u_vs.vline);
        if (field_tog != ft) begin ft <= field_tog; fld = fld + 1; end
        if (wr_en && locked) $fwrite(f, "%0d %0d %0d %0d\n", fld, u_vs.orow_cur, wr_addr[9:0], wr_data);
    end
endmodule
