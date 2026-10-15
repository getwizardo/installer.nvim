/**
 * TTML parser — Apple Music, lrc.red, AMLL (QQ/NCM), and legacy YouTube captions.
 *
 * The plugin's lyrics pipeline speaks one shape (see `lua/kaeru/kikru/lyrics.lua`):
 *
 *   { synced: [{time, text, words: [{t, text}]}], plain, source, offset, meta, raw }
 *
 * `time` is seconds, `words[].t` is a per-word offset **inside the line** — the
 * same convention the enhanced-LRC parser produces (`[mm:ss.xx]<mm:ss.xx>word`).
 * Everything here normalises to that, so a TTML hit drives karaoke exactly like
 * an LRC hit does, and it can be rendered back as enhanced LRC for the Lua side.
 */

import { attr, childNamed, childrenNamed, collapse, descendantsNamed, hasAttr, parseXml, textOf, type XmlNode } from "./xml.ts";

export interface TtmlWord {
  /** Offset from the start of the line, in seconds. */
  t: number;
  /** Absolute time of this word, in seconds. */
  time: number;
  text: string;
  /** End offset from the start of the line, in seconds. */
  e?: number;
  /** `ttm:role` carried by an ancestor (e.g. `x-bg` for background vocals). */
  role?: string;
  /**
   * The source had no whitespace before this fragment: it continues the
   * previous word (`lit` + `tle` = *little*, and AMLL splits every syllable).
   * Writers must join these without a separator.
   */
  glue?: boolean;
}

export interface TtmlLine {
  /** Line start, in seconds. */
  time: number;
  /** Line end, in seconds. */
  end?: number;
  text: string;
  words: TtmlWord[];
  /** 1-based index inside its `<div>`, i.e. the singer for Apple duets. */
  agent?: number;
  /** Raw agent id (`v1`, `v1000`, …). */
  agentId?: string;
  /** `itunes:key` — Apple's stable line id, used to attach translations. */
  key?: string;
  /** `itunes:songPart` of the enclosing `<div>` (`Chorus`, `Bridge`, …). */
  part?: string;
}

export interface LyricsDoc {
  synced: TtmlLine[];
  plain: string;
  /** ISO code of the lyric language, from `xml:lang` on the root. */
  lang?: string;
  timing?: "Line" | "Word" | "None";
  /** Apple's translation set, keyed by `itunes:key`, primary language first. */
  translations: Record<string, string>;
  /** `xml:lang` of each translation, in the order they were declared. */
  translationLangs: string[];
  /** Transliteration (romanisation) tracks — word timed when the source is. */
  transliterations: { lang?: string; lines: Record<string, { text: string; words: TtmlWord[] }> }[];
  /** Per-line singer index for duets (1-based), keyed by `itunes:key` or index. */
  agents: number[];
  /** `itunes:key` per line index. */
  keys: string[];
  meta: Record<string, string | string[]>;
  /** `<div begin>` — the master tempo/offset, in **milliseconds**. */
  offset: number;
  /** True when any line carries per-word timing. */
  wordSync: boolean;
  /** True when `ttm:role="x-bg"` lines or spans were present. */
  hasBackground: boolean;
  /** 0..1 — how much of the timeline is covered by `<p>` elements. */
  coverage: number;
}

/** Historical name — a parsed document from any supported source. */
export type ParsedTtml = LyricsDoc;

export interface ParseOptions {
  /** Player-clock -> lyric-clock in seconds, e.g. `<audio lyricOffset>`. */
  lyricOffset?: number;
  /** Keep `x-bg` background lines instead of folding them into the parent line. */
  keepBackground?: boolean;
}

/* -------------------------------------------------------------------------- */
/* Time                                                                        */
/* -------------------------------------------------------------------------- */

/** Lyric timestamps are only meaningful down to the millisecond. */
function ms(value: number): number {
  return Math.round(value * 1000) / 1000;
}

const TIME_UNITS: Record<string, number> = {
  h: 3600,
  m: 60,
  s: 1,
  ms: 0.001,
  f: 1 / 30,
  t: 0.01,
};

/**
 * Parse a TTML time expression.
 *
 * Accepted: `1:23.456`, `00:01:23.456`, `83.456`, `83s`, `1.5m`, `2h`,
 * `120ms`, `10f`, `12t`, and `offset`-style relative values are *not* handled
 * here because TTML clock offsets never appear in lyric documents.
 */
