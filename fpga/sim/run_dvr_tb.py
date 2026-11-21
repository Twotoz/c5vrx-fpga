"""Triversity: DVR end to end in simulation. A small FAT32 card image (MBR,
partition, two FATs, TRIDVR.BIN contiguous, 300 sectors so the ring wraps
off a frame boundary) -> sd_model; tb_dvr streams synthetic fields into
rtl/io/dvr.v (which finds the file by its header sector); the written file is decoded with tools/dvr_to_mp4.frames and every
frame is checked pixel for pixel.

    python fpga/sim/run_dvr_tb.py [fields] [busy bytes per block]
"""
import struct, subprocess, sys, tempfile
from pathlib import Path
import numpy as np
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import rtl as rtl_  # noqa: E402
sys.path.insert(0, str(HERE.parent.parent / 'tools'))
import dvr_to_mp4 as D  # noqa: E402

SECTORS, PART, RSVD, FATSZ, SPC, FILE_SECT = 3072, 64, 32, 8, 8, 300


def image():
    img = bytearray(SECTORS * 512)
    # MBR: one FAT32 LBA partition
    img[446 + 4] = 0x0c
    img[446 + 8:446 + 12] = struct.pack('<I', PART)
    img[446 + 12:446 + 16] = struct.pack('<I', SECTORS - PART)
    img[510:512] = b'\x55\xaa'
    bs = PART * 512
    img[bs:bs + 3] = b'\xeb\x58\x90'
    img[bs + 3:bs + 11] = b'MSWIN4.1'
    struct.pack_into('<HBHBHHBHHHII', img, bs + 11, 512, SPC, RSVD, 2, 0, 0, 0xf8, 0, 63, 255, PART, SECTORS - PART)
    struct.pack_into('<IHHIHH', img, bs + 36, FATSZ, 0, 0, 2, 1, 6)
    img[bs + 82:bs + 90] = b'FAT32   '
    img[bs + 510:bs + 512] = b'\x55\xaa'
    data = PART + RSVD + 2 * FATSZ
    nclus = -(-FILE_SECT // SPC)
    for f in range(2):                               # FAT: root (2), file chain 3..
        fat = (PART + RSVD + f * FATSZ) * 512
        ent = [0x0ffffff8, 0x0fffffff, 0x0fffffff] + [4 + i for i in range(nclus - 1)] + [0x0fffffff]
        for i, e in enumerate(ent):
            struct.pack_into('<I', img, fat + 4 * i, e)
    root = data * 512                                # cluster 2
    img[root:root + 11] = b'TRIVERSITY '; img[root + 11] = 0x08
    img[root + 32:root + 43] = b'OTHER   TXT'; img[root + 43] = 0x20
    e = root + 64
    img[e:e + 11] = b'TRIDVR  BIN'; img[e + 11] = 0x20
    struct.pack_into('<H', img, e + 20, 0); struct.pack_into('<H', img, e + 26, 3)
    struct.pack_into('<I', img, e + 28, FILE_SECT * 512)
    hdr = (data + SPC) * 512                         # tools/make_dvr_file.py: the header sector
    img[hdr:hdr + 16] = b'TRIDVR-FILE-0001'
    struct.pack_into('<I', img, hdr + 16, FILE_SECT - 1)
    return img, hdr + 512


def main():
    fields = int(sys.argv[1]) if len(sys.argv) > 1 else 12
    busy = int(sys.argv[2]) if len(sys.argv) > 2 else 40   # card busy bytes after each block (400: a slow card)
    img, file_off = image()
    with tempfile.TemporaryDirectory() as t:
        t = Path(t)
        (t / 'sd.hex').write_text('\n'.join(f'{b:02x}' for b in img) + '\n')
        subprocess.run(['iverilog', '-g2012', f'-Ptb_dvr.BUSY={busy}', '-o', str(t / 'tb'), str(HERE / 'tb_dvr.v'), str(HERE / 'sd_model.v'),
                        *rtl_.src('dvr.v')], check=True)
        r = subprocess.run(['vvp', '-n', str(t / 'tb'), f'+fields={fields}'], cwd=t, capture_output=True, text=True)
        print(r.stdout[-3000:])
        words = [x for ln in (t / 'sd_out.hex').read_text().splitlines() for x in ln.split('//')[0].split()]
        bad = [i for i, x in enumerate(words) if 'x' in x or 'z' in x]
        assert not bad, f'undefined bytes written: {len(bad)} from {bad[:4]}'
        out = bytes(int(x, 16) for x in words)
    end = file_off + (FILE_SECT - 1) * 512
    fdata = out[file_off:end]
    assert out[:file_off] == bytes(img[:file_off]), 'DVR wrote outside the file (or over its header)'
    assert out[end:] == bytes(img[end:]), 'DVR wrote past the file'
    fr = D.frames(fdata)
    ok = 0
    x = np.arange(D.W) * 2
    r = np.arange(D.H)[:, None]
    for num, pal, im in fr:
        fld = 2 * (num - 1)                          # frame n = field 2(n-1)
        want = ((((x[None, :] // 8 + r // 4 + fld * 3) % 16) << 4) >> 4) * 17
        good = im is not None and np.array_equal(im, want)
        ok += good
        print(f'frame {num}: {"OK" if good else "short" if im is None else "WRONG"}')
    short = sum(im is None for _, _, im in fr)
    full = len(fr) >= 3 and ok + short == len(fr) and ok >= 1
    print('PASS' if full else 'FAIL', f'{ok}/{len(fr)} frames match, {short} short, no writes outside TRIDVR.BIN')
    sys.exit(0 if full else 1)


if __name__ == '__main__':
    main()
