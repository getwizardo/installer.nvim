"""BMP decoder with the standard library only: uncompressed 8, 24 and 32 bit images."""
import struct


def decode(data):
    """(width, height, rgb bytes, top-down) for a BMP file's bytes."""
    if data[:2] != b"BM" or len(data) < 54:
        raise ValueError("not a BMP")
    offset = struct.unpack_from("<I", data, 10)[0]
    header_size = struct.unpack_from("<I", data, 14)[0]
    if header_size < 40:
        raise ValueError("unsupported BMP header")
    width, height = struct.unpack_from("<ii", data, 18)
    _, bpp, compression = struct.unpack_from("<HHI", data, 26)
    if compression not in (0, 3):
        raise ValueError("compressed BMP is not supported")
    if bpp not in (8, 24, 32):
        raise ValueError("BMP with %d bits per pixel is not supported" % bpp)
    top_down = height < 0
    height = abs(height)
    palette = None
    if bpp == 8:
        count = struct.unpack_from("<I", data, 46)[0] or 256
        start = 14 + header_size
        palette = [data[start + 4 * i:start + 4 * i + 3] for i in range(count)]
    stride = ((width * bpp + 31) // 32) * 4
    step = bpp // 8
    rgb = bytearray(width * height * 3)
    for y in range(height):
        src = y if top_down else height - 1 - y
        base = offset + src * stride
        row = data[base:base + stride]
        if bpp == 8:
            out = b"".join(palette[row[x]][::-1] for x in range(width))
            rgb[y * width * 3:(y + 1) * width * 3] = out
        else:
            out = bytearray(width * 3)
            out[0::3] = row[2:width * step:step]
            out[1::3] = row[1:width * step:step]
            out[2::3] = row[0:width * step:step]
            rgb[y * width * 3:(y + 1) * width * 3] = out
    return width, height, bytes(rgb), True
