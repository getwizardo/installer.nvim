/**
 * A tiny namespace-aware XML parser.
 *
 * TTML (Apple Music / lrc.red / AMLL / YouTube) needs element structure,
 * attributes with prefixes and entities — not XSLT. This is a hand-written
 * scanner: no dependencies, no DOM, ~200 lines, and it keeps the prefixes
 * (`ttm:agent`, `itunes:key`, `amll:meta`) instead of resolving them, which is
 * exactly how the TTML profiles are read in practice.
 */

export interface XmlNode {
  /** Qualified name as written in the document (`ttm:agent`). */
  name: string;
  /** Local name (`agent`). */
  local: string;
  /** Namespace prefix, if any (`ttm`). */
  prefix?: string;
  attrs: Record<string, string>;
  children: XmlNode[];
  /**
   * Children **and** text nodes in document order. Interleaving matters for
   * TTML: the space in `<span>Hush,</span> <span>little</span>` is a text node
   * between two elements.
   */
  content: (XmlNode | string)[];
  /** Text directly inside this element (entities decoded, children excluded). */
  text: string;
  parent?: XmlNode;
}

const NAMED_ENTITIES: Record<string, string> = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
  nbsp: "\u00a0",
  hellip: "\u2026",
  mdash: "\u2014",
  ndash: "\u2013",
  lsquo: "\u2018",
  rsquo: "\u2019",
  ldquo: "\u201c",
  rdquo: "\u201d",
  copy: "\u00a9",
  deg: "\u00b0",
  middot: "\u00b7",
  times: "\u00d7",
};

/** Decode XML entities (`&amp;`, `&#39;`, `&#x27;`). */
export function decodeEntities(input: string): string {
  return input.replace(/&(#x?[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);/g, (match, entity: string) => {
    if (entity.startsWith("#x") || entity.startsWith("#X")) {
      const code = Number.parseInt(entity.slice(2), 16);
      return Number.isFinite(code) ? String.fromCodePoint(code) : match;
    }
    if (entity.startsWith("#")) {
      const code = Number.parseInt(entity.slice(1), 10);
      return Number.isFinite(code) ? String.fromCodePoint(code) : match;
    }
    return NAMED_ENTITIES[entity.toLowerCase()] ?? match;
  });
}

export function splitName(name: string): { local: string; prefix?: string } {
  const colon = name.indexOf(":");
  if (colon === -1) return { local: name };
  return { local: name.slice(colon + 1), prefix: name.slice(0, colon) };
}

function makeNode(name: string, attrs: Record<string, string>, parent?: XmlNode): XmlNode {
  const { local, prefix } = splitName(name);
  return { name, local, ...(prefix ? { prefix } : {}), attrs, children: [], content: [], text: "", ...(parent ? { parent } : {}) };
}

function addText(node: XmlNode | undefined, raw: string): void {
  if (!node || raw === "") return;
  const text = decodeEntities(raw);
  node.text += text;
  node.content.push(text);
}

