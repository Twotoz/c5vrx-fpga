"""Triversity: the 90 Hz HDMI output (TRI_HDMI90) from source to pixels:
rtl/video/fbuf.v (field buffer, SDRAM via rtl/io/sdram.v and sim/sdram_model.v)
and rtl/video/lcd_out.v at 48.6 MHz, fed like vid_sync feeds the line buffer
(40 MHz, NTSC 262.5 / PAL 312.5 lines a field, 240 / 288 shown, 720 pixels).
Every source pixel encodes {field mod 8, line, x mod 16}. Checked per output
frame: one whole field (no tear), every line where it belongs and shown twice,
every pixel; the fields in order, none skipped; no SDRAM timing violation;
the output frame rate.

    python fpga/sim/run_hdmi90_tb.py [--pal] [--frames=N]
"""
import subprocess, sys, tempfile
from pathlib import Path
import numpy as np

HERE = Path(__file__).resolve().parent
RTL = HERE.parent / 'rtl'

TB = r'''
`timescale 1ns/1ps
module tb;
    reg aclk = 0; always #12.5 aclk = ~aclk;            // 40 MHz IQ clock
    reg pclk = 0; always #10.288 pclk = ~pclk;          // 48.6 MHz pixel clock
    reg rst = 1, rst_p = 1;
    localparam PAL = __PAL__;
    localparam LT = PAL ? 2560 : 2542;                  // source line, clocks
    localparam SHOW0 = PAL ? 23 : 20, NSHOW = PAL ? 288 : 240;
    // ---- source: vid_sync's line-buffer interface ----
    reg wr_en = 0; reg [10:0] wr_addr = 0; reg [15:0] wr_data = 0;
    reg line_tog = 0, field_tog = 0; reg [8:0] line_info = 0;
    integer hc = 0, ln = 0, fld = 0, flines, px, dda, orow = 0, show = 0;
    always @(posedge aclk) begin
        wr_en <= 0;
        if (!rst) begin
            flines = PAL ? (fld[0] ? 313 : 312) : (fld[0] ? 263 : 262);
            if (hc == LT - 1) begin
                hc <= 0;
                line_info <= {show[0], orow[7:0]}; line_tog <= ~line_tog;
                if (show) orow <= orow + 1;
                if (ln == flines - 1) begin ln <= 0; fld <= fld + 1; field_tog <= ~field_tog; orow <= 0; show <= 0; end
                else begin ln <= ln + 1; show <= (ln + 1 >= SHOW0 && ln + 1 < SHOW0 + NSHOW); end
                px = 0; dda = 0;
            end else hc <= hc + 1;
            if (show && hc >= 300 && px < 720) begin
                dda = dda + 720;
                if (dda >= 2104) begin
                    dda = dda - 2104;
                    wr_en <= 1; wr_addr <= {orow[0], px[9:0]};
                    wr_data <= {fld[2:0], orow[8:0], px[3:0]};
                    px = px + 1;
                end
            end
        end
    end
    // ---- DUT ----
    wire fb_frame, fb_fetch; wire [8:0] fb_line; wire [10:0] ra; wire [15:0] rd;
    wire sdclk, sdcke, sdcs, sdras, sdcas, sdwe; wire [10:0] sda; wire [1:0] sdba; wire [3:0] sddqm; wire [31:0] sddq;
    fbuf u_fb (.clk(aclk), .rst(rst), .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data), .line_tog(line_tog), .line_info(line_info),
               .field_tog(field_tog), .frame_tog_p(fb_frame), .fetch_tog_p(fb_fetch), .fetch_line_p(fb_line),
               .rclk(pclk), .raddr(ra), .rdata(rd),
               .O_sdram_clk(sdclk), .O_sdram_cke(sdcke), .O_sdram_cs_n(sdcs), .O_sdram_ras_n(sdras), .O_sdram_cas_n(sdcas),
               .O_sdram_wen_n(sdwe), .O_sdram_addr(sda), .O_sdram_ba(sdba), .O_sdram_dqm(sddqm), .IO_sdram_dq(sddq));
    sdram_model u_ram (.clk(sdclk), .cke(sdcke), .cs_n(sdcs), .ras_n(sdras), .cas_n(sdcas), .we_n(sdwe), .addr(sda), .ba(sdba),
                       .dqm(sddqm), .dq(sddq));
    wire de, hs, vs; wire [4:0] r5, b5; wire [5:0] g6; wire [7:0] pr, pg, pb; wire [10:0] oa;
    lcd_out u_lcd (.clk(pclk), .rst(rst_p), .line_tog_a(1'b0), .line_info_a(9'd0), .field_tog_a(1'b0), .locked_a(1'b1), .pal_a(PAL[0]),
                   .hmode(2'd0), .lb_addr(ra), .lb_data(rd), .osd_addr(oa), .osd_cell(12'd0),
                   .lcd_de(de), .lcd_hs(hs), .lcd_vs(vs), .lcd_r(r5), .lcd_g(g6), .lcd_b(b5), .px_r(pr), .px_g(pg), .px_b(pb),
                   .frame_tog(fb_frame), .fetch_tog(fb_fetch), .fetch_line(fb_line));
    // ---- capture: every active pixel, a marker per frame ----
    integer f, nfr = 0; reg vs_p = 1;
    always @(posedge pclk) if (!rst_p) begin
        vs_p <= vs;
        if (vs_p && !vs) begin nfr = nfr + 1; $fwrite(f, "F %0t\n", $time); if (nfr > __FRAMES__) begin
            $display("sdram_errors %0d", u_ram.errors); $fclose(f); $finish; end end
        if (de) $fwrite(f, "%04x\n", {pr[7:3], pg[7:2], pb[7:3]});
    end
    initial begin f = $fopen("out.txt", "w"); #1000 rst = 0; #3000 rst_p = 0; end
endmodule
'''


