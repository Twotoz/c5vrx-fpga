// Triversity: link to the C5s (c5/main/fpga_link.h), one UART wire to
// D10 of all three, 115200 8N1, sent inverted: the line idles low (pin 51 of
// the Tang Nano 20K also enables its audio amplifier, which then stays off).
// Frames 0xC5, tag, value, 0x79 ^ value ^ tag ^ 'C', repeated: 'C' channel,
// 'G' gain model and 'A' AFC only once the menu changed them, 'F' the
// calibration sequence number. Silent until `on`.
`default_nettype none
module link_tx #(parameter CLK_HZ = 33750000, parameter BAUD = 115200) (
    input  wire       clk,
    input  wire       rst,
    input  wire       on,
    input  wire [5:0] channel,
    input  wire       g_set,
    input  wire [1:0] gain_model,
    input  wire       a_set,
    input  wire       afc,
    input  wire [7:0] f_seq,
    output reg        tx                 // inverted line
);
    localparam DIV = CLK_HZ / BAUD;
    reg [15:0] bt; reg [3:0] bitn; reg [9:0] sh; reg busy;
    reg [1:0]  bi;                       // byte in frame
    reg [1:0]  fsel;                     // frame: 0 C, 1 G, 2 A, 3 F
    reg [7:0]  gap;
    wire [7:0] tag = fsel == 2'd0 ? 8'h43 : fsel == 2'd1 ? 8'h47 : fsel == 2'd2 ? 8'h41 : 8'h46;
    wire [7:0] val = fsel == 2'd0 ? {2'd0, channel} : fsel == 2'd1 ? {6'd0, gain_model} : fsel == 2'd2 ? {7'd0, afc} : f_seq;
    wire [7:0] byte_now = bi == 2'd0 ? 8'hC5 : bi == 2'd1 ? tag : bi == 2'd2 ? val : (8'h79 ^ val ^ tag ^ 8'h43);
    wire       skip = (fsel == 2'd1 && !g_set) || (fsel == 2'd2 && !a_set);
    always @(posedge clk) begin
        if (rst) begin busy <= 1'b0; bi <= 2'd0; fsel <= 2'd0; gap <= 8'd0; tx <= 1'b0; end
        else if (busy) begin
            if (bt == DIV - 1) begin
                bt <= 16'd0;
                tx <= ~sh[0];            // inverted
                sh <= {1'b1, sh[9:1]};
                if (bitn == 4'd10) busy <= 1'b0; else bitn <= bitn + 4'd1;   // start, 8 data, stop, one stop period
            end else bt <= bt + 16'd1;
        end else if (gap != 8'd0) begin
            if (bt == DIV - 1) begin bt <= 16'd0; gap <= gap - 8'd1; end else bt <= bt + 16'd1;
            tx <= 1'b0;
        end else if (on) begin
            if (bi == 2'd0 && skip) fsel <= fsel + 2'd1;
            else begin
                sh <= {1'b1, byte_now, 1'b0};     // stop, data LSB first, start
                busy <= 1'b1; bitn <= 4'd0; bt <= DIV - 1;
                if (bi == 2'd3) begin bi <= 2'd0; fsel <= fsel + 2'd1; gap <= 8'd20; end
                else bi <= bi + 2'd1;
            end
        end else tx <= 1'b0;
    end
endmodule
`default_nettype wire
