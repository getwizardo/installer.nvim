import { NextRequest, NextResponse } from "next/server";
import {
  getProviders,
  CLINA_MCP_TOOLS,
  listWorkspaceFiles,
  readWorkspaceFile,
  writeWorkspaceFile,
  createUnifiedDiff,
  runClinaAgent,
  ClinaRequestPayload,
} from "@/lib/clina";

export const dynamic = "force-dynamic";

export async function GET(req: NextRequest) {
  const file = req.nextUrl.searchParams.get("file");
  if (file) {
    return NextResponse.json(readWorkspaceFile(file));
  }
  return NextResponse.json({
    ok: true,
    engine: "clina-typescript-ide",
    providers: getProviders(),
    mcpTools: CLINA_MCP_TOOLS,
    files: listWorkspaceFiles(),
  });
}

export async function POST(req: NextRequest) {
  try {
    const body = await req.json();
    const action = String(body.action || "agent");

    if (action === "read") {
      return NextResponse.json(readWorkspaceFile(String(body.path || "")));
    }

    if (action === "write" || action === "apply") {
      const targetPath = String(body.path || "");
      const content = String(body.content ?? body.code ?? "");
      const res = writeWorkspaceFile(targetPath, content);
      return NextResponse.json({
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
      return NextResponse.json({ ok: true, diff });
    }

    const result = await runClinaAgent(body as ClinaRequestPayload);
    return NextResponse.json(result);
  } catch (err) {
    return NextResponse.json(
      { ok: false, error: err instanceof Error ? err.message : String(err) },
      { status: 400 }
    );
  }
}
