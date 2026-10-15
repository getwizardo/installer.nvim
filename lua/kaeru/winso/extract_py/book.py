"""Dispatch: pick the reader for a file by its extension."""
import os

from .docx import read_docx
from .epub import read_epub
from .fb2 import read_fb2
from .mobi import read_mobi
from .pdf import read_pdf
from .plain import read_text


def extract(path):
    lower = path.lower()
    if lower.endswith(".epub"):
        return read_epub(path)
    if lower.endswith(".fb2") or lower.endswith(".fb2.zip"):
        return read_fb2(path)
    if lower.endswith(".docx"):
        return read_docx(path)
    if lower.endswith(".pdf"):
        return read_pdf(path)
    if lower.endswith((".mobi", ".azw", ".azw3", ".prc")):
        return read_mobi(path)
    if lower.endswith((".html", ".htm", ".xhtml")):
        return read_text(path, "html")
    if lower.endswith((".md", ".markdown")):
        return read_text(path, "md")
    if lower.endswith((".txt", ".text", ".log", "")):
        return read_text(path, "txt")
    raise ValueError("unsupported format: " + os.path.splitext(path)[1] + " (Winso reads epub, fb2, pdf, mobi, azw3, docx, html, md, txt)")
