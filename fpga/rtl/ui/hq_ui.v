// Triversity HQ DVR build: the live view without the menu (LCD clock domain).
// The full menu's page templates do not fit next to the JPEG encoder, so this
// draws the live page of the normal build (gen_osd.py page 0, same cells,
// same look) straight from the cell position, with the buttons:
//   UP / DOWN       previous / next channel (the channel pill lights up 2 s)
//   SELECT          record on / off (TF card; "No card" / "Card err" if it cannot)
//   SELECT held     Single <-> Diversity (the receiver bar greys out C5 B);
//                   TRI_TRIDVR build: Triversity -> Diversity -> Single, no
//                   logo, 7-segment glyphs (lcd_out.v seg_row)
// Aspect follows the camera (Auto), backlight full. Ports as menu.v, so
// tri_top.v swaps the two; gen_osd.py fill() with hq=True is the reference.
`default_nettype none
module hq_ui #(parameter CLK_HZ = 33750000) (
    input  wire        clk,
    input  wire        rst,
    input  wire        mk_tog_a,
    input  wire [1:0]  mk_src_a,
    input  wire [15:0] mk_pl_a,
    input  wire        s2_n,
    input  wire        locked_a,
    input  wire        pal_a,
    input  wire [15:0] sync_q_a,
    input  wire [1:0]  dvr_state_a,
    input  wire        wide_a,
    output reg         osd_we,
    output reg  [10:0] osd_waddr,
    output reg  [11:0] osd_wdata,
    output reg         dvr,
    output wire        lg,               // link log: not in the live view build
    output reg  [1:0]  mode,
    output wire [1:0]  hmode,
    output reg  [5:0]  channel,
    output reg         link_on,
    output wire        g_set, a_set,
    output wire [1:0]  gain_model,
    output wire        afc,
    output wire [7:0]  f_seq,
    output wire        klock, async_on, nfilt,   // (the menu's Signal page: off here)
    output wire [1:0]  rescue,                   // rescue PLL: Auto here
    output wire [1:0]  hz90,               // the 90 Hz HDMI build's output mode (not in this UI: Free)
    output wire        bl_pwm
);
    assign g_set = 1'b0; assign a_set = 1'b0; assign gain_model = 2'd0; assign afc = 1'b1; assign f_seq = 8'd0;
    assign klock = 1'b0; assign async_on = 1'b0; assign nfilt = 1'b0; assign lg = 1'b0; assign rescue = 2'd1; assign hz90 = 2'd0;
    assign bl_pwm = 1'b1;
    localparam [6:0] G_LOGO0 = 22, G_CAPL = 1, G_CAPR = 2, G_DOT = 8, G_BARS = 13, G_MID = 20, SP = 32;
    localparam [2:0] WHITE = 0, GREY = 1, ACCENT = 2, RED = 3, PANELFG = 7;
    localparam [1:0] BG_VIDEO = 0, BG_PANEL = 1, BG_BAR = 2;
    // ---- slow clock, crossings ----
    localparam MS = CLK_HZ / 1000;
    reg [15:0] mscnt; reg ms;
    always @(posedge clk) begin
        ms <= 1'b0;
        if (rst) mscnt <= 16'd0;
        else if (mscnt == MS - 1) begin mscnt <= 16'd0; ms <= 1'b1; end else mscnt <= mscnt + 16'd1;
    end
    reg [2:0] mt; reg [1:0] lk, wd; reg [1:0] ds1, ds2;
    always @(posedge clk) begin mt <= {mt[1:0], mk_tog_a}; lk <= {lk[0], locked_a}; wd <= {wd[0], wide_a}; ds1 <= dvr_state_a; ds2 <= ds1; end
    wire mk_ev = mt[2] ^ mt[1];
    wire locked = lk[1];
    assign hmode = wd[1] ? 2'd0 : 2'd1;
    // ---- C5 signal per C5 (live bars) ----
    reg [6:0]  st_sig [0:2];
    reg [11:0] st_life [0:2];            // ms left of the last marker's 3 s
    reg [3:0]  btn; reg btn_ev;
    integer k;
    always @(posedge clk) begin
        btn_ev <= 1'b0;
        if (rst) begin for (k = 0; k < 3; k = k + 1) begin st_life[k] <= 12'd0; st_sig[k] <= 7'd0; end end
        else begin
            if (ms) for (k = 0; k < 3; k = k + 1) if (st_life[k] != 12'd0) st_life[k] <= st_life[k] - 12'd1;
            if (mk_ev && mk_src_a != 2'd3) begin
                st_life[mk_src_a] <= 12'd3000;
                if (mk_pl_a[15:12] == 4'd1) begin btn <= mk_pl_a[3:0] | {mk_pl_a[4], 3'b0}; btn_ev <= 1'b1; end
                if (mk_pl_a[15:12] == 4'd6) st_sig[mk_src_a] <= mk_pl_a[6:0] > 7'd100 ? 7'd100 : mk_pl_a[6:0];
            end
        end
    end
    wire [2:0] fresh = {st_life[2] != 12'd0, st_life[1] != 12'd0, st_life[0] != 12'd0};
    // ---- Tang S2: SELECT (short) / SELECT held (0.6 s) ----
    reg [1:0] s2s; reg [9:0] s2_ms; reg s2_long_done; reg s2_ev; reg [3:0] s2_btn;
    always @(posedge clk) begin
        s2s <= {s2s[0], ~s2_n}; s2_ev <= 1'b0;
        if (rst) begin s2_ms <= 10'd0; s2_long_done <= 1'b0; end
        else if (ms) begin
            if (s2s[1]) begin
                if (s2_ms != 10'h3ff) s2_ms <= s2_ms + 10'd1;
                if (s2_ms == 10'd600 && !s2_long_done) begin s2_long_done <= 1'b1; s2_ev <= 1'b1; s2_btn <= 4'b1010; end
            end else begin
                if (s2_ms >= 10'd30 && !s2_long_done) begin s2_ev <= 1'b1; s2_btn <= 4'b0010; end
                s2_ms <= 10'd0; s2_long_done <= 1'b0;
            end
        end
    end
    // ---- state ----
    reg [10:0] toast_ms;
    reg [9:0]  sec_ms; reg [3:0] m1, m0, s1, s0;   // recording time, decimal digits
    wire       ev = btn_ev | s2_ev;
    wire [3:0] b  = btn_ev ? btn : s2_btn;
    wire       up = b[0], sel = b[1] && !b[3], dn = b[2], hold = b[1] && b[3];
    always @(posedge clk) begin
        if (rst) begin
`ifdef TRI_TRIDVR
            dvr <= 1'b0; mode <= 2'd2;
