/**
 * TTML parser tests — the fixtures mirror the real profiles: Apple Music
 * (`itunes:timing`, agents, translations, transliterations, `x-bg`), the
 * AMLL/QQ dialect (`amll:meta`, inline `x-translation` spans) and YouTube's
 * legacy `<timedtext format="3">`.
 */
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  describe as describeTtml,
  isTtml,
  parse,
  parseTime,
  toCues,
  toLrc,
  toPlain,
  toTtml,
  wordTimings,
} from "../src/lyrics/ttml.ts";
import { convert, detect, looksLikeLyrics, parseLrc, parse as parseTtml } from "../src/lyrics/index.ts";
import { attr, childNamed, childrenNamed, collapse, decodeEntities, descendantsNamed, parseXml, textOf } from "../src/lyrics/xml.ts";

const APPLE_WORD = `<?xml version="1.0" encoding="UTF-8"?>
<tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" itunes:timing="Word" xml:lang="en">
  <head>
    <metadata>
      <ttm:agent type="person" xml:id="v1"/>
      <ttm:agent type="person" xml:id="v2"/>
      <iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal">
        <translations>
          <translation type="subtitle" xml:lang="ja">
            <text for="L1">ボヘミアン</text>
            <text for="L2">ママは言った</text>
          </translation>
        </translations>
        <songwriters><songwriter>Freddie Mercury</songwriter><songwriter>Brian May</songwriter></songwriters>
        <audio lyricOffset="0.165" role="spatial"/>
        <transliterations>
          <transliteration automaticallyCreated="true" xml:lang="en-Latn">
            <text for="L1"><span begin="0:18.840" end="0:19.362">Is</span> <span begin="0:19.362" end="0:19.914">this</span></text>
          </transliteration>
        </transliterations>
      </iTunesMetadata>
    </metadata>
  </head>
  <body>
    <div>
      <p begin="0:18.840" end="0:22.375" itunes:key="L1" ttm:agent="v1"><span begin="0:18.840" end="0:19.362">Is</span> <span begin="0:19.362" end="0:19.914">this</span> <span begin="0:19.914" end="0:20.346">the</span> <span begin="0:20.346" end="0:20.844">real</span> <span begin="0:20.844" end="0:22.375">life?</span></p>
      <p begin="0:22.540" end="0:24.100" itunes:key="L2" ttm:agent="v2"><span begin="0:22.540" end="0:23.100">Mama,</span> <span begin="0:23.100" end="0:24.100">just killed a man</span><span ttm:role="x-bg"><span begin="0:23.500" end="0:24.100">(uh)</span></span></p>
    </div>
    <div begin="1:00.000" itunes:songPart="Chorus">
      <p begin="1:00.020" end="1:02.000" itunes:key="L3" ttm:agent="v2">Mama ooo&#8217;s</p>
    </div>
  </body>
</tt>`;

const AMLL = `<tt xmlns="http://www.w3.org/ns/ttml" xmlns:amll="http://www.example.com/ns/amll" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" itunes:timing="Word">
  <head>
    <metadata>
      <ttm:agent type="person" xml:id="v1"/>
      <amll:meta key="musicName" value="Hush Little Baby"/>
      <amll:meta key="artists" value="JOLIN"/>
      <amll:meta key="isrc" value="TWA532500125"/>
      <amll:meta key="qqMusicId" value="580908367"/>
      <amll:meta key="qqMusicId" value="001heCvT0XTVNR"/>
    </metadata>
  </head>
  <body dur="1:04.352">
    <div begin="15.627" end="1:04.352">
      <p begin="15.627" end="19.715" itunes:key="L1" ttm:agent="v1"><span begin="15.627" end="16.166">Hush,</span> <span begin="16.233" end="16.596">lit</span><span begin="16.596" end="16.746">tle</span> <span begin="16.779" end="17.309">ba</span><span begin="17.332" end="17.831">by,</span> <span begin="17.864" end="18.283">don&apos;t</span> <span begin="18.333" end="18.739">say</span> <span begin="19.018" end="19.715">a</span><span ttm:role="x-translation" xml:lang="zh-CN">嘘 小宝贝</span></p>
      <p begin="20.060" end="24.174" itunes:key="L2" ttm:agent="v1"><span begin="20.060" end="20.341">Ma</span><span begin="20.356" end="20.521">ma&apos;s</span> <span begin="20.613" end="20.998">gon</span><span begin="21.123" end="21.614">na</span> buy</p>
    </div>
  </body>
</tt>`;

