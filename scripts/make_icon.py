#!/usr/bin/env python3
"""Render the America First app icon as a 1024 PNG."""

import math
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

SIZE = 1024
NAVY = (10, 26, 58, 255)
RED = (196, 28, 42, 255)
WHITE = (255, 255, 255, 255)
ROOT = Path(__file__).resolve().parents[1]


def star(draw: ImageDraw.ImageDraw, cx: float, cy: float, radius: float, fill) -> None:
    points = []
    for index in range(10):
        angle = -math.pi / 2 + index * math.pi / 5
        length = radius if index % 2 == 0 else radius * 0.38
        points.append((cx + length * math.cos(angle), cy + length * math.sin(angle)))
    draw.polygon(points, fill=fill)


def main() -> None:
    image = Image.new("RGBA", (SIZE, SIZE), NAVY)
    draw = ImageDraw.Draw(image)
    top = 700
    count = 9
    stripe = (SIZE - top) / count
    for index in range(count):
        color = WHITE if index % 2 == 0 else RED
        y0 = int(top + index * stripe)
        y1 = SIZE if index == count - 1 else int(top + (index + 1) * stripe)
        draw.rectangle((0, y0, SIZE, y1), fill=color)
    for cx, cy, radius in (
        (150, 130, 42),
        (300, 190, 24),
        (190, 270, 18),
        (860, 140, 30),
        (780, 250, 16),
        (920, 300, 14),
    ):
        star(draw, cx, cy, radius, WHITE)
    font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 460)
    text = "AF"
    box = draw.textbbox((0, 0), text, font=font)
    x = (SIZE - (box[2] - box[0])) / 2 - box[0]
    y = 250 - box[1]
    for dx in range(-18, 19, 2):
        for dy in range(-18, 19, 2):
            if dx * dx + dy * dy <= 18 * 18:
                draw.text((x + dx, y + dy), text, font=font, fill=WHITE)
    draw.text((x, y), text, font=font, fill=RED)
    destinations = [
        ROOT / "FuentesArchive/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
        ROOT / "sidestore/icon-1024.png",
        Path("/cursor/stores/self/af-icon.png"),
    ]
    flat = Image.new("RGB", (SIZE, SIZE), NAVY[:3])
    flat.paste(image, mask=image.getchannel("A"))
    for path in destinations:
        path.parent.mkdir(parents=True, exist_ok=True)
        flat.save(path, "PNG")
        print(path)


if __name__ == "__main__":
    main()
