// Triversity: behavioural SD card in SPI mode for the DVR testbench (SDHC,
// block addressing). Image from sd.hex (bytes); CMD0/8/55/41/58/17/25 and the
// stop token; R1 after one 0xFF (NCR 1), ACMD41 busy for the first BUSY41
// tries, a programming busy of BUSY_BYTES bytes after each block.
`timescale 1ns/1ps
module sd_model #(parameter SECTORS = 4096, BUSY41 = 3, BUSY_BYTES = 40) (
    input  wire cs, sck, mosi,
    output reg  miso
);
    reg [7:0] mem [0:SECTORS*512-1];
    reg [7:0] outq [0:1023];
    integer   qh = 0, qt = 0;
    reg [7:0] rx = 0, tx = 8'hff, cmdb [0:5];
    integer   bitn = 0, ci = 0, n41 = 0, mode = 0, wi = 0, waddr = 0, k, blocks = 0;
    // mode 0 command, 1 multi-block write (waiting for a token), 2 receiving a block
    initial begin miso = 1'b1; $readmemh("sd.hex", mem); end
    task push; input [7:0] v; begin outq[qt] = v; qt = (qt + 1) % 1024; end endtask
    task r1; input [7:0] v; begin push(8'hff); push(v); end endtask
    task handle; input [7:0] v; integer a; begin
        if (mode == 2) begin
            if (wi < 512) mem[waddr * 512 + wi] = v;
            wi = wi + 1;
            if (wi == 514) begin
                push(8'h05); for (k = 0; k < BUSY_BYTES; k = k + 1) push(8'h00);
                waddr = waddr + 1; blocks = blocks + 1; mode = 1;
            end
        end else if (mode == 1) begin
            if (qh == qt) begin
                if (v == 8'hfc) begin mode = 2; wi = 0; end
                else if (v == 8'hfd) begin push(8'hff); for (k = 0; k < BUSY_BYTES; k = k + 1) push(8'h00); mode = 0; end
            end
        end else if (ci == 0 && (v & 8'hc0) == 8'h40 && qh == qt) begin cmdb[0] = v; ci = 1; end
        else if (ci > 0) begin
            cmdb[ci] = v; ci = ci + 1;
            if (ci == 6) begin
                ci = 0; a = {cmdb[1], cmdb[2], cmdb[3], cmdb[4]};
                case (cmdb[0] & 8'h3f)
                    0:  r1(8'h01);
                    8:  begin r1(8'h01); push(8'h00); push(8'h00); push(8'h01); push(8'haa); end
                    55: r1(8'h01);
                    41: begin n41 = n41 + 1; r1(n41 > BUSY41 ? 8'h00 : 8'h01); end
                    58: begin r1(8'h00); push(8'hc0); push(8'hff); push(8'h80); push(8'h00); end
                    17: begin r1(8'h00); push(8'hff); push(8'hff); push(8'hfe);
                              for (k = 0; k < 512; k = k + 1) push(mem[a * 512 + k]); push(8'h12); push(8'h34); end
                    25: begin r1(8'h00); waddr = a; mode = 1; end
                    default: r1(8'h04);
                endcase
            end
        end
    end endtask
    always @(posedge sck) if (!cs) begin
        rx = {rx[6:0], mosi}; bitn = bitn + 1;
        if (bitn == 8) begin bitn = 0; handle(rx); end
    end
    always @(negedge sck) if (!cs) begin
        if (bitn == 0) begin
            if (qh != qt) begin tx = outq[qh]; qh = (qh + 1) % 1024; end else tx = 8'hff;
            miso = tx[7];
        end else miso = tx[7 - bitn];
    end
    always @(posedge cs) begin bitn = 0; miso = 1'b1; end
endmodule