const YOUTUBE = `<?xml version="1.0" encoding="utf-8" ?><timedtext format="3">
<head>
<ws id="0"/>
<wp id="0"/>
</head>
<body>
<w t="0" id="1" wp="1" ws="1"/>
<p t="280" d="3000" w="1"><s ac="0">what&#39;s</s><s t="200" ac="0"> going</s><s t="360" ac="0"> on</s><s t="519" ac="0"> guys</s></p>
<p t="1630" d="1650" w="1" a="1">
</p>
<p t="3280" d="4960" w="1"><s ac="0">add</s><s t="119" ac="0"> a</s><s t="280" ac="0"> category</s></p>
</body></timedtext>`;

const APPLE_LINE = `<tt xmlns="http://www.w3.org/ns/ttml" xmlns:itunes="http://music.apple.com/lyric-ttml-internal" xmlns:ttm="http://www.w3.org/ns/ttml#metadata" itunes:timing="Line" xml:lang="ko">
<head><metadata><iTunesMetadata xmlns="http://music.apple.com/lyric-ttml-internal"><translations><translation type="subtitle" xml:lang="en-US"><text for="L1">Hello</text><text for="L2">World</text></translation></translations></iTunesMetadata></metadata></head>
<body><div>
<p begin="0:13.130" end="0:16.560" itunes:key="L1" ttm:agent="v1">Elit</p>
<p begin="0:27.160" end="0:29.960" itunes:key="L2" ttm:agent="v2">E&apos;te iusm<br/>turad dunt</p>
</div></body></tt>`;

/* ------------------------------- XML core -------------------------------- */

test("xml: parses nested elements, prefixes and attributes", () => {
  const root = parseXml(`<tt itunes:timing="Word"><body><div><p begin="1:00.020" ttm:agent="v2">hi<span begin="2s">there</span></p></div></body></tt>`);
  assert.equal(root.local, "tt");
  assert.equal(attr(root, "itunes:timing"), "Word");
  assert.equal(attr(root, "timing"), "Word", "local-name lookup");
  const body = childNamed(root, "body");
  const paragraph = descendantsNamed(root, "p")[0]!;
  assert.equal(attr(paragraph, "begin"), "1:00.020");
  assert.equal(childrenNamed(paragraph, "span").length, 1);
  assert.equal(collapse(textOf(paragraph)), "hithere", "textOf is literal: use parse() for whitespace-aware reading");
  assert.equal(descendantsNamed(root, "div").length, 1);
});

test("xml: decodes entities, comments, CDATA and self-closing tags", () => {
  const root = parseXml(`<tt><!-- skip --><p a="x &amp; y" b="&#39;" c="&#x41;">&lt;b&gt;<![CDATA[<raw>]]></p><br/></tt>`);
  const paragraph = childNamed(root, "p")!;
  assert.equal(attr(paragraph, "a"), "x & y");
  assert.equal(attr(paragraph, "b"), "'");
  assert.equal(attr(paragraph, "c"), "A");
  assert.equal(textOf(paragraph), "<b><raw>");
  assert.equal(decodeEntities("&nbsp;&hellip;"), "\u00a0\u2026");
  assert.equal(childrenNamed(root, "br").length, 1, "self-closing child");
});

