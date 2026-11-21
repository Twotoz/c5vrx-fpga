// Triversity: DVI / HDMI TMDS encoder for one channel (DVI 1.0, 3.2.1):
// transition-minimised 8 -> 9 bits, then DC balance with a running disparity;
// the four control symbols in the blanking. One symbol a pixel clock,
// registered. model/tmds_model.py is the reference (sim/run_tmds_tb.py).
`default_nettype none
module tmds_enc (
    input  wire       clk,
    input  wire       de,          // video data
    input  wire [7:0] d,
    input  wire [1:0] c,           // control (blanking): {c1, c0}
    output reg  [9:0] q
);
    function [3:0] ones8; input [7:0] v; integer i; begin ones8 = 4'd0; for (i = 0; i < 8; i = i + 1) ones8 = ones8 + v[i]; end endfunction
    wire [3:0] n1d = ones8(d);
    wire       xn = n1d > 4'd4 || (n1d == 4'd4 && !d[0]);
    wire [8:0] qm;
    assign qm[0] = d[0];
    genvar i;
    generate for (i = 1; i < 8; i = i + 1) begin : m
        assign qm[i] = xn ? ~(qm[i-1] ^ d[i]) : (qm[i-1] ^ d[i]);
    end endgenerate
    assign qm[8] = ~xn;
    wire [3:0] n1 = ones8(qm[7:0]);
    wire signed [5:0] bal = $signed({2'b0, n1}) - 6'sd4;          // (ones - zeros) / 2
    reg  signed [5:0] cnt = 6'sd0;                                // running disparity / 2
    always @(posedge clk) begin
        if (!de) begin
            cnt <= 6'sd0;
            case (c)
                2'b00: q <= 10'b1101010100;
                2'b01: q <= 10'b0010101011;
                2'b10: q <= 10'b0101010100;
                default: q <= 10'b1010101011;
            endcase
        end else if (cnt == 6'sd0 || bal == 6'sd0) begin
            q <= {~qm[8], qm[8], qm[8] ? qm[7:0] : ~qm[7:0]};
            cnt <= qm[8] ? cnt + bal : cnt - bal;
        end else if ((cnt > 6'sd0 && bal > 6'sd0) || (cnt < 6'sd0 && bal < 6'sd0)) begin
            q <= {1'b1, qm[8], ~qm[7:0]};
            cnt <= cnt + {5'd0, qm[8]} - bal;
        end else begin
            q <= {1'b0, qm[8], qm[7:0]};
            cnt <= cnt - {5'd0, ~qm[8]} + bal;
        end
    end
endmodule
`default_nettype wire