`else
            dvr <= 1'b0; mode <= 2'd1;
`endif channel <= 6'd8; link_on <= 1'b0; toast_ms <= 11'd0;
            sec_ms <= 10'd0; {m1, m0, s1, s0} <= 16'd0;
        end else begin
            if (ms && toast_ms != 11'd0) toast_ms <= toast_ms - 11'd1;
            if (!(dvr && ds2 == 2'd2)) begin sec_ms <= 10'd0; {m1, m0, s1, s0} <= 16'd0; end
            else if (ms) begin
                if (sec_ms == 10'd999) begin
                    sec_ms <= 10'd0;
                    if (s0 != 4'd9) s0 <= s0 + 4'd1;
                    else begin
                        s0 <= 4'd0;
                        if (s1 != 4'd5) s1 <= s1 + 4'd1;
                        else begin
                            s1 <= 4'd0;
                            if (m0 != 4'd9) m0 <= m0 + 4'd1;
                            else if (m1 != 4'd9) begin m0 <= 4'd0; m1 <= m1 + 4'd1; end
                        end
                    end
                end else sec_ms <= sec_ms + 10'd1;
            end
            if (mk_ev && mk_pl_a[15:12] == 4'd5 && mk_src_a == 2'd0 && !link_on && mk_pl_a[5:0] < 6'd48)
                begin channel <= mk_pl_a[5:0]; link_on <= 1'b1; end
            if (ev) begin
                link_on <= 1'b1;
`ifdef TRI_TRIDVR
                if (hold) mode <= mode == 2'd0 ? 2'd2 : mode - 2'd1;     // Triversity, Diversity, Single
`else
                if (hold) mode <= mode == 2'd0 ? 2'd1 : 2'd0;
`endif
                else if (sel) dvr <= ~dvr;
                else if (up) begin channel <= channel == 6'd47 ? 6'd0 : channel + 6'd1; toast_ms <= 11'd2000; end
                else if (dn) begin channel <= channel == 6'd0 ? 6'd47 : channel - 6'd1; toast_ms <= 11'd2000; end
            end
        end
    end
    // ---- renderer: one cell per clock ----
    reg [15:0] freq [0:47];
`include "osd_freq.vh"
    reg [10:0] ra; reg [6:0] rc; reg [4:0] rr;
    reg [6:0] c1; reg [4:0] r1; reg [10:0] wa1; reg [15:0] fq;
    always @(posedge clk) begin
        ra <= (rst || ra == 11'd1319) ? 11'd0 : ra + 11'd1;
        if (rst || ra == 11'd1319) begin rc <= 7'd0; rr <= 5'd0; end
        else if (rc == 7'd65) begin rc <= 7'd0; rr <= rr + 5'd1; end else rc <= rc + 7'd1;
        c1 <= rc; r1 <= rr; wa1 <= ra; fq <= freq[channel];
    end
    function [7:0] digit; input [3:0] d; digit = 8'd48 + d; endfunction
    wire       toast = toast_ms != 11'd0;
    wire       rec_on = dvr && ds2 == 2'd2, rec_err = dvr && (ds2 == 2'd0 || ds2 == 2'd3);
    // REC pill text from column 3: "REC  m:ss" / "No card" / "Card err"
    function [6:0] errc; input [3:0] i; input e; reg [8*8-1:0] s; begin
        s = e ? "Card err" : "No card "; errc = s[8 * (7 - i) +: 7]; end endfunction
    reg [6:0] ch; reg [2:0] fg; reg [1:0] bg;
    reg [6:0] fi; reg [1:0] bk;
    always @(*) begin
        ch = 7'd0; fg = WHITE; bg = BG_VIDEO; fi = 7'd0; bk = 2'd0;
        if (r1 == 5'd1 && c1 >= 7'd3 && c1 <= 7'd13) begin                  // channel pill
            fi = c1 - 7'd4;
            if (c1 == 7'd3 || c1 == 7'd13) begin ch = c1 == 7'd3 ? G_CAPL : G_CAPR; fg = toast ? ACCENT : PANELFG; end
            else begin
                bg = toast ? BG_BAR : BG_PANEL;
                case (fi)
                    7'd0: ch = channel[5:3] == 3'd0 ? "R" : channel[5:3] == 3'd1 ? "A" : channel[5:3] == 3'd2 ? "B" :
                               channel[5:3] == 3'd3 ? "E" : channel[5:3] == 3'd4 ? "F" : "L";
                    7'd1: ch = digit({1'b0, channel[2:0]} + 4'd1);
                    7'd3: ch = G_MID;
                    7'd5: ch = digit(fq[15:12]); 7'd6: ch = digit(fq[11:8]); 7'd7: ch = digit(fq[7:4]); 7'd8: ch = digit(fq[3:0]);
                    default: ch = SP;
                endcase
            end
        end else if (r1 == 5'd1 && c1 >= 7'd50 && c1 <= 7'd62 && (rec_on || rec_err)) begin   // REC pill
            fi = c1 - 7'd50; bg = BG_PANEL;
            case (fi)
                7'd0: begin ch = G_CAPL; fg = PANELFG; bg = BG_VIDEO; end
                7'd1: begin ch = G_DOT; fg = RED; end
                7'd12: begin ch = G_CAPR; fg = PANELFG; bg = BG_VIDEO; end
                default: if (rec_err) ch = (fi >= 7'd3 && fi <= 7'd10) ? errc(fi[3:0] - 4'd3, ds2 == 2'd3) : SP;
                         else case (fi)
                             7'd3: ch = "R"; 7'd4: ch = "E"; 7'd5: ch = "C";
                             7'd7: ch = m1 != 4'd0 ? digit(m1) : SP;
                             7'd8: ch = digit(m0);
                             7'd9: ch = ":";
                             7'd10: ch = digit(s1); 7'd11: ch = digit(s0);
                             default: ch = SP;
                         endcase
            endcase
        end else if (r1 == 5'd9 && c1 >= 7'd26 && c1 <= 7'd38 && !locked) begin             // NO SIGNAL
            fi = c1 - 7'd26; bg = BG_PANEL;
            case (fi)
                7'd0: begin ch = G_CAPL; fg = PANELFG; bg = BG_VIDEO; end
                7'd12: begin ch = G_CAPR; fg = PANELFG; bg = BG_VIDEO; end
                7'd2: ch = "N"; 7'd3: ch = "O"; 7'd5: ch = "S"; 7'd6: ch = "I"; 7'd7: ch = "G"; 7'd8: ch = "N"; 7'd9: ch = "A"; 7'd10: ch = "L";
                default: ch = SP;
            endcase
        end else if (r1 == 5'd18 && c1 >= 7'd3 && c1 <= 7'd16) begin                       // receiver bar
            fi = c1 - 7'd3; bg = BG_PANEL;
            bk = fi < 7'd5 ? 2'd0 : fi < 7'd9 ? 2'd1 : 2'd2;
            if (fi == 7'd0 || fi == 7'd13) begin ch = fi == 7'd0 ? G_CAPL : G_CAPR; fg = PANELFG; bg = BG_VIDEO; end
            else if (fi == 7'd2 || fi == 7'd6 || fi == 7'd10) begin
                ch = bk == 2'd0 ? "A" : bk == 2'd1 ? "B" : "C"; fg = fresh[bk] && bk <= mode ? WHITE : GREY;
            end else if (fi == 7'd3 || fi == 7'd7 || fi == 7'd11) begin
                fg = fresh[bk] && bk <= mode ? WHITE : GREY;
                ch = !fresh[bk] ? G_BARS : st_sig[bk] >= 7'd88 ? G_BARS + 7'd4 : st_sig[bk] >= 7'd63 ? G_BARS + 7'd3 :
                     st_sig[bk] >= 7'd38 ? G_BARS + 7'd2 : st_sig[bk] >= 7'd13 ? G_BARS + 7'd1 : G_BARS;
            end else ch = SP;
`ifndef TRI_TRIDVR
        end else if (r1 == 5'd18 && c1 >= 7'd51 && c1 <= 7'd62) begin                      // logo
            fi = c1 - 7'd51;
            if (fi == 7'd0 || fi == 7'd11) begin ch = fi == 7'd0 ? G_CAPL : G_CAPR; fg = PANELFG; end
            else begin ch = G_LOGO0 + fi - 7'd1; fg = fi <= 7'd4 ? ACCENT : WHITE; bg = BG_PANEL; end
`endif
        end
    end
    always @(posedge clk) begin osd_we <= !rst; osd_waddr <= wa1; osd_wdata <= {bg, fg, ch}; end
endmodule
`default_nettype wire
