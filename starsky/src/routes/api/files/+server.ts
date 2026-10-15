import { json } from "@sveltejs/kit";
import { listWorkspaceFiles } from "#lib/server/workspace";

export const prerender = false;

/** Workspace tree for the IDE explorer (paths stay inside the repository). */
export function GET() {
  const files = listWorkspaceFiles();
  return json({ ok: true, files });
}