test("xml: tolerates unquoted attributes and a DOCTYPE", () => {
  const root = parseXml(`<?xml version="1.0"?><!DOCTYPE tt [ <!ELEMENT tt ANY> ]><tt xmlns=foo><p>ok</p></tt>`);
  assert.equal(root.attrs["xmlns"], "foo");
  assert.equal(collapse(textOf(root)), "ok");
});

/* -------------------------------- Times ---------------------------------- */

test("ttml: parseTime understands every clock form used by the profiles", () => {
  assert.equal(parseTime("0:18.840"), 18.84);
  assert.equal(parseTime("1:00.020"), 60.02);
  assert.equal(parseTime("00:01:23.456"), 83.456);
  assert.equal(parseTime("15.627"), 15.627);
  assert.equal(parseTime("1:04.352"), 64.352);
  assert.equal(parseTime("83s"), 83);
  assert.equal(parseTime("1.5m"), 90);
  assert.equal(parseTime("2h"), 7200);
  assert.equal(parseTime("120ms"), 0.12);
  assert.equal(parseTime("300f"), 10);
  assert.equal(parseTime("12t"), 0.12);
  assert.equal(parseTime(undefined), undefined);
  assert.equal(parseTime("nonsense"), undefined);
});

test("ttml: recognises TTML and rejects other lyrics formats", () => {
  assert.equal(isTtml(APPLE_WORD), true);
  assert.equal(isTtml(YOUTUBE), true);
  assert.equal(isTtml("[00:12.00]hello"), false);
  assert.equal(isTtml("WEBVTT\n\n00:01.000 --> 00:02.000\nhi"), false);
  assert.throws(() => parse("[00:12.00]hello"), /not a TTML document/);
  assert.throws(() => parse("   "), /empty document/);
  assert.throws(() => parse("<tt><body><div/></body></tt>"), /no timed lines/);
});

/* ------------------------- Apple Music, word timed ------------------------ */

test("ttml: Apple word timing, agents, keys, translations and offset", () => {
  const parsed = parse(APPLE_WORD);
  assert.equal(parsed.timing, "Word");
  assert.equal(parsed.lang, "en");
  assert.equal(parsed.synced.length, 3);

  const first = parsed.synced[0]!;
  assert.equal(first.time, 18.84);
  assert.equal(first.end, 22.375);
  assert.equal(first.key, "L1");
  assert.equal(first.agent, 1);
  assert.equal(first.agentId, "v1");
  assert.equal(first.text, "Is this the real life?");
  assert.equal(first.words.length, 5);
  assert.deepEqual(first.words.map((word) => word.text), ["Is", "this", "the", "real", "life?"]);
  assert.deepEqual(first.words.map((word) => word.t), [0, 0.522, 1.074, 1.506, 2.004]);
  assert.deepEqual(first.words.map((word) => word.e), [0.522, 1.074, 1.506, 2.004, 3.535]);
  assert.equal(first.words[4]!.time, 20.844, "absolute time = line start + offset");

  const second = parsed.synced[1]!;
  assert.equal(second.agent, 2, "duet: v2 is the second singer");
  assert.equal(second.time, 22.54);
  assert.equal(second.text, "Mama, just killed a man (uh)", "background vocals fold into the line");
  assert.deepEqual(second.words.filter((word) => word.role === "x-bg").map((word) => word.text), ["(uh)"]);
  assert.equal(parsed.hasBackground, true);

  const chorus = parsed.synced[2]!;
  assert.equal(chorus.part, "Chorus");
  assert.equal(chorus.time, 60.02);
  assert.equal(chorus.agent, 2);
  assert.equal(chorus.words.length, 1, "untimed line becomes one whole-line word");
  assert.equal(chorus.words[0]!.t, 0);
  assert.equal(chorus.words[0]!.e, 1.98);

  assert.deepEqual(parsed.keys, ["L1", "L2", "L3"]);
  assert.deepEqual(parsed.agents, [1, 2, 2]);
  assert.deepEqual(parsed.translations, { L1: "ボヘミアン", L2: "ママは言った" });
  assert.deepEqual(parsed.translationLangs, ["ja"]);
  assert.equal(parsed.offset, 165, "lyricOffset is milliseconds");
  assert.deepEqual(parsed.meta.songwriters, ["Freddie Mercury", "Brian May"]);
  assert.equal(parsed.meta.audioRole, "spatial");
  assert.equal(parsed.plain, "Is this the real life?\nMama, just killed a man (uh)\nMama ooo\u2019s");
  assert.equal(parsed.wordSync, true);
  // ~38 s of instrumental between L2 and the chorus is not covered by any <p>.
  assert.ok(parsed.coverage > 0.15 && parsed.coverage < 0.5, `coverage ${parsed.coverage}`);
  assert.match(describeTtml(parsed), /^3 lines · 00:18\.84–01:00\.02 · word-timed · 2 singers · translations: ja/);

  const transliteration = parsed.transliterations[0]!;
  assert.equal(transliteration.lang, "en-Latn");
  assert.equal(transliteration.lines["L1"]!.text, "Is this");
  assert.deepEqual(transliteration.lines["L1"]!.words.map((word) => word.t), [18.84, 19.362]);
});

