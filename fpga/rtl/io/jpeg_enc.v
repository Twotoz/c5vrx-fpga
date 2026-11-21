// Triversity HQ DVR: baseline JPEG encoder for one video field at a time,
// bit-exact with fpga/model/jpeg_model.py (record()).
// Four block stages with double-buffered memories between them:
//   A  row DCT: even / odd butterfly, four products a clock (DSP), one
//      coefficient a clock
//   B  column DCT: the same on the transposed rows
//   C  quantisation in zigzag order: |F| x R (DSP), rounded, sign back
//   D  entropy coding: DC differences per component, AC run / size, ZRL,
//      EOB; Huffman codes from a ROM, a 48-bit bit packer, 0xFF stuffing
// B -> C and C -> D buffers are BSRAM (registered reads).
// A field: f_start (quality index, PAL height, field number, parity) sends
// the 8-byte record prefix and the JPEG header; the parent writes blocks
// (64 samples, row-major, four a word) into the input buffer while in_rdy
// and commits each; f_end after the last block: the bits are padded with ones, EOI
// follows, f_done pulses with the field's byte count.
`default_nettype none
module jpeg_enc (
    input  wire        clk,
    input  wire        rst,
    input  wire        f_start,
    input  wire [2:0]  qi,
    input  wire        pal,
    input  wire        parity,
    input  wire [15:0] seq,
    input  wire        f_end,
    output reg         busy,
    output reg         f_done,
    output reg  [17:0] f_bytes,
    output wire        in_rdy,          // an input bank is free
    input  wire        in_we,
    input  wire [3:0]  in_addr,         // {r, h}: samples k = 4h .. 4h + 3 of row r
    input  wire [31:0] in_data,         // sample 4h + j in bits 8j + 7 .. 8j
    input  wire [1:0]  in_comp,         // 0 Y, 1 Cb, 2 Cr (with the commit)
    input  wire        in_commit,
    output reg         o_valid,
    output reg  [7:0]  o_data,
    input  wire        o_ready
);
    reg [20:0] huff [0:1023];
    reg [16:0] rcp  [0:1023];
    reg [7:0]  hdr  [0:1023];
    reg [7:0]  dqt  [0:1023];
`include "jpeg_tab.vh"
    reg [2:0] fqi; reg fpal, fpar; reg [15:0] fseq;

    // ================= input buffer: 8 columns k, {bank, r} =================
    reg        ibw = 1'b0, ibr = 1'b0;          // bank written by the parent / read by A
    reg  [1:0] ib_full = 2'b00;
    reg  [1:0] ib_comp [0:1];
    assign in_rdy = !ib_full[ibw];
    wire [7:0] ibx [0:7];
    reg  [2:0] a_r, a_u;
    genvar g;
    generate for (g = 0; g < 8; g = g + 1) begin : ibk
        reg [7:0] m [0:15];
        always @(posedge clk) if (in_we && in_addr[0] == g[2]) m[{ibw, in_addr[3:1]}] <= in_data[8 * (g % 4) +: 8];
        assign ibx[g] = m[{ibr, a_r}];
    end endgenerate

    // ================= stage A: rows =================
    // even / odd butterfly: C[u][7-k] = (-1)^u C[u][k] holds exactly for the
    // rounded table, so sum_k x_k C[u][k] = sum_{k<4} (x_k +- x_{7-k}) C[u][k]
    reg        a_run = 1'b0;
    reg        tw = 1'b0, tr = 1'b0;
    reg  [1:0] t_full = 2'b00;
    reg  [1:0] t_comp [0:1];
    wire signed [12:0] tval;
    wire [35:0] ma0, ma1, ma2, ma3;
    function signed [9:0] bfa; input [7:0] p, q; input odd;
        bfa = odd ? $signed({2'b0, p}) - $signed({2'b0, q}) : $signed({2'b0, p}) + $signed({2'b0, q}) - 10'sd256;
    endfunction
    wire signed [9:0] xa0 = bfa(ibx[0], ibx[7], a_u[0]), xa1 = bfa(ibx[1], ibx[6], a_u[0]);
    wire signed [9:0] xa2 = bfa(ibx[2], ibx[5], a_u[0]), xa3 = bfa(ibx[3], ibx[4], a_u[0]);
    wire signed [13:0] ca0 = dctc(a_u, 3'd0), ca1 = dctc(a_u, 3'd1), ca2 = dctc(a_u, 3'd2), ca3 = dctc(a_u, 3'd3);
    mul18 u_a0 (.a({{8{xa0[9]}}, xa0}), .b({{4{ca0[13]}}, ca0}), .y(ma0));
    mul18 u_a1 (.a({{8{xa1[9]}}, xa1}), .b({{4{ca1[13]}}, ca1}), .y(ma1));
    mul18 u_a2 (.a({{8{xa2[9]}}, xa2}), .b({{4{ca2[13]}}, ca2}), .y(ma2));
    mul18 u_a3 (.a({{8{xa3[9]}}, xa3}), .b({{4{ca3[13]}}, ca3}), .y(ma3));
    wire signed [26:0] sa_all = $signed(ma0[26:0]) + $signed(ma1[26:0]) + $signed(ma2[26:0]) + $signed(ma3[26:0]) + 27'sd512;
    assign tval = sa_all >>> 10;
    // T buffer: 8 rows r, {bank, u}
    wire signed [12:0] trx [0:7];
    reg  [2:0] b_u, b_v;
    generate for (g = 0; g < 8; g = g + 1) begin : trk
        reg signed [12:0] m [0:15];
        always @(posedge clk) if (a_run && a_r == g) m[{tw, a_u}] <= tval;
        assign trx[g] = m[{tr, b_u}];
    end endgenerate
    always @(posedge clk) begin
        if (rst) begin a_run <= 1'b0; ib_full <= 2'b00; ibw <= 1'b0; ibr <= 1'b0; tw <= 1'b0; end
        else begin
            if (in_commit) begin ib_full[ibw] <= 1'b1; ib_comp[ibw] <= in_comp; ibw <= ~ibw; end
            if (!a_run) begin
                if (ib_full[ibr] && !t_full[tw]) begin a_run <= 1'b1; a_r <= 3'd0; a_u <= 3'd0; end
            end else begin
                a_u <= a_u + 3'd1;
                if (a_u == 3'd7) begin
                    a_r <= a_r + 3'd1;
                    if (a_r == 3'd7) begin
                        a_run <= 1'b0; ib_full[ibr] <= 1'b0; ibr <= ~ibr;
                        t_comp[tw] <= ib_comp[ibr]; tw <= ~tw;
                    end
                end
            end
        end
    end
    // t_full is set by A (end of block) and cleared by B (end of block)
    wire a_done = a_run && a_u == 3'd7 && a_r == 3'd7;

    // ================= stage B: columns =================
    reg        b_run = 1'b0;
    reg        zw = 1'b0, zr = 1'b0;
    reg  [1:0] z_full = 2'b00;
    reg  [1:0] z_comp [0:1];
    wire [35:0] mb0, mb1, mb2, mb3;
    function signed [13:0] bfb; input signed [12:0] p, q; input odd;
        bfb = odd ? $signed({p[12], p}) - $signed({q[12], q}) : $signed({p[12], p}) + $signed({q[12], q});
    endfunction
    wire signed [13:0] tb0 = bfb(trx[0], trx[7], b_v[0]), tb1 = bfb(trx[1], trx[6], b_v[0]);
    wire signed [13:0] tb2 = bfb(trx[2], trx[5], b_v[0]), tb3 = bfb(trx[3], trx[4], b_v[0]);
    wire signed [13:0] cb0 = dctc(b_v, 3'd0), cb1 = dctc(b_v, 3'd1), cb2 = dctc(b_v, 3'd2), cb3 = dctc(b_v, 3'd3);
    mul18 u_b0 (.a({{4{tb0[13]}}, tb0}), .b({{4{cb0[13]}}, cb0}), .y(mb0));
    mul18 u_b1 (.a({{4{tb1[13]}}, tb1}), .b({{4{cb1[13]}}, cb1}), .y(mb1));
    mul18 u_b2 (.a({{4{tb2[13]}}, tb2}), .b({{4{cb2[13]}}, cb2}), .y(mb2));
    mul18 u_b3 (.a({{4{tb3[13]}}, tb3}), .b({{4{cb3[13]}}, cb3}), .y(mb3));
    wire signed [27:0] sb_all = $signed(mb0[27:0]) + $signed(mb1[27:0]) + $signed(mb2[27:0]) + $signed(mb3[27:0]) + 28'sd8192;
    wire signed [12:0] fval = sb_all >>> 14;
    (* ram_style = "block" *) reg signed [12:0] zb [0:127];   // {bank, v, u}: natural order (BSRAM, read registered)
    wire b_done = b_run && b_v == 3'd7 && b_u == 3'd7;
    always @(posedge clk) begin
        if (rst) begin b_run <= 1'b0; t_full <= 2'b00; tr <= 1'b0; zw <= 1'b0; end
        else begin
            if (a_done) t_full[tw] <= 1'b1;
            if (!b_run) begin
                if (t_full[tr] && !z_full[zw]) begin b_run <= 1'b1; b_u <= 3'd0; b_v <= 3'd0; end
            end else begin
                zb[{zw, b_v, b_u}] <= fval;
                b_v <= b_v + 3'd1;
                if (b_v == 3'd7) begin
                    b_u <= b_u + 3'd1;
                    if (b_u == 3'd7) begin
                        b_run <= 1'b0; t_full[tr] <= 1'b0; tr <= ~tr;
                        z_comp[zw] <= t_comp[tr]; zw <= ~zw;
                    end
                end
            end
        end
    end

    // ================= stage C: quantisation (zigzag order) =================
    reg        c_run = 1'b0;
    reg  [6:0] c_i;                              // issue index, 64 = drain
    reg        c_v; reg [5:0] c_wi; reg c_neg; reg [11:0] c_mag;
    reg        qw = 1'b0, qr = 1'b0;
    reg  [1:0] q_full = 2'b00;
    reg  [1:0] q_comp [0:1];
    (* ram_style = "block" *) reg signed [12:0] qb [0:127];   // {bank, zigzag index} (BSRAM, read registered)
    reg  [16:0] rq, rq0;
    reg  signed [12:0] fz;                       // zb read, one clock after the issue
    wire [12:0] fz_abs, q_signed;                // |F| and the quantised value with the sign back (ADDSUB chains)
    addsub #(13) u_fza (.a(13'd0), .b(fz), .sub(fz[12]), .y(fz_abs));
    reg        p_v; reg [5:0] p_wi;
    wire [1:0]  c_comp = z_comp[zr];
    wire [35:0] mq;
    mul18 #(.A_SIGNED(0), .B_SIGNED(0)) u_q (.a({6'd0, c_mag}), .b({1'b0, rq}), .y(mq));
    wire [19:0] qm = (mq[31:0] + 32'd32768) >> 16;
    addsub #(13) u_qs (.a(13'd0), .b({1'b0, qm[11:0]}), .sub(c_neg), .y(q_signed));
    wire c_done = c_run && c_i == 7'd65;
    always @(posedge clk) begin
        fz <= zb[{zr, zigzag(c_i[5:0])}];
        rq0 <= rcp[{fqi, c_comp != 2'd0, c_i[5:0]}];
        if (rst) begin c_run <= 1'b0; z_full <= 2'b00; zr <= 1'b0; qw <= 1'b0; c_v <= 1'b0; p_v <= 1'b0; end
        else begin
            if (b_done) z_full[zw] <= 1'b1;
            p_v <= 1'b0; c_v <= p_v;
            if (p_v) begin c_wi <= p_wi; c_neg <= fz[12]; c_mag <= fz_abs[11:0]; rq <= rq0; end
            if (c_v) qb[{qw, c_wi}] <= q_signed;
            if (!c_run) begin
                if (z_full[zr] && !q_full[qw]) begin c_run <= 1'b1; c_i <= 7'd0; end
            end else if (c_i < 7'd64) begin
                p_v <= 1'b1; p_wi <= c_i[5:0];
                c_i <= c_i + 7'd1;
            end else if (c_i == 7'd64) c_i <= 7'd65;
            else begin                              // the last result is written this clock
                c_run <= 1'b0; z_full[zr] <= 1'b0; zr <= ~zr;
                q_comp[qw] <= z_comp[zr]; qw <= ~qw;
            end
        end
    end

    // ================= stage D: entropy coding =================
    reg        d_run = 1'b0;
    reg  [5:0] d_i; reg [5:0] d_runz;
    reg  signed [12:0] pred [0:2];
    reg        hdr_done;
    wire [1:0] d_comp = q_comp[qr];
    reg  signed [12:0] dq;                       // qb at d_i: read with the next d_i (d_i_n, qr_n)
    reg  [5:0] d_i_n; reg qr_n;
    wire signed [13:0] ddiff = {dq[12], dq} - {pred[d_comp][12], pred[d_comp]};
    wire signed [13:0] dval = d_i == 6'd0 ? ddiff : {dq[12], dq};
    wire [13:0] dmag_w;
    addsub #(14) u_dm (.a(14'd0), .b(dval), .sub(dval[13]), .y(dmag_w));
    wire [12:0] dmag = dmag_w[12:0];
    wire [3:0] dn = dmag[11] ? 4'd12 : dmag[10] ? 4'd11 : dmag[9] ? 4'd10 : dmag[8] ? 4'd9 : dmag[7] ? 4'd8 : dmag[6] ? 4'd7 :
                    dmag[5] ? 4'd6 : dmag[4] ? 4'd5 : dmag[3] ? 4'd4 : dmag[2] ? 4'd3 : dmag[1] ? 4'd2 : dmag[0] ? 4'd1 : 4'd0;
    wire [13:0] dev = dval < 0 ? dval - 14'sd1 : dval;          // ones' complement for negatives
    // packer
    reg  [47:0] acc; reg [6:0] cnt; reg pad_done;               // the top cnt bits (left-aligned): the next byte is always acc[47:40];
                                                  // issue needs cnt + in-flight <= 21, + the new (<= 27) <= 48
    reg         iv; reg [3:0] in_n; reg [11:0] iev;           // the symbol in the Huffman ROM read
    reg  [20:0] hq;
    wire [4:0]  ilen_code = hq[20:16];
    wire [5:0]  ilen = iv ? {1'b0, ilen_code} + {2'b0, in_n} : 6'd0;
    wire        room = {1'b0, cnt} + {2'b0, ilen} <= 8'd21;
    reg  [9:0]  haddr;
    reg         issue; reg [3:0] is_n; reg [11:0] is_ev;
    wire        last_blk_done;
    // decide this clock's symbol
    always @(*) begin
        issue = 1'b0; haddr = 10'd0; is_n = 4'd0; is_ev = 12'd0;
        if (d_run && hdr_done && room) begin
            if (d_i == 6'd0) begin issue = 1'b1; haddr = {d_comp != 2'd0, 1'b0, 4'd0, dn}; is_n = dn; is_ev = dev[11:0]; end
            else if (dq == 0) begin
                if (d_i == 6'd63) begin issue = 1'b1; haddr = {d_comp != 2'd0, 1'b1, 8'h00}; end
            end else if (d_runz > 6'd15) begin issue = 1'b1; haddr = {d_comp != 2'd0, 1'b1, 8'hf0}; end
            else begin issue = 1'b1; haddr = {d_comp != 2'd0, 1'b1, d_runz[3:0], dn}; is_n = dn; is_ev = dev[11:0]; end
        end
    end
    always @(*) begin
        d_i_n = d_i; qr_n = qr;
        if (!d_run) begin if (q_full[qr]) d_i_n = 6'd0; end
        else if (d_i == 6'd0) begin if (issue) d_i_n = 6'd1; end
        else if (dq == 0) begin
            if (d_i == 6'd63) begin if (issue) qr_n = ~qr; end
            else d_i_n = d_i + 6'd1;
        end else if (issue && d_runz <= 6'd15) begin
            if (d_i == 6'd63) qr_n = ~qr; else d_i_n = d_i + 6'd1;
        end
    end
    always @(posedge clk) dq <= qb[{qr_n, d_i_n}];
    always @(posedge clk) begin
        hq <= huff[haddr];
        if (rst) begin d_run <= 1'b0; q_full <= 2'b00; qr <= 1'b0; iv <= 1'b0; end
        else begin
            if (c_done) q_full[qw] <= 1'b1;
            iv <= issue; in_n <= is_n; iev <= is_ev;
            if (f_start) begin pred[0] <= 13'sd0; pred[1] <= 13'sd0; pred[2] <= 13'sd0; end
            if (!d_run) begin
                if (q_full[qr]) begin d_run <= 1'b1; d_i <= 6'd0; d_runz <= 6'd0; end
            end else if (d_i == 6'd0) begin
                if (issue) begin pred[d_comp] <= dq; d_i <= 6'd1; end
            end else if (dq == 0) begin
                if (d_i == 6'd63) begin
                    if (issue) begin d_run <= 1'b0; q_full[qr] <= 1'b0; qr <= ~qr; end
                end else begin d_runz <= d_runz + 6'd1; d_i <= d_i + 6'd1; end
            end else if (issue) begin
                if (d_runz > 6'd15) d_runz <= d_runz - 6'd16;
                else begin
                    d_runz <= 6'd0;
                    if (d_i == 6'd63) begin d_run <= 1'b0; q_full[qr] <= 1'b0; qr <= ~qr; end
                    else d_i <= d_i + 6'd1;
                end
            end
        end
    end

    // ================= packer, header, output =================
    localparam O_IDLE = 0, O_HDR = 1, O_DATA = 2, O_PAD = 3, O_DRAIN = 4, O_EOI = 5, O_EOI2 = 6;
    reg  [2:0] os;
    reg  [9:0] hj;                                // prefix 0..7, header 8..
    reg        stuff;
    reg        fend_seen;
    wire       ent_put = iv;
    wire [27:0] ent_val = ({12'd0, hq[15:0]} << in_n) | {16'd0, iev & ((12'd1 << in_n) - 12'd1)};
    wire       can_out = !o_valid || o_ready;
    wire       pipe_empty = ib_full == 2'b00 && !a_run && !b_run && !c_run && !d_run && t_full == 2'b00 && z_full == 2'b00 &&
                            q_full == 2'b00 && !iv;
    // header byte: prefix, then the ROM with the DQT tables of this quality and the height
    wire [9:0] hk = hj - 10'd8;
    reg  [7:0] hrom, drom; reg hph;
    wire [9:0] hk72 = hk - 10'd72, hk7 = hk - 10'd7;
    wire [6:0] dqi = (hk >= 10'd72) ? {1'b1, hk72[5:0]} : {1'b0, hk7[5:0]};
    always @(posedge clk) begin hrom <= hdr[hk]; drom <= dqt[{fqi, dqi}]; end     // ROM reads (BSRAM)
    reg  [7:0] hbyte;
    always @(*) begin
        case (hj)
            10'd0: hbyte = "T"; 10'd1: hbyte = "R"; 10'd2: hbyte = "I"; 10'd3: hbyte = "J";
            10'd4: hbyte = fseq[7:0]; 10'd5: hbyte = fseq[15:8]; 10'd6: hbyte = {6'd0, fpar, fpal}; 10'd7: hbyte = {5'd0, fqi};
            default: hbyte = (hk >= 10'd7 && hk <= 10'd70) || (hk >= 10'd72 && hk <= 10'd135) ? drom :
                             (fpal && hk == HDR_HPOS) ? 8'd1 : (fpal && hk == HDR_HPOS + 1) ? 8'd32 : hrom;
        endcase
    end
    always @(posedge clk) begin
        f_done <= 1'b0;
        if (rst) begin
            os <= O_IDLE; busy <= 1'b0; o_valid <= 1'b0; acc <= 48'd0; cnt <= 7'd0; stuff <= 1'b0; hdr_done <= 1'b0; fend_seen <= 1'b0;
        end else begin
            if (o_valid && o_ready) o_valid <= 1'b0;
            if (f_end) fend_seen <= 1'b1;
            // the entropy put (D's symbol, its code from the ROM now)
            begin : pack
                reg [47:0] a; reg [6:0] c;
                a = acc; c = cnt; pad_done = 1'b0;
                if (can_out && (os == O_DATA || os == O_PAD || os == O_DRAIN)) begin
                    if (stuff) begin o_valid <= 1'b1; o_data <= 8'h00; stuff <= 1'b0; f_bytes <= f_bytes + 18'd1; end
                    else if (c >= 7'd8) begin
                        o_valid <= 1'b1; o_data <= a[47:40]; stuff <= a[47:40] == 8'hff;
                        a = a << 8; c = c - 7'd8; f_bytes <= f_bytes + 18'd1;
                    end
                end
                // the symbol's bits go right below the ones waiting: its LSB at 48 - c - len
                if (ent_put) begin
                    a = a | ({20'd0, ent_val} << (7'd48 - c - {2'b0, ilen_code} - {3'b0, in_n}));
                    c = c + {2'b0, ilen_code} + {3'b0, in_n};
                end
                // padding to a byte with ones (python Bits.flush), once fewer than 8 bits wait
                if (os == O_PAD && c < 7'd8 && !stuff) begin
                    if (c != 7'd0) begin a = a | {8'hff >> c[2:0], 40'd0}; c = 7'd8; end
                    pad_done = 1'b1;
                end
                acc <= a; cnt <= c;
            end
            case (os)
                O_IDLE: if (f_start) begin
                    os <= O_HDR; busy <= 1'b1; hj <= 10'd0; hph <= 1'b0; hdr_done <= 1'b0; fend_seen <= 1'b0; f_bytes <= 18'd0;
                    fqi <= qi; fpal <= pal; fpar <= parity; fseq <= seq;
                end
                O_HDR: if (!hph) hph <= 1'b1;                   // the ROMs read hj's byte
                else if (can_out) begin
                    o_valid <= 1'b1; o_data <= hbyte; f_bytes <= f_bytes + 18'd1; hj <= hj + 10'd1; hph <= 1'b0;
                    if (hj == 10'd8 + HDR_LEN - 1) begin os <= O_DATA; hdr_done <= 1'b1; end
                end
                O_DATA: if (fend_seen && pipe_empty && !iv) os <= O_PAD;
                O_PAD: if (pad_done) os <= O_DRAIN;      // (the pack block pads)
                O_DRAIN: if (cnt == 7'd0 && !stuff && can_out) begin
                    o_valid <= 1'b1; o_data <= 8'hff; f_bytes <= f_bytes + 18'd1; os <= O_EOI;
                end
                O_EOI: if (can_out) begin o_valid <= 1'b1; o_data <= 8'hd9; f_bytes <= f_bytes + 18'd1; os <= O_EOI2; end
                default: begin os <= O_IDLE; busy <= 1'b0; f_done <= 1'b1; hdr_done <= 1'b0; end
            endcase
        end
    end
endmodule
`default_nettype wire
