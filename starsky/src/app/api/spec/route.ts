import { NextRequest, NextResponse } from "next/server";
import {
  generateSpec,
  saveSpecToDisk,
  listSavedSpecs,
  deleteSavedSpec,
  getDefaultPluginsDir,
  KaeruForm,
} from "@/lib/luaBridge";

export const dynamic = "force-dynamic";

export async function GET(req: NextRequest) {
  const customDir = req.nextUrl.searchParams.get("dir") || undefined;
  return NextResponse.json({
    ok: true,
    pluginsDir: getDefaultPluginsDir(customDir),
    specs: listSavedSpecs(customDir),
  });
}

export async function POST(req: NextRequest) {
  try {
    const body = await req.json();
    const action = (body.action || "generate") as
      | "generate"
      | "save"
      | "list"
      | "delete";
    const form = (body.form || {}) as KaeruForm;
    const customDir = body.dir as string | undefined;

    if (action === "list") {
      return NextResponse.json({
        ok: true,
        pluginsDir: getDefaultPluginsDir(customDir),
        specs: listSavedSpecs(customDir),
      });
    }

    if (action === "delete") {
      const deleted = deleteSavedSpec(String(body.file || ""), customDir);
      return NextResponse.json({
        ok: deleted,
        specs: listSavedSpecs(customDir),
      });
    }

    if (action === "save") {
      const saved = saveSpecToDisk(form, customDir);
      return NextResponse.json(saved);
    }

    const generated = generateSpec(form);
    return NextResponse.json(generated);
  } catch (err) {
    return NextResponse.json(
      {
        ok: false,
        error: err instanceof Error ? err.message : String(err),
      },
      { status: 400 }
    );
  }
}
