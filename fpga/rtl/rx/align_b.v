// Two-receiver FPGA variants share the same alignment engine.
`default_nettype none
module align_b (
    input  wire       clk_b,
    input  wire [7:0] raw_b_in,
    input  wire       clk_a, rst_a, ref_lost,
    input  wire [7:0] raw_a,
    output wire [7:0] raw_a_d, raw_b,
    output wire       en_b, b_alive,
    output wire [5:0] lag
);
    align_bc #(.HAS_C(0)) u_align (
        .clk_b(clk_b), .clk_c(clk_b), .raw_b_in(raw_b_in), .raw_c_in(8'd0),
        .clk_a(clk_a), .rst_a(rst_a), .ref_lost(ref_lost), .raw_a(raw_a),
        .raw_a_d(raw_a_d), .raw_b(raw_b), .raw_c(), .en_b(en_b), .en_c(),
        .b_alive(b_alive), .c_alive(), .lag_b(lag), .lag_c()
    );
endmodule
`default_nettype wire
