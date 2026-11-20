// Triversity: DVR testbench. A synthetic NTSC field stream (vid_sync's pixel
// write pattern: 240 rows of 800 pixels, 262.5 lines of 2542 clocks) into
// dvr.v, writing to sd_model; at the end the card image goes to sd_out.hex.
`timescale 1ns/1ps
module tb_dvr #(parameter BUSY = 40);
    reg clk = 0, rst = 1, rec = 0;
    always #12.5 clk = ~clk;
    reg px_we = 0; reg [10:0] px_addr = 0; reg [7:0] px_data = 0; reg field_tog = 0;
    wire cs, sck, mosi, miso; wire [1:0] state; wire [15:0] frames, dropped;
    dvr u_dvr (.clk(clk), .rst(rst), .rec(rec), .px_we(px_we), .px_addr(px_addr), .px_data(px_data),
               .field_tog(field_tog), .pal(1'b0), .sd_cs(cs), .sd_sck(sck), .sd_mosi(mosi), .sd_miso(miso),
               .state(state), .frames(frames), .dropped(dropped));
    sd_model #(.SECTORS(3072), .BUSY_BYTES(BUSY)) u_sd (.cs(cs), .sck(sck), .mosi(mosi), .miso(miso));
    integer fld = 0, line, x, nfields;
    // field f, row r, pixel x: a gray pattern the checker can recompute
    function [7:0] pix; input integer f, r, x; pix = ((x / 8 + r / 4 + f * 3) % 16) << 4; endfunction
    initial begin
        if (!$value$plusargs("fields=%d", nfields)) nfields = 12;
        #200 rst = 0;
        wait (state == 2'd1);
        $display("card ready at %0t ns: file_lba=%0d sectors=%0d", $time, u_dvr.file_lba, u_dvr.file_sect);
        rec = 1;
        repeat (100) @(posedge clk);
        for (fld = 0; fld < nfields; fld = fld + 1) begin
            @(posedge clk) field_tog <= ~field_tog;
            for (line = 0; line < 262; line = line + 1) begin
                if (line >= 18 && line < 258) begin
                    repeat (376) @(posedge clk);
                    for (x = 0; x < 800; x = x + 1) begin
                        @(posedge clk) begin px_we <= 1; px_addr <= {line[0], x[9:0]}; px_data <= pix(fld, line - 18, x); end
                        @(posedge clk) px_we <= 0;
                        if (x % 3 == 0) @(posedge clk);
                    end
                    repeat (2542 - 376 - 1867) @(posedge clk);
                end else repeat (2542) @(posedge clk);
            end
            $display("field %0d done at %0t ns: state=%0d frames=%0d dropped=%0d ring=%0d pos=%0d", fld, $time, state,
                     frames, dropped, u_dvr.used, u_dvr.pos);
        end
        rec = 0;
        wait (state == 2'd1);
        $display("stopped at %0t ns: frames=%0d dropped=%0d blocks=%0d", $time, frames, dropped, u_sd.blocks);
        $writememh("sd_out.hex", u_sd.mem);
        $finish;
    end
    initial begin #2000000000; $display("TIMEOUT state=%0d st=%0d", state, u_dvr.st); $finish; end
    always @(state) $display("state %0d at %0t ns (st %0d)", state, $time, u_dvr.st);
endmodule
