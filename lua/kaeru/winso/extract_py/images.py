"""Embedded pictures: sizing, naming and the list written next to the book."""
import os
import re
import struct

IMAGE_EXT = (".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp")

_state = {"dir": None, "images": []}


def configure(image_dir):
    """Where pictures are written. None keeps them in memory only (no files)."""
    _state["dir"] = image_dir


def images():
    """Entries saved so far for the current book."""
    return list(_state["images"])


def image_size(data):
    """(width, height) from PNG, GIF or JPEG headers; None when unknown."""
    try:
        if data[:8] == b"\x89PNG\r\n\x1a\n":
            return struct.unpack(">II", data[16:24])
        if data[:6] in (b"GIF87a", b"GIF89a"):
            return struct.unpack("<HH", data[6:10])
        if data[:2] == b"\xff\xd8":
            i = 2
            while i + 9 < len(data):
                if data[i] != 0xFF:
                    i += 1
                    continue
                marker = data[i + 1]
                if marker in (0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF):
                    h, w = struct.unpack(">HH", data[i + 5:i + 9])
                    return (w, h)
                seg = struct.unpack(">H", data[i + 2:i + 4])[0]
                i += 2 + seg
    except (struct.error, IndexError):
        return None
    return None


def is_image_name(name):
    return name.lower().endswith(IMAGE_EXT)


def sniff_ext(data):
    """File extension from the magic bytes, so viewers can open images without one."""
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return ".png"
    if data[:2] == b"\xff\xd8":
        return ".jpg"
    if data[:6] in (b"GIF87a", b"GIF89a"):
        return ".gif"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return ".webp"
    if data[:2] == b"BM":
        return ".bmp"
    return ""


def save_image(name, data):
    """Write an image into the images directory; returns the registered entry or None.

    Without a directory (no --images flag) pictures are skipped, so no placeholders appear.
    """
    if _state["dir"] is None or not data:
        return None
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", os.path.basename(name)) or "image"
    if not is_image_name(safe):
        safe += sniff_ext(data)
    filename = "%03d-%s" % (len(_state["images"]) + 1, safe)
    path = os.path.join(_state["dir"], filename)
    with open(path, "wb") as fh:
        fh.write(data)
    size = image_size(data) or (0, 0)
    entry = {"name": filename, "path": path, "width": size[0], "height": size[1], "bytes": len(data)}
    _state["images"].append(entry)
    return entry


def image_placeholder(entry):
    return "\n[[image: %s]]\n" % entry["name"]
