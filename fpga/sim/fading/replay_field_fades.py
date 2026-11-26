"""10 ms fade across vertical sync, from synthetic IQ through demod to receive-field RTL."""
import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import subprocess
import sys
import tempfile

import numpy as np
from scipy import signal as sg

import compare_d3 as bench

SIMDIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SIMDIR))
import rtl  # noqa: E402


def run_case(args):
    standard, kind, keep, fade_start_ms = args
    sim, mrc, d3 = bench.SIM, bench.mrc, bench.d3
    nfield = 800000 if standard == "PAL" else 667333
    ire, region = sim.raster(standard, 875, 8)
    # Deep attenuation around the first broad pulse of field six. Generate
    # the same IQ for both demod options and both Keep Lock settings.
    rng = np.random.default_rng(875)
    freq = sim.PORCH_HZ + .7 * sg.lfilter(sg.firwin(81, 6e6, fs=80e6), 1, np.repeat(ire, 2)) / 140 * sim.DEV_PP
    wave = sg.sosfilt(sim.CHAN, np.exp(2j * np.pi * np.cumsum(freq) / 80e6))[::2]
    wave /= np.sqrt(np.mean(np.abs(wave)**2))
    fade_start = 6 * nfield + round(fade_start_ms * 40_000)
    wave[fade_start:fade_start + 400000] = 0
    noise = sg.sosfilt(sim.CHAN, rng.normal(size=2 * len(ire)) + 1j * rng.normal(size=2 * len(ire)))[::2]
    noise /= np.sqrt(np.mean(np.abs(noise)**2))
    raw = mrc.to_raw3((wave + .035 * noise) * 6)
    code, phi = mrc.run([raw], disc=True, return_phi=True, rescue=1)
    if kind == "d3":
        valid = np.ones(len(code), np.bool_)
        click, steady = d3.evidence(phi, valid)
        code, _ = d3.estimate(phi, valid, click, steady)
    with tempfile.TemporaryDirectory() as temp:
        p = Path(temp)
        code_ascii = np.array([f"{v:02x}\n" for v in range(64)], dtype="S3")
        (p / "video.hex").write_bytes(code_ascii[code].tobytes())
        subprocess.run(["iverilog", "-g2012", *rtl.inc(), "-s", "tb_cvbs_fields", "-o", str(p / "tb"),
                        str(SIMDIR / "tb_cvbs_fields.v"), *rtl.src("vid_sync.v")], check=True)
        text = subprocess.run(["vvp", "-n", str(p / "tb"), f"+n={len(code)}", f"+keep={keep}"],
                              cwd=p, capture_output=True, text=True, check=True).stdout
    events = np.array([tuple(map(int, line.split()[1:])) for line in text.splitlines() if line.startswith("field ")])
    # Measure once the PAL detector has three clean intervals.
    measured = events[events[:, 0] > 5 * nfield + 12000]
    assert len(measured) >= 2, (args, events)
    assert np.all(measured[:, 1] == (standard == "PAL")), (args, events)
    delta = np.diff(measured[:, 0]) - nfield
    assert np.all(np.abs(delta) <= 6005), (args, events)
    assert np.any(measured[:, 2]), (args, events)
    print(f"{standard} {kind} KeepLock={keep} fade={fade_start_ms:+g} ms: "
          f"{len(measured)} fields, {np.sum(measured[:, 2] == 0)} held over, "
          f"max interval error {max(abs(delta)) / 40:.2f} us", flush=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--jobs", type=int, default=2)
    p.add_argument("--standards", choices=("NTSC", "PAL"), nargs="+", default=["NTSC", "PAL"])
    p.add_argument("--modes", choices=("auto", "d3"), nargs="+", default=["auto", "d3"])
    p.add_argument("--keep", type=int, choices=(0, 1), nargs="+", default=[0, 1])
    p.add_argument("--start-ms", type=float, nargs="+", default=[-5])
    args = p.parse_args()
    cases = [(s, m, k, start) for s in args.standards for m in args.modes for k in args.keep for start in args.start_ms]
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        list(pool.map(run_case, cases))


if __name__ == "__main__":
    main()
