"""Triversity: the 90 Hz HDMI output (TRI_HDMI90) from source to pixels:
rtl/video/fbuf.v (field buffer, SDRAM via rtl/io/sdram.v and sim/sdram_model.v,
motion.v) and rtl/video/lcd_out.v at 48.6 MHz, fed like vid_sync feeds the
line buffer (40 MHz, NTSC 262.5 / PAL 312.5 lines a field, 240 / 288 shown,
720 pixels a line).

Source pixels: green a texture that moves (--motion: VX pixels right and VY
lines down a field), red and blue a 10-bit code of {field, line, column}.
Checked:
  - every checked frame pixel for pixel: one field (no tear), each source line
    where it belongs (twice), shifted by the frame's own shifts (Smooth), black
    outside; the fields in order, none skipped; no SDRAM timing violation;
  - the output frame rate; with --mode=1/2 the lock to the fields (cadence) and
    the age of the shown fields; with --motion and --mode=2 the motion estimate
    and how evenly the picture moves from frame to frame (judder).

    python fpga/sim/run_hdmi90_tb.py [--pal] [--mode=0|1|2] [--motion] [--frames=N]
"""
import subprocess, sys, tempfile
from pathlib import Path
import numpy as np

HERE = Path(__file__).resolve().parent
RTL = HERE.parent / 'rtl'
VX, VY = 4, 1                       # --motion: pixels right, source lines down, a field

TB = r'''
`timescale 1ns/1ps
module tb;
    reg aclk = 0; always #12.5 aclk = ~aclk;            // 40 MHz IQ clock
    reg pclk = 0; always #10.288 pclk = ~pclk;          // 48.6 MHz pixel clock
    reg rst = 1, rst_p = 1;
    localparam PAL = __PAL__, MODE = __MODE__, VX = __VX__, VY = __VY__, EVERY = __EVERY__;
    localparam LT = PAL ? 2560 : 2542;                  // source line, clocks
    localparam SHOW0 = PAL ? 20 : 18, NSHOW = PAL ? 288 : 240;
    reg [5:0] tex [0:262143];
    // ---- source: vid_sync's line-buffer interface ----
    reg wr_en = 0; reg [10:0] wr_addr = 0; reg [15:0] wr_data = 0;
    reg line_tog = 0, field_tog = 0; reg [8:0] line_info = 0;
    integer hc = 0, ln = 0, fld = 0, flines, px, dda, orow = 0, show = 0, sx, sy, code;
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
                    sx = px - VX * fld; sy = orow - VY * fld;
                    code = (fld * 67 + orow * 13 + px) % 1024;
                    wr_en <= 1; wr_addr <= {orow[0], px[9:0]};
                    wr_data <= {code[9:5], tex[{sy[8:0], sx[8:0]}], code[4:0]};
                    px = px + 1;
                end
            end
        end
    end
    // ---- DUT ----
    wire fb_frame, fb_fetch; wire [8:0] fb_line; wire [10:0] ra; wire [15:0] rd;
    wire signed [7:0] sh_h, sh_r; wire signed [5:0] sh_v;
    wire sdclk, sdcke, sdcs, sdras, sdcas, sdwe; wire [10:0] sda; wire [1:0] sdba; wire [3:0] sddqm; wire [31:0] sddq;
    fbuf u_fb (.clk(aclk), .rst(rst), .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data), .line_tog(line_tog), .line_info(line_info),
               .field_tog(field_tog), .pal(PAL[0]), .mode_p(MODE[1:0]), .sh_h(sh_h), .sh_r(sh_r), .sh_v(sh_v),
               .frame_tog_p(fb_frame), .fetch_tog_p(fb_fetch), .fetch_line_p(fb_line),
               .rclk(pclk), .raddr(ra), .rdata(rd),
               .O_sdram_clk(sdclk), .O_sdram_cke(sdcke), .O_sdram_cs_n(sdcs), .O_sdram_ras_n(sdras), .O_sdram_cas_n(sdcas),
               .O_sdram_wen_n(sdwe), .O_sdram_addr(sda), .O_sdram_ba(sdba), .O_sdram_dqm(sddqm), .IO_sdram_dq(sddq));
    sdram_model u_ram (.clk(sdclk), .cke(sdcke), .cs_n(sdcs), .ras_n(sdras), .cas_n(sdcas), .we_n(sdwe), .addr(sda), .ba(sdba),
                       .dqm(sddqm), .dq(sddq));
    wire de, hs, vs; wire [4:0] r5, b5; wire [5:0] g6; wire [7:0] pr, pg, pb; wire [10:0] oa;
    lcd_out u_lcd (.clk(pclk), .rst(rst_p), .line_tog_a(1'b0), .line_info_a(9'd0), .field_tog_a(field_tog), .locked_a(1'b1), .pal_a(PAL[0]),
                   .hmode(2'd0), .boot(1'b0), .lb_addr(ra), .lb_data(rd), .osd_addr(oa), .osd_cell(12'd0),
                   .lcd_de(de), .lcd_hs(hs), .lcd_vs(vs), .lcd_r(r5), .lcd_g(g6), .lcd_b(b5), .px_r(pr), .px_g(pg), .px_b(pb),
                   .hz90(MODE[1:0]), .sh_h(sh_h), .sh_r(sh_r), .sh_v(sh_v),
                   .frame_tog(fb_frame), .fetch_tog(fb_fetch), .fetch_line(fb_line));
    // which source field each slot holds
    integer slotf [0:2];
    always @(posedge aclk) if (wr_en) slotf[u_fb.wslot] <= fld;
    // ---- capture: per frame its field, age, shifts and the motion estimate; the pixels of every EVERY-th ----
    integer f, nfr = 0, row = 0; reg vs_p = 1, de_p = 0, dump = 0;
    always @(posedge pclk) if (!rst_p) begin
        vs_p <= vs; de_p <= de;
        if (vs_p && !vs) begin
            nfr = nfr + 1; row = 0;
            if (nfr > __FRAMES__) begin $display("sdram_errors %0d", u_ram.errors); $fclose(f); $finish; end
        end
        if (de && !de_p) begin
            if (row == 0) begin
                dump = (nfr % EVERY) == 0;
                $fwrite(f, "F %0t %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d\n", $time, slotf[u_fb.rslot], u_fb.age,
                        u_lcd.hh, u_lcd.hr, u_lcd.hv, u_lcd.VT, u_fb.u_mo.vh0, u_fb.u_mo.vh1, u_fb.u_mo.vh2, u_fb.u_mo.vh3,
                        u_fb.u_mo.vv, u_fb.u_mo.valid, dump);
            end
            row = row + 1;
        end
        if (de && dump) $fwrite(f, "%04x\n", {pr[7:3], pg[7:2], pb[7:3]});
    end
    initial begin
        $readmemh("tex.hex", tex);
        f = $fopen("out.txt", "w"); #1000 rst = 0; #__PDELAY__ rst_p = 0;
    end
endmodule
'''


