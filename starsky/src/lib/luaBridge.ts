import { spawnSync } from "child_process";
import fs from "fs";
import path from "path";

export interface InstallerForm {
  repo: string;
  file?: string;
  name?: string;
  lazy?: string;
  priority?: string;
  event?: string;
  cmd?: string;
  ft?: string;
  keys?: string;
  dependencies?: string;
  branch?: string;
  tag?: string;
  version?: string;
  commit?: string;
  build?: string;
  opts?: string;
  config?: string;
  init?: string;
  pin?: string;
  cond?: string;
  enabled?: string;
}

export interface GeneratedSpec {
  source: string;
  name: string;
  file: string;
  short?: string;
}

export interface SavedSpecFile {
  file: string;
  filename: string;
  path: string;
  relativePath: string;
  size: number;
  mtime: string;
  source: string;
  repo: string;
}

export function getRepoRoot(): string {
  const cwd = process.cwd();
  if (fs.existsSync(path.join(cwd, "lua", "installer", "init.lua"))) {
    return cwd;
  }
  const parent = path.resolve(cwd, "..");
  if (fs.existsSync(path.join(parent, "lua", "installer", "init.lua"))) {
    return parent;
  }
  return "/home/user/installer.nvim";
}

export function getDefaultPluginsDir(customDir?: string): string {
  if (customDir && customDir.trim() !== "") {
    const trimmed = customDir.trim();
    if (path.isAbsolute(trimmed)) {
      return trimmed;
    }
    return path.join(getRepoRoot(), trimmed);
  }
  return path.join(getRepoRoot(), "lua", "plugins");
}

const PYTHON_BRIDGE = `
import sys, json
from lupa import LuaRuntime

repo_root = sys.argv[1]
action = sys.argv[2]
payload = json.loads(sys.argv[3])

lua = LuaRuntime(unpack_returned_tuples=True)
lua.execute(f'package.path = "{repo_root}/lua/?.lua;{repo_root}/lua/?/init.lua;" .. package.path')

lua.execute("""
local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end
_G.vim = {
  trim = trim,
  split = function(s, sep)
    local out = {}
    for part in tostring(s):gmatch("([^" .. sep .. "]+)") do
      out[#out + 1] = part
    end
    return out
  end,
  tbl_contains = function(t, val)
    for _, v in ipairs(t) do
      if v == val then return true end
    end
    return false
  end,
  list_slice = function(list, s, e)
    local out = {}
    for i = s or 1, e or #list do
      out[#out + 1] = list[i]
    end
    return out
  end,
  deepcopy = function(orig)
    local function copy(o)
      if type(o) ~= "table" then return o end
      local res = {}
      for k, v in pairs(o) do res[copy(k)] = copy(v) end
      return res
    end
    return copy(orig)
  end,
  tbl_deep_extend = function(_, ...)
    local res = {}
    for i = 1, select("#", ...) do
      local t = select(i, ...)
      if type(t) == "table" then
        for k, v in pairs(t) do res[k] = v end
      end
    end
    return res
  end,
  fn = {
    stdpath = function() return "/tmp" end,
    fnamemodify = function(p) return p end,
    expand = function(p) return p end,
    isdirectory = function() return 0 end,
    filereadable = function() return 0 end,
  },
  log = { levels = { INFO = 1, WARN = 2, ERROR = 3 } },
  o = { columns = 120, lines = 40 },
}
_G._bridge_helpers = {
  spec_generate = function(form)
    local Spec = require("installer.spec")
    local g, err = Spec.generate(form)
    return { g = g, err = err }
  end,
  parse_all = function(text)
    local Parser = require("installer.parser")
    local items, err = Parser.parse_all(text)
    return { items = items, err = err }
  end,
}
""")

def to_py(val):
    if val is None or isinstance(val, (str, int, float, bool)):
        return val
    try:
        keys = list(val.keys())
        if not keys:
            return []
        if all(isinstance(k, int) for k in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
            return [to_py(val[i]) for i in range(1, len(keys) + 1)]
        return {str(k): to_py(val[k]) for k in keys}
    except Exception:
        return str(val)

def to_lua_table(d):
    tbl = lua.table()
    if isinstance(d, dict):
        for k, v in d.items():
            if v is not None:
                tbl[k] = to_lua_table(v) if isinstance(v, (dict, list)) else v
    elif isinstance(d, list):
        for idx, v in enumerate(d, start=1):
            tbl[idx] = to_lua_table(v) if isinstance(v, (dict, list)) else v
    return tbl

helpers = lua.globals()._bridge_helpers

if action == "spec_generate":
    form = to_lua_table(payload.get("form", {}))
    res = to_py(helpers.spec_generate(form))
    if not res or not res.get("g"):
        print(json.dumps({"ok": False, "error": str(res.get("err") if res else "Failed to generate spec")}))
    else:
        print(json.dumps({"ok": True, "generated": res["g"]}))

elif action == "parse":
    text = payload.get("text", "")
    res = to_py(helpers.parse_all(text))
    items = res.get("items") if res else None
    if not items:
        print(json.dumps({"ok": False, "error": str(res.get("err") if res else "No plugin specs found"), "items": []}))
    else:
        print(json.dumps({"ok": True, "items": items}))

elif action == "complete":
    Complete = lua.require("installer.complete")
    key = payload.get("key", "repo")
    base = payload.get("base", "")
    form = to_lua_table(payload.get("form", {}))
    items = Complete.complete_field(key, base, form)
    print(json.dumps({"ok": True, "items": to_py(items) or []}))
`;

