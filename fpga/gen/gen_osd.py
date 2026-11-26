"""Triversity: the OSD's look, generated for the FPGA (rtl/ui/osd_font.vh,
rtl/ui/osd_pages.vh), and the reference renderer the RTL is checked against.

Grid: 66 x 20 cells of 12 x 24 pixels on the 800 x 480 LCD (4 px margin left
and right). Every cell is a glyph with 2-bit coverage (anti-aliased), a
foreground colour and a background:

  background  0 video, 1 panel (dimmed video), 2 bar (panel; the accent bar
              when its row is selected, dark while it is being edited),
              3 dark
  foreground  0 white, 1 grey, 2 accent, 3 red, 4 green, 5 amber, 6 dark,
              7 panel (rounded panel corners and pill caps over video)

Glyphs: ASCII from JetBrains Mono SemiBold (SIL OFL 1.1, JetBrains) at 20 px,
and drawn symbols in codes 1..31 (pill caps, panel corners, divider, dot,
chevrons, arrows, signal bars, level segments, check).

Aspect: hmaps() writes rtl/video/hmap.vh, the LCD column mapping per mode.

Pages (template words, 18 bits: bg[17:16] fg[15:13] field[12:7] char[6:0]):
0 live view, 1 menu, 2 receivers, 3 settings. Field cells are filled in live
by rtl/ui/menu.v; fill() below is the reference for that logic.

    python fpga/gen/gen_osd.py      writes rtl/ui/osd_font.vh and osd_pages.vh
"""
import os
import re
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

HERE = Path(__file__).resolve().parent
RTL = HERE.parent / 'rtl' / 'ui'
COLS, ROWS, CW, CH, X0 = 66, 20, 12, 24, 4
FONT = os.environ.get('TRI_OSD_FONT', '/usr/share/fonts/truetype/jetbrains-mono/JetBrainsMono-SemiBold.ttf')   # fonts-jetbrains-mono 2.304

# colours (8-bit RGB); 7 is the panel, computed from the video
PAL = [(240, 242, 245), (142, 149, 160), (0, 88, 242), (255, 69, 58), (48, 209, 88), (255, 176, 32), (16, 18, 22)]
DARK = PAL[6]
WHITE, GREY, ACCENT, RED, GREEN, AMBER, DARKFG, PANEL = range(8)
BG_VIDEO, BG_PANEL, BG_BAR, BG_DARK = range(4)

# symbol codes
CAP_L, CAP_R, C_TL, C_TR, C_BL, C_BR, DIV, DOT, CHEV_L, CHEV_R, ARR_U, ARR_D = range(1, 13)
BARS0 = 13                                   # 13..17: signal 0..4 bars
SEG_ON, SEG_OFF, MIDDOT, CHECK = range(18, 22)
LOGO0, LOGO_N, LOGO_BLUE = 22, 10, 4   # 22..31: the C5VRX logo, 10 cells (C5 in 0..3)
LOGO = HERE.parent.parent / 'docs' / 'c5vrx_logo.png'

FREQS = [5658, 5695, 5732, 5769, 5806, 5843, 5880, 5917, 5865, 5845, 5825, 5805, 5785, 5765, 5745, 5725,
         5733, 5752, 5771, 5790, 5809, 5828, 5847, 5866, 5705, 5685, 5665, 5645, 5885, 5905, 5925, 5945,
         5740, 5760, 5780, 5800, 5820, 5840, 5860, 5880, 5362, 5399, 5436, 5473, 5510, 5547, 5584, 5621]
BANDS = 'RABEFL'

FIELDS = ['', 'CAPL', 'CAPR', 'LIVECH', 'REC', 'NOSIG', 'RXBAR', 'VSTD', 'CHVAL', 'SCANV', 'RECV', 'RXCNT',
          'RXROW', 'GAINV', 'AFCV', 'BRIGHTV', 'CALV', 'EDL', 'EDR', 'MODEV', 'ASPV', 'LOGOV', 'LOGO',
          'KLOCKV', 'ASYNCV', 'NFILTV', 'HZ90V',
          'BOOTBLD', 'BOOTVER', 'BOOTRX', 'BOOTSD', 'NATIVEV']
FID = {n: i for i, n in enumerate(FIELDS)}

# menu geometry
P0, P1 = 16, 49            # panel columns (inclusive)
TOP, BOT = 3, 16           # panel rows (inclusive)
ITEM0 = 7                  # first item row
MAIN_ITEMS = [('Channel', 'CHVAL'), ('Mode', 'MODEV'), ('Scan', 'SCANV'), ('Record', 'RECV'), ('Receivers', 'RXCNT'),
              ('Signal', None), ('Settings', None), ('Exit', None)]
SIG_ITEMS = [('Keep lock', 'KLOCKV'), ('Adaptive sync', 'ASYNCV'), ('Noise filter', 'NFILTV'),
             ('Native AGC (EXP)', 'NATIVEV'), ('Back', None)]
