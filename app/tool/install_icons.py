#!/usr/bin/env python3
"""assets/logo PNG'lerini platform ikonlarına dönüştürür. macOS'taki sips'i kullanır."""
import shutil
import struct
import subprocess
import tempfile
from pathlib import Path

APP = Path(__file__).resolve().parent.parent
LOGO = APP / "assets/logo"
FULL = LOGO / "logo_1024.png"
MAC = LOGO / "logo_macos_1024.png"
FOREGROUND = LOGO / "logo_foreground_432.png"


def resize(source: Path, size: int, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        ["sips", "-s", "format", "png", "-z", str(size), str(size), str(source), "--out", str(target)],
        check=True,
        capture_output=True,
    )


def write_ico(target: Path, sizes: list[int]) -> None:
    """PNG gömülü ICO yazar (Windows Vista ve sonrası)."""
    with tempfile.TemporaryDirectory() as temp:
        blobs = []
        for size in sizes:
            path = Path(temp) / f"{size}.png"
            resize(FULL, size, path)
            blobs.append((size, path.read_bytes()))
    offset = 6 + 16 * len(blobs)
    header = struct.pack("<HHH", 0, 1, len(blobs))
    entries, data = b"", b""
    for size, blob in blobs:
        side = 0 if size >= 256 else size
        entries += struct.pack("<BBBBHHII", side, side, 0, 0, 1, 32, len(blob), offset)
        data += blob
        offset += len(blob)
    target.write_bytes(header + entries + data)


def main() -> None:
    mac_dir = APP / "macos/Runner/Assets.xcassets/AppIcon.appiconset"
    for size in (16, 32, 64, 128, 256, 512, 1024):
        resize(MAC, size, mac_dir / f"app_icon_{size}.png")

    write_ico(APP / "windows/runner/resources/app_icon.ico", [16, 24, 32, 48, 64, 128, 256])

    res = APP / "android/app/src/main/res"
    densities = {"mdpi": (48, 108), "hdpi": (72, 162), "xhdpi": (96, 216), "xxhdpi": (144, 324), "xxxhdpi": (192, 432)}
    for density, (icon, foreground) in densities.items():
        resize(FULL, icon, res / f"mipmap-{density}/ic_launcher.png")
        resize(FOREGROUND, foreground, res / f"mipmap-{density}/ic_launcher_foreground.png")
    adaptive = res / "mipmap-anydpi-v26"
    adaptive.mkdir(exist_ok=True)
    (adaptive / "ic_launcher.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@drawable/ic_launcher_background" />\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
        "</adaptive-icon>\n"
    )
    (res / "drawable/ic_launcher_background.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<shape xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <gradient android:angle="270" android:startColor="#2F7BFF" android:endColor="#0B2E8A" />\n'
        "</shape>\n"
    )

    icons = APP.parent / "extension/icons"
    for size in (16, 32, 48, 128):
        resize(FULL, size, icons / f"icon{size}.png")
    print("İkonlar güncellendi.")


if __name__ == "__main__":
    main()
