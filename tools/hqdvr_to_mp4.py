#!/usr/bin/env python3
"""Triversity HQ DVR: TRIDVR.BIN (fpga/rtl/io/dvr_hq.v) to a video file.

The file holds one record per video field: "TRIJ", the field number (16 bit),
flags (bit 0 PAL, bit 1 field parity), the quality index, then a complete
JPEG of the field (720 x 240 NTSC, 720 x 288 PAL, colour 4:2:0). The FPGA
writes the file as a ring, so records are found by their marker and put in
field-number order (the oldest first). Dropped fields leave a gap in the
numbers and are filled by repeating the last one.

  --weave (default)  two fields into one 720 x 480 / 576 frame, 29.97 / 25 fps
  --bob              every field line-doubled, 59.94 / 50 fps (smoother motion)

    python tools/hqdvr_to_mp4.py /media/TF/TRIDVR.BIN rec.mp4 [--bob]   (needs ffmpeg)
    python tools/hqdvr_to_mp4.py TRIDVR.BIN frames/                     (PNG per frame)
"""
import io, subprocess, sys
from pathlib import Path
import numpy as np
from PIL import Image


def records(data):
    """[(number, pal, parity, jpeg bytes)] in recording order."""
    out, i = [], 0
    data = bytes(data) + bytes(data[:200000])          # a record may wrap round the end of the file
    n = len(data) - 200000
    while True:
        i = data.find(b'TRIJ', i)
        if i < 0 or i >= n:
            break
        e = data.find(b'\xff\xd9', i)
        if e < 0:
            break
        if data[i + 8:i + 10] == b'\xff\xd8':
            out.append((data[i + 4] | data[i + 5] << 8, data[i + 6] & 1, data[i + 6] >> 1 & 1, data[i + 8:e + 2]))
        i = e + 2
    if not out:
        return out
    seen = {}
    for r in out:
        seen[r[0]] = r                                   # a field written twice (ring): keep one
    out = sorted(seen.values())
    nums = [r[0] for r in out]
    gaps = [(nums[(k + 1) % len(nums)] - nums[k]) % 65536 for k in range(len(nums))]
    s = (int(np.argmax(gaps)) + 1) % len(out)
    return out[s:] + out[:s]


def fields(recs):
    """Decoded fields (H x 720 x 3) with the gaps filled, and their parities."""
    last, out = None, []
    for k, (num, pal, par, jpg) in enumerate(recs):
        gap = (num - recs[k - 1][0]) % 65536 if k else 1
        if last is not None and 1 < gap < 100:
            out += [last] * (gap - 1)
        try:
            img = np.asarray(Image.open(io.BytesIO(jpg)).convert('RGB'))
        except Exception:
            img = last
        if img is None:
            continue
        last = (img, par)
        out.append(last)
    return out


def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    if len(args) != 2:
        sys.exit(__doc__)
    bob = '--bob' in sys.argv
    recs = records(Path(args[0]).read_bytes())
    if not recs:
        sys.exit('no records found')
    pal = recs[0][1]
    fl = fields(recs)
    if bob:
        frames = [np.repeat(f, 2, 0) for f, _ in fl]
        rate = '50' if pal else '60000/1001'
    else:
        frames = []
        for k in range(0, len(fl) - 1, 2):
            (a, pa), (b, _) = fl[k], fl[k + 1]
            top, bot = (b, a) if pa else (a, b)          # parity 0: this field holds the top lines
            f = np.empty((a.shape[0] * 2, a.shape[1], 3), np.uint8)
            f[0::2], f[1::2] = top, bot
            frames.append(f)
        rate = '25' if pal else '30000/1001'
    h, w = frames[0].shape[:2]
    print(f'{len(recs)} fields ({"PAL" if pal else "NTSC"}), {len(frames)} frames of {w} x {h} at {rate} fps')
    dst = Path(args[1])
    if dst.suffix == '':
        dst.mkdir(parents=True, exist_ok=True)
        for k, f in enumerate(frames):
            Image.fromarray(f).save(dst / f'{k:06d}.png')
        return
    p = subprocess.Popen(['ffmpeg', '-y', '-loglevel', 'error', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', f'{w}x{h}',
                          '-r', rate, '-i', '-', '-vf', 'setdar=4/3', '-pix_fmt', 'yuv420p', '-c:v', 'libx264', '-crf', '17',
                          str(dst)], stdin=subprocess.PIPE)
    for f in frames:
        p.stdin.write(f.tobytes())
    p.stdin.close()
    sys.exit(p.wait())


if __name__ == '__main__':
    main()
