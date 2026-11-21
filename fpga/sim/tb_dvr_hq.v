// Triversity: dvr_hq.v with a synthetic DVR stream (NTSC timing: lines of 2542
// clocks, 720 pixels from clock 376 every 3 clocks, 262 lines a field) from
// field.hex (Y, Cb, Cr per pixel, 240 x 720), writing to sd_model, the field
// buffers in sdram_model; the card
// image goes to sd_out.hex at the end.
`timescale 1ns/1ps
module tb_dvr_hq #(parameter SECTORS = 4096, parameter BUSY = 40);
    reg clk = 0, rst = 1, rec = 0;
    always #12.5 clk = ~clk;
    reg [23:0] pic [0:172799];
    reg d_valid = 0, d_fstart = 0, d_parity = 0; reg [9:0] d_x = 0; reg [8:0] d_line = 0; reg [7:0] d_y = 0, d_cb = 0, d_cr = 0;
    wire sdclk, sdcke, sdcs, sdras, sdcas, sdwe; wire [10:0] sda; wire [1:0] sdba; wire [3:0] sddqm; wire [31:0] sddq;
    wire cs, sck, mosi, miso; wire [1:0] state; wire [2:0] qi; wire [15:0] fields, dropped;
    dvr_hq u (.clk(clk), .rst(rst), .rec(rec), .d_valid(d_valid), .d_x(d_x), .d_line(d_line), .d_y(d_y), .d_cb(d_cb), .d_cr(d_cr),
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
        rec = 1;
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
        wait (state == 2'd1);
        $display("stopped: fields %0d dropped %0d qi %0d blocks %0d sdram_errors %0d", fields, dropped, qi, u_sd.blocks, u_ram.errors);
        $writememh("sd_out.hex", u_sd.mem);
        $finish;
    end
    initial begin #3000000000; $display("TIMEOUT"); $finish; end
endmodule
