import { json, type RequestEvent } from "@sveltejs/kit";
import { saveSpecToDisk, type KaeruForm } from "#lib/server/luaBridge";

export const prerender = false;

/**
 * Write a lazy.nvim spec file into the directory `:Kaeru save` uses.
 * An existing file is kept (409) unless the body sets `overwrite: true`.
 */
export async function POST({ request }: RequestEvent) {
  try {
    const body = await request.json();
    const form = (body.form || body || {}) as KaeruForm;
    const customDir = body.dir as string | undefined;
    const result = await saveSpecToDisk(form, customDir, { overwrite: body.overwrite === true });
    const status = result.ok ? 200 : result.exists ? 409 : 400;
    return json(result, { status });
  } catch (err) {
    return json(
      { ok: false, error: err instanceof Error ? err.message : String(err) },
      { status: 400 }
    );
  }
}
