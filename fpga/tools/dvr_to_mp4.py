#!/usr/bin/env python3
"""Triversity DVR: TRIDVR.BIN (fpga/rtl/dvr.v) to a video file.

The FPGA writes the file as a ring of frames, each 95 sectors: a 512-byte
header ("TRIDVR01", frame number, 400, 240, PAL, 4 bits), 48000 bytes of
4-bit gray (two pixels per byte, low nibble first), padding, and in its last
two bytes the number of pixel bytes stored (an overflowed frame is short: the
previous frame is repeated; a dropped frame leaves a gap in the numbers and
is filled the same way). Frames are found by their header on any sector
(also one wrapping round the end of the file) and put in frame-number order, so the oldest recording comes first.

    python fpga/tools/dvr_to_mp4.py /media/TF/TRIDVR.BIN out.mp4   (needs ffmpeg)
    python fpga/tools/dvr_to_mp4.py TRIDVR.BIN frames/              (PNG per frame)
"""
import subprocess, sys
from pathlib import Path
import numpy as np

SECT, FRAME_SECT, W, H = 512, 95, 400, 240
PIX = W * H // 2


def frames(data):
    """[(number, pal, image uint8 HxW or None if short)] in recording order."""
    out = []
    n = len(data) // SECT
    data = bytes(data[:n * SECT]) + bytes(data[:FRAME_SECT * SECT])   # a frame can wrap round the file end
    for s in range(n):
        o = s * SECT
        if data[o:o + 8] != b'TRIDVR01':
            continue
        num = data[o + 8] | data[o + 9] << 8
        pal = data[o + 14] & 1
        end = o + FRAME_SECT * SECT
        stored = data[end - 2] | data[end - 1] << 8
        px = np.frombuffer(data[o + SECT:o + SECT + PIX], np.uint8)
        img = None
        if stored == PIX:
            img = np.empty(W * H, np.uint8)
            img[0::2] = px & 15
            img[1::2] = px >> 4
            img = (img.reshape(H, W) * 17).astype(np.uint8)
        out.append((num, pal, img))
    if not out:
        return out
    # 16-bit frame numbers wrap: order from the largest gap (the ring's write point)
    out.sort(key=lambda f: f[0])
    nums = [f[0] for f in out]
    gaps = [(nums[(i + 1) % len(nums)] - nums[i]) % 65536 for i in range(len(nums))]
    start = (int(np.argmax(gaps)) + 1) % len(out)
    return out[start:] + out[:start]


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, dst = Path(sys.argv[1]), Path(sys.argv[2])
    fr = frames(src.read_bytes())
    if not fr:
        sys.exit('no frames found')
    pal = fr[0][1]
    imgs, last = [], np.zeros((H, W), np.uint8)
    for i, (num, _, img) in enumerate(fr):
        gap = (num - fr[i - 1][0]) % 65536 if i else 1
        imgs += [last] * (gap - 1 if gap < 100 else 0)    # dropped frames: hold the last one, keep the timing
        last = img if img is not None else last
        imgs.append(last)
    short = sum(f[2] is None for f in fr)
    print(f'{len(fr)} frames ({"PAL 25" if pal else "NTSC 29.97"} fps), {short} short, numbers {fr[0][0]}..{fr[-1][0]}')
    if dst.suffix == '':
        from PIL import Image
        dst.mkdir(parents=True, exist_ok=True)
        for i, img in enumerate(imgs):
            Image.fromarray(img).resize((640, 480), Image.NEAREST).save(dst / f'{i:06d}.png')
        return
    rate = '25' if pal else '30000/1001'
    p = subprocess.Popen(['ffmpeg', '-y', '-loglevel', 'error', '-f', 'rawvideo', '-pix_fmt', 'gray', '-s', f'{W}x{H}',
                          '-r', rate, '-i', '-', '-vf', 'scale=640:480:flags=bicubic', '-pix_fmt', 'yuv420p',
                          '-c:v', 'libx264', '-crf', '18', str(dst)], stdin=subprocess.PIPE)
    for img in imgs:
        p.stdin.write(img.tobytes())
    p.stdin.close()
    sys.exit(p.wait())


if __name__ == '__main__':
    main()
