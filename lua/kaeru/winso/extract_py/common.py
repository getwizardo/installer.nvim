"""Helpers shared by the format readers."""
import re


def local(tag):
    """XML tag without its namespace."""
    return tag.rsplit("}", 1)[-1] if isinstance(tag, str) else ""


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
    """Text from bytes: UTF-8 (with or without BOM), then cp1252, then latin-1."""
    if data.startswith(b"\xef\xbb\xbf"):
        data = data[3:]
    for enc in ("utf-8", "cp1252", "latin-1"):
        try:
            return data.decode(enc)
        except UnicodeDecodeError:
            continue
    return data.decode("utf-8", "replace")
