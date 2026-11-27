"""Compare A-only fading with and without alignment-independent failover."""
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from scipy.signal import lfilter

import rtl

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "model"))
import mrc3_model  # noqa: E402

FS = 40_000_000


def inputs():
    rng = np.random.default_rng(943)
    k = np.arange(360_000)
    # FM with video-rate detail and a slowly shifting pedestal. B/C are
    # offset by different integer delays, plus independent LO phase/drift.
    fm = 3e6 + 1.4e6 * np.sin(k * .031) + .45e6 * np.sin(k * .59)
    phase = 2 * np.pi * np.cumsum(fm) / FS
    waves = []
    # Same nominal power during a fade: amplitude-only gating cannot pass.
    for index, (delay, cfo) in enumerate([(31, 0), (14, 2500), (10, -3500)]):
        carrier = np.exp(1j * (np.roll(phase, -delay) + .8 * index + 2 * np.pi * cfo * k / FS))
        noise = lfilter([.15, .35, .35, .15], [1],
                        rng.normal(size=len(k)) + 1j * rng.normal(size=len(k)))
        noise /= np.sqrt(np.mean(np.abs(noise) ** 2))
        z = carrier + .12 * noise
        window = (slice(165_000, 245_000), slice(280_000, 306_000), slice(322_000, 348_000))[index]
        z[window] = noise[window]
        waves.append(mrc3_model.to_raw3(6 * z).astype(np.int64))
    valid = np.full(len(k), 7)
    valid[156_000:156_480] &= 6        # a 12 us in-band status marker on A
    valid[202_000:202_480] &= 5        # a B marker during the 2 ms A-only RF fade
    return fm, valid << 18 | waves[2] << 12 | waves[1] << 6 | waves[0]


def rtl_run(work, n, enabled):
    exe = work / f"tb{enabled}"
    subprocess.run(["iverilog", "-g2012", *rtl.inc(), "-s", "tb_fade_failover",
                    f"-Ptb_fade_failover.FAILOVER={enabled}", "-o", str(exe),
                    str(HERE / "tb_fade_failover.v"), *rtl.src("align_bc.v", "mrc3_core.v",
                                                             "cordic_angle.v", "cordic_iter.v", "mul_dsp.v")], check=True)
    result = subprocess.run(["vvp", "-n", str(exe), f"+n={n}"], cwd=work, check=True,
                            text=True, capture_output=True)
    samples = [line for line in result.stdout.splitlines() if len(line) == 3]
    assert len(samples) == n
    assert all("x" not in line.lower() for line in samples[4096:]), "undefined steady-state FPGA output"
    return np.array([int(line, 16) if "x" not in line.lower() else 0 for line in samples])


def main():
    fm, iq = inputs()
    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        (work / "fade.hex").write_text("".join(f"{v:06x}\n" for v in iq))
        before = rtl_run(work, len(iq), 0)
        after = rtl_run(work, len(iq), 1)
    source = after >> 6 & 3
    start, end = 165_000, 245_000
    settled = slice(start + 5000, end - 5000)
    baseline_alignment = np.mean((before[settled] >> 8) != 0)
    backup = np.mean(source[settled] != 0)
    assert baseline_alignment < .10, baseline_alignment
    assert backup > .99, backup
    assert np.all(source[202_020:202_460] == 2)
    first = np.flatnonzero(source[start:end] != 0)[0]
    restore = np.flatnonzero(source[end:280_000] == 0)[0]
    assert first < 2400 and restore < 2400, (first, restore)
    assert np.mean((before[140_000:155_000] >> 8) == 3) > .95
    assert not np.any(source[140_000:155_000])
    assert not np.any(source[282_000:304_000])
    assert not np.any(source[324_000:346_000])

    # Compare filtered video to the known FM source with latency accounted
    # for. Both epochs share the calibration measured before the fade.
    expected = lfilter(np.ones(8) / 8, [1], 25.5 + fm / 1e6 * 4.2)
    expected = np.roll(expected, 2048 - 31 + 20)
    active = slice(start + 3000, end - 3000)
    def rmse(words):
        y = lfilter(np.ones(8) / 8, [1], words & 63)
        # FIFO lag of the selected backup can differ by a few 25 ns samples.
        return min(np.sqrt(np.mean((y[active] - np.roll(expected, delay)[active]) ** 2))
                   for delay in range(-10, 11))

    old_error, new_error = rmse(before), rmse(after)
    assert new_error < old_error * .5, (old_error, new_error)
    print(f"A fade: A alignment available {baseline_alignment:.1%}, backup available {backup:.1%}; "
          f"first backup {first / 40:.1f} us, return to A {restore / 40:.1f} us")
    print(f"Filtered video RMSE {old_error:.2f} -> {new_error:.2f} DAC codes")


if __name__ == "__main__":
    main()
