import { json, type RequestEvent } from "@sveltejs/kit";
import { nvimStatus } from "#lib/server/nvim";
import { openInNvim, writeBufferInNvim } from "#lib/server/editor";
import { runWebEx } from "#lib/server/ex";
import { getRepoRoot } from "#lib/server/luaBridge";
import { resolveWorkspacePath } from "#lib/server/workspace";
import path from "node:path";

export const prerender = false;

export function GET() {
  return json({ ok: true, neovim: nvimStatus() });
}

/**
 * Remote Neovim editor API.
 *   open  { path }            open a workspace file as a Neovim buffer
 *   save  { path, content }   replace the buffer text and :write it
 *   ex    { command }         run an allowed web-terminal command
 */
export async function POST({ request }: RequestEvent) {
  const body = await request.json().catch(() => ({}));
  const action = String(body.action || "");
  const status = nvimStatus();

  try {
    if (action === "ex") {
      const res = await runWebEx(String(body.command || ""));
      return json(res, { status: res.ok ? 200 : 400 });
    }

    if (!status.available) {
      return json({ ok: false, error: "Neovim is not available on this machine" }, { status: 503 });
    }

    if (action === "open") {
      const abs = resolveWorkspacePath(String(body.path || ""));
      const buf = await openInNvim(abs);
      return json({
        ok: true,
        path: path.relative(getRepoRoot(), abs),
        bufnr: buf.bufnr,
        filetype: buf.filetype,
        content: buf.lines.join("\n"),
      });
    }

    if (action === "save") {
      const abs = resolveWorkspacePath(String(body.path || ""));
      const { bytes } = await writeBufferInNvim(abs, String(body.content ?? ""));
      return json({ ok: true, relativePath: path.relative(getRepoRoot(), abs), size: bytes });
    }

    return json({ ok: false, error: `Unknown action: ${action}` }, { status: 400 });
  } catch (err) {
    return json(
      { ok: false, error: err instanceof Error ? err.message : String(err) },
      { status: 400 }
    );
  }
}
