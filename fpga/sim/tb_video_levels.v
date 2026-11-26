// Triversity: vid_sync on a code file (code.hex), one record per line start
// to lv.txt: sample, vline, locked, k8, tip, porch, written / black / saturated
// pixels of the line just finished, shown (0: concealed / not shown), fields_real (run_video_levels_tb.py, issue #12).
`timescale 1ns/1ps
module tb_video_levels;
    reg clk = 0, rst = 1;
    always #12.5 clk = ~clk;
    reg [5:0] mem [0:16000000];
    reg [5:0] code = 0;
    reg klk = 0; integer kv, n, k, fl;
    wire wr_en, locked; wire [10:0] wr_addr; wire [15:0] wr_data; wire [8:0] line_info;
    vid_sync u_vs (.clk(clk), .rst(rst), .code(code), .keep_lock(klk), .adapt(1'b0), .ans(1'b0),
                   .d3_on(1'b0), .d3_degrade(2'd0), .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data), .line_info(line_info), .locked(locked));
    integer nwr = 0, nblk = 0, nsat = 0;
    initial begin
        if (!$value$plusargs("n=%d", n)) n = 1000;
        if ($value$plusargs("keep=%d", kv)) klk = kv != 0;
        $readmemh("code.hex", mem);
        fl = $fopen("lv.txt", "w");
        #100 rst = 0;
        for (k = 0; k < n; k = k + 1) begin @(posedge clk); code <= mem[k]; end
        $fclose(fl); $finish;
    end
    always @(posedge clk) begin
        // at hc = 1 line_info holds the line just finished, whose pixels were counted
        if (!rst && u_vs.hc == 12'd1) begin
            $fwrite(fl, "%0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n", k, u_vs.vline, locked, u_vs.k8, u_vs.tip, u_vs.porch, nwr, nblk, nsat, line_info[8], u_vs.fields_real);
            nwr = 0; nblk = 0; nsat = 0;
        end
        if (wr_en) begin
            nwr = nwr + 1;
            if (wr_data == 16'h0000) nblk = nblk + 1;
            if (wr_data == 16'hffff) nsat = nsat + 1;
        end
    end
endmodule