export function parseTime(input: string | undefined): number | undefined {
  if (input == null) return undefined;
  const value = String(input).trim().replace(/^\+/, "");
  if (value === "") return undefined;

  const unit = TIME_UNITS[value.slice(-2)] !== undefined && /[a-z]{1,2}$/i.test(value)
    ? value.slice(-2).toLowerCase()
    : /[a-z]$/i.test(value)
      ? value.slice(-1).toLowerCase()
      : undefined;
  const body = unit ? value.slice(0, -unit.length) : value;
  if (body === "" || !/^[0-9:.]+$/.test(body)) return undefined;

  const frames = body.split(":");
  if (frames.length > 4) return undefined;
  let seconds = 0;
  for (let i = 0; i < frames.length; i++) {
    const frame = frames[i]!;
    const parsed = frame === "" ? 0 : Number(frame);
    if (!Number.isFinite(parsed)) return undefined;
    seconds = seconds * 60 + parsed;
  }
  if (seconds < 0) return undefined;
  return ms(unit ? seconds * TIME_UNITS[unit]! : seconds);
}

/* -------------------------------------------------------------------------- */
/* Words                                                                      */
/* -------------------------------------------------------------------------- */

const ROLE_BG = "x-bg";
const TRANSLATION_ROLES = ["x-translation", "x-roman", "x-transliteration"];

function isBackground(role: string | undefined): boolean {
  return role !== undefined && (role === ROLE_BG || role.includes("x-bg"));
}

function isTranslationRole(role: string | undefined): boolean {
  return role !== undefined && TRANSLATION_ROLES.some((candidate) => role.includes(candidate));
}

interface WordDraft {
  text: string;
  begin?: number;
  end?: number;
  role?: string;
  lang?: string;
}

/**
 * Flatten a `<p>`'s content into word drafts in document order, preserving the
 * whitespace that separates fragments — that whitespace is meaningful
 * (`<span>Hush,</span> <span>little</span>`).
 */
function collectWords(node: XmlNode, inheritedRole: string | undefined, out: WordDraft[]): void {
  const role = attr(node, "ttm:role") ?? inheritedRole;
  const lang = attr(node, "xml:lang");
  for (const entry of node.content) {
    if (typeof entry === "string") {
      if (entry !== "") out.push({ text: entry, ...(role ? { role } : {}), ...(lang ? { lang } : {}) });
      continue;
    }
    const child = entry;
    const childRole = attr(child, "ttm:role") ?? role;
    const childLang = attr(child, "xml:lang") ?? lang;
    const begin = parseTime(attr(child, "begin"));
    const end = parseTime(attr(child, "end"));
    if (child.local === "br") {
      // A break inside a <p> is a continuation of the same cue: LRC has one
      // stamp per line, so the two halves are joined with a space.
      out.push({ text: " ", ...(childRole ? { role: childRole } : {}) });
      continue;
    }
    if (child.local === "span" && child.children.length > 0) {
      // Timed wrapper around untimed syllables (`<span begin><span>lit</span><span>tle</span></span>`):
      // recurse with the wrapper's timing as the fallback for its children.
      for (const grand of child.children) {
        const grandBegin = parseTime(attr(grand, "begin")) ?? begin;
        const grandEnd = parseTime(attr(grand, "end")) ?? end;
        const grandRole = attr(grand, "ttm:role") ?? childRole;
        const grandLang = attr(grand, "xml:lang") ?? childLang;
        if (grand.children.length === 0) {
          out.push({
            text: grand.text,
            ...(grandBegin !== undefined ? { begin: grandBegin } : {}),
            ...(grandEnd !== undefined ? { end: grandEnd } : {}),
            ...(grandRole ? { role: grandRole } : {}),
            ...(grandLang ? { lang: grandLang } : {}),
          });
          continue;
        }
        const nested = grand.text;
        if (nested !== "") out.push({ text: nested, ...(grandBegin !== undefined ? { begin: grandBegin } : {}), ...(grandRole ? { role: grandRole } : {}), ...(grandLang ? { lang: grandLang } : {}) });
        collectWordsNested(grand, grandRole, grandLang, grandBegin, grandEnd, out);
      }
      continue;
    }
    if (child.children.length === 0) {
      out.push({
        text: child.text,
        ...(begin !== undefined ? { begin } : {}),
        ...(end !== undefined ? { end } : {}),
        ...(childRole ? { role: childRole } : {}),
        ...(childLang ? { lang: childLang } : {}),
      });
      continue;
    }
    // An element with mixed content that is not a lyric span (rare: `<span>`
    // holding inline markup). Keep its structure.
    collectWordsNested(child, childRole, childLang, begin, end, out);
  }
}

/** Recurse into a nested element, inheriting timing/role/lang from its parent. */
function collectWordsNested(
  node: XmlNode,
  role: string | undefined,
  lang: string | undefined,
  begin: number | undefined,
  end: number | undefined,
  out: WordDraft[],
): void {
  for (const entry of node.content) {
    if (typeof entry === "string") {
      if (entry !== "") out.push({ text: entry, ...(begin !== undefined ? { begin } : {}), ...(end !== undefined ? { end } : {}), ...(role ? { role } : {}), ...(lang ? { lang } : {}) });
      continue;
    }
    const child = entry;
    const childRole = attr(child, "ttm:role") ?? role;
    const childLang = attr(child, "xml:lang") ?? lang;
    if (child.children.length === 0) {
      const childBegin = parseTime(attr(child, "begin")) ?? begin;
      const childEnd = parseTime(attr(child, "end")) ?? end;
      out.push({
        text: child.text,
        ...(childBegin !== undefined ? { begin: childBegin } : {}),
        ...(childEnd !== undefined ? { end: childEnd } : {}),
        ...(childRole ? { role: childRole } : {}),
        ...(childLang ? { lang: childLang } : {}),
      });
      continue;
    }
    collectWordsNested(child, childRole, childLang, parseTime(attr(child, "begin")) ?? begin, parseTime(attr(child, "end")) ?? end, out);
  }
}

