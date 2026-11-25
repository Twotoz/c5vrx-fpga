// Triversity: field buffer in the GW2AR's SDRAM for the free-running 90 Hz
// HDMI output (TRI_HDMI90). The receiver writes every field, the display reads
// the newest complete one, so the two rates need not match (59.94 / 50 Hz in,
// ~90 Hz out); each output frame shows one field, never two halves (triple
// buffering: three field slots, the writer never takes the slot being read).
//
// Write side (clk, the IQ clock): vid_sync's line-buffer writes (720 RGB565
// pixels a line, in order) are packed two pixels a word into a two-line buffer
// (by orow[0] like the line buffer); at the line toggle the finished line
// becomes a write job of 360 words. A field toggle closes the slot (it becomes
// the newest) and the writer moves to the slot that is neither the newest nor
// the one the display reads.
// Read side: the display asks for a source line (fetch toggle + line, other
// clock domain) two output lines before it shows it; the engine reads it into
// a two-line buffer that the display reads in its own clock. At each output
// frame start the display's toggle latches the newest slot.
// SDRAM word address {0, slot[1:0], line[8:0], word[8:0]}: a line is two SDRAM
// rows, 23 bursts (22 x 16 + 8 words, never across a row). A read waits for at
// most one write burst: the engine looks at reads between write bursts.
`default_nettype none
module fbuf (
    input  wire        clk,
    input  wire        rst,
    input  wire        wr_en,
    input  wire [10:0] wr_addr,        // {orow[0], x}
    input  wire [15:0] wr_data,
    input  wire        line_tog,
    input  wire [8:0]  line_info,      // {show, orow} of the line just written
    input  wire        field_tog,
    input  wire        frame_tog_p,    // display domain: a frame starts
    input  wire        fetch_tog_p,    // display domain: fetch source line fetch_line_p
    input  wire [8:0]  fetch_line_p,
    input  wire        rclk,
    input  wire [10:0] raddr,          // {line[0], x}
    output wire [15:0] rdata,
    output wire        O_sdram_clk, O_sdram_cke, O_sdram_cs_n, O_sdram_ras_n, O_sdram_cas_n, O_sdram_wen_n,
    output wire [10:0] O_sdram_addr,
    output wire [1:0]  O_sdram_ba,
    output wire [3:0]  O_sdram_dqm,
    inout  wire [31:0] IO_sdram_dq
);
    // ---- write line buffer: two lines of 360 words ----
    reg [31:0] wlb [0:1023];
    reg [15:0] lo;
    reg [9:0]  wl_ra; reg [31:0] wl_q;
    always @(posedge clk) begin
        if (wr_en && !wr_addr[0]) lo <= wr_data;
        if (wr_en && wr_addr[0]) wlb[{wr_addr[10], wr_addr[9:1]}] <= {wr_data, lo};
        wl_q <= wlb[wl_ra];
    end
    // ---- read line buffer: two lines, written here, read in the display clock ----
    reg [31:0] rlb [0:1023];
    reg [9:0]  rl_wa; reg rl_we; reg [31:0] rl_wd;
    always @(posedge clk) if (rl_we) rlb[rl_wa] <= rl_wd;
    reg [31:0] rq; reg hsel;
    always @(posedge rclk) begin rq <= rlb[raddr[10:1]]; hsel <= raddr[0]; end
    assign rdata = hsel ? rq[31:16] : rq[15:0];
    // ---- slots ----
    function [1:0] third; input [1:0] a, b;
        third = (a != 2'd0 && b != 2'd0) ? 2'd0 : (a != 2'd1 && b != 2'd1) ? 2'd1 : 2'd2;
    endfunction
    reg [1:0] wslot, latest, rslot; reg lat_ok;
    reg [8:0] wrow;
    reg       lt_p, ft_p;
    // pending write jobs, one per line-buffer half
    reg [1:0] wp; reg [8:0] wp_line [0:1]; reg [1:0] wp_slot [0:1];
    // display requests
    reg [2:0] frs, fes; reg rp; reg [8:0] rq_line, rline; reg [1:0] rj_slot; reg rvalid, rj_valid;
    // ---- engine ----
    localparam E_IDLE = 3'd0, E_WLOAD = 3'd1, E_WREQ = 3'd2, E_WRUN = 3'd3, E_RREQ = 3'd4, E_RWAIT = 3'd5;
    reg [2:0]  est;
    reg        wb;                     // the write job's line-buffer half
    reg        wact;                   // a write job is under way (it may pause for a read)
    reg [4:0]  wc, rc;                 // burst of the line, 0..22
    reg [4:0]  ld, wn;                 // words loaded / written of the burst
    reg [31:0] sr [0:15];
    reg        ld_v;
    reg [8:0]  rcnt;                   // words of the read line received
    wire [4:0] wlen = wc == 5'd22 ? 5'd8 : 5'd16, rlen = rc == 5'd22 ? 5'd8 : 5'd16;
    wire       s_ack, s_next, s_rv; wire [31:0] s_rd;
    wire       s_req = est == E_WREQ || est == E_RREQ;
    wire       s_we = est == E_WREQ;
    wire [20:0] s_addr = s_we ? {1'b0, wp_slot[wb], wp_line[wb], wc[4:0], 4'd0} : {1'b0, rj_slot, rline, rc[4:0], 4'd0};
    wire [4:0] s_len = s_we ? wlen : rlen;
    wire [31:0] s_wd = s_next ? sr[1] : sr[0];
    integer i;
    wire fr_ev = frs[2] != frs[1];
    always @(posedge clk) begin
        rl_we <= 1'b0;
        frs <= {frs[1:0], frame_tog_p}; fes <= {fes[1:0], fetch_tog_p};
        if (rst) begin
            wslot <= 2'd0; latest <= 2'd0; rslot <= 2'd0; lat_ok <= 1'b0; rvalid <= 1'b0; wrow <= 9'd0; wp <= 2'b00; rp <= 1'b0;
            lt_p <= line_tog; ft_p <= field_tog; est <= E_IDLE; wact <= 1'b0;
        end else begin
            // ---- write side ----
            lt_p <= line_tog; ft_p <= field_tog;
            if (lt_p != line_tog && line_info[8] && wrow < 9'd288) begin
                wp[line_info[0]] <= 1'b1; wp_line[line_info[0]] <= wrow; wp_slot[line_info[0]] <= wslot;
                wrow <= wrow + 9'd1;
            end
            if (ft_p != field_tog) begin
                wrow <= 9'd0;
                // the slot the display reads from now on (a frame may start in this very clock)
                if (wrow != 9'd0) begin latest <= wslot; lat_ok <= 1'b1; wslot <= third(wslot, fr_ev && lat_ok ? latest : rslot); end
            end
            // ---- display requests ----
            if (fr_ev && lat_ok) begin rslot <= latest; rvalid <= 1'b1; end
            if (fes[2] != fes[1]) begin rp <= 1'b1; rq_line <= fetch_line_p; end
            // ---- engine ----
            case (est)
                E_IDLE:
                    if (rp) begin rp <= 1'b0; rc <= 5'd0; rcnt <= 9'd0; rline <= rq_line; rj_slot <= rslot; rj_valid <= rvalid; est <= E_RREQ; end
                    else if (wact) begin est <= E_WLOAD; ld <= 5'd0; ld_v <= 1'b0; wl_ra <= {wb, wc, 4'd0}; end
                    else if (wp != 2'b00) begin
                        wb <= wp[0] ? 1'b0 : 1'b1; wact <= 1'b1; wc <= 5'd0;
                        est <= E_WLOAD; ld <= 5'd0; ld_v <= 1'b0; wl_ra <= {wp[0] ? 1'b0 : 1'b1, 9'd0};
                    end
                E_WLOAD: begin                 // wlb -> sr, one word a clock (read latency 1)
                    wl_ra <= wl_ra + 10'd1; ld_v <= 1'b1;
                    if (ld_v) begin
                        sr[ld[3:0]] <= wl_q; ld <= ld + 5'd1;
                        if (ld + 5'd1 == wlen) begin est <= E_WREQ; wn <= 5'd0; end
                    end
                end
                E_WREQ: if (s_ack) est <= E_WRUN;
                E_WRUN: if (s_next) begin
                    for (i = 0; i < 15; i = i + 1) sr[i] <= sr[i + 1];
                    wn <= wn + 5'd1;
                    if (wn + 5'd1 == wlen) begin
                        est <= E_IDLE;
                        if (wc == 5'd22) begin wact <= 1'b0; wp[wb] <= 1'b0; end
                        else wc <= wc + 5'd1;
                    end
                end
                E_RREQ: if (s_ack) begin
                    if (rc == 5'd22) est <= E_RWAIT; else rc <= rc + 5'd1;
                end
                E_RWAIT: if (rcnt == 9'd360) est <= E_IDLE;
                default: est <= E_IDLE;
            endcase
            if (s_rv) begin
                rl_we <= 1'b1; rl_wa <= {rline[0], rcnt}; rl_wd <= rj_valid ? s_rd : 32'd0; rcnt <= rcnt + 9'd1;
            end
        end
    end
    sdram u_ram (.clk(clk), .rst(rst), .ready(), .req(s_req), .req_we(s_we), .req_addr(s_addr), .req_len(s_len),
                 .req_ack(s_ack), .busy(), .wr_data(s_wd), .wr_next(s_next), .rd_valid(s_rv), .rd_data(s_rd),
                 .O_sdram_clk(O_sdram_clk), .O_sdram_cke(O_sdram_cke), .O_sdram_cs_n(O_sdram_cs_n), .O_sdram_ras_n(O_sdram_ras_n),
                 .O_sdram_cas_n(O_sdram_cas_n), .O_sdram_wen_n(O_sdram_wen_n), .O_sdram_addr(O_sdram_addr), .O_sdram_ba(O_sdram_ba),
                 .O_sdram_dqm(O_sdram_dqm), .IO_sdram_dq(IO_sdram_dq));
endmodule
`default_nettype wire
