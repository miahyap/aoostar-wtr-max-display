#!/usr/bin/env python3
"""Generate the plugin icon (64x64 PNG, pure stdlib): a dark tile with a
mini-display showing green/blue/amber stat bars."""
import struct, zlib, os

W = H = 64
px = bytearray()

def in_round_rect(x, y, x0, y0, x1, y1, r):
    if x0 + r <= x <= x1 - r and y0 <= y <= y1:
        return True
    if x0 <= x <= x1 and y0 + r <= y <= y1 - r:
        return True
    for cx in (x0 + r, x1 - r):
        for cy in (y0 + r, y1 - r):
            if (x - cx) ** 2 + (y - cy) ** 2 <= r * r:
                return True
    return False

BARS = [  # (x0, x1, height) inside the screen area
    (16, 21, 14), (25, 30, 22), (34, 39, 10), (43, 48, 18),
]
COLORS = [(46, 204, 113), (0, 174, 219), (241, 196, 15), (46, 204, 113)]

for y in range(H):
    for x in range(W):
        r, g, b, a = 0, 0, 0, 0
        if in_round_rect(x, y, 2, 6, 61, 51, 8):          # case body
            r, g, b, a = 38, 44, 54, 255
            if 10 <= x <= 53 and 13 <= y <= 44:           # screen bezel
                r, g, b = 12, 16, 22
            if 12 <= x <= 51 and 15 <= y <= 42:           # screen
                r, g, b = 18, 30, 44
                for i, (bx0, bx1, bh) in enumerate(BARS):
                    if bx0 <= x <= bx1 and 41 - bh <= y <= 41:
                        r, g, b = COLORS[i]
        elif 20 <= x <= 43 and 52 <= y <= 55:             # stand
            r, g, b, a = 38, 44, 54, 255
        elif 14 <= x <= 49 and 56 <= y <= 59:             # base
            r, g, b, a = 30, 35, 43, 255
        px += bytes((r, g, b, a))

raw = b''.join(b'\x00' + bytes(px[y * W * 4:(y + 1) * W * 4]) for y in range(H))

def chunk(tag, data):
    return (struct.pack('>I', len(data)) + tag + data +
            struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff))

png = (b'\x89PNG\r\n\x1a\n' +
       chunk(b'IHDR', struct.pack('>IIBBBBB', W, H, 8, 6, 0, 0, 0)) +
       chunk(b'IDAT', zlib.compress(raw, 9)) +
       chunk(b'IEND', b''))

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'plugin-root', 'images', 'aoostar-lcd.png')
with open(out, 'wb') as f:
    f.write(png)
print(f'wrote {out} ({len(png)} bytes)')
