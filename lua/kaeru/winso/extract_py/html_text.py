"""HTML to plain text. Block tags become line breaks; the first heading is kept as title."""
import html.parser

from .common import normalize

BLOCK_TAGS = {"p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "section", "title"}
SKIP_TAGS = {"script", "style", "head", "svg"}
HEADING_TAGS = {"h1", "h2", "h3"}


class TextHTML(html.parser.HTMLParser):
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
    """(heading, text) for an HTML document. Broken markup yields whatever was parsed."""
    parser = TextHTML(resolve_image)
    try:
        parser.feed(markup)
        parser.close()
    except Exception:
        pass
    return parser.heading, normalize("".join(parser.parts))
