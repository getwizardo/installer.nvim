"""Tests for the Winso extractor's stdlib picture path. Run: python3 -m unittest tests/winso_extract_test.py"""

import os
import struct
import sys
import tempfile
import unittest
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lua", "kaeru", "winso"))

from extract_py import png, pixels  # noqa: E402


def chunk(kind, body):
    return struct.pack(">I", len(body)) + kind + body + struct.pack(">I", zlib.crc32(kind + body) & 0xFFFFFFFF)


def make_png(width, height, rows):
    """8-bit RGB PNG. Each row is filtered with the Sub filter (type 1)."""
    raw = bytearray()
    for row in rows:
        raw.append(1)
        for i, value in enumerate(row):
            left = row[i - 3] if i >= 3 else 0
            raw.append((value - left) & 0xFF)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(raw))) + chunk(b"IEND", b"")


class PngTest(unittest.TestCase):
    def test_sub_filter_round_trips(self):
        row0 = [10, 20, 30, 200, 210, 220]
        row1 = [0, 0, 0, 255, 255, 255]
        width, height, rgb, top_down = png.decode(make_png(2, 2, [row0, row1]))
        self.assertEqual((width, height), (2, 2))
        self.assertEqual(list(rgb), row0 + row1)
        self.assertTrue(top_down)

    def test_sixteen_bit_is_rejected_for_the_fallback(self):
        ihdr = struct.pack(">IIBBBBB", 1, 1, 16, 2, 0, 0, 0)
        data = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IEND", b"")
        with self.assertRaises(ValueError):
            png.decode(data)


class GridTest(unittest.TestCase):
    def test_grid_has_requested_columns_and_pixel_count(self):
        cells = [[x * 60, y * 60, 128] for y in range(4) for x in range(4)]
        data = make_png(4, 4, [sum(cells[y * 4:(y + 1) * 4], []) for y in range(4)])
        with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as fh:
            fh.write(data)
            path = fh.name
        try:
            grid = pixels.ascii_grid(path, 8)
        finally:
            os.remove(path)
        self.assertEqual(grid["width"], 8)
        self.assertEqual(grid["height"], pixels.cell_rows(4, 4, 8))
        self.assertEqual(len(grid["pixels"]), grid["width"] * grid["height"] * 3)


if __name__ == "__main__":
    unittest.main()