test("ttml: word timing survives missing spans, zero-length spans and <br/>", () => {
  const parsed = parse(`<tt xmlns:itunes="http://music.apple.com/lyric-ttml-internal" itunes:timing="Word"><body><div>
    <p begin="0:10.000" end="0:12.000" itunes:key="L1"><span begin="0:10.000" end="0:10.500">one</span> two <span begin="0:11.000" end="0:11.000">three</span></p>
    <p begin="0:12.000" end="0:14.000" itunes:key="L2">plain<br/>line</p>
  </div></body></tt>`);
  const [first, second] = parsed.synced;
  assert.equal(first!.text, "one two three");
  assert.deepEqual(first!.words.map((word) => word.text), ["one", "two", "three"]);
  assert.equal(first!.words[1]!.t, 0.5, "untimed fragment follows the previous word");
  assert.equal(first!.words[2]!.e, 2, "zero-length span is repaired at parse time");
  assert.equal(second!.text, "plain line", "br joins the two halves of the cue");
  assert.deepEqual(second!.words.map((word) => word.text), ["plain", "line"]);
  assert.equal(second!.words[0]!.e, 2, "open word ends with the line");
});

/* ------------------------------ AMLL / QQ -------------------------------- */

test("ttml: AMLL metadata, inline translations and body offsets", () => {
  const parsed = parse(AMLL);
  assert.equal(parsed.synced.length, 2);
  assert.equal(parsed.meta.musicName, "Hush Little Baby");
  assert.equal(parsed.meta.isrc, "TWA532500125");
  assert.deepEqual(parsed.meta.qqMusicId, ["580908367", "001heCvT0XTVNR"], "repeated meta keys collect");

  const first = parsed.synced[0]!;
  assert.equal(first.time, 15.627);
  assert.equal(first.words[1]!.text, "lit");
  assert.equal(first.words[2]!.text, "tle");
  assert.equal(first.words[2]!.t, 0.969, "syllables split across adjacent spans");
  assert.equal(first.text, "Hush, little baby, don't say a");
  assert.equal(parsed.translations["L1"], "嘘 小宝贝", "inline x-translation spans become translations");
  assert.deepEqual(parsed.translationLangs, ["zh-CN"]);
  assert.equal(first.words.some((word) => word.role !== undefined), false, "translation text is not sung");
  assert.equal(first.words[first.words.length - 1]!.e, 4.088, "last word runs to the line end");
});

/* ------------------------- Apple Music, line timed ---------------------- */

