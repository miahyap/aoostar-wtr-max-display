#!/usr/bin/env python3
"""Layout regression checks for the "Unraid Dark" panel, using asterctl's
own renderer (`--simulate --save` writes the frame it would send to the LCD
as a PNG). Runs on the Mac, no hardware needed - only Docker:

    python3 unraid-plugin/src/test/test_panel.py [--keep DIR]

What it guards (all seen on the real display with the first panel):
- text straddling zone borders - asterctl offsets text by a fraction of its
  tallest glyph, which the old coordinates ignored;
- the upload sparkline running through the download speed - an all-baseline
  sparkline (idle link) rendered 0.7 x its font size lower than a busy one;
- neighbouring values colliding once real, wider numbers arrived.

How: every visible sensor is given a unique color on a black background, so
one render yields each sensor's ink bounding box. Each box must sit inside
its zone and no two may touch, across several worst-case scenarios.
"""
import glob
import itertools
import json
import os
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.dirname(HERE)
PLUGIN = os.path.dirname(SRC)
sys.path.insert(0, SRC)
import make_panel as mp  # noqa: E402

# glibc userland for the upstream x86-64 binary (emulated on Apple silicon)
IMAGE = 'debian:bookworm-slim'
ZONE_INSET = 3      # zone border (2px) + 1px of air
MIN_GAP = 2         # px of air required between two sensors' ink

BUCKETS = mp.graph_buckets()
AXIS = '▏'

CAPTIONS = {
    'lbl_cpu': 'CPU', 'lbl_gpu': 'GPU', 'lbl_temp': 'TEMP', 'lbl_ram': 'RAM',
    'lbl_up': '▲', 'lbl_down': '▼',
}

# label -> value. Values mirror what unraid-stats.sh writes (test_stats.sh
# pins those formats); unlisted labels are empty = not rendered.
SCENARIOS = {
    'typical': dict(CAPTIONS, **{
        'lbl_peak': '60 min peak',
        'cpu_util_g': '14%', 'gpu_util_r': '98%', 'cpu_temp_a': '73°C',
        'mem_pct_g': '56%',
        'net_up': '13.8 KB/s', 'net_down': '112 MB/s',
        'net_up_graph': AXIS + '▁▁▂▁▁▃▂▁▁▁▂█▃▂'[:BUCKETS].ljust(BUCKETS, '▁'),
        'net_down_graph': AXIS + '▁▂▂▃▅▇█▆▄▃▃▂▅▇'[:BUCKETS].ljust(BUCKETS, '▁'),
        'net_up_peak': '96.4 KB/s', 'net_down_peak': '113 MB/s',
        'disk_ok': 'HDD 43°C · SSD 39°C · 4 standby · Array 56%',
        'net_ip': '192.168.57.10',
    }),
    # the widest value every slot can plausibly hold
    'widest': dict(CAPTIONS, **{
        'lbl_peak': '119 min peak',
        'cpu_util_r': '100%', 'gpu_util_r': '100%', 'cpu_temp_r': '105°C',
        'mem_pct_r': '100%',
        'net_up': '1023 KB/s', 'net_down': '1023 MB/s',
        'net_up_graph': AXIS + '█' * BUCKETS,
        'net_down_graph': AXIS + '█' * BUCKETS,
        'net_up_peak': '1023 KB/s', 'net_down_peak': '1023 MB/s',
        'disk_ok': 'HDD 55°C · SSD 65°C · 12 standby · Array 100%',
        'net_ip': '192.168.100.100',
    }),
    # unplugged interface: no speeds, flat history, problem in the address
    # slot; no GPU
    'link-down': dict(CAPTIONS, **{
        'lbl_peak': '24 h peak',
        'cpu_util_g': '3%', 'cpu_temp_g': '41°C', 'mem_pct_a': '85%',
        'net_up': 'n/a', 'net_down': 'n/a',
        'net_up_graph': AXIS + '▁' * BUCKETS,
        'net_down_graph': AXIS + '▁' * BUCKETS,
        'net_up_peak': '0 B/s', 'net_down_peak': '0 B/s',
        'disk_ok': 'disks: no data',
        'net_ip': 'no default route',
    }),
    # hot disks: the alert replaces the summary AND the address
    'alert': dict(CAPTIONS, **{
        'lbl_peak': '15 min peak',
        'cpu_util_a': '71%', 'gpu_util_g': '9%', 'cpu_temp_r': '91°C',
        'mem_pct_g': '40%',
        'net_up': '0 B/s', 'net_down': '2.5 GB/s',
        'net_up_graph': AXIS + '▁' * BUCKETS,
        'net_down_graph': AXIS + '▁▁▁▁▁▁▁▁▁▁▁▁▁█'[:BUCKETS].rjust(BUCKETS, '▁'),
        'net_up_peak': '0 B/s', 'net_down_peak': '2.5 GB/s',
        'disk_alert': '⚠ HOT: parity2 56°C, disk10 57°C, cache2 66°C +12',
    }),
}
CLOCK = 'DATE_h_m_3'  # provided by asterctl itself, always rendered

