// Triversity: OSD menu, C5 status and the link to the C5s (LCD clock domain).
//  - buttons: markers of type BUTTON from any C5 (C5 A has them wired) and the
//    Tang's own S2 (short = SELECT, hold = SELECT long)
//      outside the menu: UP / DOWN next / previous channel, SELECT opens
//      in the menu: UP / DOWN move, SELECT changes the item, SELECT held closes
//  - C5 status markers (gain, C/N, flags, channel, signal) per C5; the channel
//    in use is learned from C5 A's marker before the link starts sending
//  - scan: every channel 0.5 s, scored by the video's in-window sync edges
//  - renderer: the 30 x 50 OSD template (osd_init.vh) into the char RAM,
//    fields filled in live, one character per clock
//  - link frames (firmware/main/fpga_link.h) to link_tx.v
`default_nettype none
module menu #(parameter CLK_HZ = 33750000) (
    input  wire        clk,
    input  wire        rst,
    // markers (clk_a domain): toggle, source C5 (0 A, 1 B, 2 C), payload
    input  wire        mk_tog_a,
    input  wire [1:0]  mk_src_a,
    input  wire [15:0] mk_pl_a,
    input  wire        s2_n,            // Tang S2, active low
    // video (clk_a domain, slow)
    input  wire        locked_a,
    input  wire        pal_a,
    input  wire [15:0] sync_q_a,
    // char RAM write
    output reg         osd_we,
    output reg  [10:0] osd_waddr,
    output reg  [7:0]  osd_wdata,
    // outputs
    output reg         dvr,             // DVR mode: C5 C leaves the combination
    output reg  [5:0]  channel,
    output reg         link_on,
    output reg         g_set, a_set,
    output reg  [1:0]  gain_model,      // 0 LEVEL, 1 KEEL, 2 RSSI
    output reg         afc,
    output reg  [7:0]  f_seq,
    output reg         bl_pwm
);
    // ---- slow clock ---------------------------------------------------------------
    localparam MS = CLK_HZ / 1000;
    reg [15:0] mscnt; reg ms;
    always @(posedge clk) begin ms <= 1'b0; if (mscnt == MS - 1) begin mscnt <= 16'd0; ms <= 1'b1; end else mscnt <= mscnt + 16'd1; end
    // ---- clock-domain crossing of the markers and the video status ----------------
    reg [2:0] mt; reg [1:0] lk, pl; reg [15:0] sq1, sq2;
    always @(posedge clk) begin mt <= {mt[1:0], mk_tog_a}; lk <= {lk[0], locked_a}; pl <= {pl[0], pal_a}; sq1 <= sync_q_a; sq2 <= sq1; end
    wire mk_ev = mt[2] ^ mt[1];        // payload/source stable for ~250 ms after a toggle
    wire locked = lk[1], pal = pl[1];
    // ---- C5 status ------------------------------------------------------------------
    reg [7:0]  st_gain [0:2];
    reg [11:0] st_cn [0:2];
    reg [7:0]  st_flags [0:2];
    reg [6:0]  st_sig [0:2];
    reg [11:0] st_age [0:2];           // ms since the last marker, saturating
    reg [3:0]  btn; reg btn_ev;        // decoded button event
    reg        ch_known;
    integer k;
    always @(posedge clk) begin
        btn_ev <= 1'b0;
        if (rst) begin
            ch_known <= 1'b0;
            for (k = 0; k < 3; k = k + 1) begin st_age[k] <= 12'hfff; st_sig[k] <= 7'd0; st_gain[k] <= 8'd0; st_cn[k] <= 12'd0; st_flags[k] <= 8'd0; end
        end else begin
            if (ms) for (k = 0; k < 3; k = k + 1) if (st_age[k] != 12'hfff) st_age[k] <= st_age[k] + 12'd1;
            if (mk_ev && mk_src_a != 2'd3) begin
                st_age[mk_src_a] <= 12'd0;
                case (mk_pl_a[15:12])
                    4'd1: begin btn <= mk_pl_a[3:0] | {mk_pl_a[4], 3'b0}; btn_ev <= 1'b1; end
                    4'd2: st_gain[mk_src_a] <= mk_pl_a[7:0];
                    4'd3: st_cn[mk_src_a] <= mk_pl_a[11:0];
                    4'd4: st_flags[mk_src_a] <= mk_pl_a[7:0];
                    4'd5: if (mk_src_a == 2'd0 && !ch_known && mk_pl_a[5:0] < 6'd48) ch_known <= 1'b1;
                    4'd6: st_sig[mk_src_a] <= mk_pl_a[6:0] > 7'd100 ? 7'd100 : mk_pl_a[6:0];
                    default: ;
                endcase
            end
        end
    end
    // ---- Tang S2: debounced SELECT (short) / SELECT long (0.6 s) ----------------------
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
    // ---- menu state ---------------------------------------------------------------------
    localparam N_ITEMS = 4'd8, I_CHANNEL = 0, I_SCAN = 1, I_MODE = 2, I_GAIN = 3, I_AFC = 4, I_BRIGHT = 5, I_CAL = 6, I_EXIT = 7;
    reg        open;
    reg [3:0]  cursor;
    reg [2:0]  bright;
    reg        scanning;
    reg [5:0]  scan_ch, best_ch, orig_ch;
    reg [15:0] best_q;
    reg [9:0]  scan_ms;
    wire       ev = btn_ev | s2_ev;
    wire [3:0] b  = btn_ev ? btn : s2_btn;       // bit 0 UP, 1 SELECT, 2 DOWN, 3 long
    wire [5:0] ch_next = channel == 6'd47 ? 6'd0 : channel + 6'd1;
    wire [5:0] ch_prev = channel == 6'd0 ? 6'd47 : channel - 6'd1;
    always @(posedge clk) begin
        if (rst) begin
            open <= 1'b0; cursor <= 4'd0; bright <= 3'd7; dvr <= 1'b0; channel <= 6'd8;   // A1 until C5 A says
            link_on <= 1'b0; g_set <= 1'b0; a_set <= 1'b0; gain_model <= 2'd0; afc <= 1'b1; f_seq <= 8'd0;
            scanning <= 1'b0;
        end else begin
            if (mk_ev && mk_pl_a[15:12] == 4'd5 && mk_src_a == 2'd0 && !link_on && mk_pl_a[5:0] < 6'd48)
                begin channel <= mk_pl_a[5:0]; link_on <= 1'b1; end
            if (scanning) begin
                if (ms) scan_ms <= scan_ms + 10'd1;
                if (scan_ms == 10'd500) begin
                    if (sq2 > best_q) begin best_q <= sq2; best_ch <= scan_ch; end
                    scan_ms <= 10'd0;
                    if (scan_ch == 6'd47) begin
                        scanning <= 1'b0;
                        channel <= (sq2 > best_q ? sq2 : best_q) > 16'd500 ? (sq2 > best_q ? scan_ch : best_ch) : orig_ch;
                    end else begin scan_ch <= scan_ch + 6'd1; channel <= scan_ch + 6'd1; end
                end
            end else if (ev) begin
                link_on <= 1'b1;
                if (!open) begin
                    if (b[1]) begin open <= 1'b1; cursor <= 4'd0; end
                    else if (b[0]) channel <= b[3] ? {channel[5:3] == 3'd5 ? 3'd0 : channel[5:3] + 3'd1, channel[2:0]} : ch_next;
                    else if (b[2]) channel <= ch_prev;
                end else if (b[1] && b[3]) open <= 1'b0;
                else if (b[0]) cursor <= cursor == 4'd0 ? N_ITEMS - 4'd1 : cursor - 4'd1;
                else if (b[2]) cursor <= cursor == N_ITEMS - 4'd1 ? 4'd0 : cursor + 4'd1;
                else if (b[1]) case (cursor)
                    I_CHANNEL: channel <= {channel[5:3], channel[2:0] + 3'd1};
                    I_SCAN:    begin scanning <= 1'b1; scan_ch <= 6'd0; channel <= 6'd0; orig_ch <= channel; best_q <= 16'd0; scan_ms <= 10'd0; end
                    I_MODE:    dvr <= ~dvr;
                    I_GAIN:    begin gain_model <= gain_model == 2'd2 ? 2'd0 : gain_model + 2'd1; g_set <= 1'b1; end
                    I_AFC:     begin afc <= ~afc; a_set <= 1'b1; end
                    I_BRIGHT:  bright <= bright + 3'd1;
                    I_CAL:     f_seq <= f_seq + 8'd1;
                    default:   open <= 1'b0;
                endcase
            end
        end
    end
    // ---- backlight ------------------------------------------------------------------------
    reg [10:0] pw;
    always @(posedge clk) begin pw <= pw == 11'd1279 ? 11'd0 : pw + 11'd1; bl_pwm <= pw < {bright, 8'd0} + 11'd160 + {3'd0, bright, 5'd0}; end
    // ---- renderer -----------------------------------------------------------------------------
    reg [15:0] tmpl [0:1499];
    reg [15:0] freq [0:47];
`include "osd_init.vh"
    reg [10:0] ra;  reg [5:0] rc; reg [4:0] rr;    // template address, column, row
    reg [15:0] tw; reg [10:0] wa1; reg [4:0] rr1;
    reg [15:0] fq;
    always @(posedge clk) begin
        // stage 0: address
        ra <= rst ? 11'd0 : (ra == 11'd1499 ? 11'd0 : ra + 11'd1);
        if (rst || ra == 11'd1499) begin rc <= 6'd0; rr <= 5'd0; end
        else if (rc == 6'd49) begin rc <= 6'd0; rr <= rr + 5'd1; end else rc <= rc + 6'd1;
        // stage 1: template word, frequency
        tw <= tmpl[ra]; wa1 <= ra; rr1 <= rr; fq <= freq[channel];
    end
    // field characters (stage 2)
    function [7:0] digit; input [3:0] d; digit = 8'd48 + d; endfunction
    function [7:0] bars; input [6:0] sig; input [2:0] i; input [11:0] age;
        bars = age > 12'd3000 ? 8'd46 : ({4'd0, i} * 7'd20 < sig ? 8'd35 : 8'd45);   // '.' stale, '#', '-'
    endfunction
    function [3:0] tv; input [7:0] v;    // tens of v (0..99)
        tv = v >= 8'd90 ? 4'd9 : v >= 8'd80 ? 4'd8 : v >= 8'd70 ? 4'd7 : v >= 8'd60 ? 4'd6 : v >= 8'd50 ? 4'd5 :
             v >= 8'd40 ? 4'd4 : v >= 8'd30 ? 4'd3 : v >= 8'd20 ? 4'd2 : v >= 8'd10 ? 4'd1 : 4'd0;
    endfunction
    function [7:0] tens; input [7:0] v; tens = digit(tv(v > 8'd99 ? 8'd99 : v)); endfunction
    function [7:0] ones; input [7:0] v; reg [7:0] c; begin c = v > 8'd99 ? 8'd99 : v; ones = digit(c - {tv(c), 3'b0} - {tv(c), 1'b0}); end endfunction
    function [7:0] cnchar; input [11:0] cn; input [1:0] i; input [11:0] age;
        reg signed [12:0] v; reg [7:0] db; reg neg;
        begin
            if (cn == 12'd0 || age > 12'd3000) cnchar = 8'd45;
            else begin
                v = $signed({1'b0, cn}) - 13'sd1000; neg = v < 0; v = neg ? -v : v;
                db = (v[11:0] * 12'd205) >> 11;          // /10 (dB)
                if (db > 8'd99) db = 8'd99;
                cnchar = i == 2'd0 ? (neg ? 8'd45 : 8'd32) : i == 2'd1 ? tens(db) : ones(db);
            end
        end
    endfunction
    function [7:0] flag; input [7:0] f; input [1:0] i; input [11:0] age;
        flag = age > 12'd3000 ? 8'd46 : i == 2'd0 ? (f[0] ? 8'd76 : 8'd46) : i == 2'd1 ? (f[1] ? 8'd86 : 8'd46) : (f[2] ? 8'd66 : f[3] ? 8'd68 : 8'd46);
    endfunction
    function [7:0] text; input [5:0] sel; input [2:0] i;   // fixed strings
        reg [8*9-1:0] s;
        begin
            case (sel)
                0: s = "LEVEL    "; 1: s = "KEEL     "; 2: s = "RSSI     "; 3: s = "ON       "; 4: s = "OFF      ";
                5: s = "TRI      "; 6: s = "DVR      "; 7: s = "NTSC     "; 8: s = "PAL      "; 9: s = "----     ";
                10: s = "NO VIDEO "; 11: s = "         "; default: s = "         ";
            endcase
            text = s[8*(8-i) +: 8];
        end
    endfunction
    wire [7:0] fid = tw[15:8], fi = tw[7:0];
    reg  [7:0] chv;
    always @(*) begin
        case (fid)
            8'd0:  chv = fi;
            8'd1:  chv = fi == 8'd0 ? (channel[5:3] == 3'd0 ? 8'd82 : channel[5:3] == 3'd1 ? 8'd65 : channel[5:3] == 3'd2 ? 8'd66 :
                                       channel[5:3] == 3'd3 ? 8'd69 : channel[5:3] == 3'd4 ? 8'd70 : 8'd76) : digit({1'b0, channel[2:0]} + 4'd1);
            8'd2:  chv = digit(fq[15 - 4 * fi[1:0] -: 4]);
            8'd3:  chv = bars(st_sig[0], fi[2:0], st_age[0]);
            8'd4:  chv = bars(st_sig[1], fi[2:0], st_age[1]);
            8'd5:  chv = bars(st_sig[2], fi[2:0], st_age[2]);
            8'd6:  chv = text(!locked ? 6'd9 : pal ? 6'd8 : 6'd7, fi[2:0]);
            8'd7:  chv = text(dvr ? 6'd6 : 6'd5, fi[2:0]);
            8'd8:  chv = cursor == fi[3:0] ? 8'd62 : 8'd32;
            8'd9:  chv = text({4'd0, gain_model}, fi[2:0]);
            8'd10: chv = text(afc ? 6'd3 : 6'd4, fi[2:0]);
            8'd11: chv = digit({1'b0, bright} + 4'd1);
            8'd12: chv = fi == 8'd0 ? tens(st_gain[0]) : ones(st_gain[0]);
            8'd13: chv = fi == 8'd0 ? tens(st_gain[1]) : ones(st_gain[1]);
            8'd14: chv = fi == 8'd0 ? tens(st_gain[2]) : ones(st_gain[2]);
            8'd15: chv = cnchar(st_cn[0], fi[1:0], st_age[0]);
            8'd16: chv = cnchar(st_cn[1], fi[1:0], st_age[1]);
            8'd17: chv = cnchar(st_cn[2], fi[1:0], st_age[2]);
            8'd18: chv = flag(st_flags[0], fi[1:0], st_age[0]);
            8'd19: chv = flag(st_flags[1], fi[1:0], st_age[1]);
            8'd20: chv = flag(st_flags[2], fi[1:0], st_age[2]);
            8'd21: chv = !scanning ? 8'd32 : fi == 8'd0 ? 8'd83 : fi == 8'd1 ? 8'd67 : fi == 8'd2 ? 8'd65 : fi == 8'd3 ? 8'd78 :
                         fi == 8'd5 ? tens({2'd0, scan_ch}) : fi == 8'd6 ? ones({2'd0, scan_ch}) : 8'd32;
            8'd22: chv = locked ? 8'd0 : text(6'd10, fi[2:0]);
            default: chv = 8'd32;
        endcase
    end
    always @(posedge clk) begin
        osd_we <= 1'b1; osd_waddr <= wa1;
        if (rr1 >= 5'd2 && !open && fid != 8'd22) osd_wdata <= 8'd0;                   // menu rows only while open
        else if (open && rr1 >= 5'd3 && rr1 < 5'd3 + N_ITEMS && cursor == rr1 - 5'd3 && tw != 16'd0) osd_wdata <= chv | 8'h80;
        else osd_wdata <= chv;
    end
endmodule
`default_nettype wire
