#!/usr/bin/env python3
"""Render the app icon: a red line-art profile of a man talking, on black."""

from pathlib import Path

from PIL import Image, ImageDraw

SIZE = 1024
BLACK = (0, 0, 0, 255)
RED = (219, 41, 51, 255)
ROOT = Path(__file__).resolve().parents[1]
STROKE = 46


def quad(start, control, end, steps=18):
    points = []
    for step in range(steps + 1):
        t = step / steps
        x = (1 - t) ** 2 * start[0] + 2 * (1 - t) * t * control[0] + t ** 2 * end[0]
        y = (1 - t) ** 2 * start[1] + 2 * (1 - t) * t * control[1] + t ** 2 * end[1]
        points.append((x, y))
    return points


def chain(segments):
    points = []
    for segment in segments:
        piece = quad(*segment)
        points.extend(piece if not points else piece[1:])
    return points


def stroke(draw: ImageDraw.ImageDraw, points, width=STROKE) -> None:
    draw.line(points, fill=RED, width=width, joint="curve")
    radius = width / 2
    for point in (points[0], points[-1]):
        draw.ellipse(
            (point[0] - radius, point[1] - radius, point[0] + radius, point[1] + radius),
            fill=RED,
        )


def main() -> None:
    image = Image.new("RGBA", (SIZE, SIZE), BLACK)
    draw = ImageDraw.Draw(image)
    # One profile: short side-parted hair, open mouth, strong jaw, facing right.
    crown = chain([
        ((360, 700), (250, 480), (340, 320)),
        ((340, 320), (430, 160), (600, 190)),
        ((600, 190), (760, 200), (790, 340)),
    ])
    face = chain([
        ((790, 340), (830, 430), (900, 500)),
        ((900, 500), (840, 545), (800, 575)),
        ((800, 575), (860, 600), (820, 630)),
    ])
    jaw = chain([
        ((790, 690), (860, 730), (760, 800)),
        ((760, 800), (560, 900), (390, 800)),
        ((390, 800), (320, 740), (360, 700)),
    ])
    part = chain([
        ((470, 210), (560, 250), (640, 310)),
    ])
    brow = chain([((690, 390), (750, 360), (800, 400))])
    eye = chain([((700, 455), (745, 430), (785, 460))])
    stroke(draw, crown)
    stroke(draw, face)
    stroke(draw, jaw)
    stroke(draw, part, 30)
    stroke(draw, brow, 26)
    stroke(draw, eye, 24)
    waves = [
        chain([((860, 590), (930, 545), (990, 575))]),
        chain([((870, 650), (950, 655), (1010, 610))]),
        chain([((850, 710), (930, 750), (990, 700))]),
    ]
    for wave in waves:
        stroke(draw, wave, 20)
    flat = Image.new("RGB", (SIZE, SIZE), BLACK[:3])
    flat.paste(image, mask=image.getchannel("A"))
    destinations = [
        ROOT / "FuentesArchive/Assets.xcassets/AppIcon.appiconset/icon-1024.png",
        ROOT / "sidestore/icon-1024.png",
        Path("/cursor/stores/bc-1feb3270-fa99-5c8c-bf43-8f4bc98552db/icon-preview.png"),
    ]
    for path in destinations:
        path.parent.mkdir(parents=True, exist_ok=True)
        flat.save(path, "PNG")
        print(path)


if __name__ == "__main__":
    main()