# unique, well-separated hues: every channel in {0,85,170,255} with at least
# one at 255, so anti-aliased pixels (color x alpha on black) keep the ratio
PALETTE = [c for c in itertools.product((0, 85, 170, 255), repeat=3)
           if max(c) == 255]


def read_png(path):
    d = open(path, 'rb').read()
    assert d[:8] == b'\x89PNG\r\n\x1a\n'
    pos, idat = 8, b''
    while pos < len(d):
        n, tag = struct.unpack('>I4s', d[pos:pos + 8])
        body = d[pos + 8:pos + 8 + n]
        pos += 12 + n
        if tag == b'IHDR':
            w, h, depth, ctype, _, _, interlace = struct.unpack('>IIBBBBB', body)
        elif tag == b'IDAT':
            idat += body
    assert depth == 8 and interlace == 0 and ctype in (2, 6)
    bpp = 3 if ctype == 2 else 4
    raw, stride = zlib.decompress(idat), w * bpp
    rows, prev, p = [], bytearray(stride), 0
    for _ in range(h):
        f, cur = raw[p], bytearray(raw[p + 1:p + 1 + stride])
        p += 1 + stride
        for i in range(stride):
            a = cur[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1:
                cur[i] = (cur[i] + a) & 255
            elif f == 2:
                cur[i] = (cur[i] + b) & 255
            elif f == 3:
                cur[i] = (cur[i] + (a + b) // 2) & 255
            elif f == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                cur[i] = (cur[i] + (a if pa <= pb and pa <= pc
                                    else b if pb <= pc else c)) & 255
        rows.append(cur)
        prev = cur
    return w, h, bpp, rows


def ink_boxes(png, colors):
    """{color index: (x0, y0, x1, y1)} for every palette color present."""
    w, h, bpp, rows = png
    boxes = {}
    for y in range(h):
        row = rows[y]
        for x in range(w):
            r, g, b = row[x * bpp], row[x * bpp + 1], row[x * bpp + 2]
            m = max(r, g, b)
            if m < 140:   # background or a faint anti-aliased edge
                continue
            n = (r * 255 // m, g * 255 // m, b * 255 // m)
            best = min(range(len(colors)),
                       key=lambda i: sum(abs(n[k] - colors[i][k]) for k in range(3)))
            if sum(abs(n[k] - colors[best][k]) for k in range(3)) > 60:
                continue
            bx = boxes.get(best)
            boxes[best] = ((x, y, x, y) if bx is None else
                           (min(bx[0], x), min(bx[1], y), max(bx[2], x), max(bx[3], y)))
    return boxes


def black_png(path):
    raw = b''.join(b'\x00' + bytes(mp.W * 3) for _ in range(mp.H))

    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data +
                struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff))
    with open(path, 'wb') as f:
        f.write(b'\x89PNG\r\n\x1a\n' +
                chunk(b'IHDR', struct.pack('>IIBBBBB', mp.W, mp.H, 8, 2, 0, 0, 0)) +
                chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))


def main():
    keep = sys.argv[sys.argv.index('--keep') + 1] if '--keep' in sys.argv else None
    work = tempfile.mkdtemp(prefix='alcd-panel-', dir=os.path.expanduser('~'))
    try:
        return run(work, keep)
    finally:
        shutil.rmtree(work, ignore_errors=True)


