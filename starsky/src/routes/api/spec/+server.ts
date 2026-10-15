import { json, type RequestEvent } from "@sveltejs/kit";
import {
  generateSpec,
  saveSpecToDisk,
  listSavedSpecs,
  deleteSavedSpec,
  resolvePluginsDir,
  type KaeruForm,
} from "#lib/server/luaBridge";

export const prerender = false;

export async function GET({ url }: RequestEvent) {
  const customDir = url.searchParams.get("dir") || undefined;
  return json({
    ok: true,
    pluginsDir: await resolvePluginsDir(customDir),
    specs: await listSavedSpecs(customDir),
  });
}

export async function POST({ request }: RequestEvent) {
  try {
    const body = await request.json();
    const action = (body.action || "generate") as "generate" | "save" | "list" | "delete";
    const form = (body.form || {}) as KaeruForm;
    const customDir = body.dir as string | undefined;

    if (action === "list") {
      return json({
        ok: true,
        pluginsDir: await resolvePluginsDir(customDir),
        specs: await listSavedSpecs(customDir),
      });
    }

    if (action === "delete") {
      const deleted = await deleteSavedSpec(String(body.file || ""), customDir);
      return json({ ok: deleted, specs: await listSavedSpecs(customDir) });
    }

    if (action === "save") {
      // Existing files are never overwritten unless the caller says so.
      const saved = await saveSpecToDisk(form, customDir, { overwrite: body.overwrite === true });
      return json(saved, { status: saved.ok ? 200 : saved.exists ? 409 : 400 });
    }

    return json(await generateSpec(form));
  } catch (err) {
    return json(
      { ok: false, error: err instanceof Error ? err.message : String(err) },
      { status: 400 }
    );
  }
}
