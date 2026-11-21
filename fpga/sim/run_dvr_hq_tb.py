"""Triversity HQ DVR end to end: rtl/io/dvr_hq.v (strip buffers, jpeg_enc.v,
the ring, sd_ring.v) on a synthetic DVR stream of a colour field, into an SD
card model with a FAT32 image and TRIDVR.BIN. Every record in the file must
be exactly the model's (model/jpeg_model.record) for its quality index and
field number, and must decode; nothing may be written outside the file.

tools/hqdvr_to_mp4.py must find the same records in the file. --docs saves
the first recorded field (the RTL's JPEG) as the tool's --bob frame (line
doubled to 720 x 480) in docs/hqdvr_frame.png.

    python fpga/sim/run_dvr_hq_tb.py [fields] [card busy bytes per block] [--docs]
"""
import io, struct, subprocess, sys, tempfile
from pathlib import Path
import numpy as np
from PIL import Image
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE)); sys.path.insert(0, str(HERE.parent / 'model'))
import rtl as rtl_  # noqa: E402
import jpeg_model as J  # noqa: E402
sys.path.insert(0, str(HERE.parent.parent / 'tools'))
import hqdvr_to_mp4 as T  # noqa: E402

SECTORS, PART, RSVD, FATSZ, SPC, FILE_SECT = 4096, 64, 32, 8, 8, 1600


def image():
    img = bytearray(SECTORS * 512)
    img[446 + 4] = 0x0c
    img[446 + 8:446 + 12] = struct.pack('<I', PART)
    img[446 + 12:446 + 16] = struct.pack('<I', SECTORS - PART)
    img[510:512] = b'\x55\xaa'
    data = PART + RSVD + 2 * FATSZ
    hdr = (data + SPC) * 512
    img[hdr:hdr + 16] = b'TRIDVR-FILE-0001'
    struct.pack_into('<I', img, hdr + 16, FILE_SECT - 1)
    return img, hdr + 512


def stream_planes(ycc):
    """The planes the hardware builds: Y, and Cb / Cr at 4:2:0 with its rounding."""
    Y = ycc[..., 0].astype(int)
    def c420(P):
        h = (P[:, 0::2] + P[:, 1::2] + 1) >> 1
        return (h[0::2] + h[1::2] + 1) >> 1
    return Y.astype(np.uint8), c420(ycc[..., 1].astype(int)).astype(np.uint8), c420(ycc[..., 2].astype(int)).astype(np.uint8)


def records(data):
    out, i = [], 0
    while True:
        i = data.find(b'TRIJ', i)
        if i < 0:
            return out
        e = data.find(b'\xff\xd9', i)
        if e < 0:
            return out
        out.append(data[i:e + 2]); i = e + 2


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    nf = int(args[0]) if len(args) > 0 else 4
    busy = int(args[1]) if len(args) > 1 else 40
    src = np.asarray(Image.open(HERE / 'data' / 'osd_video.png').convert('RGB').resize((720, 240), Image.BILINEAR)).astype(float)
    r, g, b = src[..., 0], src[..., 1], src[..., 2]
    ycc = np.clip(np.round(np.stack([.299 * r + .587 * g + .114 * b, 128 - .168736 * r - .331264 * g + .5 * b,
                                     128 + .5 * r - .418688 * g - .081312 * b], -1)), 0, 255).astype(int)
    Y, Cb, Cr = stream_planes(ycc)
    img, file_off = image()
    with tempfile.TemporaryDirectory() as t:
        t = Path(t)
        (t / 'sd.hex').write_text('\n'.join(f'{x:02x}' for x in img) + '\n')
        (t / 'field.hex').write_text('\n'.join(f'{a:02x}{b_:02x}{c:02x}' for a, b_, c in ycc.reshape(-1, 3)) + '\n')
        subprocess.run(['iverilog', '-g2012', f'-Ptb_dvr_hq.BUSY={busy}', *rtl_.inc(), '-o', str(t / 'tb'),
                        str(HERE / 'tb_dvr_hq.v'), str(HERE / 'sd_model.v'), *rtl_.src('dvr_hq.v', 'jpeg_enc.v', 'sd_ring.v', 'sdram.v', 'mul_dsp.v', 'addsub.v'), str(HERE / 'sdram_model.v')],
                       check=True)
        rr = subprocess.run(['vvp', '-n', str(t / 'tb'), f'+fields={nf}'], cwd=t, capture_output=True, text=True)
        print(rr.stdout[-1500:])
        words = [x for ln in (t / 'sd_out.hex').read_text().splitlines() for x in ln.split('//')[0].split()]
        out = bytes(int(x, 16) for x in words)
    end = file_off + (FILE_SECT - 1) * 512
    ok = out[:file_off] == bytes(img[:file_off]) and out[end:] == bytes(img[end:])
    recs = records(out[file_off:end])
    good = 0
    for rec in recs:
        seq = rec[4] | rec[5] << 8; flags, qi = rec[6], rec[7]
        want = J.record(Y, Cb, Cr, qi, seq, flags & 1, flags >> 1 & 1)
        same = rec == want
        if same:
            Image.open(io.BytesIO(rec[8:])).load()
        good += same
        print(f'record {seq}: quality {J.QUALITIES[qi]}, {len(rec)} bytes, {"identical" if same else "DIFFERENT"}')
    tool = T.records(out[file_off:end])
    tool_ok = [r[0] for r in tool] == [rec[4] | rec[5] << 8 for rec in recs] and len(T.fields(tool)) == len(recs)
    print('tools/hqdvr_to_mp4.py finds the same records:', tool_ok)
    if '--docs' in sys.argv and recs:
        Image.fromarray(np.repeat(T.fields(tool)[0][0], 2, 0)).save(HERE.parent.parent / 'docs' / 'hqdvr_frame.png')
    ok = ok and good == len(recs) and len(recs) >= 2 and tool_ok
    print('PASS' if ok else 'FAIL', f'{good}/{len(recs)} records identical, nothing outside TRIDVR.BIN: {out[:file_off] == bytes(img[:file_off])}')
    sys.exit(0 if ok else 1)


if __name__ == '__main__':
    main()
