#!/usr/bin/env python3
"""Triversity DVR: create TRIDVR.BIN on a TF card for the FPGA (fpga/rtl/io/dvr_hq.v, dvr.v).

The FPGA finds TRIDVR.BIN by its first sector ("TRIDVR-FILE-0001" and the
number of sectors after it), searching the first 64 MB of the card, and
records into the rest as a ring, without reading the FAT: the file must be
one contiguous run of clusters. Format the card FAT32 first (cards up to 32 GB; a larger
card needs a FAT32 tool) and run this before copying anything else onto it.
The script writes the file in large blocks and checks on Linux (filefrag)
that it is contiguous when it can.

One minute of recording is about 88 MB (HQ DVR, ~1.5 MB/s; the grey DVR
87 MB); the default 3900 MB holds about 44 minutes, then the oldest part is
overwritten.

    python fpga/tools/make_dvr_file.py /media/TF            [size in MB, default 3900]
"""
import os, struct, subprocess, sys
from pathlib import Path

FRAME = 95 * 512


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    root = Path(sys.argv[1])
    mb = int(sys.argv[2]) if len(sys.argv) == 3 else 3900
    size = min(mb * 1024 * 1024, 0xFFFFFFFF) // FRAME * FRAME     # whole frames, FAT32 file limit
    path = root / 'TRIDVR.BIN'
    others = [p.name for p in root.iterdir() if p.name != 'TRIDVR.BIN' and not p.name.startswith(('.', 'System Volume'))]
    if others:
        print(f'warning: {root} is not empty ({", ".join(others[:5])}); on a fresh card the file is contiguous for sure')
    block = b'\0' * (8 * 1024 * 1024)
    with open(path, 'wb') as f:
        f.write((b'TRIDVR-FILE-0001' + struct.pack('<I', size // 512)).ljust(512, b'\0'))   # header sector
        left = size
        while left:
            n = min(left, len(block))
            f.write(block[:n])
            left -= n
            print(f'\r{(size - left) >> 20} / {size >> 20} MB', end='', flush=True)
        f.flush()
        os.fsync(f.fileno())
    print(f'\n{path}: {size + 512} bytes, {size // FRAME} frames, about {size // FRAME / 29.97 / 60:.0f} min NTSC')
    try:
        out = subprocess.run(['filefrag', str(path)], capture_output=True, text=True, check=True).stdout
        n = int(out.split(':')[1].split()[0])
        print('contiguous: OK' if n == 1 else f'NOT contiguous ({n} extents): reformat the card and run this first')
        sys.exit(0 if n == 1 else 1)
    except (OSError, subprocess.CalledProcessError, ValueError, IndexError):
        print('(contiguity not checked: no filefrag; a freshly formatted card gives one run)')


if __name__ == '__main__':
    main()
