// Triversity: vid_sync alone; every pixel write as "field orow px data" to
// vs.txt (make_osd_video.py).
`timescale 1ns/1ps
module tb_vsync;
    reg clk = 0, rst = 1;
    always #12.5 clk = ~clk;
    reg [5:0] mem [0:4000000];
    reg [5:0] code = 0;
    wire wr_en, line_tog, field_tog, pal, locked; wire [10:0] wr_addr; wire [7:0] wr_data; wire [8:0] line_info; wire [15:0] sync_q;
    vid_sync u_vs (.clk(clk), .rst(rst), .code(code), .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
                   .line_tog(line_tog), .line_info(line_info), .field_tog(field_tog), .pal(pal), .locked(locked), .sync_q(sync_q));
    integer n, k, f, fld = 0; reg ft = 0;
    initial begin
        if (!$value$plusargs("n=%d", n)) n = 1000;
        $readmemh("code.hex", mem);
        f = $fopen("vs.txt", "w");
        #100 rst = 0;
        for (k = 0; k < n; k = k + 1) begin @(posedge clk); code <= mem[k]; end
        $fclose(f); $finish;
    end
    always @(posedge clk) begin
        if (field_tog != ft) begin ft <= field_tog; fld = fld + 1; end
        if (wr_en && locked) $fwrite(f, "%0d %0d %0d %0d\n", fld, u_vs.orow_cur, wr_addr[9:0], wr_data);
    end
endmodule
