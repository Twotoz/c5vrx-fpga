// Triversity: a byte ring to TRIDVR.BIN on the TF card, SPI mode: the card
// part of dvr.v (init, the header-sector search, CMD25 ring writes) for a
// producer that fills a ring of its own (the HQ DVR's JPEG records).
// rp advances over the bytes written; a 512-byte block goes out whenever one
// waits; recording stops once rec_on is off, the producer is idle and less
// than a block remains.
`default_nettype none
module sd_ring (
    input  wire        clk,
    input  wire        rst,
    input  wire        rec_on,         // record (this domain)
    input  wire        src_idle,       // the producer has nothing more to add
    input  wire [15:0] wp,             // ring write pointer (address + lap bit)
    input  wire [15:0] used,           // wp - rp
    input  wire [7:0]  rb_rd,          // ring byte at rp (registered read)
    output reg  [15:0] rp,
    output reg         sd_cs,
    output reg         sd_sck,
    output reg         sd_mosi,
    input  wire        sd_miso,
    output reg  [1:0]  state           // 0 no card / init, 1 ready, 2 recording, 3 error
);
    // ---- SPI byte engine: mode 0, MSB first; sck = clk / (2 * DIV) ---------------------
    reg        slow;
    reg [6:0]  div_cnt;
    reg        sp_go, sp_busy, sp_phase;
    reg [7:0]  sp_tx, sp_rx, sp_sh;
    reg [2:0]  sp_bit;
    wire [6:0] DIV = slow ? 7'd50 : 7'd1;        // 400 kHz while initialising, then 20 MHz
    always @(posedge clk) begin
        if (rst) begin sp_busy <= 1'b0; sd_sck <= 1'b0; sd_mosi <= 1'b1; div_cnt <= 7'd0; end
        else if (!sp_busy) begin
            if (sp_go) begin sp_busy <= 1'b1; sp_sh <= sp_tx; sp_bit <= 3'd0; sp_phase <= 1'b0; div_cnt <= 7'd0; sd_mosi <= sp_tx[7]; end
        end else if (div_cnt != DIV - 7'd1) div_cnt <= div_cnt + 7'd1;
        else begin
            div_cnt <= 7'd0;
            if (!sp_phase) begin sd_sck <= 1'b1; sp_rx <= {sp_rx[6:0], sd_miso}; sp_phase <= 1'b1; end
            else begin
                sd_sck <= 1'b0; sp_phase <= 1'b0;
                if (sp_bit == 3'd7) sp_busy <= 1'b0;
                else begin sp_bit <= sp_bit + 3'd1; sp_sh <= {sp_sh[6:0], 1'b1}; sd_mosi <= sp_sh[6]; end
            end
        end
    end
    // ---- card --------------------------------------------------------------------------------
    localparam S_RESET = 0, S_PWR = 1, S_NEXT = 2, S_CMD = 3, S_RESP = 4, S_EXTRA = 5, S_PARSE = 6, S_RDTOK = 7,
               S_RDDATA = 8, S_RD17 = 9, S_ROOT = 10, S_READY = 11, S_WR25 = 12, S_WRWAIT = 13, S_WRTOK = 14,
               S_WRDATA = 15, S_BUSY = 16, S_STOP = 17, S_STOPBUSY = 18, S_ERROR = 19;
    reg [4:0]  st;
    reg [2:0]  step;                 // init command: 0 CMD0, 1 CMD8, 2 CMD55, 3 ACMD41, 4 CMD58, 5 a CMD17
    reg [47:0] cmd;
    reg [3:0]  ci;
    reg [7:0]  r1;
    reg [2:0]  extra;
    reg [31:0] ocr;
    reg [15:0] tries, acmd_n;
    reg        ccs;
    reg [9:0]  bi;
    reg [31:0] lba, file_lba, file_sect, pos;
    reg        mok;                  // the sector being read starts with the magic so far
    reg [23:0] tmo;
    reg [9:0]  j; reg [7:0] b;
    localparam [31:0] SCAN_MAX = 32'd131071;             // search the first 64 MB
    function [7:0] magic; input [3:0] i;                 // "TRIDVR-FILE-0001"
        case (i)
            0: magic = "T"; 1: magic = "R"; 2: magic = "I"; 3: magic = "D"; 4: magic = "V"; 5: magic = "R"; 6: magic = "-";
            7: magic = "F"; 8: magic = "I"; 9: magic = "L"; 10: magic = "E"; 11: magic = "-"; 12: magic = "0"; 13: magic = "0";
            14: magic = "0"; default: magic = "1";
        endcase
    endfunction
    function [47:0] mk; input [5:0] c; input [31:0] arg; input [7:0] crc; mk = {2'b01, c, arg, crc}; endfunction
    wire [31:0] addr = ccs ? lba : {lba[22:0], 9'd0};
    always @(posedge clk) begin
        sp_go <= 1'b0;
        if (rst) begin st <= S_RESET; state <= 2'd0; sd_cs <= 1'b1; slow <= 1'b1; rp <= 16'd0; tmo <= 24'd0; end
        else if (!sp_busy && !sp_go) case (st)
            S_RESET: begin state <= 2'd0; sd_cs <= 1'b1; slow <= 1'b1; ci <= 4'd0; acmd_n <= 16'd0; rp <= wp; st <= S_PWR; end
            S_PWR: begin                                        // 96 clocks with CS high
                sp_tx <= 8'hff; sp_go <= 1'b1; ci <= ci + 4'd1;
                if (ci == 4'd11) begin sd_cs <= 1'b0; step <= 3'd0; st <= S_NEXT; end
            end
            S_NEXT: begin
                ci <= 4'd0; extra <= 3'd0; st <= S_CMD;
                case (step)
                    3'd0: cmd <= mk(6'd0, 32'd0, 8'h95);
                    3'd1: begin cmd <= mk(6'd8, 32'h1aa, 8'h87); extra <= 3'd4; end
                    3'd2: cmd <= mk(6'd55, 32'd0, 8'h65);
                    3'd3: cmd <= mk(6'd41, 32'h40000000, 8'h77);
                    3'd4: begin cmd <= mk(6'd58, 32'd0, 8'hfd); extra <= 3'd4; end
                    default: begin slow <= 1'b0; lba <= 32'd0; st <= S_RD17; end
                endcase
            end
            S_RD17: begin cmd <= mk(6'd17, addr, 8'hff); ci <= 4'd0; extra <= 3'd0; step <= 3'd5; st <= S_CMD; end
            S_CMD: begin
                sp_tx <= cmd[47 - 8 * ci -: 8]; sp_go <= 1'b1; ci <= ci + 4'd1;
                if (ci == 4'd5) begin st <= S_RESP; tries <= 16'd0; end
            end
            S_RESP: begin                                       // R1: the first byte with bit 7 clear
                if (ci == 4'd6) begin sp_tx <= 8'hff; sp_go <= 1'b1; ci <= 4'd7; end
                else if (!sp_rx[7]) begin r1 <= sp_rx; ci <= 4'd0; st <= extra != 3'd0 ? S_EXTRA : S_PARSE; end
                else if (tries == 16'd16) st <= S_ERROR;
                else begin tries <= tries + 16'd1; sp_tx <= 8'hff; sp_go <= 1'b1; end
            end
            S_EXTRA: begin                                      // the four bytes of R3 / R7
                if (ci != 4'd0) ocr <= {ocr[23:0], sp_rx};
                if (ci == {1'b0, extra}) st <= S_PARSE;
                else begin sp_tx <= 8'hff; sp_go <= 1'b1; ci <= ci + 4'd1; end
            end
            S_PARSE: begin
                st <= S_NEXT;
                case (step)
                    3'd0: if (r1 == 8'h01) step <= 3'd1; else st <= S_ERROR;
                    3'd1: step <= 3'd2;                         // an R7, or "illegal" from a v1 card
                    3'd2: step <= 3'd3;
                    3'd3: if (r1 == 8'h00) step <= 3'd4;
                          else if (acmd_n == 16'd8000) st <= S_ERROR;
                          else begin acmd_n <= acmd_n + 16'd1; step <= 3'd2; end
                    3'd4: begin ccs <= ocr[30]; step <= 3'd5; end
                    default: if (r1 == 8'h00) begin st <= S_RDTOK; tries <= 16'd0; ci <= 4'd0; end else st <= S_ERROR;
                endcase
            end
            S_RDTOK: begin                                      // data token 0xFE
                if (ci == 4'hf && sp_rx == 8'hfe) begin st <= S_RDDATA; bi <= 10'd0; mok <= 1'b1; end
                else if (tries == 16'd50000) st <= S_ERROR;
                else begin tries <= tries + 16'd1; sp_tx <= 8'hff; sp_go <= 1'b1; ci <= 4'hf; end
            end
            S_RDDATA: begin                                     // 512 bytes + CRC: is this the file's header?
                if (bi != 10'd0 && bi <= 10'd512) begin
                    j = bi - 10'd1; b = sp_rx;
                    if (j < 10'd16 && b != magic(j[3:0])) mok <= 1'b0;
                    if (j >= 10'd16 && j < 10'd20) file_sect <= {b, file_sect[31:8]};
                end
                if (bi == 10'd515) begin                        // sector done (2 CRC bytes read)
                    if (mok) begin
                        file_lba <= lba + 32'd1; pos <= 32'd0;
                        st <= file_sect >= 32'd95 ? S_READY : S_ERROR;
                    end else if (lba == SCAN_MAX) st <= S_ERROR;
                    else begin lba <= lba + 32'd1; st <= S_RD17; end
                end else begin sp_tx <= 8'hff; sp_go <= 1'b1; bi <= bi + 10'd1; end
            end
            S_READY: begin
                state <= 2'd1; rp <= wp;
                if (rec_on) begin state <= 2'd2; lba <= file_lba + pos; st <= S_WR25; end
            end
            S_WR25: begin cmd <= mk(6'd25, addr, 8'hff); ci <= 4'd0; st <= S_WRWAIT; end
            S_WRWAIT: begin                                     // CMD25, its R1, one gap byte
                if (ci < 4'd6) begin sp_tx <= cmd[47 - 8 * ci -: 8]; sp_go <= 1'b1; ci <= ci + 4'd1; tries <= 16'd0; end
                else if (ci == 4'd6) begin sp_tx <= 8'hff; sp_go <= 1'b1; ci <= 4'd7; end
                else if (ci == 4'd8) st <= S_WRTOK;
                else if (!sp_rx[7]) begin
                    if (sp_rx == 8'h00) begin sp_tx <= 8'hff; sp_go <= 1'b1; ci <= 4'd8; end else st <= S_ERROR;
                end else if (tries == 16'd16) st <= S_ERROR;
                else begin tries <= tries + 16'd1; sp_tx <= 8'hff; sp_go <= 1'b1; end
            end
            S_WRTOK: begin                                      // a block per 512 bytes waiting
                if (used >= 16'd512) begin sp_tx <= 8'hfc; sp_go <= 1'b1; bi <= 10'd0; st <= S_WRDATA; end
                else if (!rec_on && src_idle) st <= S_STOP;     // stop once the last frame drained
            end
            S_WRDATA: begin
                if (bi < 10'd512) begin sp_tx <= rb_rd; sp_go <= 1'b1; rp <= rp + 16'd1; bi <= bi + 10'd1; end
                else if (bi < 10'd515) begin sp_tx <= 8'hff; sp_go <= 1'b1; bi <= bi + 10'd1; end   // CRC, CRC, response
                else if (sp_rx[4:0] != 5'b00101) st <= S_ERROR;
                else begin st <= S_BUSY; tmo <= 24'd0; ci <= 4'd0; end
            end
            S_BUSY: begin                                       // MISO low while the card programs
                if (ci == 4'he && sp_rx == 8'hff) begin
                    if (pos + 32'd1 == file_sect) begin pos <= 32'd0; st <= S_STOP; end
                    else begin pos <= pos + 32'd1; st <= S_WRTOK; end
                end else if (tmo == 24'hffffff) st <= S_ERROR;
                else begin tmo <= tmo + 24'd1; sp_tx <= 8'hff; sp_go <= 1'b1; ci <= 4'he; end
            end
            S_STOP: begin sp_tx <= 8'hfd; sp_go <= 1'b1; st <= S_STOPBUSY; ci <= 4'd0; tmo <= 24'd0; end
            S_STOPBUSY: begin                                   // one byte, then busy until 0xFF
                if (ci == 4'he && sp_rx == 8'hff) st <= (pos == 32'd0 && rec_on) ? S_WR25 : S_READY;
                else if (tmo == 24'hffffff) st <= S_ERROR;
                else begin tmo <= tmo + 24'd1; sp_tx <= 8'hff; sp_go <= 1'b1; ci <= ci == 4'd0 ? 4'd1 : 4'he; end
            end
            S_ERROR: begin                                      // retry from power-up after ~0.4 s
                state <= 2'd3; sd_cs <= 1'b1; rp <= wp;
                if (tmo == 24'hffffff) begin tmo <= 24'd0; st <= S_RESET; end else tmo <= tmo + 24'd1;
            end
            default: st <= S_RESET;
        endcase
    end
endmodule
`default_nettype wire