export function runLuaBridge<T = Record<string, unknown>>(
  action: "spec_generate" | "parse" | "complete",
  payload: Record<string, unknown>
): T {
  const repoRoot = getRepoRoot();
  const proc = spawnSync(
    "python3",
    ["-c", PYTHON_BRIDGE, repoRoot, action, JSON.stringify(payload)],
    {
      encoding: "utf8",
      timeout: 8000,
    }
  );
  if (proc.status === 0 && proc.stdout) {
    try {
      return JSON.parse(proc.stdout.trim()) as T;
    } catch {
      // Fall through to TypeScript fallback
    }
  }
  return fallbackBridge(action, payload) as T;
}

/**
 * Pure-TypeScript fallback generator so spec creation & saving never fail
 * even if Python/lupa is unavailable.
 */
export function buildSpecInTypeScript(form: InstallerForm): {
  ok: boolean;
  generated?: GeneratedSpec;
  error?: string;
} {
  let repo = (form.repo || "").trim().replace(/[,;]+$/, "").trim();
  if (
    (repo.startsWith('"') && repo.endsWith('"')) ||
    (repo.startsWith("'") && repo.endsWith("'"))
  ) {
    repo = repo.slice(1, -1).trim();
  }
  if (!repo) {
    return { ok: false, error: "Repository is required (owner/repo or a git URL)" };
  }

  let shortRepo: string | undefined;
  let urlRepo: string | undefined;
  let baseName = repo;

  const ghMatch =
    repo.match(/^https?:\/\/github\.com\/([\w_.-]+)\/([\w_.-]+)\/?$/) ||
    repo.match(/^git@github\.com:([\w_.-]+)\/([\w_.-]+)$/) ||
    repo.match(/^([\w_.-]+)\/([\w_.-]+)$/);

  if (ghMatch) {
    const owner = ghMatch[1];
    const cleanRepo = ghMatch[2].replace(/\.git$/, "");
    shortRepo = `${owner}/${cleanRepo}`;
    baseName = cleanRepo;
  } else if (/^[a-z][\w+.-]*:\/\//i.test(repo) || repo.startsWith("git@")) {
    urlRepo = repo;
    baseName = (repo.split(/[/:]/).pop() || "plugin").replace(/\.git$/, "");
  } else {
    return {
      ok: false,
      error: `Invalid repository "${repo}". Use owner/repo or a full git URL`,
    };
  }

  let defaultFile = baseName
    .toLowerCase()
    .replace(/\.n?vim$/, "")
    .replace(/^n?vim-/, "")
    .replace(/-n?vim$/, "")
    .replace(/[^a-z0-9_-]/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "");
  if (!defaultFile) defaultFile = "plugin";

  const file = ((form.file || "").trim() || defaultFile).replace(/\.lua$/, "");
  if (file.includes("/") || file.includes("\\")) {
    return { ok: false, error: "File name must not contain path separators" };
  }

  const lines: string[] = [
    `-- Generated by installer.nvim on ${new Date().toISOString().slice(0, 10)}`,
    "-- Spec reference: https://lazy.folke.io/spec",
    "return {",
  ];

  if (shortRepo) {
    lines.push(`  ${JSON.stringify(shortRepo)},`);
  } else if (urlRepo) {
    lines.push(`  url = ${JSON.stringify(urlRepo)},`);
  }

  const name = (form.name || "").trim() || baseName;
  if ((form.name || "").trim()) {
    lines.push(`  name = ${JSON.stringify(form.name!.trim())},`);
  }

  const parseBool = (v?: string): boolean | undefined => {
    const s = (v || "").trim().toLowerCase();
    if (["true", "yes", "1", "on"].includes(s)) return true;
    if (["false", "no", "0", "off"].includes(s)) return false;
    return undefined;
  };

  const lazyVal = parseBool(form.lazy);
  if (lazyVal !== undefined) lines.push(`  lazy = ${lazyVal},`);

  if ((form.priority || "").trim()) {
    const n = Number(form.priority!.trim());
    if (Number.isNaN(n)) {
      return { ok: false, error: "Priority must be a number" };
    }
    lines.push(`  priority = ${n},`);
  }

  if ((form.version || "").trim()) {
    const v = form.version!.trim();
    lines.push(`  version = ${v === "false" ? "false" : JSON.stringify(v)},`);
  }

  for (const k of ["branch", "tag", "commit"] as const) {
    const v = (form[k] || "").trim();
    if (v) lines.push(`  ${k} = ${JSON.stringify(v)},`);
  }

  if (parseBool(form.pin) === true) {
    lines.push("  pin = true,");
  }

  const renderCsvOrTable = (key: string, rawVal?: string, alwaysList = false) => {
    const v = (rawVal || "").trim();
    if (!v) return;
    if (v.startsWith("{")) {
      lines.push(`  ${key} = ${v},`);
      return;
    }
    const parts = v
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean);
    if (parts.length === 0) return;
    if (parts.length === 1 && !alwaysList) {
      lines.push(`  ${key} = ${JSON.stringify(parts[0])},`);
    } else if (parts.length === 1 && alwaysList) {
      lines.push(`  ${key} = { ${JSON.stringify(parts[0])} },`);
    } else {
      lines.push(`  ${key} = {`);
      for (const p of parts) {
        lines.push(`    ${JSON.stringify(p)},`);
      }
      lines.push("  },");
    }
  };

  renderCsvOrTable("event", form.event);
  renderCsvOrTable("cmd", form.cmd);
  renderCsvOrTable("ft", form.ft);
  renderCsvOrTable("keys", form.keys, true);
  renderCsvOrTable("dependencies", form.dependencies, true);

  if ((form.build || "").trim()) {
    const b = form.build!.trim();
    if (b.startsWith("{") || b.startsWith("function")) {
      lines.push(`  build = ${b},`);
    } else {
      lines.push(`  build = ${JSON.stringify(b)},`);
    }
  }

  if ((form.opts || "").trim()) {
    let o = form.opts!.trim();
    if (!o.startsWith("{")) o = `{ ${o} }`;
    lines.push(`  opts = ${o},`);
  }

  if ((form.init || "").trim()) {
    lines.push(`  init = ${form.init!.trim()},`);
  }

  if ((form.config || "").trim()) {
    const c = form.config!.trim();
    const lc = c.toLowerCase();
    if (lc === "function" || lc === "fn" || lc === "func") {
      lines.push(
        `  config = function(_, opts)\n    -- require("${defaultFile}").setup(opts)\n  end,`
      );
    } else if (lc.startsWith("function")) {
      lines.push(`  config = ${c},`);
    } else {
      const b = parseBool(c);
      if (b !== undefined) {
        lines.push(`  config = ${b},`);
      }
    }
  }

  lines.push("}\n");

  return {
    ok: true,
    generated: {
      source: lines.join("\n"),
      name,
      file,
      short: shortRepo,
    },
  };
}

