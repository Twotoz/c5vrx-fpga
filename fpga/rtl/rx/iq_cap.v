// Triversity: capture of one C5's six IQ pads in the I/O cells, both clock edges,
// with the edge picked automatically.
// Each pad goes into an IDDR clocked by that C5's own sample clock, so every bit
// is registered at the pin with the same delay (a fabric flip-flop let the six
// bits take different routes: on the board a part of the samples mixed bits of
// two IQ words). The IDDR gives the pad as seen at both clock edges; per edge a
// counter takes the samples whose I and Q sign bits both flip (rare in a real
// FM signal: ~1 in 10^4 in a C5 snapshot, tens of percent when the edge falls in
// a data transition) over 2^16 clocks, and the edge with fewer is used. The
// choice changes only when the other edge is clearly better (fewer than half),
// so a noisy channel does not make it hop.
`default_nettype none
module iq_cap (
    input  wire       clk,          // the C5's sample clock (pad)
    input  wire [5:0] d,            // word() order: {I sign, I2, I1, Q sign, Q2, Q1}
    output reg  [5:0] q,            // the chosen edge's sample, registered on clk
    output reg        sel,          // 0: edge of Q0, 1: edge of Q1
    output reg  [15:0] jumps0,      // sign-pair flips per window, Q0 edge
    output reg  [15:0] jumps1       //                             Q1 edge
);
    wire [5:0] q0, q1;
    genvar k;
    generate for (k = 0; k < 6; k = k + 1) begin : g
        IDDR u (.D(d[k]), .CLK(clk), .Q0(q0[k]), .Q1(q1[k]));
    end endgenerate
    reg [5:0] p0, p1, r0, r1;
    reg [15:0] win = 16'd0, n0 = 16'd0, n1 = 16'd0;
    initial begin sel = 1'b0; jumps0 = 16'd0; jumps1 = 16'd0; end
    always @(posedge clk) begin
        r0 <= q0; r1 <= q1; p0 <= r0; p1 <= r1;
        q <= sel ? r1 : r0;
        win <= win + 16'd1;
        if (win == 16'd0) begin
            jumps0 <= n0; jumps1 <= n1;
            if (!sel && {n1, 1'b0} < n0) sel <= 1'b1;
            else if (sel && {n0, 1'b0} < n1) sel <= 1'b0;
            n0 <= 16'd0; n1 <= 16'd0;
        end else begin
            if (r0[5] != p0[5] && r0[2] != p0[2] && n0 != 16'hffff) n0 <= n0 + 16'd1;
            if (r1[5] != p1[5] && r1[2] != p1[2] && n1 != 16'hffff) n1 <= n1 + 16'd1;
        end
    end
endmodule
`default_nettype wire
