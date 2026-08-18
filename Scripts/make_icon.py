#!/usr/bin/env python3
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "Assets"
ICONSET = ASSETS / "DiskBloom.iconset"
ASSETS.mkdir(parents=True, exist_ok=True)
ICONSET.mkdir(parents=True, exist_ok=True)

SIZE = 1024
image = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
draw = ImageDraw.Draw(image)

# Original DiskBloom mark: a dark utility tile with layered storage rings.
draw.rounded_rectangle((32, 32, 992, 992), radius=220, fill=(12, 16, 24, 255))
draw.rounded_rectangle((54, 54, 970, 970), radius=200, outline=(255, 255, 255, 20), width=4)
draw.ellipse((180, 180, 844, 844), fill=(25, 32, 46, 255))

rings = [
    ((205, 205, 819, 819), -84, 42, (102, 217, 183, 255), 96),
    ((310, 310, 714, 714), 25, 215, (110, 168, 254, 255), 88),
    ((410, 410, 614, 614), 195, 490, (241, 180, 91, 255), 78),
]
for box, start, end, color, width in rings:
    draw.arc(box, start=start, end=end, fill=color, width=width)

# Rounded caps and a center core.
draw.ellipse((462, 462, 562, 562), fill=(242, 127, 135, 255))
draw.ellipse((245, 184, 345, 284), fill=(102, 217, 183, 255))
draw.ellipse((602, 568, 690, 656), fill=(110, 168, 254, 255))

master = ASSETS / "DiskBloom-1024.png"
image.save(master)

sizes = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}
for name, size in sizes.items():
    resized = image.resize((size, size), Image.Resampling.LANCZOS)
    resized.save(ICONSET / name)

print(master)
