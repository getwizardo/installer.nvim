"""MOBI, AZW and AZW3: converted to EPUB by Calibre's ebook-convert, then read as EPUB."""
import os
import shutil
import subprocess
import tempfile

from .epub import read_epub


def read_mobi(path):
    tool = shutil.which("ebook-convert")
    if not tool:
        raise RuntimeError("MOBI/AZW needs Calibre's ebook-convert. Install Calibre, or convert the book to EPUB first.")
    with tempfile.TemporaryDirectory() as tmp:
        out = os.path.join(tmp, "book.epub")
        result = subprocess.run([tool, path, out], capture_output=True)
        if result.returncode != 0 or not os.path.exists(out):
            raise RuntimeError("ebook-convert failed: " + result.stderr.decode("utf-8", "replace").strip()[-300:])
        book = read_epub(out)
    book["format"] = os.path.splitext(path)[1].lstrip(".").lower()
    return book
