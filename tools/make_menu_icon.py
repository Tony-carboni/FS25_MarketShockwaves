#!/usr/bin/env python3
"""
Draw the ESC-menu tab icon: a white pulse line on a transparent background.

    python3 tools/make_menu_icon.py     -> FS25_MarketShockwaves/gui/menuIcon.dds

Why this exists separately from make_icon.py: the store icon is a full-colour
picture, and the menu tints its tab icons (white normally, dark when selected),
so a colour picture comes out as a muddy square. A tab icon has to be a white
glyph whose only information is its alpha channel, like the base game's.

No imaging library needed. The glyph is rasterised here (distance to a polyline,
supersampled for smooth edges) and written as a DXT5 DDS with a full mip chain -
the menu draws it at about a quarter of its size, and without mips it shimmers.
Because the colour is pure white everywhere, DXT5 encoding is exact for colour
and only the alpha block needs any work.
"""
import math
import struct
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "FS25_MarketShockwaves/gui/menuIcon.dds"

SIZE = 256
STROKE = 15.0          # line width in pixels at SIZE
SS = 3                 # supersampling per axis

# A market shock: flat, a small dip, the spike, the rebound, flat again.
PULSE = [(30, 150), (84, 150), (104, 118), (126, 190), (150, 58),
         (174, 172), (190, 150), (226, 150)]


def dist_to_segment(px, py, ax, ay, bx, by):
    dx, dy = bx - ax, by - ay
    length2 = dx * dx + dy * dy
    t = 0.0 if length2 == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / length2))
    cx, cy = ax + t * dx, ay + t * dy
    return math.hypot(px - cx, py - cy)


def render(size):
    """Alpha values 0..255, row-major, for a size x size image."""
    scale = size / SIZE
    half = STROKE * scale / 2
    pts = [(x * scale, y * scale) for x, y in PULSE]
    alpha = []
    for y in range(size):
        for x in range(size):
            hits = 0
            for sy in range(SS):
                for sx in range(SS):
                    px, py = x + (sx + 0.5) / SS, y + (sy + 0.5) / SS
                    for i in range(len(pts) - 1):
                        if dist_to_segment(px, py, *pts[i], *pts[i + 1]) <= half:
                            hits += 1
                            break
            alpha.append(round(255 * hits / (SS * SS)))
    return alpha


# DXT5 alpha palette for a0=255 > a1=0: indices 0..7.
ALPHA_PALETTE = [255, 0] + [round(((7 - i) * 255) / 7) for i in range(1, 7)]


def dxt5_block(block_alpha):
    """Encode 16 alpha values (white colour) as one 16-byte DXT5 block."""
    bits = 0
    for i, a in enumerate(block_alpha):
        index = min(range(8), key=lambda k: abs(ALPHA_PALETTE[k] - a))
        bits |= index << (3 * i)
    alpha_part = bytes([255, 0]) + bits.to_bytes(6, "little")
    colour_part = struct.pack("<HHI", 0xFFFF, 0xFFFF, 0)      # white, all index 0
    return alpha_part + colour_part


def encode_level(alpha, size):
    out = bytearray()
    blocks = max(1, size // 4)
    for by in range(blocks):
        for bx in range(blocks):
            block = []
            for y in range(4):
                for x in range(4):
                    sx, sy = min(bx * 4 + x, size - 1), min(by * 4 + y, size - 1)
                    block.append(alpha[sy * size + sx])
            out += dxt5_block(block)
    return bytes(out)


def main():
    levels = []
    size = SIZE
    while size >= 1:
        levels.append(encode_level(render(size), size))
        size //= 2

    DDSD_CAPS, DDSD_HEIGHT, DDSD_WIDTH, DDSD_PIXELFORMAT = 0x1, 0x2, 0x4, 0x1000
    DDSD_MIPMAPCOUNT, DDSD_LINEARSIZE = 0x20000, 0x80000
    DDPF_FOURCC = 0x4
    DDSCAPS_COMPLEX, DDSCAPS_TEXTURE, DDSCAPS_MIPMAP = 0x8, 0x1000, 0x400000

    header = struct.pack(
        "<4sIIIIIII44x", b"DDS ", 124,
        DDSD_CAPS | DDSD_HEIGHT | DDSD_WIDTH | DDSD_PIXELFORMAT | DDSD_MIPMAPCOUNT | DDSD_LINEARSIZE,
        SIZE, SIZE, len(levels[0]), 0, len(levels))
    pixel_format = struct.pack("<II4sIIIII", 32, DDPF_FOURCC, b"DXT5", 0, 0, 0, 0, 0)
    caps = struct.pack("<IIIII", DDSCAPS_COMPLEX | DDSCAPS_TEXTURE | DDSCAPS_MIPMAP, 0, 0, 0, 0)
    data = header + pixel_format + caps
    assert len(data) == 128, len(data)

    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_bytes(data + b"".join(levels))
    print(f"wrote {OUT.relative_to(ROOT)}  {SIZE}x{SIZE} DXT5, {len(levels)} mip levels, "
          f"{OUT.stat().st_size} bytes")


if __name__ == "__main__":
    main()
