// Triversity: y = sub ? a - b : a + b on one Gowin carry chain. The ALU cells
// run in their ADDSUB mode (ALU_MODE 2: I3 = 1 adds, I3 = 0 subtracts), so the
// add / subtract choice costs no LUT in front of each bit; a head cell turns
// sub into the carry-in (COUT = I0 when I0 = I1). Synthesis (SYNTHESIS
// defined by Yosys) uses the cells, simulation the expression; both give the
// same W-bit result. Used where a sum's sign flips per sample (CORDIC steps,
// absolute values).
`default_nettype none
module addsub #(parameter W = 18) (
    input  wire [W-1:0] a,
    input  wire [W-1:0] b,
    input  wire         sub,
    output wire [W-1:0] y
);
`ifdef SYNTHESIS
    wire [W:0] c;
    ALU #(.ALU_MODE(0)) u_h (.SUM(), .COUT(c[0]), .I0(sub), .I1(sub), .I3(1'b0), .CIN(1'b0));
    genvar k;
    generate for (k = 0; k < W; k = k + 1) begin : b_
        ALU #(.ALU_MODE(2)) u (.SUM(y[k]), .COUT(c[k+1]), .I0(a[k]), .I1(b[k]), .I3(~sub), .CIN(c[k]));
    end endgenerate
`else
    assign y = sub ? a - b : a + b;
`endif
endmodule
`default_nettype wire
