"""Compare the fixed-point RTL phase estimator and confidence with its model."""
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

import rtl

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "model"))
from d3_model import estimate, evidence  # noqa: E402


def main():
    n = 22000
    rng = np.random.default_rng(2026)
    k = np.arange(n)
    phi = (np.cumsum(5012 + 2400 * np.sin(k * .177)).astype(np.int64) & 65535) ^ 32768
    phi[2000:2200] = rng.integers(0, 65536, 200)
    phi[3900:7800] = rng.integers(0, 65536, 3900)
    phi[17000:17400] = rng.integers(0, 65536, 400)
    valid = np.ones(n, dtype=bool)
    valid[1600:1605] = valid[6000:6008] = valid[7011:7020] = valid[9601:9850] = False
    click, _ = evidence(phi, valid)
    steady = (k >= 12000) & (k < 14300)
    expected_code, expected_level = estimate(phi, valid, click, steady)
    words = phi | valid.astype(int) << 16 | click.astype(int) << 17 | steady.astype(int) << 18
    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        (work / "d3.hex").write_text("".join(f"{v:05x}\n" for v in words))
        subprocess.run(["iverilog", "-g2012", *rtl.inc(), "-s", "tb_d3", "-o", str(work / "tb"),
                        str(HERE / "tb_d3.v"), *rtl.src("mrc3_core.v", "mul_dsp.v")], check=True)
        result = subprocess.run(["vvp", "-n", str(work / "tb"), f"+n={n}"], cwd=work,
                                capture_output=True, text=True, check=True)
    actual = np.array([int(line, 16) for line in result.stdout.splitlines() if len(line) == 2])
    expected = expected_code.astype(int) | expected_level.astype(int) << 6
    mismatch = np.flatnonzero(actual != expected)
    assert not len(mismatch), f"{len(mismatch)} mismatches, first at {mismatch[0]}"
    assert np.all((actual[9610:9850] & 63) == 25)
    assert set(actual >> 6) == {0, 1, 2, 3}
    print(f"D3 code and confidence bit-exact across {n} samples")


if __name__ == "__main__":
    main()