SET_ITEMS = [('Direct Gain', 'GAINV'), ('AFC', 'AFCV'), ('Aspect', 'ASPV'), ('Logo', 'LOGOV'), ('Brightness', 'BRIGHTV'),
             ('Calibrate', 'CALV'), ('Back', None)]
# the 90 Hz HDMI build (rtl/ui/osd_pages_h90.vh): the output mode instead of the LCD's brightness
SET_ITEMS_H90 = [(('90 Hz', 'HZ90V') if v == 'BRIGHTV' else (l, v)) for l, v in SET_ITEMS]
W_VAL = dict(NFILTV=3, KLOCKV=3, ASYNCV=3, NATIVEV=5, ASPV=9, LOGOV=3, MODEV=10, CHVAL=9, SCANV=11, RECV=9, RXCNT=3, GAINV=5, AFCV=3, BRIGHTV=8, CALV=6, HZ90V=8)
N_ITEMS = [0, 8, 1, 7, 6]  # selectable rows per page (receivers: Back only, row ITEM0 + 4); 4 = Signal


def glyphs_vh():
    """The glyphs as committed in rtl/ui/osd_font.vh (what the RTL draws): the
    testbench uses these, so another version of the font cannot differ."""
    g = [[[0] * CW for _ in range(CH)] for _ in range(128)]
    for m in re.finditer(r"font\[(\d+)\] = 24'h([0-9a-f]+);", (RTL / 'osd_font.vh').read_text()):
        a, v = int(m.group(1)), int(m.group(2), 16)
        code, y = a // 32, a % 32
        if y < CH:
            g[code][y] = [(v >> (2 * x)) & 3 for x in range(CW)]
    return g


# 7-segment glyphs (the TRI_TRIDVR build: no font ROM; rtl/video/lcd_out.v seg_row
# draws them with logic). Segments gfedcba, rectangles x0, x1, y0, y1 inclusive.
SEG_RECT = [(3, 8, 3, 4), (8, 9, 3, 12), (8, 9, 11, 20), (3, 8, 19, 20), (2, 3, 11, 20), (2, 3, 3, 12), (3, 8, 11, 12)]
SEG_MASK = {**{ord(str(d)): m for d, m in enumerate([0x3F, 0x06, 0x5B, 0x4F, 0x66, 0x6D, 0x7D, 0x07, 0x7F, 0x6F])},
            ord('A'): 0x77, ord('a'): 0x77, ord('B'): 0x7C, ord('b'): 0x7C, ord('C'): 0x39, ord('c'): 0x58,
            ord('D'): 0x5E, ord('d'): 0x5E, ord('E'): 0x79, ord('e'): 0x79, ord('F'): 0x71, ord('f'): 0x71,
            ord('G'): 0x3D, ord('g'): 0x3D, ord('I'): 0x30, ord('i'): 0x30, ord('L'): 0x38, ord('l'): 0x38,
            ord('N'): 0x37, ord('n'): 0x54, ord('O'): 0x3F, ord('o'): 0x5C, ord('R'): 0x50, ord('r'): 0x50,
            ord('S'): 0x6D, ord('s'): 0x6D, ord('-'): 0x40}


def seg_glyphs():
    """The TRI_TRIDVR build's glyphs (coverage 0 / 1 / 3), as lcd_out.v seg_row."""
    g = [[[0] * CW for _ in range(CH)] for _ in range(128)]
    for code in range(128):
        for y in range(CH):
            for x in range(CW):
                c = 0
                m = SEG_MASK.get(code, 0)
                if any(m >> k & 1 and x0 <= x <= x1 and y0 <= y <= y1 for k, (x0, x1, y0, y1) in enumerate(SEG_RECT)):
                    c = 3
                elif code == DOT:
                    c = 3 if (2 * x - 11) ** 2 + (2 * y - 23) ** 2 <= 80 else 0
                elif code == MIDDOT:
                    c = 3 if 5 <= x <= 6 and 11 <= y <= 12 else 0
                elif code == ord(':'):
                    c = 3 if 5 <= x <= 6 and (7 <= y <= 8 or 15 <= y <= 16) else 0
                elif BARS0 <= code <= BARS0 + 4:
                    k = (x - 1) // 3
                    if x >= 1 and (x - 1) % 3 < 2 and k < 4 and y <= 20 and y >= 21 - 4 * (k + 1):
                        c = 3 if k < code - BARS0 else 1
                elif code in (CAP_L, CAP_R):
                    cx = 24 if code == CAP_L else 0
                    c = 3 if (2 * x + 1 - cx) ** 2 + (2 * y + 1 - 24) ** 2 <= 529 else 0
                g[code][y][x] = c
    return g