def run(work, keep):
    tarballs = glob.glob(os.path.join(PLUGIN, 'asterctl-*.tar.gz'))
    if len(tarballs) != 1:
        sys.exit('expected exactly one committed asterctl tarball')
    app = os.path.join(work, 'app')
    with tarfile.open(tarballs[0]) as t:
        t.extractall(app)

    layout = mp.build_layout()
    visible = {}     # scenario -> [(zone, sensor, color)]
    for name, values in SCENARIOS.items():
        d = os.path.join(work, name)
        os.makedirs(os.path.join(d, 'cfg'))
        os.makedirs(os.path.join(d, 'sensors'))
        shown, sensors = [], []
        for zone, s in layout:
            if s['label'] != CLOCK and not values.get(s['label']):
                continue
            color = PALETTE[len(shown)]
            shown.append((zone, s, color))
            sensors.append(dict(s, fontColor='#%02x%02x%02x' % color))
        visible[name] = shown
        black_png(os.path.join(d, 'cfg', 'black.png'))
        with open(os.path.join(d, 'cfg', 'monitor.json'), 'w') as f:
            json.dump({'setup': {'switchTime': '30', 'refresh': 1},
                       'mianban': [1],
                       'diy': [{'type': 5, 'img': 'black.png', 'sensor': sensors}]}, f)
        # every label is written, empty when unused - as the collector does
        labels = sorted({s['label'] for _, s in layout} - {CLOCK})
        with open(os.path.join(d, 'sensors', 'unraid.txt'), 'w') as f:
            f.writelines(f'{lab}: {values.get(lab, "")}\n' for lab in labels)

    script = ' ; '.join(
        f'(cd /work/{n} && timeout 4 /work/app/asterctl --simulate --save '
        f'--config monitor.json --config-dir /work/{n}/cfg '
        f'--sensor-path /work/{n}/sensors >log.txt 2>&1)' for n in SCENARIOS)
    subprocess.run(['docker', 'run', '--rm', '--platform', 'linux/amd64',
                    '-v', f'{work}:/work', IMAGE, 'bash', '-c', script + ' ; true'],
                   check=True)

    failures = []

    def check(ok, msg):
        print(('ok   - ' if ok else 'FAIL - ') + msg)
        if not ok:
            failures.append(msg)

    boxes_by = {}    # scenario -> {label: box}
    for name, shown in visible.items():
        pngs = glob.glob(os.path.join(work, name, 'out', '*.png'))
        if not pngs:
            log = open(os.path.join(work, name, 'log.txt')).read()[-800:]
            sys.exit(f'{name}: asterctl produced no frame\n{log}')
        if keep:
            os.makedirs(keep, exist_ok=True)
            shutil.copy(pngs[0], os.path.join(keep, f'{name}.png'))
        boxes = ink_boxes(read_png(pngs[0]), [c for _, _, c in shown])
        found = {}
        for i, (zone, s, _) in enumerate(shown):
            label = s['label']
            if i not in boxes:
                check(False, f'{name}: {label} rendered no ink')
                continue
            x0, y0, x1, y1 = found[label] = boxes[i]
            zx, zy, zw, zh = mp.ZONES[zone]
            inside = (x0 >= zx + ZONE_INSET and y0 >= zy + ZONE_INSET and
                      x1 <= zx + zw - 1 - ZONE_INSET and
                      y1 <= zy + zh - 1 - ZONE_INSET)
            check(inside, f'{name}: {label} stays inside the {zone} zone '
                          f'(ink {x0},{y0}-{x1},{y1}; zone {zx},{zy}+{zw}x{zh})')
        # two sensors in different rows may share a label (lbl_peak): their
        # union box is checked against the zone above but not for overlap
        dup = {s['label'] for _, s, _ in shown
               if sum(1 for _, t, _ in shown if t['label'] == s['label']) > 1}
        for (la, a), (lb, b) in itertools.combinations(found.items(), 2):
            if la in dup or lb in dup:
                continue
            apart = (a[2] + MIN_GAP < b[0] or b[2] + MIN_GAP < a[0] or
                     a[3] + MIN_GAP < b[1] or b[3] + MIN_GAP < a[1])
            if not apart:
                check(False, f'{name}: {la} {a} collides with {lb} {b}')
        check(True, f'{name}: {len(found)} sensors checked for collisions')
        boxes_by[name] = found

    # an idle sparkline must sit where a busy one does (the shared axis
    # glyph pins it; 1px of slack for anti-aliasing at the top edge)
    for d in ('up', 'down'):
        lab = f'net_{d}_graph'
        busy, idle = boxes_by['widest'].get(lab), boxes_by['link-down'].get(lab)
        check(bool(busy and idle) and abs(busy[1] - idle[1]) <= 1
              and busy[3] == idle[3],
              f'{lab}: flat history renders at the same height as a busy one '
              f'({idle} vs {busy})')
    # "n/a" must share the baseline of a real speed
    for d in ('up', 'down'):
        lab = f'net_{d}'
        num, na = boxes_by['typical'].get(lab), boxes_by['link-down'].get(lab)
        check(bool(num and na) and abs(num[3] - na[3]) <= 1,
              f'{lab}: "n/a" sits on the same baseline as a speed')

    print()
    print('all checks passed' if not failures else f'{len(failures)} CHECK(S) FAILED')
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
