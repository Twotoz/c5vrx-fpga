// Triversity: HDMI (DVI) physical layer on the Tang Nano 20K: three TMDS
// channels and the clock, each 10 bits a pixel clock through OSER10 (fclk =
// 5 x pclk, both edges) into a true LVDS pair (LVDS25 in the 3.3 V bank, as Sipeed's example; pins 33-40, Sipeed's
// hdmi.cst). The port names are single wires: nextpnr pairs them with the
// LVDS buffers only so.
`default_nettype none
module hdmi_phy (
    input  wire       pclk,
    input  wire       fclk,
    input  wire       rst,
    input  wire [9:0] s0, s1, s2,       // blue (with the syncs), green, red; bit 0 goes first
    output wire       tmds_clk_p, tmds_clk_n,
    output wire       tmds_d0_p, tmds_d0_n,
    output wire       tmds_d1_p, tmds_d1_n,
    output wire       tmds_d2_p, tmds_d2_n
);
`ifdef SYNTHESIS
    wire [9:0] sym [0:3];
    assign sym[0] = s0; assign sym[1] = s1; assign sym[2] = s2; assign sym[3] = 10'b0000011111;
    wire [3:0] q, op, on;
    genvar i;
    generate for (i = 0; i < 4; i = i + 1) begin : ch
        OSER10 u_s (.Q(q[i]), .D0(sym[i][0]), .D1(sym[i][1]), .D2(sym[i][2]), .D3(sym[i][3]), .D4(sym[i][4]),
                    .D5(sym[i][5]), .D6(sym[i][6]), .D7(sym[i][7]), .D8(sym[i][8]), .D9(sym[i][9]),
                    .PCLK(pclk), .FCLK(fclk), .RESET(rst));
        TLVDS_OBUF u_o (.I(q[i]), .O(op[i]), .OB(on[i]));
    end endgenerate
    assign {tmds_clk_p, tmds_d2_p, tmds_d1_p, tmds_d0_p} = {op[3], op[2], op[1], op[0]};
    assign {tmds_clk_n, tmds_d2_n, tmds_d1_n, tmds_d0_n} = {on[3], on[2], on[1], on[0]};
`else
    assign {tmds_clk_p, tmds_clk_n, tmds_d0_p, tmds_d0_n, tmds_d1_p, tmds_d1_n, tmds_d2_p, tmds_d2_n} = 8'd0;
`endif
endmodule
`default_nettype wire
