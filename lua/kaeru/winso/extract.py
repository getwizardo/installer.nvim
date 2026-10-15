#!/usr/bin/env python3
"""Winso text extractor: book file in, JSON out.

Usage: extract.py <book> [--images DIR]

With --images, embedded pictures (EPUB, FB2) are written to DIR and each one
appears in the text as a placeholder line: [[image: NAME]].

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
import base64
import struct
import tempfile
import xml.etree.ElementTree as ET
import zipfile

IMAGE_DIR = None      # set from --images
_IMAGES = []          # [{name, path, width, height, bytes}] for the current book
IMAGE_EXT = (".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp")

BLOCK_TAGS = {"p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "section", "title"}
SKIP_TAGS = {"script", "style", "head", "svg"}
HEADING_TAGS = {"h1", "h2", "h3"}


def local(tag):
    """XML tag without its namespace."""
    return tag.rsplit("}", 1)[-1] if isinstance(tag, str) else ""


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
    """Write an image into the images directory; returns the registered entry or None."""
    if IMAGE_DIR is None or not data:
        return None
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", os.path.basename(name)) or "image"
    if not is_image_name(safe):
        safe += sniff_ext(data)
    filename = "%03d-%s" % (len(_IMAGES) + 1, safe)
    path = os.path.join(IMAGE_DIR, filename)
    with open(path, "wb") as fh:
        fh.write(data)
    size = image_size(data) or (0, 0)
    entry = {"name": filename, "path": path, "width": size[0], "height": size[1], "bytes": len(data)}
    _IMAGES.append(entry)
    return entry


def image_placeholder(entry):
    return "\n[[image: %s]]\n" % entry["name"]


class TextHTML(html.parser.HTMLParser):
    """HTML to plain text. Block tags become line breaks; the first heading is kept as title."""

    def __init__(self, resolve_image=None):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.skip = 0
        self.heading = None
        self.in_heading = None
        self.heading_buf = []
        self.resolve_image = resolve_image

    def handle_starttag(self, tag, attrs):
        if tag in SKIP_TAGS:
            self.skip += 1
        if tag in ("img", "image") and self.resolve_image and not self.skip:
            attr = dict((k.rsplit("}", 1)[-1], v) for k, v in attrs)
            src = attr.get("src") or attr.get("href")
            if src:
                placeholder = self.resolve_image(src)
                if placeholder:
                    self.parts.append(placeholder)
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


def html_to_text(markup, resolve_image=None):
    parser = TextHTML(resolve_image)
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
            chapter_dir = os.path.dirname(member)

            def resolve(src, chapter_dir=chapter_dir):
                if src.startswith("data:"):
                    return None
                target = posixjoin(chapter_dir, src.split("#", 1)[0])
                if target not in names or not is_image_name(target):
                    return None
                entry = save_image(target, zf.read(target))
                return image_placeholder(entry) if entry else None

            heading, text = html_to_text(decode_bytes(zf.read(member)), resolve)
            if not text:
                continue
            chapters.append({"title": heading or ("Section %d" % number), "text": text})
        return {"title": title, "author": author, "format": "epub", "chapters": chapters}


def posixjoin(base, href):
    from urllib.parse import unquote
    joined = os.path.normpath(os.path.join(base, unquote(href))) if base else unquote(href)
    return joined.replace(os.sep, "/")


# -- FB2 ---------------------------------------------------------------------------------

def fb2_text(element, binaries):
    """Paragraph text of an FB2 element, in document order; <image> becomes a placeholder."""
    out = []
    for node in element.iter():
        if local(node.tag) == "p":
            out.append("".join(node.itertext()).strip())
        elif local(node.tag) == "image":
            href = next((v for k, v in node.attrib.items() if k.rsplit("}", 1)[-1] == "href"), "")
            ref = href.lstrip("#")
            if ref in binaries:
                entry = save_image(ref, binaries[ref])
                if entry:
                    out.append(image_placeholder(entry).strip())
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
    binaries = {}
    for el in root.iter():
        if local(el.tag) == "binary" and el.get("id"):
            try:
                binaries[el.get("id")] = base64.b64decode("".join("".join(el.itertext()).split()))
            except (ValueError, TypeError):
                pass
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
        text = fb2_text(section, binaries)
        if text:
            chapters.append({"title": name, "text": text})
    if not chapters:
        chapters.append({"title": title or "Text", "text": fb2_text(body, binaries)})
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
    global IMAGE_DIR
    args = list(argv[1:])
    if "--images" in args:
        at = args.index("--images")
        IMAGE_DIR = args[at + 1] if at + 1 < len(args) else None
        del args[at:at + 2]
        if IMAGE_DIR:
            os.makedirs(IMAGE_DIR, exist_ok=True)
    if not args:
        print("usage: extract.py <book> [--images DIR]", file=sys.stderr)
        return 2
    argv = [argv[0]] + args
    try:
        book = extract(argv[1])
        if not book["chapters"]:
            raise ValueError("no readable text found in this book")
    except (ValueError, RuntimeError, zipfile.BadZipFile, ET.ParseError, OSError, KeyError, StopIteration) as err:
        print("winso: " + str(err), file=sys.stderr)
        return 1
    book["images"] = list(_IMAGES)
    json.dump(book, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
