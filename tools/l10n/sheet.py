#!/usr/bin/env python3
"""Puts screenshots side by side in one image, labelled, for comparing languages.

    tools/l10n/sheet.py out.png [--crop x,y,w,h] [--cols N] [--width W] img1.png img2.png …

--crop takes fractions of the image (0–1), to compare one area at a readable size.
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont


def main():
    args = sys.argv[1:]
    out = args.pop(0)
    crop, cols, width = None, 4, 700
    while args and args[0].startswith("--"):
        flag, value = args.pop(0), args.pop(0)
        if flag == "--crop":
            crop = [float(v) for v in value.split(",")]
        elif flag == "--cols":
            cols = int(value)
        elif flag == "--width":
            width = int(value)
    tiles = []
    for path in args:
        im = Image.open(path).convert("RGB")
        if crop:
            w, h = im.size
            x, y, cw, ch = crop
            im = im.crop((int(x * w), int(y * h), int((x + cw) * w), int((y + ch) * h)))
        im = im.resize((width, int(im.height * width / im.width)))
        tiles.append((os.path.basename(path).rsplit(".", 1)[0], im))
    th = max(t.height for _, t in tiles) + 30
    rows = (len(tiles) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * (width + 10), rows * th), "white")
    draw = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 22)
    except OSError:
        font = ImageFont.load_default()
    for i, (name, im) in enumerate(tiles):
        x, y = (i % cols) * (width + 10), (i // cols) * th
        draw.text((x + 4, y + 4), name, fill="black", font=font)
        sheet.paste(im, (x, y + 30))
    sheet.save(out)


if __name__ == "__main__":
    main()
