#!/usr/bin/env python3
"""Generate the "Unraid Dark" panel for the AOOSTAR LCD (960x376):
- plugin-root/panel/unraid-dark.png  (background image, pure-stdlib PNG)
- plugin-root/panel/monitor.json     (asterctl/AOOSTAR-X panel definition)

Layout constants are shared so background zones and sensor positions stay
in sync. All text is rendered by asterctl (DejaVuSans built-in); dynamic
colors work via green/amber/red label "slots": the collector script writes
each value under exactly one of the slot labels, and asterctl skips
sensors whose label has no value.

Text placement
--------------
asterctl does not treat a text sensor's `y` as its top edge. It draws the
line box at

    line_top = y - int(tallest_glyph_ink_height * 1.3333 / 2)

(render_text() in aoostar-rs' render.rs), so where a string lands depends
on the tallest glyph it happens to contain. The first version of this
panel ignored that: text sat a size-dependent distance above its intended
position (captions straddling zone borders), and a sparkline of only
baseline glyphs dropped 0.7 x its font size into the row below.

Everything here is therefore positioned by BASELINE, and each sensor
declares the tallest glyph class its values contain (the TALL_* constants,
measured with `asterctl --simulate`). The collector keeps that class
stable for every value it writes - e.g. sparklines always start with a
full-height axis glyph. src/test/test_panel.py renders the panel in the
simulator and checks the result.
"""
import json
import os
import re
import struct
import zlib

W, H = 960, 376
SRC = os.path.dirname(os.path.abspath(__file__))
STATS_SH = os.path.join(SRC, 'plugin-root', 'scripts', 'unraid-stats.sh')

# palette: pure black background and saturated colors. The panel's black
# level is poor off-axis (dark greys read as blue) and its gamut is narrow
# (GitHub-style muted green/red/amber read as teal/pink/cream), so status
# colors need all the separation they can get.
BG      = (0, 0, 0)
ZONE    = (0, 0, 0)
BORDER  = (56, 68, 92)
GREEN   = '#2fe36a'
AMBER   = '#ffb300'
RED     = '#ff4136'
TEXT    = '#ffffff'
MUTED   = '#b3bcc8'
BLUE    = '#4aa8ff'

# smallest font used anywhere: below this the panel is unreadable from
# across a room
MIN_FONT = 20

# zones: (x, y, w, h)
TILE_W, TILE_H, TILE_GAP = 226, 128, 10
TILE_X0, TILE_Y = 13, 12
TILES = ('cpu', 'gpu', 'temp', 'ram')
TILE_ZONES = {
    name: (TILE_X0 + i * (TILE_W + TILE_GAP), TILE_Y, TILE_W, TILE_H)
    for i, name in enumerate(TILES)
}
NET_ZONE  = (13, 150, 934, 154)
DISK_ZONE = (13, 314, 934, 50)
ZONES = dict(TILE_ZONES, net=NET_ZONE, disk=DISK_ZONE)

# ---- asterctl text metrics (fractions of fontSize, measured in simulator) --
# tallest-glyph ink height per class of content
TALL_CAPS  = 0.725   # capitals only ("CPU")
TALL_DIGIT = 0.775   # digits, %, lowercase with ascenders/descenders
TALL_SLASH = 0.825   # anything containing "/" ("13.8 MB/s", "n/a")
TALL_BLOCK = 1.2     # full-height block elements (sparkline axis glyph)
BASELINE   = 0.908   # line top -> baseline
CAP_TOP    = 0.19    # line top -> top of capitals/digits
BLOCK_TOP  = -0.025  # line top -> top of a full block
BLOCK_ADV  = 0.8     # horizontal advance of a block element

# network zone geometry
NET_ROW_H    = NET_ZONE[3] // 2
ARROW_SIZE   = 34
SPEED_SIZE   = 40
SPEED_X      = 72
SPARK_SIZE   = 40
SPARK_X      = 290
PEAK_X, PEAK_W = 780, 150
PEAK_CAP_SIZE, PEAK_SIZE = 20, 24

TILE_CAP_SIZE, TILE_VAL_SIZE = 24, 68
STRIP_SIZE = 24


