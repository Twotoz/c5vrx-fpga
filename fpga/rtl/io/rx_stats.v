// Triversity: receive statistics for the live status (log_uart.v), in the IQ
// clock domain: discriminator clicks counted over 100 ms (saturating), and the
// Rescue PLL's share of it from 100 evenly spaced looks at ract (the count is
// the percentage). Both held for the next 100 ms.
`default_nettype none
module rx_stats #(parameter CLK_HZ = 40000000) (
    input  wire        clk,
    input  wire        rst,
    input  wire        click_ev,      // mrc3_core: one clock per click
    input  wire        ract,          // mrc3_core: the Rescue PLL in use
    output reg  [15:0] clicks = 16'd0,
    output reg  [6:0]  rescue_pct = 7'd0
);
    localparam integer LOOK = CLK_HZ / 1000;     // 100 looks in 100 ms
    reg [16:0] lt; reg [6:0] looks; reg [15:0] nc; reg [6:0] nr;
    always @(posedge clk) begin
        if (rst) begin lt <= 17'd0; looks <= 7'd0; nc <= 16'd0; nr <= 7'd0; end
        else begin
            if (click_ev && !(&nc)) nc <= nc + 16'd1;
            if (lt == LOOK - 1) begin
                lt <= 17'd0;
                if (looks == 7'd99) begin
                    looks <= 7'd0; clicks <= nc + {15'd0, click_ev && !(&nc)}; rescue_pct <= nr + {6'd0, ract};
                    nc <= 16'd0; nr <= 7'd0;
                end else begin looks <= looks + 7'd1; nr <= nr + {6'd0, ract}; end
            end else lt <= lt + 17'd1;
        end
    end
endmodule
`default_nettype wire