def main():
    pal = '--pal' in sys.argv
    frames = int(next((a.split('=')[1] for a in sys.argv if a.startswith('--frames=')), 9))
    nrow = 576 if pal else 480
    with tempfile.TemporaryDirectory() as t:
        t = Path(t)
        (t / 'tb.v').write_text(TB.replace('__PAL__', str(int(pal))).replace('__FRAMES__', str(frames)))
        srcs = [RTL / 'video/fbuf.v', RTL / 'io/sdram.v', RTL / 'video/lcd_out.v', HERE / 'sdram_model.v']
        inc = sum([['-I', str(d)] for d in (RTL, RTL / 'video', RTL / 'ui', RTL / 'rx')], [])
        subprocess.run(['iverilog', '-g2012', '-DTRI_HDMI', '-DTRI_HDMI90', '-DTRI_HMAPCALC', *inc, '-o', str(t / 'sim'),
                        str(t / 'tb.v'), *map(str, srcs)], check=True)
        r = subprocess.run(['vvp', '-n', str(t / 'sim')], cwd=t, capture_output=True, text=True, check=True)
        errs = int(r.stdout.split('sdram_errors')[1].split()[0])
        txt = (t / 'out.txt').read_text().split('F ')[1:]
    ok = errs == 0
    times, shown = [], []
    for k, blk in enumerate(txt):
        lines = blk.split('\n')
        times.append(int(lines[0].split()[0]))
        px = np.array([int(x, 16) for x in lines[1:] if x], np.int64)
        if len(px) != nrow * 720:
            continue                                     # the last, unfinished frame
        px = px.reshape(nrow, 720)
        if not px.any():
            shown.append(None); continue                 # before the first field
        fl, ln, xm = px >> 13, (px >> 4) & 511, px & 15
        rows = np.arange(nrow)[:, None]
        good = (fl == fl[0, 0]) & (ln == rows // 2) & (xm == np.arange(720)[None, :] % 16)
        if not good.all():
            bad = np.argwhere(~good)
            print(f'frame {k}: {len(bad)} wrong pixels, first at row/x {tuple(bad[0])}: field {fl[tuple(bad[0])]} '
                  f'line {ln[tuple(bad[0])]} x%16 {xm[tuple(bad[0])]}')
            ok = False
        shown.append(int(fl[0, 0]))
    fs = [s for s in shown if s is not None]
    steps = [(b - a) % 8 for a, b in zip(fs, fs[1:])]
    if any(s > 1 for s in steps):
        print('a field was skipped:', fs); ok = False
    rate = 1e12 / np.mean(np.diff(times)) if len(times) > 2 else 0
    print(('PAL' if pal else 'NTSC') + f': {len(fs)} frames checked, fields shown {fs}, {rate:.2f} Hz, SDRAM violations {errs}')
    print('PASS' if ok and fs else 'FAIL')
    sys.exit(0 if ok and fs else 1)


if __name__ == '__main__':
    main()
