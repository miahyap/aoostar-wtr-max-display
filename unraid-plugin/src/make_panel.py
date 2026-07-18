#!/usr/bin/env python3
"""Generate the "Unraid Dark" panel for the AOOSTAR LCD (960x376):
- plugin-root/panel/unraid-dark.png  (background image, pure-stdlib PNG)
- plugin-root/panel/monitor.json     (asterctl/AOOSTAR-X panel definition)

Layout constants are shared so background zones and sensor positions stay
in sync. All text is rendered by asterctl (DejaVuSans built-in); dynamic
colors work via green/amber/red label "slots": the collector script writes
each value under exactly one of the slot labels, and asterctl skips
sensors whose label has no value.
"""
import json
import struct
import zlib
import os

W, H = 960, 376

# palette (GitHub-dark inspired)
BG      = (11, 15, 20)
ZONE    = (17, 23, 30)
BORDER  = (38, 48, 65)
GREEN   = '#3fb950'
AMBER   = '#d29922'
RED     = '#f85149'
TEXT    = '#e6edf3'
MUTED   = '#8b949e'
BLUE    = '#58a6ff'

# zones: (x, y, w, h)
CPU_ZONE  = (16, 16, 320, 280)
NET_ZONE  = (352, 16, 592, 280)
DISK_ZONE = (16, 312, 928, 48)

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

    for zx, zy, zw, zh in (CPU_ZONE, NET_ZONE, DISK_ZONE):
        r = 10
        for y in range(zy, zy + zh):
            for x in range(zx, zx + zw):
                if in_round(x, y, zx, zy, zw, zh, r):
                    edge = not in_round(x, y, zx + 1, zy + 1, zw - 2, zh - 2, r)
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

def text(label, x, y, size, color, align='left', width=0, unit='',
         decimals=0, name=''):
    return {
        'mode': 1, 'type': 1, 'name': name or label, 'label': label,
        'x': x, 'y': y, 'width': width, 'height': 0,
        'textDirection': 0, 'direction': 1, 'value': '',
        'fontSize': size, 'fontColor': color, 'fontWeight': 'normal',
        'textAlign': align, 'integerDigits': -1, 'decimalDigits': decimals,
        'unit': unit, 'minAngle': 0, 'maxAngle': 180,
        'minValue': 0, 'maxValue': 100, 'pic': '', 'xz_x': 0, 'xz_y': 0,
    }


def slots(label, x, y, size, align='left', width=0, unit='', decimals=0,
          name=''):
    """One text element per color slot; the collector writes all three each
    cycle with only one non-empty (units baked into the value), because
    asterctl's sensor map never drops absent keys - empty overwrites are
    what clears a stale slot."""
    return [
        text(f'{label}_g', x, y, size, GREEN, align, width, unit, decimals, f'{name} (ok)'),
        text(f'{label}_a', x, y, size, AMBER, align, width, unit, decimals, f'{name} (warn)'),
        text(f'{label}_r', x, y, size, RED,   align, width, unit, decimals, f'{name} (hot)'),
    ]


def make_monitor(path):
    cx, cy, cw, ch = CPU_ZONE
    nx, ny, nw, nh = NET_ZONE
    dx, dy, dw, dh = DISK_ZONE

    half = cw // 2
    sensors = []
    # --- CPU/GPU zone: utilizations side by side, shared die temp below ---
    sensors.append(text('lbl_cpu', cx + 16, cy + 12, 22, MUTED, name='zone header'))
    sensors += slots('cpu_util', cx, cy + 48, 60, 'center', half, '', 0, 'CPU utilization')
    sensors += slots('gpu_util', cx + half, cy + 48, 60, 'center', half, '', 0, 'GPU utilization')
    sensors.append(text('lbl_cpu_cap', cx, cy + 130, 16, MUTED, 'center', half, name='CPU caption'))
    sensors.append(text('lbl_gpu_cap', cx + half, cy + 130, 16, MUTED, 'center', half, name='GPU caption'))
    sensors += slots('cpu_temp', cx, cy + 162, 62, 'center', cw, '', 0, 'die temperature')
    sensors.append(text('lbl_ram', cx + 16, cy + 250, 18, MUTED, name='RAM caption'))
    sensors.append(text('mem_pct', cx + 70, cy + 250, 18, TEXT, name='RAM usage'))

    # --- NET zone: current speeds with history sparklines under each ---
    sensors.append(text('lbl_net', nx + 16, ny + 12, 22, MUTED, name='NET header'))
    sensors.append(text('DATE_h_m_3', nx, ny + 10, 26, MUTED, 'right', nw - 16, name='clock'))
    sensors.append(text('lbl_up', nx + 20, ny + 48, 32, GREEN, name='upload arrow'))
    sensors.append(text('net_up', nx + 70, ny + 40, 44, TEXT, 'right', nw - 90, name='upload speed'))
    sensors.append(text('net_up_graph', nx + 20, ny + 90, 26, GREEN, name='upload history'))
    sensors.append(text('net_up_peak', nx, ny + 96, 15, MUTED, 'right', nw - 16, name='upload peak'))
    sensors.append(text('lbl_down', nx + 20, ny + 134, 32, BLUE, name='download arrow'))
    sensors.append(text('net_down', nx + 70, ny + 126, 44, TEXT, 'right', nw - 90, name='download speed'))
    sensors.append(text('net_down_graph', nx + 20, ny + 176, 26, BLUE, name='download history'))
    sensors.append(text('net_down_peak', nx, ny + 182, 15, MUTED, 'right', nw - 16, name='download peak'))
    sensors.append(text('lbl_ip', nx + 20, ny + 238, 18, MUTED, name='IP caption'))
    sensors.append(text('net_ip', nx + 60, ny + 236, 20, TEXT, name='IP address'))
    sensors.append(text('lbl_window', nx, ny + 240, 16, MUTED, 'right', nw - 16, name='graph window caption'))

    # --- disk strip: exactly one of these is present at a time ---
    sensors.append(text('disk_ok', dx + 16, dy + 12, 20, GREEN, name='disk summary'))
    sensors.append(text('disk_alert', dx + 16, dy + 10, 22, RED, name='disk alert'))

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
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'plugin-root', 'panel')
    os.makedirs(out, exist_ok=True)
    make_background(os.path.join(out, 'unraid-dark.png'))
    make_monitor(os.path.join(out, 'monitor.json'))
