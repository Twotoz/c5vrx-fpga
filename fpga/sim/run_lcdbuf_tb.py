"""Triversity: the buffered LCD (TRI_LCDBUF) from source to panel: rtl/video/fbuf.v
(SDRAM via rtl/io/sdram.v and sim/sdram_model.v) and rtl/video/lcd_out.v at
33.75 MHz, fed like vid_sync feeds the line buffer (40 MHz, NTSC 262 / 263 lines a
field, 240 shown, 800 pixels a line). Every source line carries {field, row} in
its pixels. The lock drops once and comes back.
Checked:
  - the panel: every line HHALF (1072) clocks, every frame 480 rows of 800 pixels,
    frame lengths within VFRAME +- 4: whatever the source does;
  - every frame (outside the lock loss): each LCD row shows the source row it
    belongs to, all rows from one field, never an older field than before;
  - settled (from the first frame 2 .. 5 ms behind the camera, after the start and
    again after the relock, which must come): every frame the next field, row 0
    2 .. 5 ms behind the camera. While acquiring, the frame lock may show each
    field one frame later (~19 ms) until the frame start has moved past it;
  - rows marked corrupt (line_skip, every 7th field) show the same row of one of
    the three fields before, the other rows the current field (temporal
    concealment, #12);
  - no SDRAM timing violation.
    python fpga/sim/run_lcdbuf_tb.py [--frames=N] [--pdelay=ns]
"""
import subprocess, sys, tempfile
from pathlib import Path
HERE = Path(__file__).resolve().parent
RTL = HERE.parent / 'rtl'
TB = r'''
`timescale 1ns/1ps
module tb;
    reg aclk = 0; always #12.5 aclk = ~aclk;            // 40 MHz IQ clock
    reg pclk = 0; always #14.815 pclk = ~pclk;          // 33.75 MHz LCD clock
    reg rst = 1, rst_p = 1, locked = 1;
    integer fs;
    localparam LT = 2542, SHOW0 = 18, NSHOW = 240;
    // ---- source: vid_sync's line-buffer interface, 800 pixels a line ----
    reg wr_en = 0; reg [10:0] wr_addr = 0; reg [15:0] wr_data = 0;
    reg line_tog = 0, field_tog = 0; reg [8:0] line_info = 0; reg line_skip = 0;
    integer hc = 0, ln = 0, fld = 0, flines, px, orow = 0, show = 0;
    always @(posedge aclk) begin
        wr_en <= 0;
        if (!rst) begin
            flines = fld[0] ? 263 : 262;
            if (hc == LT - 1) begin
                hc <= 0;
                line_info <= {show[0], orow[7:0]}; line_tog <= ~line_tog;
                // corrupt rows (vid_sync's line_skip): SKIP_R0 .. SKIP_R1 - 1 of every 7th field
                line_skip <= show && fld % 7 == 4 && orow >= __SKIP_R0__ && orow < __SKIP_R1__;
                if (show) begin
                    orow <= orow + 1;
                    $fwrite(fs, "W %0d %0d %0d\n", $time, fld, orow);        // row orow of field fld complete
                end
                if (ln == flines - 1) begin ln <= 0; fld <= fld + 1; field_tog <= ~field_tog; orow <= 0; show <= 0; end
                else begin ln <= ln + 1; show <= (ln + 1 >= SHOW0 && ln + 1 < SHOW0 + NSHOW); end
                px = 0;
            end else hc <= hc + 1;
            if (show && hc >= 300 && px < 800 && hc[0]) begin
                wr_en <= 1; wr_addr <= {orow[0], px[9:0]};
                wr_data <= {fld[7:0], orow[7:0]};
                px = px + 1;
            end
        end
    end
    // ---- DUT ----
    wire fb_frame, fb_fetch; wire [8:0] fb_line; wire [10:0] ra; wire [15:0] rd;
    wire signed [7:0] sh_h, sh_r; wire signed [5:0] sh_v;
    wire sdclk, sdcke, sdcs, sdras, sdcas, sdwe; wire [10:0] sda; wire [1:0] sdba; wire [3:0] sddqm; wire [31:0] sddq;
    fbuf #(.WPL(400), .RACE_N(24), .RACE_P(24), .SMOOTH(0)) u_fb (.clk(aclk), .rst(rst), .wr_en(wr_en), .wr_addr(wr_addr),
               .wr_data(wr_data), .line_tog(line_tog), .line_info(line_info), .line_skip(line_skip),
               .field_tog(field_tog), .pal(1'b0), .mode_p(2'd1), .sh_h(sh_h), .sh_r(sh_r), .sh_v(sh_v),
               .frame_tog_p(fb_frame), .fetch_tog_p(fb_fetch), .fetch_line_p(fb_line),
               .rclk(pclk), .raddr(ra), .rdata(rd),
               .O_sdram_clk(sdclk), .O_sdram_cke(sdcke), .O_sdram_cs_n(sdcs), .O_sdram_ras_n(sdras), .O_sdram_cas_n(sdcas),
               .O_sdram_wen_n(sdwe), .O_sdram_addr(sda), .O_sdram_ba(sdba), .O_sdram_dqm(sddqm), .IO_sdram_dq(sddq));
    sdram_model u_ram (.clk(sdclk), .cke(sdcke), .cs_n(sdcs), .ras_n(sdras), .cas_n(sdcas), .we_n(sdwe), .addr(sda), .ba(sdba),
                       .dqm(sddqm), .dq(sddq));
    wire de, hs, vs; wire [4:0] r5, b5; wire [5:0] g6; wire [7:0] pr, pg, pb; wire [10:0] oa;
    lcd_out u_lcd (.clk(pclk), .rst(rst_p), .line_tog_a(1'b0), .line_info_a(9'd0), .field_tog_a(field_tog), .locked_a(locked), .pal_a(1'b0),
                   .hmode(2'd0), .boot(1'b0), .lb_addr(ra), .lb_data(rd), .osd_addr(oa), .osd_cell(12'd0),
                   .lcd_de(de), .lcd_hs(hs), .lcd_vs(vs), .lcd_r(r5), .lcd_g(g6), .lcd_b(b5), .px_r(pr), .px_g(pg), .px_b(pb),
                   .hz90(2'd1), .sh_h(sh_h), .sh_r(sh_r), .sh_v(sh_v),
                   .frame_tog(fb_frame), .fetch_tog(fb_fetch), .fetch_line(fb_line));
    // ---- capture: HS periods, frames, and per row the code in the middle of the line ----
    integer cyc = 0, last_hs = 0, nfr = 0, row = 0, npx = 0, lines = 0;
    reg vs_p = 1, de_p = 0, hs_p = 1;
    reg [15:0] mid;
    always @(posedge pclk) if (!rst_p) begin
        cyc = cyc + 1;
        hs_p <= hs; vs_p <= vs; de_p <= de;
        if (hs_p && !hs) begin
            if (last_hs != 0) $fwrite(fs, "H %0d %0d %0d\n", cyc - last_hs, $time, u_lcd.lv);
            last_hs = cyc; lines = lines + 1;
        end
        if (vs_p && !vs) begin
            $fwrite(fs, "V %0d %0d %0d %0d\n", $time, row, lines, locked);
            nfr = nfr + 1; row = 0; lines = 0;
            if (nfr > __FRAMES__) begin $display("sdram_errors %0d", u_ram.errors); $fclose(fs); $finish; end
        end
        if (de) begin npx = npx + 1; if (npx == 400) mid = u_lcd.lb_data; end
        if (de_p && !de) begin
            $fwrite(fs, "R %0d %0d %0d %04x\n", $time, row, npx, mid);
            row = row + 1; npx = 0;
        end
    end
    initial begin
        fs = $fopen("out.txt", "w"); #1000 rst = 0; #__PDELAY__ rst_p = 0;
        #(__UNLOCK_AT__) locked = 0;
        #(30000000) locked = 1;
    end
endmodule
'''


