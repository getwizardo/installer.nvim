"""Plain text, Markdown and HTML pages. Chapter boundaries come from headings or chapter lines."""
import os
import re

from .common import decode_bytes, normalize
from .html_text import html_to_text

CHAPTER_RE = re.compile(r"^\s*(chapter|part|book|section|chương|chapitre|kapitel)\b.*$", re.IGNORECASE)


def split_plain(text, base_title):
    """Split plain text into chapters at chapter-like lines; one chapter when none are found."""
    lines = text.split("\n")
    starts = [i for i, line in enumerate(lines) if CHAPTER_RE.match(line) and len(line.strip()) <= 80]
    if len(starts) < 2:
        return [{"title": base_title, "text": normalize(text)}]
    chapters = []
    bounds = starts + [len(lines)]
    if starts[0] > 0 and normalize("\n".join(lines[:starts[0]])):
        chapters.append({"title": "Front matter", "text": normalize("\n".join(lines[:starts[0]]))})
    for start, end in zip(bounds, bounds[1:]):
        body = normalize("\n".join(lines[start + 1:end]))
        if body:
            chapters.append({"title": lines[start].strip(), "text": body})
    return chapters


def read_text(path, fmt):
    with open(path, "rb") as fh:
        raw = decode_bytes(fh.read())
    title = os.path.splitext(os.path.basename(path))[0]
    if fmt in ("html", "htm", "xhtml"):
        heading, text = html_to_text(raw)
        return {"title": heading or title, "author": "", "format": fmt, "chapters": [{"title": heading or title, "text": text}]}
    if fmt == "md":
        # markdown headings become chapter boundaries
        lines = raw.split("\n")
        starts = [i for i, line in enumerate(lines) if re.match(r"^#{1,2}\s+\S", line)]
        if len(starts) >= 2:
            bounds = starts + [len(lines)]
            chapters = []
            for start, end in zip(bounds, bounds[1:]):
                name = re.sub(r"^#+\s*", "", lines[start]).strip()
                body = normalize("\n".join(lines[start + 1:end]))
                chapters.append({"title": name, "text": body})
            return {"title": title, "author": "", "format": fmt, "chapters": chapters}
        return {"title": title, "author": "", "format": fmt, "chapters": [{"title": title, "text": normalize(raw)}]}
    return {"title": title, "author": "", "format": fmt or "txt", "chapters": split_plain(raw, title)}