/** Parse an XML document and return its root element. */
export function parseXml(source: string): XmlNode {
  let index = 0;
  const length = source.length;
  let root: XmlNode | undefined;
  let current: XmlNode | undefined;

  const readName = (): string => {
    const start = index;
    while (index < length && !/[\s/>=]/.test(source[index]!)) index++;
    return source.slice(start, index);
  };

  const skipWhitespace = (): void => {
    while (index < length && /\s/.test(source[index]!)) index++;
  };

  const parseAttributes = (): Record<string, string> => {
    const attrs: Record<string, string> = {};
    for (;;) {
      skipWhitespace();
      if (index >= length) break;
      const char = source[index]!;
      if (char === "/" || char === ">" || char === "?") break;
      const name = readName();
      if (name === "") {
        index++;
        continue;
      }
      skipWhitespace();
      if (source[index] === "=") {
        index++;
        skipWhitespace();
        const quote = source[index];
        if (quote === '"' || quote === "'") {
          index++;
          const end = source.indexOf(quote, index);
          const raw = end === -1 ? source.slice(index) : source.slice(index, end);
          attrs[name] = decodeEntities(raw);
          index = end === -1 ? length : end + 1;
        } else {
          const start = index;
          while (index < length && !/[\s/>]/.test(source[index]!)) index++;
          attrs[name] = decodeEntities(source.slice(start, index));
        }
      } else {
        attrs[name] = "";
      }
    }
    return attrs;
  };

  while (index < length) {
    const next = source.indexOf("<", index);
    if (next === -1) {
      addText(current, source.slice(index));
      break;
    }
    if (next > index) addText(current, source.slice(index, next));
    index = next;

    if (source.startsWith("<!--", index)) {
      const end = source.indexOf("-->", index);
      index = end === -1 ? length : end + 3;
      continue;
    }
    if (source.startsWith("<![CDATA[", index)) {
      const end = source.indexOf("]]>", index);
      const raw = source.slice(index + 9, end === -1 ? length : end);
      if (current) {
        current.text += raw;
        current.content.push(raw);
      }
      index = end === -1 ? length : end + 3;
      continue;
    }
    if (source.startsWith("<?", index)) {
      const end = source.indexOf("?>", index);
      index = end === -1 ? length : end + 2;
      continue;
    }
    if (source.startsWith("<!", index)) {
      // DOCTYPE and friends: skip to the matching '>' (allowing nested brackets)
      let depth = 0;
      while (index < length) {
        const char = source[index];
        if (char === "[") depth++;
        else if (char === "]") depth--;
        else if (char === ">" && depth <= 0) {
          index++;
          break;
        }
        index++;
      }
      continue;
    }
    if (source.startsWith("</", index)) {
      index += 2;
      readName();
      const end = source.indexOf(">", index);
      index = end === -1 ? length : end + 1;
      if (current) current = current.parent;
      continue;
    }

    // Start tag
    index++;
    const name = readName();
    if (name === "") {
      index++;
      continue;
    }
    const attrs = parseAttributes();
    const selfClosing = source[index] === "/";
    if (selfClosing) index++;
    const end = source.indexOf(">", index);
    index = end === -1 ? length : end + 1;

    const node = makeNode(name, attrs, current);
    if (current) {
      current.children.push(node);
      current.content.push(node);
    }
    else if (!root) root = node;
    if (!selfClosing) current = node;
  }

  if (!root) throw new Error("xml: no root element");
  return root;
}

/** Attribute lookup that accepts either the qualified or the local name. */
export function attr(node: XmlNode | undefined, name: string): string | undefined {
  if (!node) return undefined;
  if (node.attrs[name] !== undefined) return node.attrs[name];
  const { local } = splitName(name);
  for (const [key, value] of Object.entries(node.attrs)) {
    if (splitName(key).local === local) return value;
  }
  return undefined;
}

export function hasAttr(node: XmlNode | undefined, name: string): boolean {
  return attr(node, name) !== undefined;
}

/** Direct children whose local name matches. */
export function childrenNamed(node: XmlNode | undefined, local: string): XmlNode[] {
  if (!node) return [];
  return node.children.filter((child) => child.local === local);
}

/** First direct child with that local name. */
export function childNamed(node: XmlNode | undefined, local: string): XmlNode | undefined {
  return childrenNamed(node, local)[0];
}

/** All descendants with that local name (depth first). */
export function descendantsNamed(node: XmlNode | undefined, local: string): XmlNode[] {
  const out: XmlNode[] = [];
  const walk = (entry: XmlNode | undefined): void => {
    for (const child of entry?.children ?? []) {
      if (child.local === local) out.push(child);
      walk(child);
    }
  };
  walk(node);
  return out;
}

/** Text of a whole subtree, entities already decoded. */
export function textOf(node: XmlNode | undefined): string {
  if (!node) return "";
  let out = node.text;
  for (const child of node.children) out += textOf(child);
  return out;
}

/** Normalise whitespace the way TTML text content is usually read. */
export function collapse(text: string): string {
  return text.replace(/\s+/g, " ").trim();
}
