"""FictionBook 2 (.fb2 and .fb2.zip): sections become chapters, base64 pictures are saved."""
import base64
import xml.etree.ElementTree as ET
import zipfile

from . import images
from .common import local, normalize


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
                entry = images.save_image(ref, binaries[ref])
                if entry:
                    out.append(images.image_placeholder(entry).strip())
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
