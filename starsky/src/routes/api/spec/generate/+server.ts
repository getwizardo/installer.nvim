import { json, type RequestEvent } from "@sveltejs/kit";
import { generateSpec, type KaeruForm } from "#lib/server/luaBridge";

export const prerender = false;

export async function POST({ request }: RequestEvent) {
  try {
    const body = await request.json();
    const form = (body.form || body || {}) as KaeruForm;
    return json(await generateSpec(form));
  } catch (err) {
    return json(
      { ok: false, error: err instanceof Error ? err.message : String(err) },
      { status: 400 }
    );
  }
}
