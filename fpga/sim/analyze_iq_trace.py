"""Read IQTRACE snapshots and estimate relative lag and carrier offset."""
import argparse
from pathlib import Path
import re
import time

import numpy as np


HEADER = re.compile(rb'\xa5\x5aI[QRS]')
SAMPLES = 4096
FS = 40_000_000
FFT_SIZE = 4 * SAMPLES
SEARCH_HZ = 2_500_000
MAX_LAG = 64
TRACK_BLOCK = 32


def trace_packets(data):
    size = SAMPLES * 3
    cursor = 0
    while header := HEADER.search(data, cursor):
        start = header.end()
        status = fusion = None
        version = data[start - 1]
        if version != ord('Q'):
            status = int.from_bytes(data[start:start + 4], 'little')
            start += 4
        if version == ord('S'):
            fusion = int.from_bytes(data[start:start + 4], 'little')
            start += 4
        cursor = start + size
        if cursor > len(data):
            return
        yield status, fusion, np.frombuffer(data[start:cursor], dtype=np.uint8).reshape(SAMPLES, 3)


def packets(data):
    for status, _, frame in trace_packets(data):
        yield status, frame


def frames(data):
    for _, frame in packets(data):
        yield frame


def field_status(status):
    return (status >> 24, (status >> 16) & 255, (status >> 12) & 15,
            bool(status & 2048), bool(status & 1024), ((status & 1023) ^ 512) - 512)


def collect(port, count):
    import serial

    uart = serial.Serial(baudrate=1_000_000, timeout=0.25)
    uart.port = port
    uart.dtr = False
    uart.rts = False
    data = bytearray()
    deadline = time.monotonic() + count * 1.5 + 3
    with uart:
        while time.monotonic() < deadline:
            data += uart.read(4096)
            if sum(1 for _ in frames(data)) >= count:
                break
    return bytes(data)


def decode(frame):
    i = ((frame >> 3) & 7).astype(np.int8)
    q = (frame & 7).astype(np.int8)
    return ((i ^ 4) - 4 + 0.5) + 1j * ((q ^ 4) - 4 + 0.5)


def centered_pair(a, b, valid):
    if np.count_nonzero(valid) < SAMPLES // 2:
        return None
    a = np.where(valid, a - np.mean(a[valid]), 0)
    b = np.where(valid, b - np.mean(b[valid]), 0)
    norm = np.linalg.norm(a) * np.linalg.norm(b)
    return (a.conj() * b, norm) if norm > 0 else None


def correlation(a, b, valid):
    """Cross correlation at one lag, before and after carrier correction."""
    pair = centered_pair(a, b, valid)
    if pair is None:
        return 0., 0., 0.
    product, norm = pair
    spectrum = np.abs(np.fft.fftshift(np.fft.fft(product, FFT_SIZE)))
    center = FFT_SIZE // 2
    bins = int(SEARCH_HZ * FFT_SIZE / FS)
    lo, hi = center - bins, center + bins + 1
    peak = lo + np.argmax(spectrum[lo:hi])
    return spectrum[peak] / norm, (peak - center) * FS / FFT_SIZE, spectrum[center] / norm


def lag_pairs(a, b, va, vb):
    center = slice(MAX_LAG, -MAX_LAG)
    for lag in range(-MAX_LAG, MAX_LAG + 1):
        other = slice(MAX_LAG + lag, len(b) - MAX_LAG + lag)
        yield lag, a[center], b[other], va[center] & vb[other]


def alignment(a, b, va, vb):
    """Positive lag means B's matching sample appears later in the capture."""
    scores = [(*correlation(x, y, valid), lag) for lag, x, y, valid in lag_pairs(a, b, va, vb)]
    return scores[MAX_LAG], max(scores, key=lambda score: score[0])


def block_alignment(a, b, va, vb):
    """Prototype a lag and carrier tracker using short cross-product sums."""
    best_score = 0.
    best_pair = None
    for lag, x, y, valid in lag_pairs(a, b, va, vb):
        pair = centered_pair(x, y, valid)
        if pair is None:
            continue
        product, norm = pair
        sums = product.reshape(-1, TRACK_BLOCK).sum(axis=1)
        score = np.abs(sums).sum() / norm
        if score > best_score:
            best_score = score
            best_pair = lag, product, norm, sums, valid
    if best_pair is None:
        return None
    lag, product, norm, sums, valid = best_pair
    good = valid.reshape(-1, TRACK_BLOCK).sum(axis=1) >= 26
    adjacent = good[:-1] & good[1:]
    rate = np.angle(np.vdot(sums[:-1][adjacent], sums[1:][adjacent])) / TRACK_BLOCK
    n = np.arange(len(product))
    residual = (product * np.exp(-1j * rate * n)).reshape(-1, TRACK_BLOCK).sum(axis=1)
    span = 4
    distant = good[:-span] & good[span:]
    rate += np.angle(np.vdot(residual[:-span][distant], residual[span:][distant])) / (span * TRACK_BLOCK)
    corrected = abs(np.sum(product * np.exp(-1j * rate * n))) / norm
    return lag, rate * FS / (2 * np.pi), corrected


def report(n, frame, prototype=False):
    iq, valid = decode(frame), (frame & 0x40) != 0
    gates = (frame & 0x80) != 0
    print(f'#{n}  B gate={gates[:, 0].mean():.0%}  C gate={gates[:, 1].mean():.0%}'
          f'  A fade={gates[:, 2].mean():.0%}')
    for j, name in enumerate('BC', 1):
        now, best = alignment(iq[:, 0], iq[:, j], valid[:, 0], valid[:, j])
        print(f'  {name}: lag0 corr={now[2]:.2f}, with carrier correction={now[0]:.2f}'
              f'  |  best lag={best[3]:+d} corr={best[0]:.2f} (raw {best[2]:.2f})'
              f'  {best[1] / 1000:+.1f} kHz vs A')
        if prototype:
            tracked = block_alignment(iq[:, 0], iq[:, j], valid[:, 0], valid[:, j])
            if tracked:
                lag, cfo, corrected = tracked
                print(f'  {name} prototype: lag={lag:+d} CFO={cfo / 1000:+.1f} kHz corr={corrected:.2f}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument('--port')
    source.add_argument('--input', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--frames', type=int, default=8)
    parser.add_argument('--prototype', action='store_true', help='also try a 32-sample block tracker')
    opts = parser.parse_args()
    if opts.frames < 1:
        parser.error('--frames must be positive')
    data = opts.input.read_bytes() if opts.input else collect(opts.port, opts.frames)
    if opts.output:
        opts.output.write_bytes(data)
    captures = list(trace_packets(data))
    if not captures:
        parser.exit(1, f'No complete IQ frames in {len(data)} bytes.\n')
    previous = None
    for n, (status, fusion, frame) in enumerate(captures[:opts.frames], 1):
        if status is not None:
            real, coast, anchors, locked, pal, error = field_status(status)
            if previous is not None:
                delta = (real - previous[0]) & 255, (coast - previous[1]) & 255, (anchors - previous[2]) & 15
                print(f'  V lock={int(locked)} PAL={int(pal)} real={delta[0]} predicted={delta[1]}'
                      f' reanchors={delta[2]}  last error={error:+d} samples')
            previous = real, coast, anchors
        if fusion is not None:
            mode = (fusion >> 24) & 3
            weights = tuple((fusion >> (i * 8)) & 255 for i in range(3))
            print(f'  mode={mode} effective weights A/B/C={weights[0]}/{weights[1]}/{weights[2]}')
        report(n, frame, opts.prototype)


if __name__ == '__main__':
    main()
