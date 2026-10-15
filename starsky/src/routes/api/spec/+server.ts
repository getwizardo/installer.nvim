import { json, type RequestEvent } from "@sveltejs/kit";
import {
  generateSpec,
  saveSpecToDisk,
  listSavedSpecs,
  deleteSavedSpec,
  getDefaultPluginsDir,
  type KaeruForm,
} from "#lib/server/luaBridge";

export const prerender = false;

export async function GET({ url }: RequestEvent) {
  const customDir = url.searchParams.get("dir") || undefined;
  return json({
    ok: true,
    pluginsDir: getDefaultPluginsDir(customDir),
    specs: listSavedSpecs(customDir),
  });
}

export async function POST({ request }: RequestEvent) {
  try {
    const body = await request.json();
    const action = (body.action || "generate") as
      | "generate"
      | "save"
      | "list"
      | "delete";
    const form = (body.form || {}) as KaeruForm;
    const customDir = body.dir as string | undefined;

    if (action === "list") {
      return json({
        ok: true,
        pluginsDir: getDefaultPluginsDir(customDir),
        specs: listSavedSpecs(customDir),
      });
    }

    if (action === "delete") {
      const deleted = deleteSavedSpec(String(body.file || ""), customDir);
      return json({
        ok: deleted,
        specs: listSavedSpecs(customDir),
      });
    }

    if (action === "save") {
      const saved = await saveSpecToDisk(form, customDir);
      return json(saved);
    }

    const generated = await generateSpec(form);
    return json(generated);
  } catch (err) {
    return json(
      {
        ok: false,
        error: err instanceof Error ? err.message : String(err),
      },
      { status: 400 }
    );
  }
}
