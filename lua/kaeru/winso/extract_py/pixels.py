"""Pictures to a grid of RGB cells for the colored ASCII view.

Decoders, in order: the built-in PNG and BMP readers (no dependencies), Pillow when it
is installed, then ImageMagick (`magick` or `convert`), which reads JPEG, GIF and WebP.
Each cell is the average of up to nine sample points inside it. A cell is about twice
as tall as it is wide, so the grid has half as many rows as the columns would suggest.
"""
import os
import shutil
import subprocess

from . import bmp, png


def cell_rows(width, height, cols):
    """Grid rows for a picture of width x height at `cols` columns."""
    if width <= 0 or height <= 0:
        return max(1, cols // 2)
    return max(1, round(cols * height / width * 0.5))


def sample(width, height, rgb, cols, rows):
    """Average the sample points of each cell. Returns flat r, g, b integers, row by row."""
    out = []
    for cy in range(rows):
        y0 = cy * height // rows
        y1 = max(y0 + 1, (cy + 1) * height // rows)
        for cx in range(cols):
            x0 = cx * width // cols
            x1 = max(x0 + 1, (cx + 1) * width // cols)
            r = g = b = n = 0
            for ky in range(3):
                y = min(height - 1, y0 + (y1 - y0 - 1) * ky // 2)
                for kx in range(3):
                    x = min(width - 1, x0 + (x1 - x0 - 1) * kx // 2)
                    at = (y * width + x) * 3
                    r += rgb[at]
                    g += rgb[at + 1]
                    b += rgb[at + 2]
                    n += 1
            out.extend((r // n, g // n, b // n))
    return out


def _builtin(data):
    """Decode with the stdlib readers, or None when neither understands the file."""
    for decoder in (png.decode, bmp.decode):
        try:
            return decoder(data)
        except Exception:  # noqa: BLE001 - a malformed file is a reason to try the next decoder
            continue
    return None


def _pillow_module():
    try:
        from PIL import Image
    except ImportError:
        return None
    return Image


def _pillow(Image, path, cols, rows):
    with Image.open(path) as im:
        im.seek(0)
        resized = im.convert("RGB").resize((cols, rows), Image.BOX)
        return list(resized.tobytes())


def _imagemagick(path, cols, rows):
    convert = shutil.which("magick") or shutil.which("convert")
    if not convert:
        return None
    result = subprocess.run(
        [convert, path + "[0]", "-resize", "%dx%d!" % (cols, rows), "-depth", "8", "RGB:-"],
        capture_output=True,
    )
    if result.returncode != 0 or len(result.stdout) != cols * rows * 3:
        return None
    return list(result.stdout)


def _imagemagick_size(path):
    identify = shutil.which("magick")
    argv = [identify, "identify"] if identify else [shutil.which("identify")]
    if argv[-1] is None:
        return None
    result = subprocess.run(argv + ["-format", "%w %h", path + "[0]"], capture_output=True, text=True)
    try:
        width, height = result.stdout.split()[:2]
        return int(width), int(height)
    except ValueError:
        return None


def ascii_grid(path, cols):
    """{"width", "height", "pixels"} for the picture at `path`, `cols` cells wide."""
    cols = max(8, min(int(cols), 200))
    with open(path, "rb") as fh:
        data = fh.read()
    decoded = _builtin(data)
    if decoded is not None:
        width, height, rgb, _ = decoded
        rows = cell_rows(width, height, cols)
        return {"width": cols, "height": rows, "pixels": sample(width, height, rgb, cols, rows)}

    Image = _pillow_module()
    if Image is not None:
        with Image.open(path) as im:
            width, height = im.size
        rows = cell_rows(width, height, cols)
        return {"width": cols, "height": rows, "pixels": _pillow(Image, path, cols, rows)}

    size = _imagemagick_size(path)
    if size is not None:
        width, height = size
        rows = cell_rows(width, height, cols)
        pixels = _imagemagick(path, cols, rows)
        if pixels is not None:
            return {"width": cols, "height": rows, "pixels": pixels}

    raise RuntimeError(
        "cannot decode %s: install Pillow (pip install pillow) or ImageMagick for JPEG, GIF and WebP"
        % os.path.basename(path)
    )
