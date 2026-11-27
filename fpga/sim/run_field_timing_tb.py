"""Field-grid and free-running HDMI regressions, including crystal offsets."""
from pathlib import Path
import subprocess
import tempfile

import rtl

HERE = Path(__file__).resolve().parent


def main():
    with tempfile.TemporaryDirectory() as tmp:
        target = str(Path(tmp) / "sim")

        def run(top, options, *sources):
            subprocess.run(["iverilog", "-g2012", *rtl.inc(), *options, "-s", top, "-o", target,
                            str(HERE / f"{top}.v"), *rtl.src(*sources)], check=True)
            subprocess.run(["vvp", "-n", target], check=True)

        run("tb_field_grid", ["-DTRI_DEBUG"], "vid_sync.v")   # DEBUG: the fields-a-second counters too
        for ppm in (200, -200):
            run("tb_hdmi_cadence", ["-DTRI_HDMI", "-DTRI_HMAPCALC", f"-Ptb_hdmi_cadence.PPM={ppm}"], "lcd_out.v")


if __name__ == "__main__":
    main()
