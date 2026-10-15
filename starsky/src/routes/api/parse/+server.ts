import { json, type RequestEvent } from "@sveltejs/kit";
import { runLuaBridge } from "#lib/server/luaBridge";

export const prerender = false;

export async function POST({ request }: RequestEvent) {
  try {
    const body = await request.json();
    let text = String(body.text || "");
    const repo = String(body.repo || "").trim();

    if (!text && repo) {
      for (const branch of ["main", "master"]) {
        const res = await fetch(
          `https://api.github.com/repos/${repo}/contents/README.md?ref=${branch}`,
          {
            headers: {
              Accept: "application/vnd.github.v3.raw",
              "User-Agent": "kaeru.nvim-starsky-sveltekit",
            },
          }
        );
        if (res.ok) {
          text = await res.text();
          break;
        }
      }
      if (!text) {
        return json({
          ok: false,
          error: `Could not fetch README.md for ${repo}`,
          items: [],
        });
      }
    }

    const parsed = await runLuaBridge<{
      ok: boolean;
      items?: unknown[];
      error?: string;
    }>("parse", { text });
    return json(parsed);
  } catch (err) {
    return json(
      { ok: false, error: err instanceof Error ? err.message : String(err) },
      { status: 400 }
    );
  }
}
