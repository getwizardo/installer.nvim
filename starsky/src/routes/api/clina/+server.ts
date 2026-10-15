import { json, type RequestEvent } from "@sveltejs/kit";
import {
  getProviders,
  CLINA_MCP_TOOLS,
  listWorkspaceFiles,
  readWorkspaceFile,
  writeWorkspaceFile,
  createUnifiedDiff,
  runClinaAgent,
  type ClinaRequestPayload,
} from "#lib/server/clina";

export const prerender = false;

export async function GET({ url }: RequestEvent) {
  const file = url.searchParams.get("file");
  if (file) {
    return json(readWorkspaceFile(file));
  }
  return json({
    ok: true,
    engine: "clina-typescript-ide",
    providers: getProviders(),
    mcpTools: CLINA_MCP_TOOLS,
    files: listWorkspaceFiles(),
  });
}

export async function POST({ request }: RequestEvent) {
  try {
    const body = await request.json();
    const action = String(body.action || "agent");

    if (action === "read") {
      return json(readWorkspaceFile(String(body.path || "")));
    }

    if (action === "write" || action === "apply") {
      const targetPath = String(body.path || "");
      const content = String(body.content ?? body.code ?? "");
      const res = writeWorkspaceFile(targetPath, content);
      return json({
        ...res,
        files: listWorkspaceFiles(),
      });
    }

    if (action === "diff") {
      const diff = createUnifiedDiff(
        String(body.original || ""),
        String(body.modified || ""),
        String(body.path || "workspace/file")
      );
      return json({ ok: true, diff });
    }

    const result = await runClinaAgent(body as ClinaRequestPayload);
    return json(result);
  } catch (err) {
    return json(
      { ok: false, error: err instanceof Error ? err.message : String(err) },
      { status: 400 }
    );
  }
}