interface BuiltLine {
  text: string;
  words: TtmlWord[];
  /** Inline `x-translation` fragments found inside the line. */
  inline: { lang?: string; text: string }[];
  /** True when the document timed individual words of this line. */
  timed: boolean;
}

/**
 * Turn drafts into a line: `words` for karaoke (offsets relative to the line),
 * `text` for display. Whitespace comes from the document, so adjacent spans
 * without a space (`lit` + `tle`) join into one word.
 */
function buildLine(drafts: WordDraft[], lineStart: number, lineEnd: number | undefined, keepBackground: boolean): BuiltLine {
  const words: TtmlWord[] = [];
  const inline: { lang?: string; text: string }[] = [];
  let text = "";
  let pendingSpace = false;

  const append = (fragment: string, role: string | undefined, leading: string): void => {
    if (fragment === "") return;
    const background = isBackground(role);
    // Background vocals stay on the singer's line (in parentheses) unless the
    // caller asked for them separately.
    if (background && keepBackground) return;
    const needsSpace = background || leading !== "" || pendingSpace;
    if (needsSpace && text !== "" && !/\s$/.test(text)) text += " ";
    text += fragment;
  };

  for (const draft of drafts) {
    const fragment = draft.text;
    if (fragment === "") continue;
    if (isTranslationRole(draft.role)) {
      const value = collapse(fragment);
      if (value !== "") inline.push({ ...(draft.lang ? { lang: draft.lang } : {}), text: value });
      continue;
    }
    const leading = /^\s*/.exec(fragment)![0];
    const trailing = /\s*$/.exec(fragment)![0];
    const core = fragment.trim();
    if (core === "") {
      pendingSpace = true;
      continue;
    }
    let offset = draft.begin !== undefined ? draft.begin - lineStart : undefined;
    if (offset === undefined) {
      // Untimed fragment (an interjection written as plain text, a syllable
      // continuing the previous span): it belongs right after the word before it.
      const previous = words[words.length - 1];
      offset = previous ? previous.e ?? previous.t : 0;
    }
    const relative = Math.max(0, ms(offset));
    const background = isBackground(draft.role);
    const glue = words.length > 0 && !background && leading === "" && !pendingSpace;
    const word: TtmlWord = {
      t: relative,
      time: ms(lineStart + relative),
      text: core,
      ...(draft.end !== undefined ? { e: Math.max(relative, ms(draft.end - lineStart)) } : {}),
      ...(background ? { role: draft.role } : {}),
      ...(glue ? { glue: true } : {}),
    };
    words.push(word);
    append(core, draft.role, leading);
    pendingSpace = trailing !== "";
  }

  if (words.length === 0) {
    // No per-word structure at all: the whole line is one fragment.
    const flat = collapse(text);
    if (flat !== "") words.push({ t: 0, time: lineStart, text: flat, ...(lineEnd !== undefined ? { e: ms(lineEnd - lineStart) } : {}) });
    text = flat;
  }

  const cleaned = text.replace(/[^\S\n]+/g, " ").replace(/ ?\n ?/g, "\n").trim();
  return {
    text: cleaned === "" ? collapse(text) : cleaned,
    words: normaliseWords(words, lineEnd !== undefined ? ms(lineEnd - lineStart) : undefined),
    inline,
    timed: drafts.some((draft) => draft.begin !== undefined && draft.text.trim() !== ""),
  };
}

/** Drop empty fragments, repair offsets that go backwards and close open ends. */
function normaliseWords(words: TtmlWord[], lineDuration: number | undefined): TtmlWord[] {
  const out: TtmlWord[] = [];
  for (const word of words) {
    if (word.text === "") continue;
    const text = word.text.replace(/\s+/g, " ");
    const previous = out[out.length - 1];
    if (previous) {
      const floor = previous.e ?? previous.t;
      if (word.t < floor) word.t = floor;
      if (lineDuration !== undefined && word.t > lineDuration) word.t = lineDuration;
    }
    if (word.e !== undefined && word.e <= word.t) delete word.e;
    out.push({ ...word, text });
  }
  for (let i = 0; i < out.length; i++) {
    const word = out[i]!;
    if (word.e !== undefined) continue;
    const next = out[i + 1];
    word.e = next && next.t > word.t ? next.t : lineDuration ?? word.t;
  }
  return out;
}