test("ttml: line-timed Apple lyrics still give per-line words and translations", () => {
  const parsed = parse(APPLE_LINE);
  assert.equal(parsed.timing, "Line");
  assert.equal(parsed.wordSync, false);
  assert.equal(parsed.synced.length, 2);
  assert.equal(parsed.synced[0]!.text, "Elit");
  assert.equal(parsed.synced[0]!.words.length, 1);
  assert.equal(parsed.synced[0]!.words[0]!.t, 0);
  assert.equal(parsed.synced[0]!.words[0]!.e, 3.43);
  assert.equal(parsed.synced[1]!.text, "E'te iusm turad dunt");
  assert.deepEqual(parsed.translations, { L1: "Hello", L2: "World" });
  assert.match(describeTtml(parsed), /line-timed/);
  assert.doesNotMatch(describeTtml(parsed), /word-timed/);
});

/* ------------------------------- YouTube -------------------------------- */

test("ttml: YouTube timedtext uses relative <s t> offsets in milliseconds", () => {
  const parsed = parse(YOUTUBE);
  assert.equal(parsed.synced.length, 2, "the empty spacer paragraph is dropped");
  const first = parsed.synced[0]!;
  assert.equal(first.time, 0.28);
  assert.equal(first.end, 3.28);
  assert.equal(first.text, "what's going on guys");
  assert.deepEqual(first.words.map((word) => word.t), [0, 0.2, 0.36, 0.519]);
  assert.equal(first.words[1]!.time, 0.48);
  assert.equal(parsed.synced[1]!.words[2]!.text, "category");
  assert.equal(parsed.timing, "Word");
});

/* -------------------------------- Output -------------------------------- */

test("ttml: toLrc emits enhanced LRC the Lua parser understands", () => {
  const parsed = parse(APPLE_WORD);
  const lrc = toLrc(parsed);
  const lines = lrc.split("\n");
  assert.equal(lines[0], "[length:01:02.00]");
  assert.equal(lines[1], "[00:18.84]<00:18.84>Is <00:19.36>this <00:19.91>the <00:20.35>real <00:20.84>life?");
  assert.match(lines[2]!, /^\[00:22\.54\]<00:22\.54>Mama, /);

  const shifted = toLrc(parsed, { offsetMs: -165 });
  assert.match(shifted, /\[00:18\.68\]/, "offset applies to line and word stamps");
  const plainLrc = toLrc(parsed, { withWords: false });
  assert.match(plainLrc, /\[00:18\.84\]Is this the real life\?/);
});

test("ttml: toPlain, toCues, wordTimings and translation helpers", () => {
  const parsed = parse(APPLE_WORD);
  assert.equal(toPlain(parsed, { translations: true }), [
    "Is this the real life?\nボヘミアン",
    "Mama, just killed a man (uh)\nママは言った",
    "Mama ooo\u2019s",
  ].join("\n"));

  const cues = toCues(parsed);
  assert.equal(cues.length, 3);
  assert.deepEqual(cues[0], { start: 18.84, end: 22.375, text: "Is this the real life?" });
  assert.deepEqual(cues[2], { start: 60.02, end: 62.0, text: "Mama ooo\u2019s" }, "last cue uses its end attribute");

  const timed = wordTimings(parsed);
  assert.equal(timed[0]!.index, 0);
  assert.deepEqual(timed[0]!.words[1], { time: 19.362, text: "this" });

  const cuesShifted = toCues(parsed, 500);
  assert.equal(cuesShifted[0]!.start, 19.34);
});

/* ------------------------------ Robustness ------------------------------ */

