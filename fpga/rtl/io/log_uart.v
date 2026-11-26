// Triversity: live status over the Tang Nano 20K's USB serial (BL616 UART
// bridge, FPGA pin 69 -> the PC's second serial port), 115200 8N1, ten text
// lines a second for reading along while flying or on the bench:
//
//   t=12.3 lock=1 pal=0 fps=59/0 k8=555 q=1580 A=G54,+18.4,u,78 B=G61,+12.1,f,55 C=-
//
//   t      seconds since start (tenths)
//   lock   video lock; pal 1 = PAL, 0 = NTSC
//   fps    fields of the last second from a real vertical sync / predicted
//          by the flywheel (vid_sync fps_real / fps_pred)
//   k8     video gain (vid_sync); q in-window sync edges per 100 ms
//   A/B/C  per C5 from its markers: Direct Gain row (G..), C/N dB (? not
//          known), IQ lane u ultrafine / f fine / c coarse (STRONG LANE) or
//          n Native AGC, signal 0..100; "-" when no marker for 3 s
//
// Only in DEBUG=1 builds (fpga/build.sh, TRI_DEBUG): the normal builds are
// full. Reads the marker bus itself (as menu.v / hq_ui.v), so it works with
// either UI. All inputs are slow and read as they are while a line goes out (one
// flop for the buses): a value that changes mid-line may show torn once,
// which a status line can afford, and it saves a snapshot of everything.
// sim/run_log_uart_tb.py decodes the serial output and checks the text.
`default_nettype none
module log_uart #(parameter CLK_HZ = 33750000, parameter BAUD = 115200) (
    input  wire        clk,
    input  wire        rst,
    input  wire        mk_tog_a,           // markers (tri_top, other clock domain)
    input  wire [1:0]  mk_src_a,
    input  wire [15:0] mk_pl_a,
    input  wire        locked_a,
    input  wire        pal_a,
    input  wire [6:0]  fps_real_a,
    input  wire [6:0]  fps_pred_a,
    input  wire [15:0] k8_a,
    input  wire [15:0] sync_q_a,
    output reg         tx = 1'b1
);
    localparam integer DIV = CLK_HZ / BAUD;
    localparam integer TICK = CLK_HZ / 10;     // a line every 100 ms
    localparam integer MSDIV = CLK_HZ / 1000;
    // ---- inputs into this domain ----
    reg [2:0] mt; reg [1:0] lk, pl;
    reg [6:0] fr, fp; reg [15:0] k8, sq;
    always @(posedge clk) begin
        mt <= {mt[1:0], mk_tog_a}; lk <= {lk[0], locked_a}; pl <= {pl[0], pal_a};
        fr <= fps_real_a; fp <= fps_pred_a; k8 <= k8_a; sq <= sync_q_a;
    end
    wire mk_ev = mt[2] ^ mt[1];            // payload / source stable long after a toggle
    // ---- C5 status from the markers (c5/main/fpga_link.h) ----
    reg [7:0] g [0:2]; reg [11:0] cn [0:2]; reg [7:0] fl [0:2]; reg [6:0] sg [0:2]; reg [11:0] age [0:2];
    reg [16:0] mscnt; reg ms;
    integer i;
    always @(posedge clk) begin
        ms <= 1'b0;
        if (mscnt == MSDIV - 1) begin mscnt <= 17'd0; ms <= 1'b1; end else mscnt <= mscnt + 17'd1;
        if (rst) begin
            mscnt <= 17'd0;
            for (i = 0; i < 3; i = i + 1) begin g[i] <= 8'd0; cn[i] <= 12'd0; fl[i] <= 8'd0; sg[i] <= 7'd0; age[i] <= 12'hfff; end
        end else begin
            if (ms) for (i = 0; i < 3; i = i + 1) if (age[i] != 12'hfff) age[i] <= age[i] + 12'd1;
            if (mk_ev && mk_src_a != 2'd3) begin
                age[mk_src_a] <= 12'd0;
                case (mk_pl_a[15:12])
                    4'd2: g[mk_src_a] <= mk_pl_a[7:0];
                    4'd3: cn[mk_src_a] <= mk_pl_a[11:0];
                    4'd4: fl[mk_src_a] <= mk_pl_a[7:0];
                    4'd6: sg[mk_src_a] <= mk_pl_a[6:0] > 7'd100 ? 7'd100 : mk_pl_a[6:0];
                    default: ;
                endcase
            end
        end
    end
    // ---- time ----
    reg [15:0] sec; reg [3:0] tenth; reg [23:0] tick;
    // ---- the line as tokens: 0 literal, 1 number (field), 2 C5 special, 3 end ----
    // header 0..34, C5 blocks of 12 at 35 (A), 47 (B), 59 (C), CR LF at 71, 72
    localparam [1:0] K_LIT = 2'd0, K_NUM = 2'd1, K_SPC = 2'd2, K_END = 2'd3;
    reg  [6:0] idx;
    wire [1:0] c = idx < 7'd47 ? 2'd0 : idx < 7'd59 ? 2'd1 : 2'd2;
    wire [6:0] j = idx - (c == 2'd0 ? 7'd35 : c == 2'd1 ? 7'd47 : 7'd59);
    reg  [9:0] t;                          // {kind, arg} of token idx
    always @(*) begin
        t = {K_END, 8'd0};
        if (idx < 7'd35) case (idx)
            0: t = {K_LIT, "t"}; 1: t = {K_LIT, "="}; 2: t = {K_NUM, 8'd0}; 3: t = {K_LIT, "."}; 4: t = {K_NUM, 8'd1};
            5: t = {K_LIT, " "}; 6: t = {K_LIT, "l"}; 7: t = {K_LIT, "o"}; 8: t = {K_LIT, "c"}; 9: t = {K_LIT, "k"};
            10: t = {K_LIT, "="}; 11: t = {K_NUM, 8'd2}; 12: t = {K_LIT, " "}; 13: t = {K_LIT, "p"}; 14: t = {K_LIT, "a"};
            15: t = {K_LIT, "l"}; 16: t = {K_LIT, "="}; 17: t = {K_NUM, 8'd3}; 18: t = {K_LIT, " "}; 19: t = {K_LIT, "f"};
            20: t = {K_LIT, "p"}; 21: t = {K_LIT, "s"}; 22: t = {K_LIT, "="}; 23: t = {K_NUM, 8'd4}; 24: t = {K_LIT, "/"};
            25: t = {K_NUM, 8'd5}; 26: t = {K_LIT, " "}; 27: t = {K_LIT, "k"}; 28: t = {K_LIT, "8"}; 29: t = {K_LIT, "="};
            30: t = {K_NUM, 8'd6}; 31: t = {K_LIT, " "}; 32: t = {K_LIT, "q"}; 33: t = {K_LIT, "="}; default: t = {K_NUM, 8'd7};
        endcase else if (idx < 7'd71) case (j)
            0: t = {K_LIT, " "}; 1: t = {K_SPC, 8'd0};          // the C5's letter
            2: t = {K_LIT, "="}; 3: t = {K_SPC, 8'd1};          // "G", or "-" and the block's end when silent
            4: t = {K_NUM, 8'd8}; 5: t = {K_LIT, ","};
            6: t = {K_SPC, 8'd2};                                // C/N sign, or "?" and on to its ","
            7: t = {K_NUM, 8'd9}; 8: t = {K_LIT, ","};
            9: t = {K_SPC, 8'd3};                                // lane / native
            10: t = {K_LIT, ","}; default: t = {K_NUM, 8'd10};
        endcase
        else if (idx == 7'd71) t = {K_LIT, 8'd13};
        else if (idx == 7'd72) t = {K_LIT, 8'd10};
    end
    wire [11:0] cnc = cn[c];
    wire        live = age[c] < 12'd3000;
    wire [12:0] cn_rel = {1'b0, cnc} - 13'd1000;               // C/N x10, signed
    wire [11:0] cn_abs = cn_rel[12] ? 12'd1000 - cnc : cn_rel[11:0];
    reg  [15:0] fval;
    always @(*) case (t[3:0])
        4'd0: fval = sec; 4'd1: fval = {12'd0, tenth}; 4'd2: fval = {15'd0, lk[1]}; 4'd3: fval = {15'd0, pl[1]};
        4'd4: fval = {9'd0, fr}; 4'd5: fval = {9'd0, fp}; 4'd6: fval = k8; 4'd7: fval = sq;
        4'd8: fval = {8'd0, g[c]}; 4'd9: fval = {4'd0, cn_abs}; 4'd10: fval = {9'd0, sg[c]};
        default: fval = 16'd0;
    endcase
    // ---- number to decimal: double dabble, 16 shifts ----
    reg [15:0] bin; reg [19:0] bcd; reg [4:0] nconv; reg [2:0] dig; reg started, tenths, dot;
    reg [19:0] bcd_a;
    integer d;
    always @(*) begin
        bcd_a = bcd;
        for (d = 0; d < 5; d = d + 1) if (bcd_a[4 * d +: 4] >= 4'd5) bcd_a[4 * d +: 4] = bcd_a[4 * d +: 4] + 4'd3;
    end
    wire [3:0] dval = bcd[4 * dig +: 4];
    // ---- sequencer and UART ----
    localparam [2:0] S_IDLE = 3'd0, S_TOK = 3'd1, S_CONV = 3'd2, S_DIG = 3'd3, S_SEND = 3'd4;
    reg [2:0]  st, ret;
    reg [7:0]  ch;
    reg [9:0]  sh; reg [3:0] nbit; reg [15:0] bdiv;
    always @(posedge clk) begin
        if (rst) begin
            st <= S_IDLE; tx <= 1'b1; tick <= 24'd0; sec <= 16'd0; tenth <= 4'd0; idx <= 7'd0; nbit <= 4'd0;
        end else begin
            tick <= tick == TICK - 1 ? 24'd0 : tick + 24'd1;
            case (st)
                S_IDLE: if (tick == 24'd0) begin
                    if (tenth == 4'd9) begin tenth <= 4'd0; sec <= sec + 16'd1; end else tenth <= tenth + 4'd1;
                    idx <= 7'd0; st <= S_TOK;
                end
                S_TOK: case (t[9:8])
                    K_LIT: begin ch <= t[7:0]; idx <= idx + 7'd1; ret <= S_TOK; st <= S_SEND; end
                    K_NUM: begin
                        bin <= fval; bcd <= 20'd0; nconv <= 5'd16; dig <= 3'd4; started <= 1'b0; dot <= 1'b0;
                        tenths <= t[3:0] == 4'd9; st <= S_CONV;
                    end
                    K_SPC: begin
                        idx <= idx + 7'd1; ret <= S_TOK; st <= S_SEND;
                        case (t[1:0])
                            2'd0: ch <= "A" + {6'd0, c};
                            2'd1: if (live) ch <= "G"; else begin ch <= "-"; idx <= idx + 7'd9; end
                            2'd2: if (cnc == 12'd0) begin ch <= "?"; idx <= idx + 7'd2; end
                                  else ch <= cn_rel[12] ? "-" : "+";
                            default: ch <= fl[c][7] ? "n" : fl[c][5:4] == 2'd2 ? "u" : fl[c][5:4] == 2'd1 ? "f" : "c";
                        endcase
                    end
                    default: st <= S_IDLE;
                endcase
                S_CONV: if (nconv != 5'd0) begin
                    bcd <= {bcd_a[18:0], bin[15]}; bin <= {bin[14:0], 1'b0}; nconv <= nconv - 5'd1;
                end else st <= S_DIG;
                S_DIG:
                    // digits from the top without leading zeros (C/N: at least "d.d")
                    if (dot) begin ch <= "."; dot <= 1'b0; ret <= S_DIG; st <= S_SEND; end
                    else if (!started && dval == 4'd0 && dig > (tenths ? 3'd1 : 3'd0)) dig <= dig - 3'd1;
                    else begin
                        ch <= "0" + {4'd0, dval}; started <= 1'b1; st <= S_SEND;
                        if (dig == 3'd0) begin ret <= S_TOK; idx <= idx + 7'd1; end
                        else begin ret <= S_DIG; dig <= dig - 3'd1; dot <= tenths && dig == 3'd1; end
                    end
                S_SEND: if (nbit == 4'd0) begin sh <= {1'b1, ch, 1'b0}; nbit <= 4'd10; bdiv <= 16'd0; end
                    else if (bdiv == DIV - 1) begin
                        bdiv <= 16'd0; tx <= sh[0]; sh <= {1'b1, sh[9:1]}; nbit <= nbit - 4'd1;
                        if (nbit == 4'd1) st <= ret;
                    end else bdiv <= bdiv + 16'd1;
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
`default_nettype wire