def graph_buckets():
    """GRAPH_BUCKETS lives in the collector (it builds the sparkline
    string); read it from there so the layout check below and the script
    can never disagree."""
    with open(STATS_SH, encoding='utf-8') as f:
        m = re.search(r'^GRAPH_BUCKETS=(\d+)', f.read(), re.M)
    if not m:
        raise SystemExit('GRAPH_BUCKETS not found in unraid-stats.sh')
    return int(m.group(1))


def spark_width(buckets):
    # one leading axis glyph + one glyph per bucket
    return int((buckets + 1) * BLOCK_ADV * SPARK_SIZE)


# ---------------------------------------------------------------- background

def make_background(path):
    px = [[BG for _ in range(W)] for _ in range(H)]

    def in_round(x, y, zx, zy, zw, zh, r):
        x1, y1 = zx + zw - 1, zy + zh - 1
        if zx + r <= x <= x1 - r and zy <= y <= y1:
            return True
        if zx <= x <= x1 and zy + r <= y <= y1 - r:
            return True
        for cx in (zx + r, x1 - r):
            for cy in (zy + r, y1 - r):
                if (x - cx) ** 2 + (y - cy) ** 2 <= r * r:
                    return True
        return False

    for zx, zy, zw, zh in ZONES.values():
        r = 10
        for y in range(zy, zy + zh):
            for x in range(zx, zx + zw):
                if in_round(x, y, zx, zy, zw, zh, r):
                    edge = not in_round(x, y, zx + 2, zy + 2, zw - 4, zh - 4, r)
                    px[y][x] = BORDER if edge else ZONE

    raw = b''.join(
        b'\x00' + bytes(c for p in row for c in p) for row in px)

    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data +
                struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff))

    png = (b'\x89PNG\r\n\x1a\n' +
           chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 2, 0, 0, 0)) +
           chunk(b'IDAT', zlib.compress(raw, 9)) +
           chunk(b'IEND', b''))
    with open(path, 'wb') as f:
        f.write(png)
    print(f'wrote {path} ({len(png)} bytes)')

# ------------------------------------------------------------------- sensors

def sensor_y(baseline, size, tall):
    """The `y` that makes asterctl put the text baseline at `baseline`,
    for content whose tallest glyph class is `tall` (see module docstring)."""
    line_top = baseline - BASELINE * size
    return round(line_top) + int(tall * size * 1.3333 / 2)


def text(label, x, baseline, size, color, tall, align='left', width=0,
         name=''):
    if size < MIN_FONT:
        raise SystemExit(f'{label}: font size {size} is below MIN_FONT')
    return {
        'mode': 1, 'type': 1, 'name': name or label, 'label': label,
        'x': x, 'y': sensor_y(baseline, size, tall), 'width': width,
        'height': 0,
        'textDirection': 0, 'direction': 1, 'value': '',
        'fontSize': size, 'fontColor': color, 'fontWeight': 'normal',
        'textAlign': align, 'integerDigits': -1, 'decimalDigits': 0,
        'unit': '', 'minAngle': 0, 'maxAngle': 180,
        'minValue': 0, 'maxValue': 100, 'pic': '', 'xz_x': 0, 'xz_y': 0,
    }


def slots(label, x, baseline, size, tall, align='left', width=0, name=''):
    """One text element per color slot; the collector writes all three each
    cycle with only one non-empty (units baked into the value), because
    asterctl's sensor map never drops absent keys - empty overwrites are
    what clears a stale slot."""
    return [
        text(f'{label}_g', x, baseline, size, GREEN, tall, align, width, f'{name} (ok)'),
        text(f'{label}_a', x, baseline, size, AMBER, tall, align, width, f'{name} (warn)'),
        text(f'{label}_r', x, baseline, size, RED,   tall, align, width, f'{name} (hot)'),
    ]