test("ttml: minimal documents, whitespace and unknown namespaces", () => {
  const parsed = parse(`<tt xmlns:itunes="x" itunes:timing="Line"><body><div>
    <p begin="1.5s" end="3s">   hello    world   </p>
  </div></body></tt>`);
  assert.equal(parsed.synced[0]!.time, 1.5);
  assert.equal(parsed.synced[0]!.text, "hello world");

  const wrapped = parse(`<lyrics><tt><body><div><p begin="2" end="4">wrapped</p></div></body></tt></lyrics>`);
  assert.equal(wrapped.synced[0]!.text, "wrapped");

  const noAgent = parse(`<tt itunes:timing="Word"><body><div>
    <p begin="0:01.000" end="0:02.000"><span begin="0:01.000" end="0:01.500">a</span> <span begin="0:01.500" end="0:02.000">b</span></p>
    <p begin="0:02.000" end="0:03.000"><span begin="0:02.000" end="0:03.000">c</span></p>
  </div></body></tt>`);
  assert.equal(noAgent.wordSync, true);
  assert.deepEqual(noAgent.synced[0]!.words.map((word) => word.t), [0, 0.5]);
});

test("ttml: keeps background lines when asked, folds them otherwise", () => {
  const doc = `<tt itunes:timing="Word"><body><div>
    <p begin="0:01.000" end="0:05.000"><span begin="0:01.000" end="0:02.000">lead</span><span ttm:role="x-bg"><span begin="0:02.000" end="0:03.000">(backup)</span></span></p>
  </div></body></tt>`;
  const folded = parse(doc);
  assert.equal(folded.synced[0]!.text, "lead (backup)", "folded background vocals get a separator");
  assert.equal(folded.synced[0]!.words.length, 2);
  assert.equal(folded.synced[0]!.words[1]!.role, "x-bg");

  const kept = parse(doc, { keepBackground: true });
  assert.equal(kept.synced[0]!.text, "lead", "background vocals leave the singer line when kept separately");
  assert.equal(kept.synced[0]!.words.length, 2);
  assert.equal(kept.hasBackground, true);
  assert.match(describeTtml(kept), /background vocals/);
});

/* ------------------------- TTML ⇄ LRC conversion -------------------------- */

test("ttml: toTtml round-trips lines, words, agents and translations", () => {
  const original = parse(APPLE_WORD);
  const written = toTtml(original);
  assert.match(written, /^<\?xml version="1\.0" encoding="UTF-8"\?>\n<tt /);
  assert.match(written, /itunes:timing="Word"/);
  assert.match(written, /xml:lang="en"/);
  assert.match(written, /<ttm:agent type="person" xml:id="v1"\/>/);
  assert.match(written, /<translation type="subtitle" xml:lang="ja">/);
  assert.match(written, /<audio lyricOffset="0\.165"\/>/);
  assert.match(written, /<transliteration automaticallyCreated="true" xml:lang="en-Latn">/);
  assert.match(written, /<div begin="0:18\.840" end="0:22\.375" ttm:agent="v1">/);
  assert.match(written, /<div begin="0:22\.540" end="1:02\.000" ttm:agent="v2">/, "consecutive lines of the same singer share a div");

  const again = parse(written);
  assert.equal(again.synced.length, original.synced.length);
  assert.equal(again.wordSync, true);
  assert.equal(again.lang, "en");
  assert.equal(again.offset, 165);
  assert.deepEqual(again.synced[0]!.words.map((word) => word.text), original.synced[0]!.words.map((word) => word.text));
  assert.deepEqual(again.synced[0]!.words.map((word) => word.t), original.synced[0]!.words.map((word) => word.t));
  assert.equal(again.synced[0]!.agent, 1);
  assert.equal(again.synced[1]!.agent, 2);
  assert.deepEqual(again.translations, original.translations);
  assert.equal(again.translations["L2"], "ママは言った");
  assert.deepEqual(again.transliterations[0]!.lines["L1"]!.words.map((word) => word.t), [18.84, 19.362]);
});

