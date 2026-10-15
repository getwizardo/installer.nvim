import { NextRequest, NextResponse } from "next/server";
import { generateSpec, KaeruForm } from "@/lib/luaBridge";

export const dynamic = "force-dynamic";

export async function POST(req: NextRequest) {
  try {
    const body = await req.json();
    const form = (body.form || body || {}) as KaeruForm;
    return NextResponse.json(generateSpec(form));
  } catch (err) {
    return NextResponse.json(
      { ok: false, error: err instanceof Error ? err.message : String(err) },
      { status: 400 }
    );
  }
}