def build_layout():
    """[(zone name, sensor dict), ...] - the zone is what the simulator test
    uses to check that each sensor's ink stays inside its box."""
    out = []

    def add(zone, *sensors):
        out.extend((zone, s) for s in sensors)

    # --- four stat tiles: caption on top, big threshold-colored value ---
    tile_values = {
        'cpu':  ('lbl_cpu',  'cpu_util', 'CPU utilization'),
        'gpu':  ('lbl_gpu',  'gpu_util', 'GPU utilization'),
        'temp': ('lbl_temp', 'cpu_temp', 'die temperature'),
        'ram':  ('lbl_ram',  'mem_pct',  'RAM usage'),
    }
    for tile, (cap, val, name) in tile_values.items():
        zx, zy, zw, zh = TILE_ZONES[tile]
        add(tile, text(cap, zx, zy + 36, TILE_CAP_SIZE, MUTED, TALL_CAPS,
                       'center', zw, f'{name} caption'))
        add(tile, *slots(val, zx, zy + 108, TILE_VAL_SIZE, TALL_DIGIT,
                         'center', zw, name))

    # --- network: one row per direction - arrow, speed, history, peak ---
    nx, ny, nw, nh = NET_ZONE
    buckets = graph_buckets()
    if SPARK_X + spark_width(buckets) > PEAK_X - 8:
        raise SystemExit(
            f'sparkline ({buckets} buckets at size {SPARK_SIZE}) is '
            f'{spark_width(buckets)}px wide and runs into the peak column')
    rows = (('up', GREEN, 'upload'), ('down', BLUE, 'download'))
    for r, (d, color, name) in enumerate(rows):
        centre = ny + r * NET_ROW_H + NET_ROW_H // 2
        add('net', text(f'lbl_{d}', nx + 17, centre + 9, ARROW_SIZE, color,
                        TALL_DIGIT, name=f'{name} arrow'))
        add('net', text(f'net_{d}', SPEED_X, centre + 14, SPEED_SIZE, TEXT,
                        TALL_SLASH, name=f'{name} speed'))
        # block glyphs span BLOCK_TOP .. BLOCK_TOP+TALL_BLOCK of the line
        # box: centre them on the row
        spark_top = centre - TALL_BLOCK * SPARK_SIZE / 2
        spark_base = spark_top + (BASELINE - BLOCK_TOP) * SPARK_SIZE
        add('net', text(f'net_{d}_graph', SPARK_X, spark_base, SPARK_SIZE,
                        color, TALL_BLOCK, name=f'{name} history'))
        add('net', text('lbl_peak', PEAK_X, centre - 8, PEAK_CAP_SIZE, MUTED,
                        TALL_DIGIT, 'right', PEAK_W, f'{name} peak caption'))
        add('net', text(f'net_{d}_peak', PEAK_X, centre + 22, PEAK_SIZE, TEXT,
                        TALL_SLASH, 'right', PEAK_W, f'{name} peak'))

    # --- bottom strip: disks on the left (summary OR alert - exactly one
    # is non-empty at a time), address and clock on the right ---
    dx, dy, dw, dh = DISK_ZONE
    base = dy + 34
    add('disk', text('disk_ok', dx + 17, base, STRIP_SIZE, GREEN, TALL_DIGIT,
                     name='disk summary'))
    add('disk', text('disk_alert', dx + 17, base, STRIP_SIZE, RED, TALL_DIGIT,
                     name='disk alert'))
    add('disk', text('net_ip', dx + 580, base, STRIP_SIZE, TEXT, TALL_DIGIT,
                     'right', 245, 'IP address / network problem'))
    add('disk', text('DATE_h_m_3', dx + 837, base, STRIP_SIZE, MUTED,
                     TALL_DIGIT, 'right', 80, 'clock'))
    return out


def make_monitor(path):
    sensors = [s for _, s in build_layout()]
    cfg = {
        'setup': {'switchTime': '30', 'refresh': 1},
        'mianban': [1],
        'diy': [{
            'type': 5,
            'img': 'unraid-dark.png',
            'sensor': sensors,
        }],
    }
    with open(path, 'w') as f:
        json.dump(cfg, f, indent=1, ensure_ascii=False)
        f.write('\n')
    print(f'wrote {path} ({len(sensors)} sensors)')


if __name__ == '__main__':
    out = os.path.join(SRC, 'plugin-root', 'panel')
    os.makedirs(out, exist_ok=True)
    make_background(os.path.join(out, 'unraid-dark.png'))
    make_monitor(os.path.join(out, 'monitor.json'))
