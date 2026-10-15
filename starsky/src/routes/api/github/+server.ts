import { json, type RequestEvent } from "@sveltejs/kit";
import { execFile } from "child_process";
import { promisify } from "util";

const execFileAsync = promisify(execFile);

export const prerender = false;

async function curlGet(url: string, rawAccept?: string): Promise<string> {
  const { stdout } = await execFileAsync(
    "curl",
    [
      "-fsSL",
      "-H",
      `Accept: ${rawAccept || "application/vnd.github+json"}`,
      "-H",
      "User-Agent: kaeru.nvim-starsky-sveltekit",
      url,
    ],
    { timeout: 8000 }
  );
  return stdout;
}

export async function GET({ url: requestUrl }: RequestEvent) {
  const action = requestUrl.searchParams.get("action") || "search";

  if (action === "readme") {
    const repo = (requestUrl.searchParams.get("repo") || "").trim();
    if (!repo.includes("/")) {
      return json(
        { ok: false, error: "Invalid owner/repo" },
        { status: 400 }
      );
    }
    try {
      const url = `https://api.github.com/repos/${repo}/readme`;
      const raw = await curlGet(url, "application/vnd.github.raw+json");
      return json({ ok: true, repo, readme: raw });
    } catch (err) {
      return json(
        { ok: false, error: err instanceof Error ? err.message : String(err) },
        { status: 500 }
      );
    }
  }

  const q = requestUrl.searchParams.get("q") || "topic:neovim-plugin";
  const query = q.toLowerCase().includes("neovim") ? q : `${q} neovim`;
  const url = `https://api.github.com/search/repositories?q=${encodeURIComponent(
    query
  )}&sort=stars&order=desc&per_page=24`;
  try {
    const raw = await curlGet(url);
    const data = JSON.parse(raw);
    const items = (data.items || []).map((it: Record<string, unknown>) => ({
      full_name: it.full_name,
      description: it.description || "",
      stargazers_count: it.stargazers_count || 0,
      stars: it.stargazers_count || 0,
      html_url: it.html_url,
      url: it.html_url,
      topics: it.topics || [],
      updated_at: it.updated_at,
    }));
    return json({ ok: true, items });
  } catch (err) {
    return json(
      { ok: false, error: err instanceof Error ? err.message : String(err) },
      { status: 500 }
    );
  }
}
