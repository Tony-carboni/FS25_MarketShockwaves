#!/usr/bin/env python3
"""
Generate the mod icon.

A volatile market trend line: it climbs, spikes hard on an event, corrects, and
partially recovers - the shape the mod actually produces. Shockwave arcs radiate
from the spike.

Everything is drawn at 4x and downsampled, which is how the curves and diagonals
come out smooth without any AA support in PIL's drawing primitives.

Outputs:
  FS25_MarketShockwaves/icon_marketShockwaves.dds   256x256 DXT5, what the game loads
  FS25_MarketShockwaves/icon_marketShockwaves.png   256x256, fallback
  docs/icon_preview.png                             512x512, for looking at
  docs/banner.png                                   1280x640, for GitHub/ModHub

Run: python3 tools/make_icon.py
"""
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
FONTS = Path("/mnt/skills/examples/canvas-design/canvas-fonts")
FONT_BOLD = FONTS / "BigShoulders-Bold.ttf"
FONT_REG = FONTS / "BigShoulders-Regular.ttf"
FALLBACK = Path("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf")

SS = 4  # supersample factor

# The mod list crops the tile's edges, so keep everything important inside a
# safe area rather than running to the frame. The game also prints the mod name
# in its own bar underneath, so our wordmark is secondary - the chart is the hero.
SAFE_TEXT_FRACTION = 0.60   # widest the wordmark may be, as a fraction of width
CHART_INSET = 0.17          # left/right chart margin, fraction of width

# Palette: deep cold chart background, warm wheat-gold line.
BG_TOP = (13, 21, 32)
BG_BOT = (22, 34, 42)
GRID = (255, 255, 255, 16)
GOLD = (242, 178, 60)
GOLD_HI = (255, 214, 128)
GREEN = (108, 168, 92)
RED = (208, 88, 72)


def font(path, size):
    for p in (path, FALLBACK):
        try:
            return ImageFont.truetype(str(p), size)
        except Exception:
            continue
    return ImageFont.load_default()