/* -------------------------------------------------------------------------- */
/* Metadata                                                                    */
/* -------------------------------------------------------------------------- */

function addMeta(into: Record<string, string | string[]>, key: string, value: string): void {
  const existing = into[key];
  if (existing === undefined) into[key] = value;
  else if (Array.isArray(existing)) existing.push(value);
  else into[key] = [existing, value];
}

function toMs(seconds: number | undefined): number {
  if (seconds === undefined) return 0;
  return Math.round(seconds * 1000);
}

/**
 * Text of an element keeping the whitespace between child elements — needed for
 * `<text for="L1"><span>Is</span> <span>this</span></text>`, where `textOf`
 * would glue the words together.
 */
function inlineText(node: XmlNode): string {
  let out = "";
  for (const entry of node.content) {
    if (typeof entry === "string") out += entry;
    else if (entry.local === "br") out += " ";
    else out += textOf(entry);
  }
  return out;
}

function collectTranslations(root: XmlNode): { translations: Record<string, string>; langs: string[] } {
  const translations: Record<string, string> = {};
  const langs: string[] = [];
  for (const node of descendantsNamed(root, "translation")) {
    const lang = attr(node, "xml:lang") ?? "";
    if (!langs.includes(lang)) langs.push(lang);
    for (const textNode of childrenNamed(node, "text")) {
      const key = attr(textNode, "for") ?? attr(textNode, "itunes:key");
      if (!key) continue;
      const value = collapse(inlineText(textNode));
      if (value === "") continue;
      if (translations[key] === undefined) translations[key] = value;
    }
  }
  return { translations, langs };
}

function collectTransliterations(root: XmlNode): LyricsDoc["transliterations"] {
  const tracks: LyricsDoc["transliterations"] = [];
  for (const node of descendantsNamed(root, "transliteration")) {
    const lang = attr(node, "xml:lang");
    const lines: Record<string, { text: string; words: TtmlWord[] }> = {};
    for (const textNode of childrenNamed(node, "text")) {
      const key = attr(textNode, "for") ?? attr(textNode, "itunes:key");
      if (!key) continue;
      const words: TtmlWord[] = [];
      for (const span of childrenNamed(textNode, "span")) {
        const begin = parseTime(attr(span, "begin"));
        const end = parseTime(attr(span, "end"));
        const value = collapse(textOf(span));
        if (value === "" || begin === undefined) continue;
        words.push({ t: begin, time: begin, text: value, ...(end !== undefined ? { e: end } : {}) });
      }
      lines[key] = { text: collapse(inlineText(textNode)), words };
    }
    tracks.push({ ...(lang ? { lang } : {}), lines });
  }
  return tracks;
}

/* -------------------------------------------------------------------------- */
/* Parse                                                                       */
/* -------------------------------------------------------------------------- */

/**
 * Apple/AMLL-style lyric TTML: `<p>` lines with optional word `<span>`s,
 * agents for duets, translations and transliterations in `<head>`.
 */
