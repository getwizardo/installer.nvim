/**
 * Lyrics formats — detection and conversion.
 *
 * `karu lyrics` is the CLI edge of this module; everything here is pure so it
 * can be tested and reused by the receiver (e.g. to show a line in the bridge).
 */
import { buildLrc, parseLrc } from "./lrc.ts";
import { describe as describeTtml, isTtml, parse as parseTtml, toCues, toLrc, toPlain, toTtml, wordTimings, type LyricsDoc } from "./ttml.ts";

export * from "./ttml.ts";
export * from "./lrc.ts";

export type LyricFormat = "ttml" | "lrc" | "unknown";

/** Which lyrics format is this text? */
export function detect(text: string): LyricFormat {
  if (isTtml(text)) return "ttml";
  if (/\[\d{1,3}:\d{1,2}([.:]\d{1,3})?\]/.test(text.slice(0, 8192))) return "lrc";
  return "unknown";
}

export interface ConvertOptions {
  /** Language tag to write into TTML output / to pick for `plain`. */
  lang?: string;
  /** Player-clock offset in milliseconds. */
  offsetMs?: number;
  /** Attach translations to `plain` output. */
  translations?: boolean;
}

export interface Conversion {
  kind: LyricFormat;
  doc: LyricsDoc;
  lrc: string;
  ttml: string;
  plain: string;
  summary: string;
  json: Record<string, unknown>;
}

/** Parse any supported lyrics text and derive every output shape at once. */
export function convert(text: string, options: ConvertOptions = {}): Conversion {
  const kind = detect(text);
  if (kind === "unknown") throw new Error("not LRC or TTML");
  const doc = kind === "ttml" ? parseTtml(text) : parseLrc(text);
  const offsetMs = options.offsetMs ?? 0;
  const lrc = kind === "ttml" ? toLrc(doc, { offsetMs }) : buildLrc(doc, { offsetMs, withWords: doc.wordSync });
  // Translation tracks always travel with TTML output; `translations` only
  // controls whether `plain` interleaves them.
  const ttml = toTtml(doc, { ...(options.lang ? { lang: options.lang } : {}), offsetMs });
  const plain = toPlain(doc, { translations: options.translations === true });
  const duration = doc.synced.reduce((max, line) => Math.max(max, line.end ?? line.time), 0);
  return {
    kind,
    doc,
    lrc,
    ttml,
    plain,
    summary: describeTtml(doc),
    json: {
      ok: true,
      kind,
      lines: doc.synced.length,
      timing: doc.timing ?? (doc.wordSync ? "Word" : "Line"),
      wordSync: doc.wordSync,
      lang: doc.lang ?? null,
      translationLangs: doc.translationLangs,
      translations: doc.translations,
      transliterations: doc.transliterations.map((track) => ({ lang: track.lang ?? null, lines: Object.keys(track.lines).length })),
      agents: doc.agents,
      singers: new Set(doc.agents.filter((agent) => agent > 0)).size,
      meta: doc.meta,
      offset: doc.offset,
      coverage: doc.coverage,
      duration,
      summary: describeTtml(doc),
      cues: toCues(doc, offsetMs),
      words: wordTimings(doc),
      plain: doc.plain,
      lrc,
    },
  };
}

/** Is the text start LRC/TTML? Used by callers that already have both paths. */
export function looksLikeLyrics(text: string): boolean {
  return detect(text) !== "unknown";
}
