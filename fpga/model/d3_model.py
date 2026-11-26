"""Fixed-point causal D3 estimator used by fpga/rtl/rx/mrc3_core.v."""
import numpy as np
from numba import njit


@njit(cache=True)
def dac(step):
    step = min(511, max(-512, step))
    if not -312 <= step <= 384:
        step = (179 * step) >> 8
    cy = (105 * step + 32896) >> 8
    return min(63, max(0, (cy * 205) >> 10))


@njit(cache=True)
def estimate(phi, valid, clicks, steady):
    """40 MS/s, first sample even. Outputs include the synchronous DAC ROM."""
    out = np.full(len(phi), 25, np.uint8)
    levels = np.zeros(len(phi), np.uint8)
    buckets = np.zeros(4, np.int64)
    pos = 0
    bad = 0
    theta = freq = last_advance = even_step = step = fresh = 0
    missed = 9
    for k in range(len(phi)):
        out[k] = dac(step)
        gain_bad = bad >> 6
        count = np.sum(buckets)
        target = 4096 if steady[k] or count >= 4 else count * 1024
        if target > bad:
            bad += (target - bad + 63) >> 6
        elif target < bad:
            bad -= (bad - target + 255) >> 8
        gain_next = bad >> 6
        levels[k] = 3 if gain_next >= 56 else 2 if gain_next >= 32 else 1 if gain_next >= 12 else 0
        if k % 2 == 0:
            buckets[0] = min(4, buckets[0] + clicks[k])
            pos = (pos + 1) & 511
            if pos == 0:
                buckets[3], buckets[2], buckets[1], buckets[0] = buckets[2], buckets[1], buckets[0], 0
        if not valid[k]:
            fresh = 0
            if missed < 8:
                theta = (theta + freq) & 65535
                step = freq >> 5
            else:
                step = 0
            missed = min(9, missed + 1)
            continue
        if missed == 9:
            theta = phi[k] & 65535
            freq = last_advance = step = 0
            missed, fresh = 0, 1
            continue
        missed = 0
        innovation = ((phi[k] - theta + 32768) & 65535) - 32768
        scaled = innovation * gain_bad
        advance = freq + innovation - 3 * (scaled >> 8)
        theta = (theta + advance) & 65535
        freq = max(-8192, min(8192, freq + ((scaled + 4096) >> 13)))
        pair_step = (advance + last_advance) >> 6
        last_advance = advance
        if fresh == 0:
            even_step, step = pair_step, 0
        elif k % 2 == 0:
            even_step = step = pair_step
        elif fresh >= 2:
            delta = pair_step - even_step
            correction = (delta if gain_bad >= 56 else (delta >> 1) + (delta >> 2) if gain_bad >= 40
                          else delta >> 1 if gain_bad >= 24 else delta >> 2 if gain_bad >= 8 else 0)
            step = even_step + correction
        fresh = min(3, fresh + 1)
    return out, levels


@njit(cache=True)
def evidence(phi, valid):
    """Causal D32 innovation and PR #7 steady-click occupancy on phase samples."""
    clicks = np.zeros(len(phi), np.bool_)
    steady = np.zeros(len(phi), np.bool_)
    tracker = (phi[0] >> 6) ^ 512
    occupied = False
    count = 0
    on = False
    for k in range(len(phi)):
        steady[k] = on
        if k % 2:
            continue
        d = (((phi[k] >> 6) ^ 512) - tracker + 512) % 1024 - 512
        click = d < -312 or d > 384
        clicks[k] = click and valid[k]
        tracker = (tracker + ((179 * d) >> 8 if click else d)) % 1024
        occupied |= click
        if k != 0 and (k // 2) % 4096 == 4095:
            count += occupied
            occupied = False
            if (k // 8192) % 64 == 63:
                on = count >= 48
                count = 0
    return clicks, steady
