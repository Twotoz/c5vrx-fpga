// C5VRX by Twotoz and the C5VRX contributors: TANG9K_DUAL vectoring CORDIC.
// Angle of (x, y) in 2^-16 turns, bit-exact with mrc_model.cordic_angle:
// a 180-degree pre-rotation for x < 0, then N shift-add steps (arithmetic
// shifts). Fully pipelined: one result per clock, latency N + 1.
`default_nettype none
module cordic_angle #(
    parameter W = 18,             // input width; |x|,|y| < 2^(W-3) keeps the gain growth inside
    parameter N = 10              // steps (mrc_model.CORDIC_ITERS)
) (
    input  wire                clk,
    input  wire signed [W-1:0] x_in,
    input  wire signed [W-1:0] y_in,
    output wire        [15:0]  ang
);
`include "tables.vh"
    reg signed [W-1:0] xs [0:N];
    reg signed [W-1:0] ys [0:N];
    reg        [15:0]  as [0:N];

    // 180-degree pre-rotation for x < 0: 0 - v or 0 + v on one carry chain
    wire neg = x_in[W-1];
    wire [W-1:0] x0, y0;
    addsub #(W) u_x0 (.a({W{1'b0}}), .b(x_in), .sub(neg), .y(x0));
    addsub #(W) u_y0 (.a({W{1'b0}}), .b(y_in), .sub(neg), .y(y0));
    always @(posedge clk) begin
        xs[0] <= x0;
        ys[0] <= y0;
        as[0] <= neg ? 16'd32768 : 16'd0;
    end

    genvar i;
    generate
        for (i = 0; i < N; i = i + 1) begin : step
            wire pos = ys[i] > 0;
            wire signed [W-1:0] ysh = ys[i] >>> i, xsh = xs[i] >>> i;
            // x + y, y - x, a + atan (pos) or x - y, y + x, a - atan: ADDSUB carry chains
            wire [W-1:0] xn, yn; wire [15:0] an;
            addsub #(W)  u_x (.a(xs[i]), .b(ysh), .sub(~pos), .y(xn));
            addsub #(W)  u_y (.a(ys[i]), .b(xsh), .sub(pos), .y(yn));
            addsub #(16) u_a (.a(as[i]), .b(atan_lut(i)), .sub(~pos), .y(an));
            always @(posedge clk) begin
                xs[i+1] <= xn;
                ys[i+1] <= yn;
                as[i+1] <= an;
            end
        end
    endgenerate

    assign ang = as[N];
endmodule
`default_nettype wire
