"""Triversity HQ DVR: baseline JPEG encoder for one video field, written as the
hardware does it (reference for rtl/io/jpeg_enc.v, bit-exact).

  - field: Y 720 x H (H = 240 NTSC, 288 PAL), Cb / Cr 4:2:0 (360 x H/2)
  - MCU 16 x 16: Y blocks (0,0) (0,8) (8,0) (8,8), then Cb, Cr
  - DCT: separable matrix products with 13-bit coefficients (round(4096 c(u)
    cos((2k+1) u pi / 16))); rows: sum >> 10 (two fraction bits), columns:
    sum >> 14 (the JPEG scale), both rounded
  - quantisation: sign(F) ((|F| R + 2^15) >> 16), R = round(2^16 / Q), Q the
    Annex K tables scaled to a quality (libjpeg's rule); eight qualities
  - entropy: the Annex K Huffman tables, DC differences per component, AC
    run / size with ZRL and EOB, 0xFF stuffing, padding with ones
Every field is a complete JPEG (SOI DQT SOF0 DHT SOS ... EOI).

    python fpga/model/jpeg_model.py      encodes a test field, checks it decodes, prints sizes and PSNR
"""
import io, math
import numpy as np

QUALITIES = [30, 40, 50, 60, 70, 75, 80, 90]

# Annex K.1 quantisation tables (natural order)
QY = [16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58, 60, 55, 14, 13, 16, 24, 40, 57, 69, 56,
      14, 17, 22, 29, 51, 87, 80, 62, 18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
      49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99]
QC = [17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99, 99, 99, 24, 26, 56, 99, 99, 99, 99, 99,
      47, 66, 99, 99, 99, 99, 99, 99] + [99] * 32
ZIGZAG = [0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14,
          21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53,
          60, 61, 54, 47, 55, 62, 63]

# Annex K.3 Huffman tables: (bits[1..16], values)
DC_Y = ([0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0], list(range(12)))
DC_C = ([0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0], list(range(12)))
AC_Y = ([0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d], [
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
    0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
    0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
    0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
    0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
    0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa])
AC_C = ([0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77], [
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
    0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
    0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
    0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
    0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
    0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
    0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
    0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
    0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
    0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa])


def huff_codes(spec):
    """{symbol: (code, length)} from (bits, values), Annex C."""
    bits, vals = spec
    codes, code, k = {}, 0, 0
    for length in range(1, 17):
        for _ in range(bits[length - 1]):
            codes[vals[k]] = (code, length)
            code += 1; k += 1
        code <<= 1
    return codes


HC = {'dcy': huff_codes(DC_Y), 'dcc': huff_codes(DC_C), 'acy': huff_codes(AC_Y), 'acc': huff_codes(AC_C)}

# DCT coefficients, 13 bit
C13 = [[round(4096 * (math.sqrt(1 / 8) if u == 0 else 0.5) * math.cos((2 * k + 1) * u * math.pi / 16)) for k in range(8)]
       for u in range(8)]


