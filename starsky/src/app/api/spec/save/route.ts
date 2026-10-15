import { NextRequest, NextResponse } from "next/server";
import { saveSpecToDisk, KaeruForm } from "@/lib/luaBridge";

export const dynamic = "force-dynamic";

export async function POST(req: NextRequest) {
  try {
    const body = await req.json();
    const form = (body.form || body || {}) as KaeruForm;
    const customDir = body.dir as string | undefined;
    return NextResponse.json(saveSpecToDisk(form, customDir));
  } catch (err) {
    return NextResponse.json(
      { ok: false, error: err instanceof Error ? err.message : String(err) },
      { status: 400 }
    );
  }
}
