// C5VRX by Twotoz and the C5VRX contributors: TANG9K_DUAL iterative
// vectoring CORDIC (one shift-add step per clock), for the slow phase
// tracker angle. Same arithmetic as cordic_angle.v / mrc_model.cordic_angle:
// start latches (x, y); done pulses N + 1 clocks later with ang valid.
`default_nettype none
module cordic_iter #(
    parameter W = 20,
    parameter N = 10
) (
    input  wire                clk,
    input  wire                start,
    input  wire signed [W-1:0] x_in,
    input  wire signed [W-1:0] y_in,
    output reg         [15:0]  ang,
    output reg                 done
);
`include "tables.vh"
    reg signed [W-1:0] x, y;
    reg        [4:0]   i;
    reg                busy = 1'b0;
    wire signed [W-1:0] ysh = y >>> i, xsh = x >>> i;
    wire pos = y > 0;
    wire [W-1:0] xn, yn, x0, y0; wire [15:0] an;               // ADDSUB carry chains
    addsub #(W)  u_x (.a(x), .b(ysh), .sub(~pos), .y(xn));     // x + y or x - y
    addsub #(W)  u_y (.a(y), .b(xsh), .sub(pos), .y(yn));      // y - x or y + x
    addsub #(16) u_a (.a(ang), .b(atan_lut(i)), .sub(~pos), .y(an));
    addsub #(W)  u_x0 (.a({W{1'b0}}), .b(x_in), .sub(x_in[W-1]), .y(x0));
    addsub #(W)  u_y0 (.a({W{1'b0}}), .b(y_in), .sub(x_in[W-1]), .y(y0));
    always @(posedge clk) begin
        done <= 1'b0;
        if (start) begin
            x    <= x0;
            y    <= y0;
            ang  <= (x_in < 0) ? 16'd32768 : 16'd0;
            i    <= 5'd0;
            busy <= 1'b1;
        end else if (busy) begin
            x   <= xn;
            y   <= yn;
            ang <= an;
            if (i == N - 1) begin busy <= 1'b0; done <= 1'b1; end
            i <= i + 5'd1;
        end
    end
endmodule
`default_nettype wire
