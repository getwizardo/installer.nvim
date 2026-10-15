import { NextRequest, NextResponse } from "next/server";
import { execFile } from "child_process";
import { promisify } from "util";
import { runLuaBridge } from "@/lib/luaBridge";

const execFileAsync = promisify(execFile);

export const dynamic = "force-dynamic";

interface CompletionCandidate {
  word: string;
  menu?: string;
  kind?: string;
}

const ghAutocompleteCache = new Map<
  string,
  { items: CompletionCandidate[]; ts: number }
>();

function formatStars(n: number): string {
  if (n >= 1000) return `${(n / 1000).toFixed(1)}k`;
  return String(n);
}

async function fetchJsonViaCurlOrFetch(
  url: string
): Promise<Record<string, unknown> | null> {
  try {
    const { stdout } = await execFileAsync(
      "curl",
      [
        "-fsSL",
        "-H",
        "Accept: application/vnd.github+json",
        "-H",
        "User-Agent: installer.nvim-starsky-autocomplete",
        url,
      ],
      { timeout: 6000 }
    );
    return JSON.parse(stdout);
  } catch {
    try {
      const res = await fetch(url, {
        headers: {
          Accept: "application/vnd.github+json",
          "User-Agent": "installer.nvim-starsky-autocomplete",
        },
      });
      if (!res.ok) return null;
      return (await res.json()) as Record<string, unknown>;
    } catch {
      return null;
    }
  }
}

async function fetchGithubPluginCompletions(
  base: string
): Promise<CompletionCandidate[]> {
  const q = base.trim();
  if (q.length < 2) return [];
  const cacheKey = q.toLowerCase();
  const cached = ghAutocompleteCache.get(cacheKey);
  if (cached && Date.now() - cached.ts < 300_000) {
    return cached.items;
  }

  let searchQuery = `${q} neovim in:name,description,topics`;
  const slashMatch = q.match(/^([\w_.-]+)\/([\w_.-]*)$/);
  if (slashMatch) {
    const [, owner, repoPart] = slashMatch;
    searchQuery = repoPart
      ? `${repoPart} user:${owner} in:name`
      : `user:${owner} nvim in:name,description`;
  }

  const url = `https://api.github.com/search/repositories?q=${encodeURIComponent(
    searchQuery
  )}&sort=stars&order=desc&per_page=12`;

  const data = await fetchJsonViaCurlOrFetch(url);
  if (!data || !Array.isArray(data.items)) return [];

  const items: CompletionCandidate[] = (
    data.items as Record<string, unknown>[]
  ).map((it) => ({
    word: String(it.full_name || ""),
    menu: `[GitHub ★${formatStars(Number(it.stargazers_count || 0))}] ${String(
      it.description || ""
    )}`,
    kind: "GitHub API",
  }));

  ghAutocompleteCache.set(cacheKey, { items, ts: Date.now() });
  return items;
}

export async function GET(req: NextRequest) {
  const key =
    req.nextUrl.searchParams.get("field") ||
    req.nextUrl.searchParams.get("key") ||
    "repo";
  const base =
    req.nextUrl.searchParams.get("prefix") ||
    req.nextUrl.searchParams.get("base") ||
    "";
  const repo = req.nextUrl.searchParams.get("repo") || "";

  const luaRes = runLuaBridge<{ ok: boolean; items: CompletionCandidate[] }>(
    "complete",
    {
      key,
      base,
      form: { repo },
    }
  );
  const localItems = Array.isArray(luaRes?.items) ? luaRes.items : [];

  if ((key === "repo" || key === "dependencies") && base.trim().length >= 2) {
    const ghItems = await fetchGithubPluginCompletions(base);
    const seen = new Set<string>();
    const merged: CompletionCandidate[] = [];
    for (const item of [...ghItems, ...localItems]) {
      const k = (item.word || "").toLowerCase();
      if (k && !seen.has(k)) {
        seen.add(k);
        merged.push(item);
      }
    }
    return NextResponse.json({
      ok: true,
      source: ghItems.length > 0 ? "github-api+local" : "local",
      githubCount: ghItems.length,
      items: merged,
    });
  }

  return NextResponse.json({
    ok: true,
    source: "local",
    githubCount: 0,
    items: localItems,
  });
}
