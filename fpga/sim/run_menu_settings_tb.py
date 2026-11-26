"""Triversity: the menu's stored settings (tb_menu_settings.v): markers 7 / 8
from the C5s load the menu once, the 'S' / 'T' link frames are armed only then
or after a change in the menu.

    python fpga/sim/run_menu_settings_tb.py
"""
import subprocess, sys, tempfile
from pathlib import Path
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import rtl as rtl_  # noqa: E402


def main():
    with tempfile.TemporaryDirectory() as t:
        subprocess.run(['iverilog', '-g2012', *rtl_.inc(), '-s', 'tb_menu_settings', '-o', f'{t}/tb',
                        str(HERE / 'tb_menu_settings.v'), *rtl_.src('menu.v')], check=True)
        out = subprocess.run(['vvp', '-n', f'{t}/tb'], cwd=t, check=True, capture_output=True, text=True).stdout
    print(out.strip())
    sys.exit(0 if 'PASS' in out.split() and 'FAIL' not in out else 1)


if __name__ == '__main__':
    main()