test("ttml: toLrc output is re-readable by the LRC parser", () => {
  const original = parse(AMLL);
  const lrc = toLrc(original);
  const doc = parseLrc(lrc);
  assert.equal(doc.synced.length, original.synced.length);
  assert.equal(doc.wordSync, true);
  assert.equal(doc.synced[0]!.time, 15.63, "LRC keeps centisecond stamps");
  assert.equal(doc.synced[0]!.text, original.synced[0]!.text, "the sung text survives the round trip");
  assert.ok(doc.synced[0]!.words.length >= original.synced[0]!.words.length, "LRC words split on whitespace");
  assert.equal(doc.synced[0]!.words[0]!.t, 0);
  assert.equal(doc.synced[0]!.words[1]!.t, 0.6, "LRC keeps centisecond word offsets");
});

test("lyrics: LRC parses metadata, offset and is converted to TTML", () => {
  const text = "[ti:Bohemian Rhapsody]\n[ar:Queen]\n[offset:-250]\n[00:12.00]<00:12.00>Is <00:12.50>this\n[00:20.50]the real life?\n";
  const doc = parseLrc(text);
  assert.equal(doc.meta.title, "Bohemian Rhapsody");
  assert.equal(doc.meta.artist, "Queen");
  assert.equal(doc.offset, -250);
  assert.equal(doc.synced.length, 2);
  assert.equal(doc.synced[0]!.words.length, 2);
  assert.deepEqual(doc.synced[0]!.words.map((word) => word.t), [0, 0.5]);
  assert.equal(doc.wordSync, true);

  const conversion = convert(text, { lang: "en" });
  assert.equal(conversion.kind, "lrc");
  assert.match(conversion.ttml, /itunes:timing="Word"/);
  assert.match(conversion.ttml, /<span begin="0:12\.000" end="0:12\.500">Is<\/span> <span begin="0:12\.500"/);
  assert.match(conversion.ttml, /<p begin="0:20\.500" end="0:23\.500" itunes:key="L2">the real life\?<\/p>/);
  assert.match(conversion.ttml, /<audio lyricOffset="-0\.250"\/>/);
  const back = parseTtml(conversion.ttml);
  assert.equal(back.synced[1]!.text, "the real life?");
  assert.equal(conversion.lrc, "[ti:Bohemian Rhapsody]\n[ar:Queen]\n[00:12.00]<00:12.00>Is <00:12.50>this\n[00:20.50]the real life?");
  assert.match(conversion.summary, /^2 lines · 00:12\.00–00:20\.50 · word-timed/);
  assert.equal(conversion.json["lines"], 2);
  assert.equal(conversion.json["kind"], "lrc");
});

test("lyrics: detect() tells the three profiles apart", () => {
  assert.equal(detect(APPLE_WORD), "ttml");
  assert.equal(detect(YOUTUBE), "ttml");
  assert.equal(detect("[00:12.00]hello"), "lrc");
  assert.equal(detect("just some prose\nwith lines"), "unknown");
  assert.equal(looksLikeLyrics("just some prose"), false);
  assert.throws(() => convert("just some prose"), /not LRC or TTML/);
});

test("lyrics: conversion honours offset and translation options", () => {
  const conversion = convert(APPLE_WORD, { offsetMs: -165, translations: true, lang: "en" });
  assert.equal(conversion.doc.offset, 165, "the document offset is preserved as-is");
  assert.match(conversion.lrc.split("\n")[1]!, /^\[00:18\.68\]/, "output stamps are shifted");
  assert.equal(conversion.plain.split("\n").slice(0, 2).join("\n"), "Is this the real life?\nボヘミアン");
  assert.equal(conversion.json["singers"], 2);
  assert.deepEqual(conversion.json["translationLangs"], ["ja"]);
  const cues = conversion.json["cues"] as { start: number }[];
  assert.equal(cues[0]!.start, 18.675);
  const words = conversion.json["words"] as { words: { time: number }[] }[];
  assert.equal(words[0]!.words[0]!.time, 18.84, "wordTimings reports document time; --offset only shifts output");
  const noTranslations = toPlain(parse(APPLE_WORD));
  assert.equal(noTranslations.split("\n").length, 3, "plain output drops translations unless asked");
});
