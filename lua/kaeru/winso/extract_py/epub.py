"""EPUB 2 and 3: spine order, embedded CSS ignored, pictures saved through images.py."""
import os
import xml.etree.ElementTree as ET
import zipfile
from urllib.parse import unquote

from . import images
from .common import decode_bytes, local
from .html_text import html_to_text


def posixjoin(base, href):
    joined = os.path.normpath(os.path.join(base, unquote(href))) if base else unquote(href)
    return joined.replace(os.sep, "/")


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
                if target not in names or not images.is_image_name(target):
                    return None
                entry = images.save_image(target, zf.read(target))
                return images.image_placeholder(entry) if entry else None

            heading, text = html_to_text(decode_bytes(zf.read(member)), resolve)
            if not text:
                continue
            chapters.append({"title": heading or ("Section %d" % number), "text": text})
        return {"title": title, "author": author, "format": "epub", "chapters": chapters}
