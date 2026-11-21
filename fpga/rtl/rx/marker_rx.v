// Triversity: in-band marker receiver for one C5 (c5/main/fpga_link.h).
// A C5 replaces its six FPGA data pads for ~12 us with six words, each held
// ~80 samples: 0x38, 0x07, then four payload words (0x20 | nibble,
// 0x10 | nibble, ...) = type (4 bits) and value (12 bits). This module
//  - detects a marker on the undelayed stream (a word held 48 samples),
//  - delays the stream by 128 samples so the combiner never sees a marker:
//    valid_d is 0 from 15 samples before the marker start until ~640
//    samples later (the marker plus slack),
//  - decodes the payload (ev pulses one clock with payload).
`default_nettype none
module marker_rx (
    input  wire        clk,
    input  wire        rst,
    input  wire [5:0]  raw,        // {I sign, I2, I1, Q sign, Q2, Q1}
    output reg  [5:0]  raw_d,      // raw delayed by 129 clocks
    output reg         valid_d = 1'b1,  // with raw_d: IQ (1) or marker (0)
    output reg         ev = 1'b0,       // one clock: a decoded marker
    output reg  [15:0] payload = 16'd0,
    output reg  [15:0] count       // markers decoded (status)
);
    localparam HOLD = 8'd48, INVAL = 10'd600, TIMEOUT = 9'd300;
    // ---- 128-sample delay of the stream and of its valid flag -----------
    (* ram_style = "block" *) reg [5:0] mem [0:127];   // BSRAM (read before write)
    integer     mi;
    initial for (mi = 0; mi < 128; mi = mi + 1) mem[mi] = 6'd0;
    reg [6:0]   wp = 7'd0;
    reg [127:0] vsr = {128{1'b1}};
    reg [9:0]   inval = 10'd0;
    reg         hit = 1'b0;
    always @(posedge clk) begin
        raw_d <= mem[wp];
        mem[wp] <= raw;
        wp <= wp + 7'd1;
        vsr <= hit ? {vsr[126:64], 65'd0} : {vsr[126:0], inval == 10'd0};
        valid_d <= vsr[127];
        if (rst) inval <= 10'd0;
        else if (hit) inval <= INVAL;
        else if (inval != 10'd0) inval <= inval - 10'd1;
    end
    // ---- run length and decode ---------------------------------------------
    reg [5:0] prev = 6'd0;
    reg [7:0] run = 8'd0;
    reg [2:0] stage = 3'd0;              // 0 idle, 1 expect 0x07, 2..5 payload words
    reg [8:0] age = 9'd0;
    reg [15:0] sh = 16'd0;
    wire held = run == HOLD;
    wire [5:0] mbit = stage[0] ? 6'h10 : 6'h20;   // stage 2: 0x20, 3: 0x10, 4: 0x20, 5: 0x10
    always @(posedge clk) begin
        ev  <= 1'b0;
        hit <= 1'b0;
        prev <= raw;
        run  <= raw != prev ? 8'd0 : (run == 8'hff ? run : run + 8'd1);
        if (rst) begin stage <= 3'd0; count <= 16'd0; age <= 9'd0; end
        else begin
            age <= stage == 3'd0 ? 9'd0 : age + 9'd1;
            if (stage != 3'd0 && age == TIMEOUT) stage <= 3'd0;
            else if (held) begin
                case (stage)
                    3'd0: if (raw == 6'h38) begin stage <= 3'd1; hit <= 1'b1; age <= 9'd0; end
                    3'd1: begin stage <= raw == 6'h07 ? 3'd2 : 3'd0; age <= 9'd0; end
                    default: begin
                        if ((raw & 6'h30) != mbit) stage <= 3'd0;
                        else begin
                            sh <= {sh[11:0], raw[3:0]};
                            age <= 9'd0;
                            if (stage == 3'd5) begin
                                stage <= 3'd0;
                                payload <= {sh[11:0], raw[3:0]};
                                ev <= 1'b1;
                                count <= count + 16'd1;
                            end else stage <= stage + 3'd1;
                        end
                    end
                endcase
            end
        end
    end
endmodule
`default_nettype wire