SKIP = (100, 130)     # source rows skipped (line_skip) in every 7th field: an earlier field's rows stay


def main():
    frames = int(next((a.split('=')[1] for a in sys.argv if a.startswith('--frames=')), 44))
    pdelay = int(next((a.split('=')[1] for a in sys.argv if a.startswith('--pdelay=')), 2_300_000))   # panel starts near the lock
    with tempfile.TemporaryDirectory() as t:
        t = Path(t)
        tb = TB
        for k, v in dict(FRAMES=frames, PDELAY=pdelay, UNLOCK_AT=250_000_000, SKIP_R0=SKIP[0], SKIP_R1=SKIP[1]).items():
            tb = tb.replace(f'__{k}__', str(v))
        (t / 'tb.v').write_text(tb)
        srcs = [str(RTL / 'video' / 'fbuf.v'), str(RTL / 'video' / 'motion.v'), str(RTL / 'video' / 'lcd_out.v'),
                str(RTL / 'io' / 'sdram.v'), str(HERE / 'sdram_model.v')]
        inc = [f'-I{d}' for d in sorted({p.parent for p in RTL.rglob('*.v*')})]
        subprocess.run(['iverilog', '-g2012', '-DTRI_LCDBUF', '-DTRI_LIVEUI', *inc, '-s', 'tb', '-o', str(t / 'sim'),
                        str(t / 'tb.v'), *srcs], check=True)
        r = subprocess.run(['vvp', '-n', str(t / 'sim')], cwd=t, capture_output=True, text=True)
        print(r.stdout.strip()[-300:])
        lines = (t / 'out.txt').read_text().split('\n')
    ok = True
    def fail(m):
        nonlocal ok
        ok = False; print('FAIL', m)
    if 'sdram_errors 0' not in r.stdout: fail('SDRAM timing: ' + r.stdout[-200:])
    hs = [l.split() for l in lines if l.startswith('H ')][1:]     # the first: counted from hs_p's start value
    bad = [(int(h[1]), int(h[2]) / 1e6, int(h[3])) for h in hs if int(h[1]) != 1072]
    if bad: fail(f'{len(bad)} LCD lines other than 1072 clocks (clocks, ms, lv): {bad[:6]}')
    # writes: time of row orow of field f complete
    wr = {}
    for l in lines:
        if l.startswith('W '):
            _, tm, f, o = l.split(); wr[(int(f), int(o))] = int(tm)
    # frames: rows between V markers
    frames, cur = [], []
    for l in lines:
        if l.startswith('R '):
            _, tm, row, npx, code = l.split()
            cur.append((int(tm), int(row), int(npx), int(code, 16) if 'x' not in code.lower() else -1))
        elif l.startswith('V '):
            _, tm, nrow, nlines, lk = l.split()
            frames.append((int(tm), cur, int(nlines), int(lk))); cur = []
    frames = frames[1:]                     # the first is partial
    unlock_t, relock_t = 250_000_000 + 1000 + pdelay, 280_000_000 + 1000 + pdelay
    # settled: from the first frame whose row 0 is 2 .. 5 ms behind the camera, after
    # the start and again after the relock; from then on every frame shows the next
    # field 2 .. 5 ms late. Before that (acquiring) the panel may show a field late
    # (one frame more), but every frame still shows one whole field, never an older one.
    last_field, shown, delays, settled, settle_t, concealed = None, 0, [], False, [], 0
    for k, (tm, rows, nlines, lk) in enumerate(frames):
        if len(rows) != 480 or any(r[2] != 800 for r in rows):
            fail(f'frame {k}: {len(rows)} rows, pixels {sorted({r[2] for r in rows})[:4]}')
        if not 521 <= nlines <= 529: fail(f'frame {k}: {nlines} lines')
        t0 = rows[0][0] if rows else tm
        if unlock_t - 20_000_000 < t0 < relock_t + 20_000_000:
            settled = False; last_field = None; continue          # around the lock loss: snow / the held field
        if t0 < 40_000_000: continue                               # SDRAM start, first fields
        want = [r[1] // 2 for r in rows]
        got = [r[3] & 255 if r[3] >= 0 else -1 for r in rows]
        conc = [SKIP[0] <= w < SKIP[1] for w in want]
        flds = {r[3] >> 8 for r, c in zip(rows, conc) if r[3] >= 0 and not c}
        if len(flds) != 1: fail(f'frame {k}: rows from fields {sorted(flds)}'); continue
        f0 = next(iter(flds))
        if f0 % 7 == 4:
            # concealed rows: the same row from one of the 3 fields before (the slot's older field)
            old = {(f0 - (r[3] >> 8)) % 256 for r, c in zip(rows, conc) if c}
            if not old <= {1, 2, 3}: fail(f'frame {k}: concealed rows {sorted(old)} fields old, want 1 .. 3')
            concealed += 1
        elif any(c and (r[3] >> 8) != f0 for r, c in zip(rows, conc)):
            fail(f'frame {k}: rows {SKIP} not from field {f0} although it was not skipped')
        if got != want:
            i = next(j for j in range(len(got)) if got[j] != want[j])
            fail(f'frame {k}: row {i} shows source row {got[i]}, wants {want[i]}'); continue
        f = flds.pop()
        w = wr.get((f, 0))
        d = (rows[0][0] - w) / 1e6 if w is not None else None
        if '--log' in sys.argv: print(f'frame {k} t0 {t0/1e6:.2f} ms field {f} delay {d}')
        if last_field is not None and (f - last_field) % 256 not in ((1,) if settled else (0, 1, 2)):
            fail(f'frame {k}: field {f} after {last_field}')
        last_field = f
        if not settled and d is not None and 2.0 <= d <= 5.0:
            settled = True; settle_t.append(t0)
        if settled:
            shown += 1
            if d is not None: delays.append(d)
    if shown < 10: fail(f'only {shown} settled frames checked')
    if concealed < 2: fail(f'only {concealed} frames with concealed rows checked')
    print(f'{concealed} frames with rows {SKIP[0]} .. {SKIP[1] - 1} concealed from an earlier field')
    if not any(t > relock_t for t in settle_t): fail('not settled again after the relock')
    print('settled at', [f'{t / 1e6:.1f} ms' for t in settle_t], '(lock lost', unlock_t / 1e6, 'back', relock_t / 1e6, 'ms)')
    if delays:
        print(f'row 0 camera-to-panel delay: {min(delays):.2f} .. {max(delays):.2f} ms over {len(delays)} frames')
        if not all(2.0 <= d <= 5.0 for d in delays): fail('delay outside 2 .. 5 ms')
    print('PASS' if ok else 'FAIL', f'({len(frames)} frames, {shown} checked)')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