function fallbackBridge(
  action: string,
  payload: Record<string, unknown>
): Record<string, unknown> {
  if (action === "spec_generate") {
    return buildSpecInTypeScript((payload.form || {}) as InstallerForm);
  }
  return { ok: false, error: "Fallback unsupported for action: " + action };
}

export function generateSpec(form: InstallerForm): {
  ok: boolean;
  generated?: GeneratedSpec;
  error?: string;
} {
  const res = runLuaBridge<{
    ok: boolean;
    generated?: GeneratedSpec;
    error?: string;
  }>("spec_generate", { form });
  if (res && res.ok && res.generated) {
    return res;
  }
  if (res && res.error) {
    return res;
  }
  return buildSpecInTypeScript(form);
}

export function saveSpecToDisk(
  form: InstallerForm,
  customDir?: string
): {
  ok: boolean;
  path?: string;
  relativePath?: string;
  file?: string;
  generated?: GeneratedSpec;
  savedSpecs?: SavedSpecFile[];
  error?: string;
} {
  const genRes = generateSpec(form);
  if (!genRes.ok || !genRes.generated) {
    return { ok: false, error: genRes.error || "Invalid plugin spec" };
  }

  const dir = getDefaultPluginsDir(customDir);
  try {
    fs.mkdirSync(dir, { recursive: true });
    const filename = `${genRes.generated.file}.lua`;
    const fullPath = path.join(dir, filename);
    fs.writeFileSync(fullPath, genRes.generated.source, "utf8");
    const repoRoot = getRepoRoot();
    const relativePath = fullPath.startsWith(repoRoot)
      ? path.relative(repoRoot, fullPath)
      : fullPath;

    return {
      ok: true,
      path: fullPath,
      relativePath,
      file: genRes.generated.file,
      generated: genRes.generated,
      savedSpecs: listSavedSpecs(customDir),
    };
  } catch (err) {
    return {
      ok: false,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}

export function listSavedSpecs(customDir?: string): SavedSpecFile[] {
  const dir = getDefaultPluginsDir(customDir);
  if (!fs.existsSync(dir)) {
    return [];
  }
  const repoRoot = getRepoRoot();
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  const out: SavedSpecFile[] = [];
  for (const entry of entries) {
    if (entry.isFile() && entry.name.endsWith(".lua")) {
      const fullPath = path.join(dir, entry.name);
      const stat = fs.statSync(fullPath);
      const source = fs.readFileSync(fullPath, "utf8");
      const repoMatch =
        source.match(/return\s*\{\s*["']([^"']+\/[^"']+)["']/) ||
        source.match(/url\s*=\s*["']([^"']+)["']/);
      out.push({
        file: entry.name.replace(/\.lua$/, ""),
        filename: entry.name,
        path: fullPath,
        relativePath: fullPath.startsWith(repoRoot)
          ? path.relative(repoRoot, fullPath)
          : fullPath,
        size: stat.size,
        mtime: stat.mtime.toISOString(),
        source,
        repo: repoMatch ? repoMatch[1] : entry.name.replace(/\.lua$/, ""),
      });
    }
  }
  out.sort((a, b) => b.mtime.localeCompare(a.mtime));
  return out;
}

export function deleteSavedSpec(file: string, customDir?: string): boolean {
  const clean = file.replace(/\.lua$/, "").replace(/[/\\]/g, "");
  const fullPath = path.join(getDefaultPluginsDir(customDir), `${clean}.lua`);
  if (fs.existsSync(fullPath)) {
    fs.unlinkSync(fullPath);
    return true;
  }
  return false;
}