def emit_seg():
    """rtl/video/osd_seg.vh: seg_row() for lcd_out.v (TRI_TRIDVR) as tables:
    segments by row range, the round glyphs by row."""
    g = seg_glyphs()
    L = ['// Generated by fpga/gen/gen_osd.py (seg_glyphs); do not edit.',
         'function [6:0] segm; input [6:0] c;', '    case (c)']
    for code, m in sorted(SEG_MASK.items()):
        L.append(f"        7'd{code}: segm = 7'h{m:02x};")
    L += ["        default: segm = 7'h00;", '    endcase', 'endfunction',
          'function [23:0] seg_row; input [6:0] c; input [4:0] y;', '    reg [6:0] m; reg [11:0] on;', '    begin',
          '        m = segm(c); on = 12\'d0;']
    for k, (x0, x1, y0, y1) in enumerate(SEG_RECT):
        xm = sum(1 << x for x in range(x0, x1 + 1))
        L.append(f"        if (m[{k}] && y >= 5'd{y0} && y <= 5'd{y1}) on = on | 12'h{xm:03x};")
    L.append('        seg_row = {on[11], on[11], on[10], on[10], on[9], on[9], on[8], on[8], on[7], on[7], on[6], on[6],')
    L.append('                   on[5], on[5], on[4], on[4], on[3], on[3], on[2], on[2], on[1], on[1], on[0], on[0]};')
    L.append('        case (c)')
    for code in [DOT, MIDDOT, ord(':'), CAP_L, CAP_R] + list(range(BARS0, BARS0 + 5)):
        L.append(f"            7'd{code}: case (y)")
        for y in range(CH):
            v = sum(g[code][y][x] << (2 * x) for x in range(CW))
            if v:
                L.append(f"                5'd{y}: seg_row = 24'h{v:06x};")
        L.append("                default: seg_row = 24'h000000;")
        L.append('            endcase')
    L += ['            default: ;', '        endcase', '    end', 'endfunction']
    (RTL.parent / 'video' / 'osd_seg.vh').write_text('\n'.join(L) + '\n')


