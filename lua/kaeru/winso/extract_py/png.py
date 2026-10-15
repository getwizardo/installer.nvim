"""PNG decoder with the standard library only (zlib). 8-bit, non-interlaced images.

Anything else raises ValueError, and pixels.py falls back to Pillow or ImageMagick.
"""
import struct
import zlib

CHANNELS = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}


def _unfilter(kind, line, prev, bpp):
    """Undo one scanline filter in place."""
    n = len(line)
    if kind == 0:
        return
    if kind == 1:
        for i in range(bpp, n):
            line[i] = (line[i] + line[i - bpp]) & 0xFF
    elif kind == 2:
        for i in range(n):
            line[i] = (line[i] + prev[i]) & 0xFF
    elif kind == 3:
        for i in range(n):
            left = line[i - bpp] if i >= bpp else 0
            line[i] = (line[i] + ((left + prev[i]) >> 1)) & 0xFF
    elif kind == 4:
        for i in range(n):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            p = a + b - c
            pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            pred = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
            line[i] = (line[i] + pred) & 0xFF
    else:
        raise ValueError("bad PNG filter type %d" % kind)


def _to_rgb(line, ctype, palette):
    """One unfiltered scanline to RGB bytes."""
    if ctype == 2:
        return bytes(line)
    out = bytearray(len(line) // CHANNELS[ctype] * 3)
    if ctype == 0:
        out[0::3] = line
        out[1::3] = line
        out[2::3] = line
    elif ctype == 4:
        out[0::3] = line[0::2]
        out[1::3] = line[0::2]
        out[2::3] = line[0::2]
    elif ctype == 6:
        out[0::3] = line[0::4]
        out[1::3] = line[1::4]
        out[2::3] = line[2::4]
    elif ctype == 3:
        if palette is None:
            raise ValueError("indexed PNG without a palette")
        return b"".join(palette[i] for i in line)
    return bytes(out)


def decode(data):
    """(width, height, rgb bytes, top-down) for a PNG file's bytes."""
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    pos, width, height, bitdepth, ctype, interlace = 8, None, None, None, None, 0
    palette, idat = None, []
    while pos + 8 <= len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        kind = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if kind == b"IHDR":
            width, height, bitdepth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
        elif kind == b"PLTE":
            palette = [bytes(body[i:i + 3]) for i in range(0, len(body) - 2, 3)]
        elif kind == b"IDAT":
            idat.append(body)
        elif kind == b"IEND":
            break
    if width is None:
        raise ValueError("PNG has no header")
    if interlace:
        raise ValueError("interlaced PNG is not supported by the built-in decoder")
    if bitdepth != 8 or ctype not in CHANNELS:
        raise ValueError("PNG bit depth %s is not supported by the built-in decoder" % bitdepth)
    channels = CHANNELS[ctype]
    stride = width * channels
    raw = zlib.decompress(b"".join(idat))
    if len(raw) < height * (stride + 1):
        raise ValueError("truncated PNG data")
    rgb = bytearray()
    prev = bytearray(stride)
    at = 0
    for _ in range(height):
        kind = raw[at]
        line = bytearray(raw[at + 1:at + 1 + stride])
        at += stride + 1
        _unfilter(kind, line, prev, channels)
        rgb += _to_rgb(line, ctype, palette)
        prev = line
    return width, height, bytes(rgb), True
