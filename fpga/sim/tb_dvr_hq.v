// Triversity: dvr_hq.v with a synthetic DVR stream (NTSC timing: lines of 2542
// clocks, 720 pixels from clock 376 every 3 clocks, 262 lines a field) from
// field.hex (Y, Cb, Cr per pixel, 240 x 720), writing to sd_model, the field
// buffers in sdram_model; the card
// image goes to sd_out.hex at the end.
`timescale 1ns/1ps
module tb_dvr_hq #(parameter SECTORS = 4096, parameter BUSY = 40);
    reg clk = 0, rst = 1, rec = 0, lg = 0;
    reg [135:0] lgd = 136'd0;
    always #12.5 clk = ~clk;
    reg [23:0] pic [0:172799];
    reg d_valid = 0, d_fstart = 0, d_parity = 0; reg [9:0] d_x = 0; reg [8:0] d_line = 0; reg [7:0] d_y = 0, d_cb = 0, d_cr = 0;
    wire sdclk, sdcke, sdcs, sdras, sdcas, sdwe; wire [10:0] sda; wire [1:0] sdba; wire [3:0] sddqm; wire [31:0] sddq;
    wire cs, sck, mosi, miso; wire [1:0] state; wire [2:0] qi; wire [15:0] fields, dropped;
    integer logm = 0;
    dvr_hq #(.LOG_FIELDS(3'd1)) u (.clk(clk), .rst(rst), .rec(rec), .lg(lg), .lg_data(lgd), .d_valid(d_valid), .d_x(d_x), .d_line(d_line), .d_y(d_y), .d_cb(d_cb), .d_cr(d_cr),
              .d_fstart(d_fstart), .d_parity(d_parity), .pal(1'b0), .sd_cs(cs), .sd_sck(sck), .sd_mosi(mosi), .sd_miso(miso),
              .state(state), .qi(qi), .fields(fields), .dropped(dropped),
              .O_sdram_clk(sdclk), .O_sdram_cke(sdcke), .O_sdram_cs_n(sdcs), .O_sdram_ras_n(sdras), .O_sdram_cas_n(sdcas),
              .O_sdram_wen_n(sdwe), .O_sdram_addr(sda), .O_sdram_ba(sdba), .O_sdram_dqm(sddqm), .IO_sdram_dq(sddq));
    sdram_model u_ram (.clk(sdclk), .cke(sdcke), .cs_n(sdcs), .ras_n(sdras), .cas_n(sdcas), .we_n(sdwe), .addr(sda), .ba(sdba),
                       .dqm(sddqm), .dq(sddq));
    sd_model #(.SECTORS(SECTORS), .BUSY_BYTES(BUSY)) u_sd (.cs(cs), .sck(sck), .mosi(mosi), .miso(miso));
    integer fld, line, x, nf;
    initial begin
        if (!$value$plusargs("fields=%d", nf)) nf = 4;
        $readmemh("field.hex", pic);
        #200 rst = 0;
        wait (state == 2'd1);
        $display("card ready at %0t", $time);
        if ($value$plusargs("log=%d", logm)) ;
        for (x = 0; x < 17; x = x + 1) lgd[8 * x +: 8] = 8'h40 + x;
        rec = 1; lg = logm != 0;
        repeat (50) @(posedge clk);
        for (fld = 0; fld < nf; fld = fld + 1) begin
            @(posedge clk) begin d_fstart <= 1; d_parity <= fld[0]; end
            @(posedge clk) d_fstart <= 0;
            for (line = 0; line < 262; line = line + 1) begin
                if (line >= 20 && line < 260) begin
                    repeat (376) @(posedge clk);
                    for (x = 0; x < 720; x = x + 1) begin
                        @(posedge clk) begin d_valid <= 1; d_x <= x; d_line <= line - 20;
                            {d_y, d_cb, d_cr} <= pic[(line - 20) * 720 + x]; end
                        @(posedge clk) d_valid <= 0;
                        @(posedge clk);
                    end
                    repeat (2542 - 376 - 2160) @(posedge clk);
                end else repeat (2542) @(posedge clk);
            end
            $display("field %0d sent: fields %0d dropped %0d qi %0d ring %0d", fld, fields, dropped, qi, u.used);
        end
        rec = 0;
        if (lg) begin   // log only: four more field starts (no pixels), once rec has crossed the synchroniser
            repeat (16) @(posedge clk);
            repeat (4) begin @(posedge clk) d_fstart <= 1; @(posedge clk) d_fstart <= 0; repeat (66000) @(posedge clk); end
            lg = 0;
        end
        wait (state == 2'd1);
        $display("stopped: fields %0d dropped %0d qi %0d blocks %0d sdram_errors %0d", fields, dropped, qi, u_sd.blocks, u_ram.errors);
        $writememh("sd_out.hex", u_sd.mem);
        $finish;
    end
    initial begin #3000000000; $display("TIMEOUT"); $finish; end
`ifdef DBG
    reg xseen = 0; always @(posedge clk) if (!rst && !xseen && (^u.fr === 1'bx || ^u.f_pop === 1'bx)) begin xseen = 1; $display("X at %0t: fr=%b f_pop=%b wnext=%b dmark=%b fq_ok=%b fq=%h st=%0d we=%b reqwe=%b sreq=%b fw=%0d", $time, u.fr, u.f_pop, u.s_wnext, u.d_mark, u.fq_ok, u.fq, u.u_ram.st, u.u_ram.we, u.s_we, u.s_req, u.fw); end
    initial begin #150; repeat (12) begin @(posedge clk); #1 $display("rst=%b fr=%0d fq_ok=%b f_pop=%b wnext=%b dmark=%b fq=%h fw=%0d", rst, u.fr, u.fq_ok, u.f_pop, u.s_wnext, u.d_mark, u.fq, u.fw); end end
    always begin #2000000;
        $display("t=%0t inf=%b end=%b fph=%0d my=%0d mx=%0d blk=%0d yl=%0d cl=%0d comp=%b dslot=%0d shead=%0d scnt=%0d ram_st=%0d fq_ok=%b fw=%0d fr=%0d rwant=%b erdy=%b ebusy=%b",
            $time, u.in_field, u.ending, u.fph, u.my, u.mx, u.blk, u.yl, u.cl, u.comp, u.dslot, u.shead, u.scnt, u.u_ram.st, u.fq_ok, u.fw, u.fr, u.r_want, u.e_rdy, u.e_busy);
    end
`endif
endmodule
