import { NextRequest, NextResponse } from "next/server";
import { runLuaBridge } from "@/lib/luaBridge";

export const dynamic = "force-dynamic";

export async function POST(req: NextRequest) {
  try {
    const body = await req.json();
    let text = String(body.text || "");
    const repo = String(body.repo || "").trim();

    if (!text && repo) {
      for (const branch of ["main", "master"]) {
        const res = await fetch(
          `https://api.github.com/repos/${repo}/contents/README.md?ref=${branch}`,
          {
            headers: {
              Accept: "application/vnd.github.v3.raw",
              "User-Agent": "installer.nvim-starsky-nextjs",
            },
          }
        );
        if (res.ok) {
          text = await res.text();
          break;
        }
      }
      if (!text) {
        return NextResponse.json({
          ok: false,
          error: `Could not fetch README.md for ${repo}`,
          items: [],
        });
      }
    }

    const parsed = runLuaBridge<{
      ok: boolean;
      items?: unknown[];
      error?: string;
    }>("parse", { text });
    return NextResponse.json(parsed);
  } catch (err) {
    return NextResponse.json(
      { ok: false, error: err instanceof Error ? err.message : String(err) },
      { status: 400 }
    );
  }
}
