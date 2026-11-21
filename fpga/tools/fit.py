#!/usr/bin/env python3
"""Triversity fit tool: where the FPGA's resources go, and a placement that fits.

  1. synthesises the design with its hierarchy kept and prints LUT, ALU, MUX,
     DFF, LUT RAM, block RAM and DSP per module instance type (the biggest
     first), so duplicated or oversized blocks stand out;
  2. synthesises it flat (as fpga/build.sh) and runs nextpnr with several
     seeds and placer densities in parallel;
  3. keeps the result that routes and has the best slowest clock, packs it
     into the bitstream and prints its utilisation and timing.

Nothing about the design changes: only how it is placed. Same inputs as
build.sh (DEF via the build flags):

    python fpga/tools/fit.py [--flags "-DTRI_HQDVR -DTRI_TRIDVR"] [--out NAME]
                             [--seeds 4] [--jobs 4] [--report-only]
"""
import argparse, concurrent.futures as cf, json, os, re, shutil, subprocess, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent          # fpga/
RTL = HERE / 'rtl'
YOSYS = shutil.which('yowasp-yosys') or shutil.which('yosys')
NEXTPNR = shutil.which('yowasp-nextpnr-himbaechel-gowin') or shutil.which('nextpnr-himbaechel')
DEVICE, FAMILY = 'GW2AR-LV18QN88C8/I7', 'GW2A-18C'
BSRAM_TYPES = ('DP', 'SDP', 'SP', 'pROM', 'DPB', 'SDPB', 'DPX9', 'SDPX9', 'SPX9', 'DPX9B', 'SDPX9B', 'pROMX9')


def sources():
    src = sorted(str(p) for p in RTL.rglob('*.v'))
    inc = sorted({f'-I{p.parent}' for p in RTL.rglob('*.v*')})
    return src, inc


def yosys(script, log):
    r = subprocess.run([YOSYS, '-q', '-l', str(log), '-p', script], cwd=RTL, capture_output=True, text=True)
    if r.returncode:
        sys.exit(f'yosys failed, see {log}')


def report(flags, out):
    """Per module type: cells by kind (hierarchy kept)."""
    src, inc = sources()
    stat = out / 'hier_stat.txt'
    yosys(f"read_verilog {flags} {' '.join(inc)} {' '.join(src)}; synth_gowin -family gw2a -nodsp -noflatten -top tri_top; "
          f"tee -q -o {stat} stat", out / 'hier_yosys.log')
    text = stat.read_text()
    rows = []
    for blk in re.split(r'\n=== ', text)[1:]:
        name = blk.split(' ===')[0]
        name = re.sub(r'^\$paramod\$[0-9a-f]+\\', '', name).replace('$paramod\\', '')
        cells = {c: int(n) for n, c in re.findall(r'^\s+(\d+)\s+(?:[\d.]+\s+)?(\S+)$', blk, re.M)}
        if name.startswith('design hierarchy') or not cells:
            continue
        get = lambda *ks: sum(v for k, v in cells.items() if any(k.startswith(x) for x in ks))
        rows.append(dict(name=name[:34], lut=get('LUT'), alu=get('ALU'), mux=get('MUX'), dff=get('DFF'),
                         ram16=get('RAM16'), bsram=sum(v for k, v in cells.items() if k.split('\\')[-1] in BSRAM_TYPES),
                         dsp=get('MULT')))
    rows.sort(key=lambda r: -(r['lut'] + r['alu']))
    print(f"{'module':34s} {'LUT':>6s} {'ALU':>6s} {'MUX':>6s} {'DFF':>6s} {'LUTRAM':>6s} {'BSRAM':>6s} {'DSP':>4s}")
    for r in rows:
        if r['lut'] + r['alu'] + r['dff'] + r['bsram'] + r['dsp'] == 0:
            continue
        print(f"{r['name']:34s} {r['lut']:6d} {r['alu']:6d} {r['mux']:6d} {r['dff']:6d} {r['ram16']:6d} {r['bsram']:6d} {r['dsp']:4d}")
    print('(per module type, one instance; LUT RAM counts RAM16SDP4 cells, each takes a whole slice)')