def texture():
    rng = np.random.default_rng(5)
    t = rng.normal(size=(512, 512))
    k = np.exp(-0.5 * (np.arange(-12, 13) / 4.0) ** 2); k /= k.sum()
    for ax in (0, 1):
        t = np.apply_along_axis(lambda v: np.convolve(np.concatenate([v[-12:], v, v[:12]]), k, 'valid'), ax, t)
    t = (t - t.min()) / (t.max() - t.min())
    return np.clip(np.round(t * 63), 0, 63).astype(int)


def main():
    pal = '--pal' in sys.argv
    motion = '--motion' in sys.argv
    mode = int(next((a.split('=')[1] for a in sys.argv if a.startswith('--mode=')), 0))
    frames = int(next((a.split('=')[1] for a in sys.argv if a.startswith('--frames=')), 14))
    every = int(next((a.split('=')[1] for a in sys.argv if a.startswith('--every=')), 1 if frames <= 20 else 5))
    pdelay = int(next((a.split('=')[1] for a in sys.argv if a.startswith('--pdelay=')), 3000))
    nrow, nsrc = (576, 288) if pal else (480, 240)
    vx, vy = (VX, VY) if motion else (0, 0)
    tex = texture()
    with tempfile.TemporaryDirectory() as t:
        t = Path(t)
        (t / 'tex.hex').write_text('\n'.join(f'{v:02x}' for v in tex.ravel()) + '\n')
        tb = TB
        for k, v in dict(PAL=int(pal), MODE=mode, VX=vx, VY=vy, EVERY=every, FRAMES=frames, PDELAY=pdelay).items():
            tb = tb.replace(f'__{k}__', str(v))
        (t / 'tb.v').write_text(tb)
        srcs = [RTL / 'video/fbuf.v', RTL / 'video/motion.v', RTL / 'io/sdram.v', RTL / 'video/lcd_out.v', HERE / 'sdram_model.v']
        inc = sum([['-I', str(d)] for d in (RTL, RTL / 'video', RTL / 'ui', RTL / 'rx')], [])
        subprocess.run(['iverilog', '-g2012', '-DTRI_HDMI', '-DTRI_HDMI90', '-DTRI_HMAPCALC', *inc, '-o', str(t / 'sim'),
                        str(t / 'tb.v'), *map(str, srcs)], check=True)
        r = subprocess.run(['vvp', '-n', str(t / 'sim')], cwd=t, capture_output=True, text=True, check=True)
        errs = int(r.stdout.split('sdram_errors')[1].split()[0])
        blocks = (t / 'out.txt').read_text().split('F ')[1:]
    ok = errs == 0
    info, checked = [], 0
    for blk in blocks:
        lines = blk.split('\n')
        h = [int(x) if x.lstrip('-').isdigit() else None for x in lines[0].split()]   # x: not set yet
        tm, fld, age, hh, hr, hv, vt, *vh, vv, mv, dump = h
        if None in (fld, age, hh, hr, hv):
            fld = None
        info.append(dict(t=tm, fld=fld, age=age, hh=hh, hr=hr, hv=hv, vt=vt, vh=vh, vv=vv, mv=mv))
        if not dump or fld is None:
            continue
        px = np.array([int(x, 16) for x in lines[1:] if x], np.int64)
        if len(px) != nrow * 720:
            continue                                     # the last, unfinished frame
        px = px.reshape(nrow, 720)
        if not px.any():
            info[-1]['fld'] = None; continue             # before the first field
        # expected: per row the RTL's shift, source line and column
        hacc = hh * 256 - hr * (nrow // 2)
        want = np.zeros((nrow, 720), np.int64)
        xs0 = np.arange(720)
        for row in range(nrow):
            hrow = (hacc + 128) >> 8
            hacc += hr
            ln = row // 2 - hv
            xs = xs0 - hrow
            okc = (xs >= 0) & (xs < 720) & (0 <= ln < nsrc)
            code = (fld * 67 + ln * 13 + xs) % 1024
            sxx, syy = (xs - vx * fld) & 511, (ln - vy * fld) & 511
            g = tex[syy, sxx]
            want[row] = np.where(okc, (code >> 5) << 11 | g << 5 | (code & 31), 0)
        bad = np.argwhere(px != want)
        checked += 1
        if len(bad):
            r0, c0 = bad[0]
            print(f'frame at {tm} (field {fld}): {len(bad)} pixels differ, first row {r0} x {c0}: {px[r0, c0]:04x} want {want[r0, c0]:04x}')
            ok = False
    fs = [i['fld'] for i in info if i['fld'] is not None and i['age'] is not None]
    fs = fs[2:]                                          # the start
    steps = [b - a for a, b in zip(fs, fs[1:])]
    if any(s < 0 or s > 1 for s in steps):
        print('fields out of order or skipped:', fs); ok = False
    tms = [i['t'] for i in info]
    rate = 1e12 / np.mean(np.diff(tms[-20:])) if len(tms) > 3 else 0
    late = info[len(info) // 2:]                          # after the lock
    lpf = (312.5 if pal else 262.5)
    lms = 64e-3 if pal else 63.556e-3
    ages = [i['age'] * lms for i in late if i['fld'] is not None]
    print(('PAL' if pal else 'NTSC') + f' mode {mode}{" motion" if motion else ""}: {len(info)} frames, {checked} checked pixel for pixel, '
          f'{rate:.2f} Hz, SDRAM violations {errs}')
    print('  fields shown (last 18):', [i['fld'] for i in info[-18:]])
    if '--diag' in sys.argv:
        for i in info[-12:]:
            print(f"    t {i['t']/1e9:9.3f} ms  field {i['fld']}  age {i['age']}  hh {i['hh']}  hr {i['hr']}  hv {i['hv']}  vt {i['vt']}")
    print('  frame lengths (last 18):', [i['vt'] for i in info[-18:]])
    if ages:
        print(f'  age of the shown field at the frame start: mean {np.mean(ages):.1f} ms, min {min(ages):.1f}, max {max(ages):.1f}')
    if motion:
        e = late[-1]
        print(f'  motion estimate: bands {e["vh"]} bins (want {vx // 2}), vertical {e["vv"]} half lines (want {2 * vy}), valid {e["mv"]}')
        if mode == 2 and not (all(v == vx // 2 for v in e['vh']) and e['vv'] == 2 * vy and e['mv'] == 1):
            print('  motion estimate wrong'); ok = False
        # where the picture stands per frame (scene position at the middle row), against a straight line
        pos = np.array([vx * i['fld'] + i['hh'] for i in late if i['fld'] is not None], float)
        tt = np.array([i['t'] for i in late if i['fld'] is not None], float)
        if len(pos) > 4:
            fit = np.polyval(np.polyfit(tt, pos, 1), tt)
            dev = pos - fit
            print(f'  horizontal judder: steps {np.diff(pos).astype(int).tolist()[-12:]} px, deviation from even motion rms {np.sqrt(np.mean(dev ** 2)):.2f} px, max {np.abs(dev).max():.2f} px')
    print('PASS' if ok and fs else 'FAIL')
    sys.exit(0 if ok and fs else 1)


if __name__ == '__main__':
    main()
