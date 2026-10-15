/**
 * LRC reader/writer.
 *
 * The *writer* is what the plugin needs (`toLrc` in ttml.ts emits enhanced LRC
 * that `lua/kaeru/kikru/lyrics.lua` parses). The *reader* makes `karu lyrics`
 * symmetric: `.lrc` in → `.ttml` out, and it is the reference implementation
 * for the Lua parser's quirks (jittered word stamps, `[offset:]`, metadata).
 */

import { stamp, type LyricsDoc, type TtmlLine, type TtmlWord } from "./ttml.ts";

export interface LrcMeta {
  title?: string;
  artist?: string;
  album?: string;
  by?: string;
  length?: string;
  offset?: number;
}

const META_KEYS: Record<string, keyof LrcMeta> = { ti: "title", ar: "artist", al: "album", by: "by", length: "length" };

/** `[mm:ss.xx]`, `[mm:ss.xxx]`, `[mm:ss]`, `[h:mm:ss.xx]`. */
export function parseStamp(value: string): number | undefined {
  const match = /^\s*(?:(\d+):)?(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\s*$/.exec(value);
  if (!match) return undefined;
  const [, hours, minutes, seconds, fraction] = match;
  const millis = fraction ? Number(`0.${fraction.padEnd(3, "0").slice(0, 3)}`) : 0;
  const total = Number(hours ?? 0) * 3600 + Number(minutes) * 60 + Number(seconds) + millis;
  return Math.round(total * 1000) / 1000;
}

/**
 * Parse LRC (plain or enhanced, word stamps in `<…>`), including the `[offset:]`
 * directive and `[ti:]`-style metadata.
 */
export function parseLrc(text: string, source = "lrc"): LyricsDoc {
  const lines: TtmlLine[] = [];
  const meta: Record<string, string | string[]> = {};
  let offset = 0;

  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (line === "") continue;
    const metaMatch = /^\[(ti|ar|al|by|length|re|ve):([^\]]*)\]$/.exec(line);
    if (metaMatch) {
      const key = META_KEYS[metaMatch[1]!.toLowerCase()];
      if (key) meta[key] = metaMatch[2]!.trim();
      continue;
    }
    const offsetMatch = /^\[offset:\s*([+-]?\d+)\s*\]$/i.exec(line);
    if (offsetMatch) {
      offset = Number(offsetMatch[1]);
      continue;
    }

    const stamps: number[] = [];
    let body = line;
    for (;;) {
      const match = /^\[([^\]]+)\]/.exec(body);
      if (!match) break;
      const time = parseStamp(match[1]!);
      if (time === undefined) break;
      stamps.push(time);
      body = body.slice(match[0].length);
    }
    if (stamps.length === 0) continue;

    // Enhanced LRC: `<mm:ss.xx>` before each word, the first one repeated.
    const words: TtmlWord[] = [];
    const chunks = body.split(/(<[^>]*>)/).filter((chunk) => chunk !== "");
    let pending: { time: number; text: string } | undefined;
    let plain = "";
    for (const chunk of chunks) {
      const stampMatch = /^<([^>]*)>$/.exec(chunk);
      if (stampMatch) {
        const time = parseStamp(stampMatch[1]!);
        if (time === undefined) {
          plain += chunk;
          continue;
        }
        if (pending) words.push({ t: 0, time: pending.time, text: pending.text });
        pending = { time, text: "" };
        continue;
      }
      plain += chunk;
      if (pending) pending.text += chunk;
    }
    if (pending) words.push({ t: 0, time: pending.time, text: pending.text });

    const text_ = plain.replace(/\s+/g, " ").trim();
    if (text_ === "" && words.length === 0) continue;
    const time = stamps[0]!;
    for (const word of words) word.t = Math.max(0, Math.round((word.time - time) * 1000) / 1000);
    for (let i = 0; i < words.length; i++) {
      const word = words[i]!;
      word.text = word.text.replace(/\s+/g, " ").trim();
      const next = words[i + 1];
      if (next && next.t > word.t) word.e = next.t;
    }
    lines.push({
      time,
      text: text_,
      words: words.filter((word) => word.text !== ""),
      key: `L${lines.length + 1}`,
    });
  }

  lines.sort((a, b) => a.time - b.time);
  const wordSync = lines.some((line) => line.words.length > 1);
  const last = lines[lines.length - 1];
  const first = lines[0];
  return {
    synced: lines,
    plain: lines.map((line) => line.text).join("\n"),
    timing: wordSync ? "Word" : "Line",
    translations: {},
    translationLangs: [],
    transliterations: [],
    agents: lines.map(() => 0),
    keys: lines.map((line, index) => line.key ?? `L${index + 1}`),
    meta: { ...meta, ...(source ? { source } : {}) },
    offset,
    wordSync,
    hasBackground: false,
    coverage: first && last ? Number(Math.min(1, lines.reduce((sum, line) => sum + Math.max(0, (line.end ?? line.time) - line.time), 0) / Math.max((last.end ?? last.time) - first.time, 0.001)).toFixed(4)) : 0,
  };
}

/** Build plain LRC (line stamps only) from any lyrics document. */
export function buildLrc(doc: LyricsDoc, opts: { offsetMs?: number; withWords?: boolean } = {}): string {
  const offset = opts.offsetMs ?? 0;
  const header: string[] = [];
  if (typeof doc.meta.title === "string") header.push(`[ti:${doc.meta.title}]`);
  if (typeof doc.meta.artist === "string") header.push(`[ar:${doc.meta.artist}]`);
  if (typeof doc.meta.album === "string") header.push(`[al:${doc.meta.album}]`);
  if (offset !== 0) header.push(`[offset:${Math.round(offset)}]`);
  const body = doc.synced.map((line) => {
    const text = line.text.replace(/\r?\n/g, " ");
    if (opts.withWords && line.words.length > 1) {
      return `[${stamp(line.time + offset / 1000)}]${line.words
        .map((word, position) => `${position > 0 && !word.glue ? " " : ""}<${stamp(line.time + word.t + offset / 1000)}>${word.text}`)
        .join("")}`;
    }
    return `[${stamp(line.time + offset / 1000)}]${text}`;
  });
  return [...header, ...body].join("\n");
}