def vertical_gradient(size, top, bottom):
    w, h = size
    grad = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / max(h - 1, 1)
        grad.putpixel((0, y), tuple(
            int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return grad.resize((w, h), Image.BILINEAR)


def trend_points(w, h):
    """The signature curve: build, spike, sharp correction, partial recovery.

    Coordinates are fractions of the drawing area so the shape is resolution
    independent.
    """
    pts = [
        (0.00, 0.73), (0.09, 0.68), (0.15, 0.71), (0.21, 0.63),
        (0.27, 0.66), (0.33, 0.57), (0.39, 0.60), (0.45, 0.48),
        (0.51, 0.40), (0.56, 0.28), (0.60, 0.17),          # <- the spike
        (0.64, 0.26), (0.68, 0.22), (0.72, 0.34), (0.76, 0.30),
        (0.81, 0.45), (0.86, 0.40), (0.91, 0.50), (1.00, 0.46),
    ]
    return [(x * w, y * h) for x, y in pts]


def draw_chart(img, area, with_text=True, title_scale=1.0):
    """Draw grid, area fill, glowing trend line and shockwave arcs into `img`."""
    x0, y0, x1, y1 = area
    w, h = x1 - x0, y1 - y0
    W, H = img.size
    d = ImageDraw.Draw(img, "RGBA")

    # --- faint chart grid ---
    for i in range(1, 5):
        y = y0 + h * i / 5
        d.line([(x0, y), (x1, y)], fill=(255, 255, 255, 12), width=max(1, SS // 2))
    for i in range(1, 8):
        x = x0 + w * i / 8
        d.line([(x, y0), (x, y1)], fill=(255, 255, 255, 7), width=max(1, SS // 2))

    pts = [(x0 + px, y0 + py) for px, py in trend_points(w, h)]
    peak = max(pts, key=lambda p: -p[1])

    # --- area fill under the line, fading to nothing at the baseline ---
    # The fade is built across the CHART area, not the whole image, otherwise the
    # gradient is still half-opaque where the polygon ends and leaves a hard edge.
    fill = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(fill).polygon(pts + [(x1, y1), (x0, y1)], fill=GOLD + (255,))
    ramp = Image.new("L", (1, H), 0)
    for y in range(H):
        if y <= y0:
            v = 80
        elif y >= y1:
            v = 0
        else:
            t = (y - y0) / max(y1 - y0, 1)
            v = int(80 * (1 - t) ** 1.6)      # fades out well before the baseline
        ramp.putpixel((0, y), v)
    ramp = ramp.resize((W, H))
    a = fill.getchannel("A").point(lambda v: 255 if v else 0)
    fill.putalpha(Image.composite(ramp, Image.new("L", (W, H), 0), a))
    img.alpha_composite(fill)

    # --- shockwave arcs radiating from the spike (after the fill, so visible) ---
    arcs = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ad = ImageDraw.Draw(arcs, "RGBA")
    for i, r in enumerate((0.08, 0.14, 0.20, 0.26)):
        rad = r * w
        alpha = int(150 - i * 32)
        ad.ellipse([peak[0] - rad, peak[1] - rad, peak[0] + rad, peak[1] + rad],
                   outline=GOLD_HI + (alpha,), width=max(1, int(SS * 1.6)))
    img.alpha_composite(arcs.filter(ImageFilter.GaussianBlur(SS * 0.8)))

    # --- glow behind the line ---
    glow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    ImageDraw.Draw(glow).line(pts, fill=GOLD + (150,), width=int(SS * 5),
                              joint="curve")
    img.alpha_composite(glow.filter(ImageFilter.GaussianBlur(SS * 3)))

    # --- the line itself ---
    d.line(pts, fill=GOLD_HI, width=int(SS * 2.4), joint="curve")

    # --- markers: green at the spike, red at the correction trough ---
    trough = min(pts[pts.index(peak):], key=lambda p: -p[1])
    for pt, col in ((peak, GREEN), (trough, RED)):
        mg = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        gr = SS * 8
        ImageDraw.Draw(mg).ellipse([pt[0] - gr, pt[1] - gr, pt[0] + gr, pt[1] + gr],
                                   fill=col + (120,))
        img.alpha_composite(mg.filter(ImageFilter.GaussianBlur(SS * 3)))
        r = SS * 4.0
        d.ellipse([pt[0] - r, pt[1] - r, pt[0] + r, pt[1] + r],
                  fill=col, outline=(255, 255, 255, 235), width=max(1, int(SS * 1.2)))

    if not with_text:
        return

    # --- wordmark, auto-fitted to a safe width ---
    # The mod list crops the tile's edges, so nothing may run to the frame edge.
    # Rather than guess a point size, binary-search the size whose rendered width
    # matches the target fraction - that holds for any font or string.
    cx = W // 2

    def fit_font(path, text, target_w, spacing_ratio=0.0, lo=6, hi=400):
        lo, hi = int(lo * SS), int(hi * SS)
        best = font(path, lo)
        while lo <= hi:
            mid = (lo + hi) // 2
            f = font(path, mid)
            w_ = d.textlength(text, font=f) + spacing_ratio * mid * (len(text) - 1)
            if w_ <= target_w:
                best, lo = f, mid + 1
            else:
                hi = mid - 1
        return best

    def centered(text, f, y, fill, spacing=0):
        if spacing:
            widths = [d.textlength(ch, font=f) for ch in text]
            total = sum(widths) + spacing * (len(text) - 1)
            x = cx - total / 2
            for ch, cw in zip(text, widths):
                d.text((x, y), ch, font=f, fill=fill)
                x += cw + spacing
        else:
            tw = d.textlength(text, font=f)
            d.text((cx - tw / 2, y), text, font=f, fill=fill)

    safe_w = W * SAFE_TEXT_FRACTION
    f2 = fit_font(FONT_BOLD, "SHOCKWAVES", safe_w)
    f1 = fit_font(FONT_REG, "MARKET", safe_w * 0.46, spacing_ratio=0.18)

    a2 = f2.getbbox("SHOCKWAVES")
    h2 = a2[3] - a2[1]
    ty = y1 + int(h2 * 0.42)
    centered("MARKET", f1, ty, (188, 208, 224),
             spacing=int(f1.size * 0.18))
    centered("SHOCKWAVES", f2, ty + int(f1.size * 0.92), GOLD_HI)


def make_icon(px=256):
    W = H = px * SS
    img = vertical_gradient((W, H), BG_TOP, BG_BOT).convert("RGBA")

    # soft radial warmth behind the spike
    halo = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    hr = W * 0.42
    ImageDraw.Draw(halo).ellipse(
        [W * 0.58 - hr, H * 0.30 - hr, W * 0.58 + hr, H * 0.30 + hr],
        fill=(242, 178, 60, 34))
    img.alpha_composite(halo.filter(ImageFilter.GaussianBlur(W * 0.10)))

    margin = int(W * CHART_INSET)
    draw_chart(img, (margin, int(H * 0.17), W - margin, int(H * 0.55)),
               with_text=True)

    return img.resize((px, px), Image.LANCZOS)


def make_banner(w=1280, h=640):
    W, H = w * 2, h * 2   # 2x is plenty at this size
    global SS
    keep, SS = SS, 2
    img = vertical_gradient((W, H), BG_TOP, BG_BOT).convert("RGBA")

    halo = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    hr = W * 0.30
    ImageDraw.Draw(halo).ellipse(
        [W * 0.55 - hr, H * 0.32 - hr, W * 0.55 + hr, H * 0.32 + hr],
        fill=(242, 178, 60, 30))
    img.alpha_composite(halo.filter(ImageFilter.GaussianBlur(W * 0.06)))

    global SAFE_TEXT_FRACTION
    keep_safe, SAFE_TEXT_FRACTION = SAFE_TEXT_FRACTION, 0.42
    draw_chart(img, (int(W * 0.06), int(H * 0.12), int(W * 0.94), int(H * 0.62)),
               with_text=True, title_scale=1.0)
    SAFE_TEXT_FRACTION = keep_safe

    d = ImageDraw.Draw(img, "RGBA")
    f = font(FONT_REG, int(26 * 2))
    tag = "dynamic market events for Farming Simulator 25"
    tw = d.textlength(tag, font=f)
    d.text(((W - tw) / 2, H * 0.90), tag, font=f, fill=(150, 172, 190))

    SS = keep
    return img.resize((w, h), Image.LANCZOS)


def main():
    (ROOT / "docs").mkdir(exist_ok=True)

    icon = make_icon(256)

    # The GIANTS engine expects a DXT-compressed DDS; uncompressed RGBA DDS is
    # not reliably loaded. DXT5 keeps a full alpha channel.
    dds = ROOT / "FS25_MarketShockwaves/icon_marketShockwaves.dds"
    try:
        icon.convert("RGBA").save(dds, pixel_format="DXT5")
        print(f"wrote {dds.relative_to(ROOT)}  256x256 DXT5")
    except Exception as e:
        icon.convert("RGBA").save(dds)
        print(f"wrote {dds.relative_to(ROOT)}  256x256 uncompressed "
              f"(DXT5 unavailable: {e})")

    # PNG alongside it as a fallback: if the game rejects the DDS, pointing
    # modDesc's <iconFilename> at this instead is a one-line change.
    png = ROOT / "FS25_MarketShockwaves/icon_marketShockwaves.png"
    icon.save(png)
    print(f"wrote {png.relative_to(ROOT)}  256x256 PNG (fallback)")

    preview = make_icon(512)
    p = ROOT / "docs/icon_preview.png"
    preview.save(p)
    print(f"wrote {p.relative_to(ROOT)}  512x512")

    b = ROOT / "docs/banner.png"
    make_banner().save(b)
    print(f"wrote {b.relative_to(ROOT)}  1280x640")


if __name__ == "__main__":
    main()
