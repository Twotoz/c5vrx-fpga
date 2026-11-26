"""Repeatable, matched-IQ SINAD and sync comparison for experimental fixed-point D3.

    C5VRX_RESEARCH=/path/to/C5VRX/research python fpga/sim/fading/compare_d3.py
"""
import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import sys

import numpy as np
from scipy import signal as sg

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "model"))
import chroma_model as cv  # noqa: E402
import d3_model as d3  # noqa: E402
import eval3  # noqa: E402
import mrc3_model as mrc  # noqa: E402

SIM = eval3.E.sim


def score(codes, truth, region, calibration, standard):
    demod = SIM.apply_cal(SIM.video_out(codes), calibration)
    active = region == 1
    active[:3000] = active[-3000:] = False
    error = demod[active] - truth[active]
    sinad = 10 * np.log10(np.var(truth[active]) / np.mean(error ** 2))
    lock = min(SIM.goggle(demod, truth, standard, agc=agc) for agc in ("ideal", "peak"))
    return sinad, lock


def trial(case):
    standard, cn, doppler, seed = case
    ire, region = cv.source(standard, cv.test_picture(240), fields=3, seed=seed)
    src = sg.lfilter(sg.firwin(81, 6e6, fs=80e6), 1, np.repeat(ire, 2))
    fm = SIM.PORCH_HZ + .7 * src / 140 * SIM.DEV_PP
    radio = sg.sosfilt(SIM.CHAN, np.exp(2j * np.pi * np.cumsum(fm) / 80e6))
    radio /= np.sqrt(np.mean(np.abs(radio) ** 2))
    noisy, clean = eval3.branch_y(radio, cn, np.random.default_rng(seed), doppler)
    valid = np.ones(len(ire), np.bool_)
    auto, phase = mrc.run([mrc.to_raw3(noisy)], disc=True, return_phi=True, rescue=1)
    clicks, steady = d3.evidence(phase, valid)
    causal, _ = d3.estimate(phase, valid, clicks, steady)
    # Model Rescue Auto is already aligned to source (its hardware delay is
    # omitted here); D3 is advanced by one sample for a common group delay.
    causal = np.roll(causal, 1)
    ideal = mrc.run([mrc.to_raw3(clean)], disc=True, rescue=0)
    scope = slice(len(ire) // 3, -3000)
    truth = sg.sosfilt(SIM.GOGGLE, ire)[scope]
    region = region[scope]
    calibration = SIM.calibrate(SIM.video_out(ideal[scope]), truth, region)
    ref = score(auto[scope], truth, region, calibration, standard)
    new = score(causal[scope], truth, region, calibration, standard)
    return case, ref, new


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--jobs", type=int, default=2)
    p.add_argument("--seeds", type=int, nargs="+", default=[11, 23])
    args = p.parse_args()
    cases = [(standard, cn, fd, seed)
             for standard in ("NTSC", "PAL")
             for cn, fd in [(30, 0), (6, 0), *((cn, fd) for cn in (14, 20) for fd in (30, 100, 300))]
             for seed in args.seeds]
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        results = list(pool.map(trial, cases))
    print("standard,cn_db,doppler_hz,seed,rescue_sinad_db,d3_sinad_db,delta_db,rescue_lock,d3_lock")
    for (standard, cn, fd, seed), (ref, lock0), (new, lock1) in results:
        print(f"{standard},{cn},{fd},{seed},{ref:.3f},{new:.3f},{new-ref:+.3f},{lock0:.4f},{lock1:.4f}")


if __name__ == "__main__":
    main()
