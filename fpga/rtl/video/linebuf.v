// Triversity: dual-clock line buffer, two lines of 800 RGB565 pixels (BSRAM).
`default_nettype none
module linebuf (
    input  wire        wclk,
    input  wire        we,
    input  wire [10:0] waddr,
    input  wire [15:0] wdata,
    input  wire        rclk,
    input  wire [10:0] raddr,
    output reg  [15:0] rdata
);
    reg [15:0] mem [0:2047];
    always @(posedge wclk) if (we) mem[waddr] <= wdata;
    always @(posedge rclk) rdata <= mem[raddr];
endmodule
`default_nettype wire