function parseAppleLike(root: XmlNode, options: ParseOptions): LyricsDoc {
  const timingAttr = (attr(root, "itunes:timing") ?? "").toLowerCase();
  const timing: LyricsDoc["timing"] =
    timingAttr === "word" ? "Word" : timingAttr === "line" ? "Line" : timingAttr === "none" ? "None" : undefined;

  const agents: { id: string; type?: string }[] = [];
  for (const agent of descendantsNamed(root, "agent")) {
    const id = attr(agent, "xml:id");
    if (id) agents.push({ id, ...(attr(agent, "type") ? { type: attr(agent, "type") } : {}) });
  }
  const agentIndex = new Map<string, number>();
  for (let i = 0; i < agents.length; i++) agentIndex.set(agents[i]!.id, i + 1);
  // The `itunes:key` sequence tells us which agents are *singers* even when the
  // `<ttm:agent>` declarations are missing (files written by hand).
  const singerAgent = new Map<string, number>();
  const body = descendantsNamed(root, "body");
  const bodyNode = body[0];
  const divs = childrenNamed(bodyNode, "div");
  const containerDivs = divs.length > 0 ? divs : childrenNamed(root, "div");

  let offset = 0;
  let minBegin = Number.POSITIVE_INFINITY;
  let maxEnd = 0;
  const synced: TtmlLine[] = [];
  const keys: string[] = [];
  const lineAgents: number[] = [];
  let wordSync = false;
  let hasBackground = false;
  let covered = 0;
  const inlineTranslations: { key: string; lang?: string; text: string }[] = [];

  for (const div of containerDivs) {
    const part = attr(div, "itunes:songPart");
    const divBegin = parseTime(attr(div, "begin"));
    if (divBegin !== undefined && divBegin !== 0) offset = Math.max(offset, toMs(divBegin));
    const paragraphs = childrenNamed(div, "p");
    for (let index = 0; index < paragraphs.length; index++) {
      const paragraph = paragraphs[index]!;
      const begin = parseTime(attr(paragraph, "begin")) ?? divBegin ?? 0;
      const end = parseTime(attr(paragraph, "end"));
      const agentId = attr(paragraph, "ttm:agent");
      const drafts: WordDraft[] = [];
      collectWords(paragraph, attr(paragraph, "ttm:role"), drafts);
      const line = buildLine(drafts, begin, end, options.keepBackground ?? false);
      const key = attr(paragraph, "itunes:key") ?? attr(paragraph, "key");
      const instrument = line.text === "" && line.words.length === 0;

      let agent: number | undefined;
      if (agentId !== undefined) {
        const declared = agentIndex.get(agentId);
        const derived = singerAgent.get(agentId) ?? declared ?? (singerAgent.size + 1);
        singerAgent.set(agentId, derived);
        agent = derived;
      }

      if (line.words.some((word) => isBackground(word.role))) hasBackground = true;
      if (!instrument && line.timed && line.words.length > 1) wordSync = true;

      if (instrument) {
        if (end !== undefined) maxEnd = Math.max(maxEnd, end);
        if (begin !== undefined) minBegin = Math.min(minBegin, begin);
        continue;
      }

      for (const translation of line.inline) inlineTranslations.push({ key: key ?? `L${synced.length + 1}`, ...translation });
      synced.push({
        time: begin,
        ...(end !== undefined ? { end } : {}),
        text: line.text,
        words: line.words,
        ...(agent !== undefined ? { agent } : {}),
        ...(agentId !== undefined ? { agentId } : {}),
        ...(key ? { key } : {}),
        ...(part ? { part } : {}),
      });
      keys.push(key ?? `L${synced.length}`);
      lineAgents.push(agent ?? 0);
      minBegin = Math.min(minBegin, begin);
      if (end !== undefined) {
        maxEnd = Math.max(maxEnd, end);
        covered += Math.max(0, end - begin);
      }
    }
  }

  synced.sort((a, b) => a.time - b.time);

  const meta: Record<string, string | string[]> = {};
  for (const node of descendantsNamed(root, "meta")) {
    const key = attr(node, "key") ?? attr(node, "property") ?? attr(node, "name");
    const value = attr(node, "value") ?? attr(node, "content");
    if (key && value !== undefined) addMeta(meta, key, value);
  }
  const songwriters = descendantsNamed(root, "songwriter").map((node) => collapse(textOf(node))).filter(Boolean);
  if (songwriters.length > 0) meta.songwriters = songwriters;
  const audio = descendantsNamed(root, "audio")[0];
  const lyricOffset = options.lyricOffset ?? parseTime(attr(audio, "lyricOffset")) ?? 0;
  if (attr(audio, "role") !== undefined) meta.audioRole = attr(audio, "role")!;

  const { translations, langs } = collectTranslations(root);
  for (const inline of inlineTranslations) {
    if (translations[inline.key] === undefined) translations[inline.key] = inline.text;
    if (inline.lang && !langs.includes(inline.lang)) langs.push(inline.lang);
  }
  const transliterations = collectTransliterations(root);
  const total = maxEnd > 0 ? maxEnd : 0;
  const coverage = total > 0 && Number.isFinite(minBegin)
    ? Math.min(1, Math.max(0, covered / Math.max(total - minBegin, 0.001)))
    : 0;

  return {
    synced,
    plain: synced.map((line) => line.text).join("\n"),
    ...(attr(root, "xml:lang") ? { lang: attr(root, "xml:lang") } : {}),
    ...(timing ? { timing } : {}),
    translations,
    translationLangs: langs,
    transliterations,
    agents: lineAgents,
    keys,
    meta,
    offset: toMs(lyricOffset),
    wordSync,
    hasBackground,
    coverage: Number(coverage.toFixed(4)),
  };
}

/**
 * Legacy YouTube timed-text (`<timedtext format="3">`) — paragraph `t`/`d` in
 * milliseconds and `<s>` spans with *relative* `t` offsets.
 */
