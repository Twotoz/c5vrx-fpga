#!/usr/bin/env python3
"""Triversity link log: the "TRIL" records in TRIDVR.BIN (fpga/rtl/io/dvr_hq.v,
menu Record: On = video + log, Log = log only) to CSV, one row every sixth
video field (0.1 s NTSC, 0.12 s PAL).

Record (25 bytes, little-endian):
   0  "TRIL"
   4  log number (16 bit, +1 per record)
   6  video field number (the HQ DVR's JPEG records, tools/hqdvr_to_mp4.py)
   8  weight in use A, B, C (8 bit each)
  11  flags: bit 0 PAL, 1 sync locked, 2 B enabled (aligned), 3 C enabled,
      4 B alive, 5 C alive, 6 Rescue PLL in use
  12  sync quality (in-window sync edges in the last 100 ms, 16 bit)
  14  channel index (bits 0..5), Noise filter level 0..3 (bits 6..7)
  15  Signal switches (bit 0 Keep lock, 2 Adaptive sync, 3..4 Rescue 0 Off
      1 Auto 2 On, 5 Noise filter),
      mode (bits 6..7: 0 Single, 1 Diversity, 2 Triversity)
  16  per C5 A, B, C three bytes, the newest marker values (c5/main/fpga_link.h):
      C/N x10 + 1000 (12 bits, 0 unknown), flags bits 0..3 (AFC locked,
      video, busy, DC fault; 4 bits), signal 0..100 (8 bits)

The file is a ring: records are put in log-number order, the oldest first.

    python tools/trilog.py /media/TF/TRIDVR.BIN log.csv
    python tools/trilog.py TRIDVR.BIN log.csv --plot log.png     (needs matplotlib)
"""
import csv, struct, sys
from pathlib import Path

SIZE = 25
SW = ['keep_lock', None, 'adaptive_sync', None, None, 'noise_filter']
RESCUE = ['Off', 'Auto', 'On', 'On']


def records(data):
    data = bytes(data) + bytes(data[:SIZE])              # a record may wrap round the end of the file
    n = len(data) - SIZE
    out, i = {}, 0
    while True:
        i = data.find(b'TRIL', i)
        if i < 0 or i >= n:
            break
        r = data[i:i + SIZE]
        num, vid = struct.unpack_from('<HH', r, 4)
        w = r[8:11]; fl = r[11]; sq = struct.unpack_from('<H', r, 12)[0]; chn = r[14]; sw = r[15]
        row = dict(log=num, video_field=vid, pal=fl & 1, locked=fl >> 1 & 1, sync_q=sq,
                   channel=chn & 63, noise_level=chn >> 6, mode=['Single', 'Diversity', 'Triversity', '?'][sw >> 6])
        row.update({s: sw >> k & 1 for k, s in enumerate(SW) if s})
        row.update(rescue=RESCUE[sw >> 3 & 3], rescue_active=fl >> 6 & 1)
        for b, name in enumerate('ABC'):
            v = int.from_bytes(r[16 + 3 * b:19 + 3 * b], 'little')
            cn, flags, sig = v & 4095, v >> 12 & 15, v >> 16
            row[f'{name}_weight'] = w[b]
            row[f'{name}_cn_db'] = round((cn - 1000) / 10, 1) if cn else ''
            row[f'{name}_signal'] = sig
            row[f'{name}_afc_locked'] = flags & 1
            row[f'{name}_video'] = flags >> 1 & 1
            if name != 'A':
                row[f'{name}_enabled'] = fl >> (2 if name == 'B' else 3) & 1
                row[f'{name}_alive'] = fl >> (4 if name == 'B' else 5) & 1
        out[num] = row
        i += SIZE
    if not out:
        return []
    nums = sorted(out)
    gaps = [(nums[(k + 1) % len(nums)] - nums[k]) % 65536 for k in range(len(nums))]
    s = (max(range(len(gaps)), key=gaps.__getitem__) + 1) % len(nums)
    rows = [out[k] for k in nums[s:] + nums[:s]]
    for k, r in enumerate(rows):
        r['t_s'] = round(((r['log'] - rows[0]['log']) % 65536) * (0.12 if r['pal'] else 0.1001), 2)
    return rows


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    rows = records(Path(sys.argv[1]).read_bytes())
    if not rows:
        sys.exit('no log records in the file')
    keys = ['t_s'] + [k for k in rows[0] if k != 't_s']
    with open(sys.argv[2], 'w', newline='') as f:
        wr = csv.DictWriter(f, keys); wr.writeheader(); wr.writerows(rows)
    print(f'{len(rows)} records, {rows[-1]["t_s"]:.1f} s -> {sys.argv[2]}')
    if '--plot' in sys.argv:
        import matplotlib; matplotlib.use('Agg')
        import matplotlib.pyplot as plt
        t = [r['t_s'] for r in rows]
        fig, ax = plt.subplots(3, 1, sharex=True, figsize=(12, 7))
        for b in 'ABC':
            ax[0].plot(t, [r[f'{b}_cn_db'] if r[f'{b}_cn_db'] != '' else float('nan') for r in rows], label=f'C5 {b}')
            ax[1].plot(t, [r[f'{b}_weight'] for r in rows], label=f'C5 {b}')
        ax[0].set_ylabel('C/N dB'); ax[0].legend(); ax[1].set_ylabel('weight')
        ax[2].plot(t, [r['sync_q'] for r in rows], label='sync quality')
        ax[2].plot(t, [0 if r['locked'] else -1 for r in rows], label='lock lost', color='red')
        ax[2].set_xlabel('s'); ax[2].legend()
        fig.tight_layout(); fig.savefig(sys.argv[sys.argv.index('--plot') + 1])


if __name__ == '__main__':
    main()
