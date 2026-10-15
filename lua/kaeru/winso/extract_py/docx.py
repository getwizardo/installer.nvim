"""Word documents (.docx): paragraph text from word/document.xml."""
import os
import xml.etree.ElementTree as ET
import zipfile

from .common import local, normalize


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
