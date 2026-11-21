// Triversity: controller for the GW2AR-18's built-in 64 Mbit SDRAM (2M x 32:
// 4 banks x 2048 rows x 256 columns), on the 40 MHz video clock.
//  - one request at a time: a run of 1..16 words in one SDRAM row, write
//    (data pulled with wr_next, one word a clock) or read (rd_valid / rd_data
//    three clocks after each READ: CAS latency 2 plus the FPGA's sampling edge);
//    back to back on an open row (a write waits until no read data is on DQ,
//    a precharge until tWR has passed)
//  - open-row policy: a request to the row already open skips ACTIVE and
//    PRECHARGE (the DVR's line writes hit the same row 16 times in a row)
//  - auto refresh every 400 clocks (10 us; 4096 rows in 64 ms needs 15.6 us),
//    first when it is due, closing the open row
//  - conservative timing for 25 ns clocks: tRCD, tRP 2 clocks, tWR 2, tRFC 4,
//    CAS latency 2, burst length 1 (one command per word)
//  - power-up: 200 us idle, PRECHARGE ALL, 8 x AUTO REFRESH, MODE (CL 2, BL 1)
// The SDRAM clock is the inverted clk: commands and write data change on
// clk's rising edge and are taken by the SDRAM half a clock later.
`default_nettype none
module sdram (
    input  wire        clk,
    input  wire        rst,
    output wire        ready,              // initialised
    // request
    input  wire        req,
    input  wire        req_we,
    input  wire [20:0] req_addr,           // word address {bank[1:0], row[10:0], col[7:0]}
    input  wire [4:0]  req_len,            // words, 1..16, inside one row
    output reg         req_ack,            // the request was taken (one clock)
    output reg         busy,               // a request is in progress
    input  wire [31:0] wr_data,
    output reg         wr_next,            // wr_data was taken: present the next word
    output reg         rd_valid,
    output reg  [31:0] rd_data,
    // SDRAM pins (sip pads of the GW2AR)
    output wire        O_sdram_clk,
    output reg         O_sdram_cke,
    output reg         O_sdram_cs_n,
    output reg         O_sdram_ras_n,
    output reg         O_sdram_cas_n,
    output reg         O_sdram_wen_n,
    output reg  [10:0] O_sdram_addr,
    output reg  [1:0]  O_sdram_ba,
    output wire [3:0]  O_sdram_dqm,
    inout  wire [31:0] IO_sdram_dq
);
    assign O_sdram_clk = ~clk;
    assign O_sdram_dqm = 4'b0000;
    reg  [31:0] dq_out; reg dq_oe;
    assign IO_sdram_dq = dq_oe ? dq_out : 32'bz;
    localparam [3:0] C_NOP = 4'b0111, C_ACT = 4'b0011, C_RD = 4'b0101, C_WR = 4'b0100,
                     C_PRE = 4'b0010, C_REF = 4'b0001, C_MRS = 4'b0000;
    task cmd; input [3:0] c; begin {O_sdram_cs_n, O_sdram_ras_n, O_sdram_cas_n, O_sdram_wen_n} <= c; end endtask
    localparam S_PWR = 0, S_PALL = 1, S_IREF = 2, S_MRS = 3, S_IDLE = 4, S_ACT = 5, S_RW = 6;
    reg  [3:0]  st;
    reg  [13:0] t;                         // wait counter
    reg  [3:0]  nref;
    reg  [8:0]  rcnt;                      // refresh interval
    reg         ref_due = 1'b0;
    reg         open; reg [12:0] open_rb;  // an open row: {bank, row}
    reg         we; reg [20:0] a; reg [4:0] n;
    reg  [2:0]  rdp;                       // READ issued, data due: a shift register of 3
    reg  [1:0]  twr;                       // clocks since the last WRITE (PRECHARGE waits for tWR)
    wire        rd_quiet = rdp == 3'd0 && !rd_valid;   // no read data on DQ: a WRITE may drive it
    assign ready = st >= S_IDLE;
    always @(posedge clk) begin
        req_ack <= 1'b0; wr_next <= 1'b0;
        rd_data <= IO_sdram_dq; rd_valid <= rdp[2]; rdp <= {rdp[1:0], 1'b0};
        cmd(C_NOP); dq_oe <= 1'b0;
        if (twr != 2'd0) twr <= twr - 2'd1;
        if (rcnt != 9'd0) rcnt <= rcnt - 9'd1; else ref_due <= 1'b1;
        if (t != 14'd0) t <= t - 14'd1;
        if (rst) begin
            st <= S_PWR; t <= 14'd8000; O_sdram_cke <= 1'b1; open <= 1'b0; busy <= 1'b0; ref_due <= 1'b0;
            rcnt <= 9'd400; rdp <= 3'd0; rd_valid <= 1'b0; twr <= 2'd0;
        end else if (t == 14'd0) case (st)
            S_PWR: begin cmd(C_PRE); O_sdram_addr <= 11'h400; st <= S_PALL; t <= 14'd2; end
            S_PALL: begin cmd(C_REF); nref <= 4'd7; st <= S_IREF; t <= 14'd4; end
            S_IREF: if (nref != 4'd0) begin cmd(C_REF); nref <= nref - 4'd1; t <= 14'd4; end
                    else begin cmd(C_MRS); O_sdram_ba <= 2'b00; O_sdram_addr <= 11'h020; st <= S_MRS; t <= 14'd2; end
            S_MRS: st <= S_IDLE;
            S_IDLE: begin
                busy <= 1'b0;
                if (ref_due) begin
                    if (open) begin if (twr == 2'd0) begin cmd(C_PRE); O_sdram_addr <= 11'h400; open <= 1'b0; t <= 14'd2; end end
                    else begin cmd(C_REF); ref_due <= 1'b0; rcnt <= 9'd400; t <= 14'd4; end
                end else if (req && (!req_we || rd_quiet) && !(open && open_rb != req_addr[20:8] && twr != 2'd0)) begin
                    req_ack <= 1'b1; busy <= 1'b1; we <= req_we; a <= req_addr; n <= req_len;
                    if (open && open_rb == req_addr[20:8]) st <= S_RW;
                    else if (open) begin cmd(C_PRE); O_sdram_addr <= 11'h400; open <= 1'b0; st <= S_ACT; t <= 14'd2; end
                    else st <= S_ACT;
                end
            end
            S_ACT: begin
                cmd(C_ACT); O_sdram_ba <= a[20:19]; O_sdram_addr <= a[18:8];
                open <= 1'b1; open_rb <= a[20:8]; st <= S_RW; t <= 14'd2;
            end
            S_RW: begin                                    // one READ / WRITE a clock
                O_sdram_ba <= a[20:19]; O_sdram_addr <= {3'b000, a[7:0]};
                if (we) begin cmd(C_WR); dq_out <= wr_data; dq_oe <= 1'b1; wr_next <= 1'b1; twr <= 2'd3; end
                else begin cmd(C_RD); rdp[0] <= 1'b1; end
                a[7:0] <= a[7:0] + 8'd1; n <= n - 5'd1;
                if (n == 5'd1) begin st <= S_IDLE; busy <= 1'b0; end
            end
            default: st <= S_IDLE;
        endcase
    end
endmodule
`default_nettype wire
