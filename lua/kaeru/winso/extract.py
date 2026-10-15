#!/usr/bin/env python3
"""Winso text extractor: book file in, JSON out.

Usage: extract.py <book> [--width N]

Prints one JSON object on stdout:
  {"title": str, "author": str, "format": str,
   "chapters": [{"title": str, "text": str}, ...]}
where `text` is plain text, paragraphs separated by blank lines.
Errors go to stderr with exit code 1, so the Lua side can show them.

Uses only the Python standard library, so it runs on Termux and minimal systems.
PDF needs `pdftotext` (poppler); MOBI/AZW/AZW3 need Calibre's `ebook-convert`.
"""
import html.parser
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

BLOCK_TAGS = {"p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "section", "title"}
SKIP_TAGS = {"script", "style", "head", "svg"}
HEADING_TAGS = {"h1", "h2", "h3"}


def local(tag):
    """XML tag without its namespace."""
    return tag.rsplit("}", 1)[-1] if isinstance(tag, str) else ""


class TextHTML(html.parser.HTMLParser):
    """HTML to plain text. Block tags become line breaks; the first heading is kept as title."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.skip = 0
        self.heading = None
        self.in_heading = None
        self.heading_buf = []

    def handle_starttag(self, tag, attrs):
        if tag in SKIP_TAGS:
            self.skip += 1
        if tag in BLOCK_TAGS:
            self.parts.append("\n")
        if tag in HEADING_TAGS and self.heading is None:
            self.in_heading = tag

    def handle_endtag(self, tag):
        if tag in SKIP_TAGS and self.skip:
            self.skip -= 1
        if tag in BLOCK_TAGS:
            self.parts.append("\n")
        if tag == self.in_heading:
            self.heading = " ".join("".join(self.heading_buf).split())
            self.in_heading = None

    def handle_data(self, data):
        if self.skip:
            return
        self.parts.append(data)
        if self.in_heading:
            self.heading_buf.append(data)


def html_to_text(markup):
    parser = TextHTML()
    try:
        parser.feed(markup)
        parser.close()
    except Exception:
        pass
    return parser.heading, normalize("".join(parser.parts))


def normalize(text):
    """Collapse runs of spaces, keep one blank line between paragraphs."""
    text = text.replace("\r\n", "\n").replace("\r", "\n").replace("\xa0", " ")
    lines = [re.sub(r"[ \t]+", " ", line).strip() for line in text.split("\n")]
    out, blank = [], True
    for line in lines:
        if line:
            out.append(line)
            blank = False
        elif not blank:
            out.append("")
            blank = True
    return "\n".join(out).strip()


def decode_bytes(data):
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    for enc in ("utf-8", "cp1252", "latin-1"):
        try:
            return data.decode(enc)
        except UnicodeDecodeError:
            continue
    return data.decode("utf-8", "replace")


# -- EPUB ------------------------------------------------------------------------------

def read_epub(path):
    with zipfile.ZipFile(path) as zf:
        names = set(zf.namelist())
        opf_path = None
        if "META-INF/container.xml" in names:
            root = ET.fromstring(zf.read("META-INF/container.xml"))
            for el in root.iter():
                if local(el.tag) == "rootfile" and el.get("full-path"):
                    opf_path = el.get("full-path")
                    break
        if not opf_path:
            opf_path = next((n for n in names if n.lower().endswith(".opf")), None)
        if not opf_path:
            raise ValueError("EPUB has no package (.opf) file")
        opf = ET.fromstring(zf.read(opf_path))
        base = os.path.dirname(opf_path)

        title, author = "", ""
        manifest, spine = {}, []
        for el in opf.iter():
            name = local(el.tag)
            if name == "title" and not title and el.text:
                title = el.text.strip()
            elif name == "creator" and not author and el.text:
                author = el.text.strip()
            elif name == "item":
                manifest[el.get("id")] = (el.get("href") or "", el.get("media-type") or "")
            elif name == "itemref":
                spine.append(el.get("idref"))

        chapters = []
        for number, idref in enumerate(spine, 1):
            href, media = manifest.get(idref, ("", ""))
            if not href or ("html" not in media and "xml" not in media and not href.lower().endswith((".html", ".xhtml", ".htm"))):
                continue
            member = posixjoin(base, href)
            if member not in names:
                continue
            heading, text = html_to_text(decode_bytes(zf.read(member)))
            if not text:
                continue
            chapters.append({"title": heading or ("Section %d" % number), "text": text})
        return {"title": title, "author": author, "format": "epub", "chapters": chapters}


def posixjoin(base, href):
    from urllib.parse import unquote
    joined = os.path.normpath(os.path.join(base, unquote(href))) if base else unquote(href)
    return joined.replace(os.sep, "/")


# -- FB2 ---------------------------------------------------------------------------------

def fb2_text(element):
    """Paragraph text of an FB2 element, in document order."""
    out = []
    for node in element.iter():
        if local(node.tag) == "p" and node.text is not None or local(node.tag) == "p":
            out.append("".join(node.itertext()).strip())
    return normalize("\n".join(out))


def read_fb2(path):
    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as zf:
            member = next(n for n in zf.namelist() if n.lower().endswith(".fb2"))
            data = zf.read(member)
    else:
        with open(path, "rb") as fh:
            data = fh.read()
    root = ET.fromstring(data)
    title, author = "", ""
    for el in root.iter():
        if local(el.tag) == "book-title" and not title and el.text:
            title = el.text.strip()
        if local(el.tag) == "author" and not author:
            author = " ".join(t.strip() for t in el.itertext() if t.strip())
    chapters = []
    body = next((el for el in root.iter() if local(el.tag) == "body"), root)
    for section in body:
        if local(section.tag) != "section":
            continue
        heading = next((el for el in section if local(el.tag) == "title"), None)
        name = " ".join("".join(heading.itertext()).split()) if heading is not None else "Section %d" % (len(chapters) + 1)
        text = fb2_text(section)
        if text:
            chapters.append({"title": name, "text": text})
    if not chapters:
        chapters.append({"title": title or "Text", "text": fb2_text(body)})
    return {"title": title, "author": author, "format": "fb2", "chapters": chapters}


# -- DOCX --------------------------------------------------------------------------------

def read_docx(path):
    with zipfile.ZipFile(path) as zf:
        root = ET.fromstring(zf.read("word/document.xml"))
    paragraphs = []
    for p in root.iter():
        if local(p.tag) == "p":
            paragraphs.append("".join(t.text or "" for t in p.iter() if local(t.tag) == "t"))
    text = normalize("\n".join(paragraphs))
    return {"title": os.path.splitext(os.path.basename(path))[0], "author": "", "format": "docx",
            "chapters": [{"title": "Document", "text": text}]}


# -- PDF / MOBI (external tools) --------------------------------------------------------

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


# -- plain text and HTML --------------------------------------------------------------

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


# -- dispatch ----------------------------------------------------------------------------

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


def main(argv):
    if len(argv) < 2:
        print("usage: extract.py <book>", file=sys.stderr)
        return 2
    try:
        book = extract(argv[1])
        if not book["chapters"]:
            raise ValueError("no readable text found in this book")
    except (ValueError, RuntimeError, zipfile.BadZipFile, ET.ParseError, OSError, KeyError, StopIteration) as err:
        print("winso: " + str(err), file=sys.stderr)
        return 1
    json.dump(book, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