def qtable(base, q):
    s = 5000 // q if q < 50 else 200 - 2 * q
    return [min(255, max(1, (b * s + 50) // 100)) for b in base]


def recip(Q):
    return [round(65536 / x) for x in Q]


def rnd_shift(x, s):
    return (x + (1 << (s - 1))) >> s


def fdct(block):
    """8 x 8 samples (level-shifted, -128..127), row-major -> 64 coefficients (natural order)."""
    t = [[rnd_shift(sum(block[r * 8 + k] * C13[u][k] for k in range(8)), 10) for u in range(8)] for r in range(8)]
    return [rnd_shift(sum(t[r][u] * C13[v][r] for r in range(8)), 14) for v in range(8) for u in range(8)]


def quant(F, R):
    out = []
    for f, r in zip(F, R):
        m = (abs(f) * r + (1 << 15)) >> 16
        out.append(-m if f < 0 else m)
    return out


def size_bits(v):
    """JPEG category and the value's bits (ones' complement for negatives)."""
    a = abs(v)
    n = a.bit_length()
    return n, (v if v >= 0 else v + (1 << n) - 1) & ((1 << n) - 1)


class Bits:
    def __init__(self):
        self.acc, self.n, self.out = 0, 0, bytearray()

    def put(self, code, length):
        self.acc = (self.acc << length) | code
        self.n += length
        while self.n >= 8:
            b = (self.acc >> (self.n - 8)) & 255
            self.out.append(b)
            if b == 0xFF:
                self.out.append(0)
            self.n -= 8
        self.acc &= (1 << self.n) - 1

    def flush(self):
        if self.n:
            self.put((1 << (8 - self.n)) - 1, 8 - self.n)


def encode_block(bits, Fq, pred, dc, ac):
    """One quantised block (natural order); returns the new DC predictor."""
    zz = [Fq[ZIGZAG[i]] for i in range(64)]
    diff = zz[0] - pred
    n, v = size_bits(diff)
    bits.put(*dc[n])
    if n:
        bits.put(v, n)
    run = 0
    for i in range(1, 64):
        if zz[i] == 0:
            run += 1
            continue
        while run > 15:
            bits.put(*ac[0xF0]); run -= 16
        n, v = size_bits(zz[i])
        bits.put(*ac[(run << 4) | n]); bits.put(v, n)
        run = 0
    if run:
        bits.put(*ac[0x00])
    return zz[0]


def header(w, h, qi):
    """SOI, DQT (Y, C), SOF0, DHT x 4, SOS for a 4:2:0 picture at quality index qi."""
    q = QUALITIES[qi]
    QYt, QCt = qtable(QY, q), qtable(QC, q)
    o = bytearray(b'\xff\xd8')
    o += b'\xff\xdb\x00\x84' + bytes([0]) + bytes(QYt[ZIGZAG[i]] for i in range(64)) + \
        bytes([1]) + bytes(QCt[ZIGZAG[i]] for i in range(64))
    o += b'\xff\xc0\x00\x11\x08' + h.to_bytes(2, 'big') + w.to_bytes(2, 'big') + \
        b'\x03\x01\x22\x00\x02\x11\x01\x03\x11\x01'
    for cls_id, spec in ((0x00, DC_Y), (0x10, AC_Y), (0x01, DC_C), (0x11, AC_C)):
        body = bytes([cls_id]) + bytes(spec[0]) + bytes(spec[1])
        o += b'\xff\xc4' + (len(body) + 2).to_bytes(2, 'big') + body
    o += b'\xff\xda\x00\x0c\x03\x01\x00\x02\x11\x03\x11\x00\x3f\x00'
    return o


def encode_field(Y, Cb, Cr, qi):
    """Y: H x 720 uint8, Cb / Cr: H/2 x 360 -> JPEG bytes."""
    h, w = Y.shape
    q = QUALITIES[qi]
    RY, RC = recip(qtable(QY, q)), recip(qtable(QC, q))
    bits = Bits()
    pred = [0, 0, 0]
    for my in range(h // 16):
        for mx in range(w // 16):
            for by, bx in ((0, 0), (0, 8), (8, 0), (8, 8)):
                blk = [int(Y[my * 16 + by + r, mx * 16 + bx + c]) - 128 for r in range(8) for c in range(8)]
                pred[0] = encode_block(bits, quant(fdct(blk), RY), pred[0], HC['dcy'], HC['acy'])
            for ci, P in ((1, Cb), (2, Cr)):
                blk = [int(P[my * 8 + r, mx * 8 + c]) - 128 for r in range(8) for c in range(8)]
                pred[ci] = encode_block(bits, quant(fdct(blk), RC), pred[ci], HC['dcc'], HC['acc'])
    bits.flush()
    return bytes(header(w, h, qi) + bits.out + b'\xff\xd9')


def to_ycbcr420(rgb):
    """8-bit RGB -> JPEG Y, Cb, Cr (4:2:0 by 2 x 2 averages), as uint8."""
    r, g, b = [rgb[..., i].astype(float) for i in range(3)]
    Y = .299 * r + .587 * g + .114 * b
    Cb = 128 - .168736 * r - .331264 * g + .5 * b
    Cr = 128 + .5 * r - .418688 * g - .081312 * b
    sub = lambda P: (P[0::2, 0::2] + P[1::2, 0::2] + P[0::2, 1::2] + P[1::2, 1::2]) / 4
    c = lambda P: np.clip(np.round(P), 0, 255).astype(np.uint8)
    return c(Y), c(sub(Cb)), c(sub(Cr))


def main():
    from pathlib import Path
    from PIL import Image
    here = Path(__file__).resolve().parent
    src = Image.open(here.parent / 'sim' / 'data' / 'osd_video.png').convert('RGB').resize((720, 240), Image.BILINEAR)
    rgb = np.asarray(src)
    Y, Cb, Cr = to_ycbcr420(rgb)
    for qi, q in enumerate(QUALITIES):
        data = encode_field(Y, Cb, Cr, qi)
        dec = np.asarray(Image.open(io.BytesIO(data)).convert('RGB')).astype(float)
        psnr = 10 * math.log10(255 ** 2 / np.mean((dec - rgb) ** 2))
        print(f'quality {q:3d}: {len(data):6d} bytes, PSNR {psnr:5.1f} dB  ({len(data) * 60 / 1e6:.2f} MB/s at 60 fields)')
    (here.parent / 'build').mkdir(exist_ok=True)
    (here.parent / 'build' / 'field_q75.jpg').write_bytes(encode_field(Y, Cb, Cr, 5))


if __name__ == '__main__':
    main()


# ---- hardware tables (rtl/io/jpeg_tab.vh) and the record framing ----
W_FIELD = 720


def huff_rom():
    """1024 x 21 bit: {table (0 DC Y, 1 AC Y, 2 DC C, 3 AC C), symbol} -> {length 5, code 16}."""
    rom = [0] * 1024
    for t, name in enumerate(('dcy', 'acy', 'dcc', 'acc')):
        for sym, (code, length) in HC[name].items():
            rom[t * 256 + sym] = length << 16 | code
    return rom


def recip_rom():
    """1024 x 17 bit: {quality index 3, table 1 (0 Y, 1 C), zigzag index 6} -> R."""
    rom = [0] * 1024
    for qi, q in enumerate(QUALITIES):
        for t, base in enumerate((QY, QC)):
            R = recip(qtable(base, q))
            for i in range(64):
                rom[qi * 128 + t * 64 + i] = R[ZIGZAG[i]]
    return rom


def header_rom():
    """The JPEG header of every quality (all the same length), height 240; the
    height's two bytes sit at HPOS (288 for PAL is patched in)."""
    hs = [header(W_FIELD, 240, qi) for qi in range(len(QUALITIES))]
    assert len({len(h) for h in hs}) == 1
    hpos = hs[0].index(b'\xff\xc0') + 5
    assert hs[0][hpos:hpos + 2] == (240).to_bytes(2, 'big')
    return hs, len(hs[0]), hpos


def record_prefix(seq, pal, parity, qi):
    """The 8 bytes before every field's JPEG: TRIJ, field number, flags, quality index."""
    return b'TRIJ' + (seq & 0xFFFF).to_bytes(2, 'little') + bytes([(parity << 1) | pal, qi])


def record(Y, Cb, Cr, qi, seq, pal, parity):
    """A field record as rtl/io/jpeg_enc.v writes it: prefix, JPEG (height patched)."""
    return record_prefix(seq, pal, parity, qi) + encode_field(Y, Cb, Cr, qi)


def emit_tables():
    from pathlib import Path
    rtl = Path(__file__).resolve().parent.parent / 'rtl' / 'io'
    hs, L, hpos = header_rom()
    lines = ['// Generated by fpga/model/jpeg_model.py emit_tables(); do not edit.',
             f'localparam HDR_LEN = {L}, HDR_HPOS = {hpos};',
             'function automatic signed [13:0] dctc; input [2:0] u, k;', '    case ({u, k})']
    lines += [f"        6'd{u * 8 + k}: dctc = {C13[u][k]};" for u in range(8) for k in range(8)]
    lines += ['        default: dctc = 0;', '    endcase', 'endfunction',
              'function automatic [5:0] zigzag; input [5:0] i;', '    case (i)']
    lines += [f"        6'd{i}: zigzag = 6'd{ZIGZAG[i]};" for i in range(64)]
    lines += ['        default: zigzag = 0;', '    endcase', 'endfunction', 'initial begin']
    lines += [f"    huff[{a}] = 21'h{v:06x};" for a, v in enumerate(huff_rom())]
    lines += [f"    rcp[{a}] = 17'h{v:05x};" for a, v in enumerate(recip_rom())]
    # one header (quality 0); the DQT tables of every quality apart: hdr bytes 7..70 are the
    # Y table, 72..135 the C table (zigzag order), from dqt[{qi, table, i}]
    assert hs[0][2:6] == b'\xff\xdb\x00\x84' and hs[0][6] == 0 and hs[0][71] == 1
    lines += [f"    hdr[{j}] = 8'h{b:02x};" for j, b in enumerate(hs[0])]
    for qi, h in enumerate(hs):
        dq = h[7:71] + h[72:136]
        lines += [f"    dqt[{qi * 128 + i}] = 8'h{b:02x};" for i, b in enumerate(dq)]
    lines.append('end')
    (rtl / 'jpeg_tab.vh').write_text('\n'.join(lines) + '\n')
    print('wrote rtl/io/jpeg_tab.vh', L, hpos)
