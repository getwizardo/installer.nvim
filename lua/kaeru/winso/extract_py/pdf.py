"""PDF through pdftotext (poppler). One chapter per page."""
import os
import shutil
import subprocess

from .common import decode_bytes, normalize


def read_pdf(path):
    tool = shutil.which("pdftotext")
    if not tool:
        raise RuntimeError("PDF needs pdftotext (poppler). Install: pkg install poppler (Termux) or apt install poppler-utils")
    result = subprocess.run([tool, "-layout", path, "-"], capture_output=True)
    if result.returncode != 0:
        raise RuntimeError("pdftotext failed: " + result.stderr.decode("utf-8", "replace").strip())
    pages = decode_bytes(result.stdout).split("\f")
    chapters = []
    for number, page in enumerate(pages, 1):
        text = normalize(page)
        if text:
            chapters.append({"title": "Page %d" % number, "text": text})
    return {"title": os.path.splitext(os.path.basename(path))[0], "author": "", "format": "pdf", "chapters": chapters}
