// Triversity: behavioural model of the GW2AR's 2M x 32 SDRAM for the
// testbenches (rtl/io/sdram.v). Commands on the rising edge of its clock,
// CAS latency 2, burst length 1; checks the timing the controller relies on
// (a READ / WRITE only to the open row of its bank, ACTIVE only to a closed
// bank, no command but NOP / ACTIVE / PRECHARGE / REFRESH / MODE otherwise)
// and counts violations in `errors`.
`timescale 1ns/1ps
module sdram_model (
    input  wire        clk,               // the SDRAM clock (O_sdram_clk)
    input  wire        cke, cs_n, ras_n, cas_n, we_n,
    input  wire [10:0] addr,
    input  wire [1:0]  ba,
    input  wire [3:0]  dqm,
    inout  wire [31:0] dq
);
    reg [31:0] mem [0:2097151];
    reg        open [0:3];
    reg [10:0] row [0:3];
    integer    errors = 0, k;
    initial for (k = 0; k < 4; k = k + 1) open[k] = 1'b0;
    reg [31:0] dout; reg doe = 1'b0;
    assign #4 dq = doe ? dout : 32'bz;
    reg [20:0] rq0, rq1; reg rv0 = 1'b0, rv1 = 1'b0;
    always @(posedge clk) begin
        // CAS latency 2: the data of a READ at edge n is driven after edge n + 2
        doe <= rv1; dout <= mem[rq1];
        rv1 <= rv0; rq1 <= rq0; rv0 <= 1'b0;
        if (cke && !cs_n) case ({ras_n, cas_n, we_n})
            3'b011: begin                                         // ACTIVE
                if (open[ba]) begin errors = errors + 1; $display("SDRAM: ACTIVE to an open bank %0d", ba); end
                open[ba] <= 1'b1; row[ba] <= addr;
            end
            3'b101: begin                                         // READ
                if (!open[ba]) begin errors = errors + 1; $display("SDRAM: READ to a closed bank"); end
                rv0 <= 1'b1; rq0 <= {ba, row[ba], addr[7:0]};
            end
            3'b100: begin                                         // WRITE
                if (!open[ba]) begin errors = errors + 1; $display("SDRAM: WRITE to a closed bank"); end
                mem[{ba, row[ba], addr[7:0]}] <= dq;
            end
            3'b010: if (addr[10]) for (k = 0; k < 4; k = k + 1) open[k] <= 1'b0; else open[ba] <= 1'b0;   // PRECHARGE
            3'b001: for (k = 0; k < 4; k = k + 1) if (open[k]) begin errors = errors + 1; $display("SDRAM: REFRESH with a bank open"); end
            3'b000: ;                                             // MODE
            default: ;
        endcase
    end
endmodule
