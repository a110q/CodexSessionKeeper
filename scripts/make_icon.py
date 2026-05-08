from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

OUT = Path("Assets")
OUT.mkdir(exist_ok=True)
S = 1024
img = Image.new("RGBA", (S, S), (8, 14, 26, 255))
px = img.load()
for y in range(S):
    for x in range(S):
        t = (x / S * 0.35 + y / S * 0.75)
        px[x, y] = (int(8 + 18 * t), int(14 + 35 * t), int(26 + 55 * t), 255)

def glow(center, color, radius):
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    cx, cy = center
    for i in range(10, 0, -1):
        r = radius * i / 10
        a = int(color[3] * (i / 10) ** 2 / 5)
        d.ellipse((cx-r, cy-r, cx+r, cy+r), fill=color[:3] + (a,))
    img.alpha_composite(layer.filter(ImageFilter.GaussianBlur(radius // 8)))

glow((330, 250), (59, 130, 246, 180), 340)
glow((720, 740), (20, 184, 166, 170), 360)

d = ImageDraw.Draw(img)
mask = Image.new("L", (S, S), 0)
md = ImageDraw.Draw(mask)
md.rounded_rectangle((0, 0, S-1, S-1), radius=220, fill=255)
img.putalpha(mask)

d.rounded_rectangle((150, 150, 874, 874), radius=170, outline=(185, 244, 255, 72), width=6)
d.rounded_rectangle((205, 235, 819, 800), radius=54, fill=(13, 28, 45, 210), outline=(96, 165, 250, 160), width=10)

# Vault door.
d.ellipse((335, 340, 689, 694), fill=(18, 44, 62, 255), outline=(94, 234, 212, 230), width=18)
d.ellipse((410, 415, 614, 619), fill=(8, 18, 30, 255), outline=(226, 232, 240, 185), width=8)
for angle in range(0, 360, 45):
    import math
    a = math.radians(angle)
    x1 = 512 + math.cos(a) * 42
    y1 = 512 + math.sin(a) * 42
    x2 = 512 + math.cos(a) * 92
    y2 = 512 + math.sin(a) * 92
    d.line((x1, y1, x2, y2), fill=(226, 232, 240, 165), width=8)
d.ellipse((482, 482, 542, 542), fill=(59, 130, 246, 255), outline=(221, 254, 251, 240), width=5)

# Session cards.
for i, (x, y, col) in enumerate([(270, 245, (96, 165, 250)), (315, 282, (20, 184, 166)), (360, 319, (245, 158, 11))]):
    d.rounded_rectangle((x, y, x + 230, y + 95), radius=20, fill=col + (210,), outline=(255, 255, 255, 80), width=3)
    d.line((x + 30, y + 32, x + 190, y + 32), fill=(255, 255, 255, 150), width=6)
    d.line((x + 30, y + 61, x + 140, y + 61), fill=(255, 255, 255, 120), width=5)

# Restore arrow.
d.arc((250, 610, 770, 890), 195, 342, fill=(125, 249, 255, 230), width=28)
d.polygon([(770, 686), (838, 640), (810, 720)], fill=(125, 249, 255, 230))

# Small shield/check.
d.polygon([(512, 725), (625, 768), (602, 868), (512, 922), (422, 868), (399, 768)], fill=(37, 99, 235, 230), outline=(191, 219, 254, 190))
d.line((463, 819, 500, 855, 568, 778), fill=(236, 253, 245, 255), width=18, joint="curve")

img.save(OUT / "CodexSessionVaultIcon.png")

