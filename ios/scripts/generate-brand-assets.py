"""Derive the iPhone icon and transparent wordmarks from the Android brand source.

Run from any directory with Pillow installed: python ios/scripts/generate-brand-assets.py
All rendered images are reductions of the original 1280px-wide source.
"""

from pathlib import Path
from statistics import median

from PIL import Image, ImageOps


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "android/app/src/main/res/drawable-nodpi/fenotip_wordmark_source.jpg"
ASSETS = ROOT / "ios/Fenotip/Assets.xcassets"


def wordmark() -> Image.Image:
    source = Image.open(SOURCE).convert("RGB")
    luminance = ImageOps.grayscale(source)
    # Ignore near-black JPEG noise; keep fractional edge coverage for smooth text.
    alpha = luminance.point(lambda v: max(0, min(255, round((v - 8) * 255 / 232))))
    bounds = alpha.point(lambda v: 255 if v > 12 else 0).getbbox()
    if bounds is None:
        raise ValueError("No wordmark pixels found in source")

    # Sample the original cream strokes, avoiding the JPEG anti-aliased border.
    light_pixels = [rgb for rgb, value in zip(source.get_flattened_data(), luminance.get_flattened_data()) if value > 235]
    cream = tuple(round(median(pixel[channel] for pixel in light_pixels)) for channel in range(3))
    left, top, right, bottom = bounds
    bounds = (max(0, left - 2), max(0, top - 2), min(source.width, right + 2), min(source.height, bottom + 2))
    result = Image.new("RGBA", (bounds[2] - bounds[0], bounds[3] - bounds[1]), cream + (0,))
    result.putalpha(alpha.crop(bounds))
    return result


def fit_width(image: Image.Image, width: int) -> Image.Image:
    if width > image.width:
        raise ValueError("Refusing to upscale the source wordmark")
    height = round(image.height * width / image.width)
    return image.resize((width, height), Image.Resampling.LANCZOS)


def main() -> None:
    logo = wordmark()
    logo.save(ASSETS / "Logo.imageset/logo.png")

    icon = Image.new("RGB", (1024, 1024), (0, 0, 0))
    art = fit_width(logo, round(1024 * 0.72))
    icon.paste(art, ((1024 - art.width) // 2, (1024 - art.height) // 2), art)
    icon.save(ASSETS / "AppIcon.appiconset/icon-1024.png")

    launch = ASSETS / "LaunchLogo.imageset"
    launch.mkdir(parents=True, exist_ok=True)
    for scale, width in ((1, 240), (2, 480), (3, 720)):
        fit_width(logo, width).save(launch / f"launch-logo@{scale}x.png")

    print(f"wordmark: {logo.size}, {logo.mode}; icon: {icon.size}, {icon.mode}; launch: 240/480/720px")


if __name__ == "__main__":
    main()