def logo_tiles():
    """The C5VRX logo (docs/c5vrx_logo.png, alpha) 116 px wide in 10 cells."""
    im = Image.open(LOGO).convert('RGBA')
    im = im.crop(im.getchannel('A').point(lambda a: 255 if a > 128 else 0).getbbox())
    h = round(im.height * 116 / im.width)
    a = im.getchannel('A').resize((116, h), Image.LANCZOS)
    canvas = Image.new('L', (CW * LOGO_N, CH), 0)
    canvas.paste(a, (0, (CH - h) // 2))
    return [canvas.crop((k * CW, 0, (k + 1) * CW, CH)) for k in range(LOGO_N)]


def glyphs():
    """128 glyphs, 24 rows x 12 columns of 2-bit coverage."""
    f = ImageFont.truetype(FONT, 20)
    S = 4
    out = []
    tiles = logo_tiles()
    for code in range(128):
        if LOGO0 <= code < LOGO0 + LOGO_N:
            img = tiles[code - LOGO0]
        elif 32 <= code < 127:
            img = Image.new('L', (CW, CH), 0)
            ImageDraw.Draw(img).text((0, -2), chr(code), font=f, fill=255)
        else:
            W, H = CW * S, CH * S
            big = Image.new('L', (W, H), 0)
            d = ImageDraw.Draw(big)
            r = 10 * S
            if code == CAP_L:
                d.ellipse((0, 0, 2 * W, H - 1), fill=255)
            elif code == CAP_R:
                d.ellipse((-W, 0, W - 1, H - 1), fill=255)
            elif code in (C_TL, C_TR, C_BL, C_BR):
                d.rectangle((0, 0, W, H), fill=255)
                cx = 0 if code in (C_TL, C_BL) else W - 2 * r
                cy = 0 if code in (C_TL, C_TR) else H - 2 * r
                corner = Image.new('L', (W, H), 0)
                cd = ImageDraw.Draw(corner)
                qx = 0 if code in (C_TL, C_BL) else W - r
                qy = 0 if code in (C_TL, C_TR) else H - r
                cd.rectangle((qx, qy, qx + r - 1, qy + r - 1), fill=255)
                cd.ellipse((cx, cy, cx + 2 * r - 1, cy + 2 * r - 1), fill=0)
                big = Image.composite(Image.new('L', (W, H), 0), big, corner)
            elif code == DIV:
                d.rectangle((0, H // 2 - S // 2, W, H // 2 + S // 2 - 1), fill=255)
            elif code == DOT:
                d.ellipse((W / 2 - 4.5 * S, H / 2 - 4.5 * S, W / 2 + 4.5 * S, H / 2 + 4.5 * S), fill=255)
            elif code in (CHEV_L, CHEV_R):
                a, b = (7.5 * S, 3.5 * S) if code == CHEV_L else (4.5 * S, 8.5 * S)
                d.line([(a, H / 2 - 5 * S), (b, H / 2), (a, H / 2 + 5 * S)], fill=255, width=int(2.2 * S), joint='curve')
            elif code in (ARR_U, ARR_D):
                y0, y1 = (H / 2 + 3.5 * S, H / 2 - 3.5 * S) if code == ARR_U else (H / 2 - 3.5 * S, H / 2 + 3.5 * S)
                d.polygon([(2 * S, y0), (10 * S, y0), (6 * S, y1)], fill=255)
            elif BARS0 <= code <= BARS0 + 4:
                n = code - BARS0
                for k in range(4):
                    x, h = (1 + 3 * k) * S, (4 + 3 * k) * S
                    d.rectangle((x, H / 2 + 7 * S - h, x + 2 * S - 1, H / 2 + 7 * S - 1), fill=255 if k < n else 80)
            elif code in (SEG_ON, SEG_OFF):
                d.rounded_rectangle((1 * S, H / 2 - 5 * S, 10 * S, H / 2 + 5 * S), radius=2 * S, fill=255 if code == SEG_ON else 80)
            elif code == MIDDOT:
                d.ellipse((W / 2 - 1.6 * S, H / 2 - 1.6 * S, W / 2 + 1.6 * S, H / 2 + 1.6 * S), fill=255)
            elif code == CHECK:
                d.line([(2 * S, H / 2), (5 * S, H / 2 + 3.5 * S), (10.5 * S, H / 2 - 4.5 * S)], fill=255, width=int(2.2 * S), joint='curve')
            img = big.resize((CW, CH), Image.LANCZOS)
        px = img.load()
        out.append([[min(3, (px[x, y] + 42) // 85) for x in range(CW)] for y in range(CH)])
    return out


class Page:
    def __init__(self):
        self.t = [[0] * COLS for _ in range(ROWS)]

    @staticmethod
    def word(bg, fg, field, ch):
        return bg << 16 | fg << 13 | field << 7 | ch

    def put(self, r, c, s, fg=WHITE, bg=BG_PANEL):
        for k, ch in enumerate(s):
            self.t[r][c + k] = self.word(bg, fg, 0, ch if isinstance(ch, int) else ord(ch))

    def field(self, r, c, name, w, fg=WHITE, bg=BG_PANEL):
        for k in range(w):
            self.t[r][c + k] = self.word(bg, fg, FID[name], k)

    def panel(self, r0, r1, c0, c1):
        for r in range(r0, r1 + 1):
            for c in range(c0, c1 + 1):
                self.t[r][c] = self.word(BG_PANEL, WHITE, 0, 32)
        for r, c, g in ((r0, c0, C_TL), (r0, c1, C_TR), (r1, c0, C_BL), (r1, c1, C_BR)):
            self.t[r][c] = self.word(BG_VIDEO, PANEL, 0, g)

    def bar(self, r, c0, c1, bg_caps):
        self.field(r, c0, 'CAPL', 1, bg=bg_caps)
        self.field(r, c1, 'CAPR', 1, bg=bg_caps)
        for c in range(c0 + 1, c1):
            self.t[r][c] = self.word(BG_BAR, WHITE, 0, 32)

    def item(self, r, label, value, chevron):
        c0, c1 = P0 + 1, P1 - 1
        self.bar(r, c0, c1, BG_PANEL)
        self.put(r, c0 + 1, label, fg=WHITE, bg=BG_BAR)
        if chevron:
            self.put(r, c1 - 1, [CHEV_R], fg=GREY, bg=BG_BAR)
        if value:
            w = W_VAL[value]
            vc = c1 - 2 - w
            self.field(r, vc - 2, 'EDL', 1, fg=ACCENT, bg=BG_BAR)
            self.field(r, vc, value, w, fg=GREY, bg=BG_BAR)
            self.field(r, vc + w + 1, 'EDR', 1, fg=ACCENT, bg=BG_BAR)


def menu_frame(p, title, right=None):
    p.panel(TOP, BOT, P0, P1)
    if title is None:                                # the logo and the product name
        for k in range(LOGO_N):
            p.put(TOP + 1, P0 + 2 + k, [LOGO0 + k], fg=ACCENT if k < LOGO_BLUE else WHITE)
        p.put(TOP + 1, P0 + 2 + LOGO_N + 1, 'Triversity', fg=GREY)
    else:
        p.put(TOP + 1, P0 + 2, title, fg=WHITE)
    if right:
        p.field(TOP + 1, P1 - 1 - right[1], right[0], right[1], fg=GREY)
    for c in range(P0 + 2, P1 - 1):
        p.t[TOP + 2][c] = Page.word(BG_PANEL, DARKFG, 0, DIV)
    p.put(BOT - 1, P0 + 2, [ARR_U, ARR_D] + list(' Move  ') + [DOT] + list(' Select'), fg=GREY)


def pages(h90=False):
    live = Page()                                   # inside columns 3..62: the HDMI build shows those (720 px)
    live.bar(1, 3, 13, BG_VIDEO)                    # channel pill, accent after a change
    live.field(1, 4, 'LIVECH', 9, fg=WHITE, bg=BG_BAR)
    live.field(1, 50, 'REC', 13, fg=WHITE, bg=BG_PANEL)
    live.field(9, 26, 'NOSIG', 13, fg=WHITE, bg=BG_PANEL)
    live.field(18, 3, 'RXBAR', 14, fg=WHITE, bg=BG_PANEL)
    live.field(18, 51, 'LOGO', 12, fg=WHITE, bg=BG_PANEL)

    main = Page()
    menu_frame(main, None, ('VSTD', 8))
    for k, (label, val) in enumerate(MAIN_ITEMS):
        main.item(ITEM0 + k, label, val, chevron=label in ('Receivers', 'Signal', 'Settings'))

    rx = Page()
    menu_frame(rx, 'Receivers')
    hdr = [32] * 30
    for col, word in ((0, 'RX'), (4, 'Signal'), (12, 'C/N'), (17, 'Gain'), (23, 'State')):
        hdr[col:col + len(word)] = map(ord, word)
    rx.put(ITEM0 - 1, P0 + 3, hdr, fg=GREY)
    for k in range(3):
        rx.field(ITEM0 + k, P0 + 3, 'RXROW', 30, fg=WHITE)
    rx.item(ITEM0 + 3, 'Back', None, chevron=False)

    st = Page()
    menu_frame(st, 'Settings')
    for k, (label, val) in enumerate(SET_ITEMS_H90 if h90 else SET_ITEMS):
        st.item(ITEM0 + k, label, val, chevron=False)
    sg = Page()
    menu_frame(sg, 'Signal')
    for k, (label, val) in enumerate(SIG_ITEMS):
        sg.item(ITEM0 + k, label, val, chevron=False)
    return [live, main, rx, st, sg]


# ---- start-up screen (menu.v boot, lcd_out.v logo layer) ---------------------------------
# The Triversity logo (docs/logo.png) at 300 x 79, shown twice as large (600 x 158) at
# x 100, y 60 of the 800 x 480 grid; run-length coded, 9 bits a run: {class, length - 1}
# (classes: background, blue half / full, white half / full; runs of 1..64 pixels, every
# row complete). The RTL colours (RGB565):
BOOT_LX, BOOT_LY, BOOT_W, BOOT_H = 100, 60, 300, 79
BOOT_RGB565 = [0x0842, 0x0b50, 0x0aff, 0x7bf0, 0xef9e]   # bg, blue half, blue, white half, white
BOOT_LOGO = HERE.parent.parent / 'docs' / 'logo.png'


def boot_classes():
    im = Image.open(BOOT_LOGO).convert('RGB').resize((BOOT_W, BOOT_H), Image.LANCZOS)
    out = []
    for y in range(BOOT_H):
        row = []
        for x in range(BOOT_W):
            r, g, b = im.getpixel((x, y))
            cov = min(1.0, max(0.0, (250 - min(r, g, b)) / 200))   # distance from the white page
            q = round(cov * 2)                               # 0, half, full
            row.append(0 if q == 0 else (q if b - r > 60 else 2 + q))
        out.append(row)
    return out


def boot_runs():
    runs = []
    for row in boot_classes():
        x = 0
        while x < BOOT_W:
            n = 1
            while x + n < BOOT_W and row[x + n] == row[x] and n < 64:
                n += 1
            runs.append(row[x] << 6 | (n - 1))
            x += n
    assert len(runs) <= 2048, len(runs)
    return runs


def boot_video():
    """The start-up screen's picture (RGB565 per pixel, 800 x 480) as lcd_out.v draws it."""
    cls = boot_classes()
    out = [[BOOT_RGB565[0]] * 800 for _ in range(480)]
    for y in range(2 * BOOT_H):
        for x in range(2 * BOOT_W):
            c = cls[y // 2][x // 2]
            out[BOOT_LY + y][BOOT_LX + x] = BOOT_RGB565[c]
    return out


def boot_page():
    """Below the logo: the C5s found, then a small table (label left, value right)."""
    p = Page()
    p.field(10, 21, 'BOOTRX', 24, fg=WHITE, bg=BG_VIDEO)
    for r, label in ((12, 'Build'), (13, 'Channel'), (14, 'SD card'), (15, 'Video')):
        p.put(r, 21, label, fg=GREY, bg=BG_VIDEO)
    p.field(12, 28, 'BOOTBLD', 9, fg=WHITE, bg=BG_VIDEO)
    p.field(12, 38, 'BOOTVER', 7, fg=GREY, bg=BG_VIDEO)
    p.field(13, 36, 'LIVECH', 9, fg=WHITE, bg=BG_VIDEO)
    p.field(14, 36, 'BOOTSD', 9, fg=WHITE, bg=BG_VIDEO)
    p.field(15, 37, 'VSTD', 8, fg=WHITE, bg=BG_VIDEO)
    return p


# ---- reference field logic (rtl/ui/menu.v does the same) -----------------------------
def rjust(s, w):
    s = list(s)
    return [32] * (w - len(s)) + [c if isinstance(c, int) else ord(c) for c in s]


def chname(ch):
    return [ord(BANDS[ch // 8]), ord('1') + ch % 8, 32, MIDDOT, 32] + [ord(c) for c in str(FREQS[ch])]


def cn_text(raw):
    """C/N marker code (dB x 10 + 1000) as whole dB, rounded on the magnitude."""
    if raw == 0:
        return '--'
    v = raw - 1000
    db = min(99, ((abs(v) + 5) * 205) >> 11)
    return ('-' if v < 0 and db else '') + str(db)


def field_cells(name, w, st, row, sel, edit):
    """[(char, fg or None, bg or None)] for a field; None keeps the template value."""
    K = lambda chars, fg=None, bg=None: [(c if isinstance(c, int) else ord(c), fg, bg) for c in chars]
    hide = [(0, None, BG_VIDEO)] * w
    if name in ('CAPL', 'CAPR'):
        g = CAP_L if name == 'CAPL' else CAP_R
        if edit:
            return [(g, DARKFG, None)]
        return [(g, ACCENT if sel else PANEL, None)]
    if name in ('EDL', 'EDR'):
        return [(CHEV_L if name == 'EDL' else CHEV_R, None, None)] if edit else [(32, None, None)]
    if name in ('LIVECH', 'CHVAL'):
        return K(chname(st['channel']))
    if name == 'VSTD':
        return K(rjust('No video' if not st['locked'] else 'PAL' if st['pal'] else 'NTSC', w))
    if name == 'SCANV':
        if not st['scanning']:
            return K([32] * w)
        n = st['scan_ch'] + 1
        segs = [SEG_ON if n > 48 * k / 5 else SEG_OFF for k in range(5)]
        return K(segs + [32] + rjust(f'{n}/48', 5))
    if name == 'RECV':
        s = st['dvr_state']
        if not st.get('has_dvr', True):
            return K(rjust('No DVR', w))
        if not st['dvr']:
            if st.get('lg'):
                return K(rjust(['No card', 'Log', 'Log', 'Card err'][s], w), fg=RED if s == 3 else None)
            return K(rjust('Off', w))
        if s == 2:
            t = st['rec_s']
            v = K(rjust([DOT, 32] + list(f'{t // 60}:{t % 60:02d}'), w))
            return [(c, RED if c == DOT else f, b) for c, f, b in v]
        return K(rjust(['No card', 'Ready', '', 'Card err'][s], w), fg=RED if s == 3 else None)
    if name == 'ASPV':
        a = st['aspect']
        return K(rjust(['4:3', '16:9', 'Stretch', 'Auto 16:9' if st['wide'] else 'Auto 4:3'][a], w))
    if name == 'LOGOV':
        return K(rjust('On' if st['logo'] else 'Off', w))
    if name == 'LOGO':
        if not st['logo']:
            return hide
        return [(CAP_L, PANEL, BG_VIDEO)] + [(LOGO0 + k, ACCENT if k < LOGO_BLUE else WHITE, None) for k in range(LOGO_N)] + \
            [(CAP_R, PANEL, BG_VIDEO)]
    if name == 'MODEV':
        return K(rjust(['Single', 'Diversity', 'Triversity'][st['mode']], w))
    if name == 'RXCNT':
        n = sum(a < 3000 for a in st['age'])
        return K(f'{n}/3')
    if name == 'GAINV':
        return K(rjust(['Level', 'Ultra', 'RSSI'][st['gain_model']], w))
    if name == 'AFCV':
        return K(rjust('On' if st['afc'] else 'Off', w))
    if name == 'BOOTBLD':
        return K(rjust(st.get('build', 'LCD'), w))
    if name == 'BOOTVER':
        return K(st.get('version', '0000000'))
    if name == 'BOOTRX':
        out = []
        for k in range(3):                               # green: works; red: faulty, or silent after 1 s
            heard = st['age'][k] < 3000
            ok = heard and not st['flags'][k] & 8
            col = GREEN if ok else RED if heard or st.get('boot_ms', 0) >= 1000 else GREY
            out += K('C5 ' + 'ABC'[k] + ' ') + [(DOT, col, None)] + (K('   ') if k < 2 else [])
        return out
    if name == 'BOOTSD':
        if not st.get('has_dvr', True):
            return K(rjust('No DVR', w))
        return K(rjust(['No card', 'Ready', 'Ready', 'Card err'][st['dvr_state']], w))
    if name == 'HZ90V':
        return K(rjust(['Free', 'Camera', 'Smooth'][st.get('hz90', 0)], w))
    if name == 'NATIVEV':
        return K(rjust('On' if st.get('native_agc', False) else 'Off', w - 1)) + K('?' if st.get('native_pending') else ' ', fg=AMBER)
    if name in ('KLOCKV', 'ASYNCV', 'NFILTV'):
        key = dict(KLOCKV='klock', ASYNCV='async', NFILTV='nfilt')[name]
        return K(rjust('On' if st.get(key, False) else 'Off', w))
    if name == 'BRIGHTV':
        return K([SEG_ON if k <= st['bright'] else SEG_OFF for k in range(8)], fg=WHITE if sel or edit else None)
    if name == 'CALV':
        return K(rjust('Sent', w - 1) + [CHECK], fg=GREEN) if st['cal_ms'] else K([32] * w)
    if name == 'REC':
        if st.get('hq') and st['dvr'] and st['dvr_state'] in (0, 3):     # hq_ui.v: why it does not record
            body = [(CAP_L, PANEL, BG_VIDEO), (DOT, RED, None), (32, None, None)] + K('Card err' if st['dvr_state'] == 3 else 'No card ')
            return body + [(32, None, None)] + [(CAP_R, PANEL, BG_VIDEO)]
        if not (st['dvr'] and st['dvr_state'] == 2):
            return hide
        t = st['rec_s']
        body = [(CAP_L, PANEL, BG_VIDEO), (DOT, RED, None), (32, None, None)] + K('REC ') + K(rjust(f'{t // 60}:{t % 60:02d}', 5))
        return body + [(32, None, None)] * (w - 1 - len(body)) + [(CAP_R, PANEL, BG_VIDEO)]
    if name == 'NOSIG':      # no NO SIGNAL label (menu.v F_NOSIG): the picture or snow stays clear
        if True:
            return hide
        return [(CAP_L, PANEL, BG_VIDEO), (32, None, None)] + K('NO SIGNAL ') + [(CAP_R, PANEL, BG_VIDEO)]
    if name == 'RXBAR':
        out = [(CAP_L, PANEL, BG_VIDEO)]
        for k in range(3):
            stale = st['age'][k] >= 3000
            lvl = 0 if stale else min(4, (st['sig'][k] + 12) // 25)
            dim = stale or k > st['mode']                       # not fused in this mode
            out += [(32, None, None), (ord('ABC'[k]), GREY if dim else WHITE, None), (BARS0 + lvl, GREY if dim else WHITE, None)]
            out += [(32, None, None)] if k < 2 else []
        out += [(32, None, None)] * (w - 1 - len(out)) + [(CAP_R, PANEL, BG_VIDEO)]
        return out
    if name == 'RXROW':
        k = row - ITEM0
        stale = st['age'][k] >= 3000
        if stale:
            return K([ord('ABC'[k]), 32, 32, 32] + [SEG_OFF] * 5 + rjust('--', 6) + rjust('--', 6) + [32, 32] +
                     list(map(ord, 'Off  ')) + [32, 32], fg=GREY)
        segs = [(SEG_ON if st['sig'][k] > 20 * j else SEG_OFF, WHITE, None) for j in range(5)]
        cns = cn_text(st['cn'][k])
        flags = st['flags'][k]
        state = ('Idle', GREY) if k > st['mode'] else ('DC!', RED) if flags & 8 else ('Lock', GREEN) if flags & 1 else ('Seek', AMBER)
        return K([ord('ABC'[k]), 32, 32, 32]) + segs + K(rjust(cns, 6)) + K(rjust(f'G{min(99, st["gain"][k])}', 6)) + \
            K([32, 32]) + K(state[0].ljust(5), fg=state[1]) + K([32, 32])
    raise KeyError(name)


def fill(ps, st):
    """The cell grid (char, fg, bg) for the state st, as the RTL renders it."""
    p = ps[st['page']] if st['open'] else ps[0]
    page = st['page'] if st['open'] else 0
    sel_row = ITEM0 + (3 if page == 2 else st['cursor']) if page else (1 if st['toast'] else -1)
    if st.get('boot'):
        p, page, sel_row = boot_page(), 0, -1
    cells = [[None] * COLS for _ in range(ROWS)]
    for r in range(ROWS):
        c = 0
        while c < COLS:
            w = p.t[r][c]
            bg, fg, fid, ch = w >> 16, (w >> 13) & 7, (w >> 7) & 63, w & 127
            sel = r == sel_row
            edit = sel and st['edit'] and page in (1, 3)
            if fid:
                n = 1
                while c + n < COLS and (p.t[r][c + n] >> 7) & 63 == fid and p.t[r][c + n] & 127 == n:
                    n += 1
                vals = field_cells(FIELDS[fid], n, st, r, sel, edit)
                assert len(vals) == n, (FIELDS[fid], len(vals), n)
                for k, (vch, vfg, vbg) in enumerate(vals):
                    cells[r][c + k] = resolve(p.t[r][c + k], vch, vfg, vbg, sel, edit)
                c += n
            else:
                cells[r][c] = resolve(w, ch, None, None, sel, edit)
                c += 1
    return cells


def resolve(w, ch, fg, bg, sel, edit):
    tbg, tfg = w >> 16, (w >> 13) & 7
    fg = tfg if fg is None else fg
    bg = tbg if bg is None else bg
    if bg == BG_BAR:
        bg = (BG_DARK if edit else BG_PANEL + 1) if sel else BG_PANEL      # 2 = accent when selected
        if sel and not edit:
            fg = WHITE if fg == GREY else fg
        if edit and fg == GREY:
            fg = ACCENT
    return ch, fg, bg


def render(g, cells, video):
    """cells -> 800 x 480 RGB image (8 bit), the RTL's pixel rule exactly;
    video pixels gray or (r, g, b)."""
    img = Image.new('RGB', (800, 480))
    px = img.load()
    for y in range(480):
        for x in range(800):
            v = video[y][x]
            vr, vg, vb = v if isinstance(v, tuple) else (v, v, v)
            ch, fg, bg = 0, WHITE, BG_VIDEO
            xc = x - X0
            if 0 <= xc < COLS * CW:
                ch, fg, bg = cells[y // CH][xc // CW]
            a = g[ch][y % CH][xc % CW] if 0 <= xc < COLS * CW else 0
            panel = (vr // 4 + 14, vg // 4 + 16, vb // 4 + 22)
            b = [(vr, vg, vb), panel, PAL[ACCENT], DARK][bg]
            f = panel if fg == PANEL else PAL[fg]
            px[x, y] = tuple(((b[i] * (3 - a) + f[i] * a) * 171) >> 9 for i in range(3))
    return img


def hmaps():
    """LCD column -> line buffer pixel (or None: black) per aspect mode:
    0 full width (16:9 cameras), 1 4:3 in 640 columns, 2 Stretch (4:3 to the
    full width, true geometry in the centre, the edges stretched: s(t) = 1.25 t
    - 0.25 t^3 on t = -1..1)."""
    full = list(range(800))
    box = [((x - 80) * 5) // 4 if 80 <= x < 720 else None for x in range(800)]
    pano = []
    for x in range(800):
        t = (x + 0.5 - 400) / 400
        pano.append(min(799, max(0, int(400 + 400 * (1.25 * t - 0.25 * t ** 3)))))
    return [full, box, pano]


def hmode(st):
    """The LCD mapping of the menu's Aspect (0 4:3, 1 16:9, 2 Stretch, 3 Auto)."""
    return [1, 0, 2, 0 if st['wide'] else 1][st['aspect']]


def emit(g, ps):
    head = ['// Generated by fpga/gen/gen_osd.py; do not edit.']
    lines = head + ['initial begin']
    for code in range(128):
        for y in range(CH):
            v = sum(g[code][y][x] << (2 * x) for x in range(CW))
            lines.append(f"    font[{code * 32 + y}] = 24'h{v:06x};")
    lines.append('end')
    (RTL / 'osd_font.vh').write_text('\n'.join(lines) + '\n')
    lines = head + ['initial begin']
    for k, p in enumerate(ps):
        for r in range(ROWS):
            for c in range(COLS):
                lines.append(f"    tmpl[{k * COLS * ROWS + r * COLS + c}] = 18'h{p.t[r][c]:05x};")
    bp = boot_page()                                # the start-up screen: rows 10..15 after the pages (the ROM's spare room)
    boot_lines = [f"    tmpl[{5 * COLS * ROWS + (r - 10) * COLS + c}] = 18'h{bp.t[r][c]:05x};" for r in range(10, 16) for c in range(COLS)]
    assert all(not bp.t[r][c] for r in range(ROWS) for c in range(COLS) if not 10 <= r <= 15)
    lines += boot_lines
    lines += [f"    freq[{i}] = 16'h{int(str(f), 16):04x};" for i, f in enumerate(FREQS)]
    lines.append('end')
    (RTL / 'osd_pages.vh').write_text('\n'.join(lines) + '\n')
    h90 = head + ['initial begin']                  # the 90 Hz HDMI build's pages
    for k, p in enumerate(pages(h90=True)):
        for r in range(ROWS):
            for c in range(COLS):
                h90.append(f"    tmpl[{k * COLS * ROWS + r * COLS + c}] = 18'h{p.t[r][c]:05x};")
    h90 += boot_lines + [l for l in lines if 'freq[' in l] + ['end']
    (RTL / 'osd_pages_h90.vh').write_text('\n'.join(h90) + '\n')
    runs = boot_runs()
    (RTL.parent / 'video' / 'boot_logo.vh').write_text('\n'.join(head + ['initial begin'] +
        [f"    logo[{i}] = 9'h{v:03x};" for i, v in enumerate(runs)] + ['end']) + '\n')
    print('boot logo', len(runs), 'runs')
    (RTL / 'osd_freq.vh').write_text('\n'.join(head + ['initial begin'] + [l for l in lines if 'freq[' in l] + ['end']) + '\n')
    lines = head + ['initial begin']
    lines += [f"    hmap[{x}] = 10'h{v:03x};" for x, v in enumerate(hmaps()[2])]
    lines.append('end')
    (RTL.parent / 'video' / 'hmap.vh').write_text('\n'.join(lines) + '\n')


def main():
    emit(glyphs(), pages())
    emit_seg()
    print('wrote rtl/ui/osd_font.vh, osd_pages.vh, osd_pages_h90.vh, osd_freq.vh, rtl/video/hmap.vh')


if __name__ == '__main__':
    main()