def place(args, out, json_in, seed, beta):
    tag = f's{seed}_b{beta}'
    log, pnr = out / f'pnr_{tag}.log', out / f'pnr_{tag}.json'
    cmd = [NEXTPNR, '-q', '-l', str(log), '--json', str(json_in), '--write', str(pnr), '--device', DEVICE,
           '--vopt', f'family={FAMILY}', '--vopt', f'cst={HERE / "boards" / ("tang_nano_20k_hdmi.cst" if "TRI_HDMI" in args.flags else "tang_nano_20k.cst")}', '--freq', '40',
           '--timing-allow-fail', '--seed', str(seed), '--placer-heap-beta', str(beta)]
    try:
        r = subprocess.run(cmd, cwd=RTL, capture_output=True, text=True, timeout=args.timeout)
        ok = r.returncode == 0 and pnr.exists()
    except subprocess.TimeoutExpired:
        ok = False
    text = log.read_text() if log.exists() else ''
    fmax = [float(x) for x in re.findall(r"Max frequency for clock\s+'[^']+':\s+([\d.]+) MHz", text)]
    return dict(tag=tag, ok=ok, pnr=pnr, fmin=min(fmax[-4:]) if fmax else 0.0, log=log,
                util={k: v for k, v in re.findall(r'^Info:\s+(LUT4|ALU|DFF|BSRAM|RAM16SDP4|MULT18X18|MULT9X9):\s+(\d+/\s*\d+)', text, re.M)})


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--flags', default='', help='Verilog defines, e.g. "-DTRI_HQDVR -DTRI_TRIDVR"')
    ap.add_argument('--out', default='triversity', help='bitstream name (fpga/build/fit/<out>.fs)')
    ap.add_argument('--seeds', type=int, default=4)
    ap.add_argument('--betas', default='0.9,0.8', help='placer densities to try')
    ap.add_argument('--jobs', type=int, default=os.cpu_count() or 2)
    ap.add_argument('--timeout', type=int, default=2400, help='seconds per placement')
    ap.add_argument('--report-only', action='store_true')
    args = ap.parse_args()
    out = HERE / 'build' / 'fit'
    out.mkdir(parents=True, exist_ok=True)
    print('== resources per module')
    report(args.flags, out)
    if args.report_only:
        return
    print('\n== synthesis (flat)')
    src, inc = sources()
    json_in = out / 'synth.json'
    yosys(f"read_verilog {args.flags} {' '.join(inc)} {' '.join(src)}; synth_gowin -family gw2a -nodsp -top tri_top -json {json_in}",
          out / 'yosys.log')
    tries = [(s, float(b)) for b in args.betas.split(',') for s in range(1, args.seeds + 1)]
    print(f'== placing and routing: {len(tries)} tries, {args.jobs} at a time')
    best = None
    with cf.ThreadPoolExecutor(args.jobs) as ex:
        futs = {ex.submit(place, args, out, json_in, s, b): (s, b) for s, b in tries}
        for f in cf.as_completed(futs):
            r = f.result()
            print(f"  {r['tag']:10s} {'routes' if r['ok'] else 'fails '}  slowest clock {r['fmin']:6.1f} MHz  "
                  + ' '.join(f'{k} {v}' for k, v in r['util'].items()))
            if r['ok'] and (best is None or r['fmin'] > best['fmin']):
                best = r
    if best is None:
        sys.exit('no placement fits: the design needs fewer resources')
    fs = out / f'{args.out}.fs'
    subprocess.run(['gowin_pack', '-d', FAMILY, '-o', str(fs), str(best['pnr'])], check=True)
    print(f"\nbest: {best['tag']}, slowest clock {best['fmin']:.1f} MHz -> {fs}")


if __name__ == '__main__':
    main()