function parseYoutube(root: XmlNode): LyricsDoc {
  const synced: TtmlLine[] = [];
  const keys: string[] = [];
  let wordSync = false;
  let maxEnd = 0;
  let minBegin = Number.POSITIVE_INFINITY;

  for (const paragraph of descendantsNamed(root, "p")) {
    const beginMs = Number(attr(paragraph, "t") ?? "");
    if (!Number.isFinite(beginMs)) continue;
    const durationMs = Number(attr(paragraph, "d") ?? "");
    const begin = ms(beginMs / 1000);
    const end = Number.isFinite(durationMs) ? ms(begin + durationMs / 1000) : undefined;
    const words: TtmlWord[] = [];
    let text = "";
    for (const span of descendantsNamed(paragraph, "s")) {
      const raw = Number(attr(span, "t") ?? "0");
      const offset = Number.isFinite(raw) ? ms(raw / 1000) : 0;
      const value = collapse(textOf(span));
      if (value === "") continue;
      words.push({ t: offset, time: ms(begin + offset), text: value });
      text += `${text === "" ? "" : " "}${value}`;
    }
    if (text === "") continue;
    if (words.length > 1) wordSync = true;
    for (let i = 0; i < words.length; i++) {
      const word = words[i]!;
      word.e = words[i + 1] ? words[i + 1]!.t : end !== undefined ? ms(end - begin) : word.t;
    }
    synced.push({ time: begin, ...(end !== undefined ? { end } : {}), text, words, key: `L${synced.length + 1}` });
    keys.push(`L${synced.length}`);
    minBegin = Math.min(minBegin, begin);
    if (end !== undefined) maxEnd = Math.max(maxEnd, end);
  }

  const total = maxEnd > 0 ? maxEnd : 0;
  const covered = synced.reduce((sum, line) => sum + Math.max(0, (line.end ?? line.time) - line.time), 0);
  return {
    synced,
    plain: synced.map((line) => line.text).join("\n"),
    timing: wordSync ? "Word" : "Line",
    translations: {},
    translationLangs: [],
    transliterations: [],
    agents: synced.map(() => 0),
    keys,
    meta: {},
    offset: 0,
    wordSync,
    hasBackground: false,
    coverage: total > 0 && Number.isFinite(minBegin) ? Number(Math.min(1, covered / Math.max(total - minBegin, 0.001)).toFixed(4)) : 0,
  };
}

/** Is this document lyric TTML rather than a WebVTT/SRT sibling or plain LRC? */
export function isTtml(text: string): boolean {
  const head = text.slice(0, 4096);
  return /<(tt|timedtext)[\s>]/.test(head);
}

export function parse(text: string, options: ParseOptions = {}): LyricsDoc {
  const trimmed = text.replace(/^\uFEFF/, "").trim();
  if (trimmed === "") throw new Error("ttml: empty document");
  if (!isTtml(trimmed)) throw new Error("ttml: not a TTML document");

  const root = parseXml(trimmed);
  if (root.local === "tt" || root.local === "timedtext") return parseDocument(root, options);
  // Tolerate wrappers (`<lyrics><tt>…`) by finding the first <tt>.
  const inner = descendantsNamed(root, "tt")[0] ?? descendantsNamed(root, "timedtext")[0];
  if (!inner) throw new Error("ttml: no <tt> element");
  return parseDocument(inner, options);
}

function parseDocument(root: XmlNode, options: ParseOptions): LyricsDoc {
  const hasParagraphs = descendantsNamed(root, "p").some((node) => hasAttr(node, "begin"));
  const isYoutube = root.attrs["format"] !== undefined && !hasParagraphs;
  const parsed = isYoutube ? parseYoutube(root) : parseAppleLike(root, options);
  if (parsed.synced.length === 0) throw new Error("ttml: no timed lines");
  return parsed;
}

/* -------------------------------------------------------------------------- */
/* Write                                                                       */
/* -------------------------------------------------------------------------- */

