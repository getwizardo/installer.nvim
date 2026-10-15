#!/usr/bin/env python3
"""Winso extractor: book file in, JSON out. The code lives in extract_py/.

Usage:
  extract.py <book> [--images DIR]
      Prints the book as JSON:
      {"title", "author", "format", "chapters": [{"title", "text"}], "images": [...]}
      With --images, embedded pictures are written to DIR and each one appears in the
      text as a placeholder line: [[image: NAME]].

  extract.py --ascii <picture> --cols N
      Prints a color grid for the ASCII picture view:
      {"width", "height", "pixels": [r, g, b, ...]} (row by row, N cells wide).

Errors go to stderr with exit code 1, so the Lua side can show them.
Uses only the Python standard library. Pillow and ImageMagick are optional (JPEG, GIF
and WebP pictures need one of them). PDF needs `pdftotext`; MOBI/AZW need `ebook-convert`.
"""
import json
import os
import sys
import xml.etree.ElementTree as ET
import zipfile

from extract_py import images
from extract_py.book import extract
from extract_py.pixels import ascii_grid


def _usage():
    print("usage: extract.py <book> [--images DIR] | extract.py --ascii <picture> --cols N", file=sys.stderr)
    return 2


def _take(args, flag):
    """Remove `flag VALUE` from args and return VALUE (None when absent)."""
    if flag not in args:
        return None
    at = args.index(flag)
    value = args[at + 1] if at + 1 < len(args) else None
    del args[at:at + 2]
    return value


def main(argv):
    args = list(argv[1:])
    if "--ascii" in args:
        picture = _take(args, "--ascii")
        cols = _take(args, "--cols") or "60"
        if not picture:
            return _usage()
        try:
            grid = ascii_grid(picture, int(cols))
        except (OSError, RuntimeError, ValueError) as err:
            print("winso: " + str(err), file=sys.stderr)
            return 1
        json.dump(grid, sys.stdout)
        sys.stdout.write("\n")
        return 0

    image_dir = _take(args, "--images")
    if image_dir:
        os.makedirs(image_dir, exist_ok=True)
        images.configure(image_dir)
    if not args:
        return _usage()
    try:
        book = extract(args[0])
        if not book["chapters"]:
            raise ValueError("no readable text found in this book")
    except (ValueError, RuntimeError, zipfile.BadZipFile, ET.ParseError, OSError, KeyError, StopIteration) as err:
        print("winso: " + str(err), file=sys.stderr)
        return 1
    book["images"] = images.images()
    json.dump(book, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