function escapeXml(text: string, attribute = false): string {
  const base = text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  return attribute ? base.replace(/"/g, "&quot;") : base;
}

/** Apple's time syntax: `m:ss.mmm` (hours only when needed). */
export function ttmlTime(seconds: number): string {
  const total = Math.round(Math.max(0, seconds) * 1000);
  const hours = Math.floor(total / 3_600_000);
  const minutes = Math.floor((total % 3_600_000) / 60_000);
  const secs = Math.floor((total % 60_000) / 1000);
  const millis = total % 1000;
  const body = `${String(secs).padStart(2, "0")}.${String(millis).padStart(3, "0")}`;
  return hours > 0 ? `${hours}:${String(minutes).padStart(2, "0")}:${body}` : `${minutes}:${body}`;
}

export interface WriteOptions {
  /** Language tag for the root `xml:lang`. */
  lang?: string;
  /** Emit `<span>`s for word timing even when the source was line timed. */
  forceWords?: boolean;
  /** Include the translation tracks found in the document. */
  translations?: boolean;
  /** Offset applied to every stamp, in milliseconds. */
  offsetMs?: number;
}

/**
 * Normalise any lyrics document into Apple-style TTML. Round-trips through
 * {@link parse}: `parse(toTtml(doc))` is equivalent to `doc` for lines, words,
 * agents and translations.
 */
export function toTtml(doc: LyricsDoc, options: WriteOptions = {}): string {
  const shift = (options.offsetMs ?? 0) / 1000;
  const lang = options.lang ?? doc.lang ?? "und";
  const timed = (options.forceWords ?? doc.wordSync) && doc.synced.some((line) => line.words.length > 1);

  const agents: number[] = [];
  for (const line of doc.synced) {
    const agent = line.agent ?? 0;
    if (!agents.includes(agent)) agents.push(agent);
  }
  const keys = doc.synced.map((line, index) => line.key ?? doc.keys[index] ?? `L${index + 1}`);

  const out: string[] = [];
  out.push('<?xml version="1.0" encoding="UTF-8"?>');
  out.push(
    `<tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" ` +
      `xmlns:ttm="http://www.w3.org/ns/ttml#metadata" xmlns:amll="http://www.example.com/ns/amll" ` +
      `itunes:timing="${timed ? "Word" : "Line"}" xml:lang="${escapeXml(lang, true)}">`,
  );

  out.push("  <head>", "    <metadata>");
  for (const agent of agents) {
    if (agent <= 0) continue;
    const declared = doc.synced.find((line) => line.agent === agent)?.agentId;
    out.push(`      <ttm:agent type="person" xml:id="${escapeXml(declared ?? `v${agent}`, true)}"/>`);
  }

  const inner: string[] = [];
  const translationKeys = options.translations === false ? [] : keys.filter((key) => doc.translations[key] !== undefined);
  if (translationKeys.length > 0) {
    const langs = doc.translationLangs.length > 0 ? doc.translationLangs : [lang];
    inner.push("        <translations>");
    for (const translationLang of langs) {
      inner.push(`          <translation type="subtitle" xml:lang="${escapeXml(translationLang || lang, true)}">`);
      for (const key of translationKeys) {
        inner.push(`            <text for="${escapeXml(key, true)}">${escapeXml(doc.translations[key]!)}</text>`);
      }
      inner.push("          </translation>");
    }
    inner.push("        </translations>");
  }
  if (doc.offset !== 0) inner.push(`        <audio lyricOffset="${(doc.offset / 1000).toFixed(3)}"/>`);
  const transliteration = doc.transliterations.find((track) => Object.keys(track.lines).length > 0);
  if (transliteration) {
    inner.push("        <transliterations>");
    inner.push(`          <transliteration automaticallyCreated="true" xml:lang="${escapeXml(transliteration.lang ?? `${lang}-Latn`, true)}">`);
    for (const key of keys) {
      const entry = transliteration.lines[key];
      if (!entry) continue;
      const body = entry.words.length > 0
        ? entry.words
            .map((word) => `<span begin="${ttmlTime(word.t + shift)}" end="${ttmlTime((word.e ?? word.t) + shift)}">${escapeXml(word.text)}</span>`)
            .join(" ")
        : escapeXml(entry.text);
      inner.push(`            <text for="${escapeXml(key, true)}">${body}</text>`);
    }
    inner.push("          </transliteration>", "        </transliterations>");
  }
  if (inner.length > 0) {
    inner.unshift('      <iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal">');
    inner.push("      </iTunesMetadata>");
    out.push(...inner);
  }
  for (const [key, value] of Object.entries(doc.meta)) {
    if (key === "songwriters" || key === "audioRole" || key === "source") continue;
    for (const entry of Array.isArray(value) ? value : [value]) {
      out.push(`      <amll:meta key="${escapeXml(key, true)}" value="${escapeXml(entry, true)}"/>`);
    }
  }
  out.push("    </metadata>", "  </head>");

  const last = doc.synced[doc.synced.length - 1];
  out.push(`  <body dur="${ttmlTime(last ? (last.end ?? last.time + 4) + shift : 0)}">`);

  // One <div> per run of the same singer, like Apple's duet files.
  let index = 0;
  while (index < doc.synced.length) {
    const agent = doc.synced[index]!.agent ?? 0;
    let stop = index;
    while (stop + 1 < doc.synced.length && (doc.synced[stop + 1]!.agent ?? 0) === agent) stop++;
    const group = doc.synced.slice(index, stop + 1);
    const tail = group[group.length - 1]!;
    const part = group[0]!.part;
    const divAttrs = [
      `begin="${ttmlTime(group[0]!.time + shift)}"`,
      `end="${ttmlTime((tail.end ?? tail.time + 3) + shift)}"`,
      ...(part ? [`itunes:songPart="${escapeXml(part, true)}"`] : []),
      ...(agent > 0 ? [`ttm:agent="${escapeXml(`v${agent}`, true)}"`] : []),
    ];
    out.push(`    <div ${divAttrs.join(" ")}>`);
    for (let offset = index; offset <= stop; offset++) {
      const line = doc.synced[offset]!;
      const lineBegin = line.time + shift;
      const lineEnd = (line.end ?? line.time + 3) + shift;
      const spans = timed && line.words.length > 1
        ? line.words
            .map((word, position) => `${position > 0 && !word.glue ? " " : ""}<span begin="${ttmlTime(lineBegin + word.t)}" end="${ttmlTime(lineBegin + (word.e ?? word.t))}">${escapeXml(word.text)}</span>`)
            .join("")
        : escapeXml(line.text);
      const attrs = [
        `begin="${ttmlTime(lineBegin)}"`,
        `end="${ttmlTime(lineEnd)}"`,
        `itunes:key="${escapeXml(keys[offset]!, true)}"`,
        ...(line.agent ? [`ttm:agent="${escapeXml(`v${line.agent}`, true)}"`] : []),
      ];
      out.push(`      <p ${attrs.join(" ")}>${spans}</p>`);
    }
    out.push("    </div>");
    index = stop + 1;
  }
  out.push("  </body>", "</tt>", "");
  return out.join("\n");
}

/* -------------------------------------------------------------------------- */
/* Downstream shapes                                                           */
/* -------------------------------------------------------------------------- */

export interface LrcLine {
  time: number;
  text: string;
  words?: { t: number; text: string }[];
}

export function stamp(seconds: number): string {
  const safe = Math.max(0, seconds);
  const minutes = Math.floor(safe / 60);
  const rest = safe - minutes * 60;
  return `${String(minutes).padStart(2, "0")}:${rest.toFixed(2).padStart(5, "0")}`;
}

function escapeText(text: string): string {
  return text.replace(/\n/g, " ");
}

/**
 * Enhanced LRC, the format the plugin's Lua parser already understands:
 * `[mm:ss.xx]<mm:ss.xx>word <mm:ss.xx>word`.
 */
export function toLrc(parsed: LyricsDoc, opts: { offsetMs?: number; withWords?: boolean } = {}): string {
  const offset = opts.offsetMs ?? 0;
  const withWords = opts.withWords ?? parsed.wordSync;
  const last = parsed.synced[parsed.synced.length - 1];
  const header: string[] = [];
  if (typeof parsed.meta.title === "string") header.push(`[ti:${parsed.meta.title}]`);
  if (typeof parsed.meta.artist === "string") header.push(`[ar:${parsed.meta.artist}]`);
  if (last) header.push(`[length:${stamp(last.end ?? last.time)}]`);
  const lines = parsed.synced.map((line) => {
    const start = stamp(line.time + offset / 1000);
    if (withWords && line.words.length > 1) {
      const body = line.words
        .map((word, position) => `${position > 0 && !word.glue ? " " : ""}<${stamp(line.time + word.t + offset / 1000)}>${escapeText(word.text)}`)
        .join("");
      return `[${start}]${body}`;
    }
    return `[${start}]${escapeText(line.text)}`;
  });
  return [...header, ...lines].join("\n");
}

/** Plain (unsynced) text, translations included when asked for. */
export function toPlain(parsed: LyricsDoc, opts: { translations?: boolean } = {}): string {
  if (!opts.translations || Object.keys(parsed.translations).length === 0) return parsed.plain;
  return parsed.synced
    .map((line, index) => {
      const key = line.key ?? parsed.keys[index];
      const translation = key ? parsed.translations[key] : undefined;
      return translation && translation !== line.text ? `${line.text}\n${translation}` : line.text;
    })
    .join("\n");
}

/** Subtitle events (`start`/`end` in seconds) for the exporter / cast bridge. */
export function toCues(parsed: LyricsDoc, offsetMs = 0): { start: number; end: number; text: string }[] {
  const start = parsed.synced[0]?.time ?? 0;
  return parsed.synced.map((line, index) => {
    const next = parsed.synced[index + 1];
    const end = line.end ?? (next ? next.time : line.time + 4);
    return { start: line.time + offsetMs / 1000, end: end + offsetMs / 1000, text: line.text };
  });
}

/** Absolute word timings, useful for LRC `/timing` debugging. */
export function wordTimings(parsed: LyricsDoc): { index: number; text: string; words: { time: number; text: string }[] }[] {
  return parsed.synced.map((line, index) => ({
    index,
    text: line.text,
    words: line.words.map((word) => ({ time: Number((line.time + word.t).toFixed(3)), text: word.text })),
  }));
}

/** Per-language lyric text (`--lang en`) taken from `<translation>` tracks. */
export function translationLines(parsed: LyricsDoc, lang: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const line of parsed.synced) {
    const key = line.key ?? "";
    const translation = parsed.translations[key];
    if (translation && (!lang || (parsed.translationLangs.includes(lang) || true))) out[key] = translation;
  }
  return out;
}

/** One-line summary for `karu info --lyrics-file`. */
export function describe(parsed: LyricsDoc): string {
  const first = parsed.synced[0]?.time ?? 0;
  const last = parsed.synced[parsed.synced.length - 1]?.time ?? first;
  const agents = new Set(parsed.synced.map((line) => line.agent ?? 0).filter((agent) => agent > 0));
  const bits = [
    `${parsed.synced.length} lines`,
    `${stamp(first)}–${stamp(last)}`,
    parsed.wordSync ? "word-timed" : "line-timed",
    ...(agents.size > 1 ? [`${agents.size} singers`] : []),
    ...(parsed.translationLangs.length > 0 ? [`translations: ${parsed.translationLangs.join(", ")}`] : []),
    ...(parsed.transliterations.length > 0 ? [`transliterations: ${parsed.transliterations.map((track) => track.lang ?? "?").join(", ")}`] : []),
    ...(parsed.hasBackground ? ["background vocals"] : []),
  ];
  return bits.join(" · ");
}
