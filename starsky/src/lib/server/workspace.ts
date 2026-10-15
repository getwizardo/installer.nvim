// Workspace files for the Starsky IDE. Every path is resolved against the
// kaeru.nvim repository root and must stay inside it, so the web API can never
// read or write arbitrary files on the machine.
import fs from "node:fs";
import path from "node:path";
import { getRepoRoot } from "./luaBridge";

export interface WorkspaceEntry {
  name: string;
  relativePath: string;
  type: "file" | "dir";
  size: number;
  language: string;
}

const LANGUAGES: Record<string, string> = {
  ".ts": "typescript",
  ".tsx": "tsx",
  ".js": "javascript",
  ".jsx": "jsx",
  ".svelte": "svelte",
  ".lua": "lua",
  ".py": "python",
  ".json": "json",
  ".yaml": "yaml",
  ".yml": "yaml",
  ".md": "markdown",
  ".txt": "text",
  ".css": "css",
  ".html": "html",
  ".sh": "bash",
  ".vim": "vim",
};

export function detectLanguage(filePath: string): string {
  return LANGUAGES[path.extname(filePath).toLowerCase()] || "plaintext";
}

const IGNORED_DIRS = new Set([
  ".git",
  "node_modules",
  ".svelte-kit",
  ".next",
  "build",
  "dist",
  "__pycache__",
  ".cache",
]);

// Git internals and credential-style files are never served, even though they
// sit inside the repository. The web API is reachable from the preview host.
const BLOCKED_SEGMENTS = new Set([".git"]);
const BLOCKED_FILE_NAME =
  /^(\.env(\..*)?|\.npmrc|\.netrc|\.pypirc|\.git-credentials|id_[a-z0-9_]+|.*\.(pem|key|p12|pfx))$/i;

/** True for paths inside the repository that the web IDE must not read or write. */
export function isBlockedRelativePath(rel: string): boolean {
  const parts = rel.split(path.sep).filter(Boolean);
  if (parts.some((part) => BLOCKED_SEGMENTS.has(part))) return true;
  return parts.length > 0 && BLOCKED_FILE_NAME.test(parts[parts.length - 1]);
}

/**
 * Resolve a workspace-relative (or absolute) path. Rejects anything outside the
 * repository root and anything that isBlockedRelativePath.
 */
export function resolveWorkspacePath(target: string, root = getRepoRoot()): string {
  const resolved = path.resolve(root, target);
  const rel = path.relative(root, resolved);
  if (rel.startsWith("..") || path.isAbsolute(rel)) {
    throw new Error(`Path is outside the workspace: ${target}`);
  }
  if (isBlockedRelativePath(rel)) {
    throw new Error(`Path is not available in the web IDE: ${target}`);
  }
  return resolved;
}

/** Sorted, depth-limited listing of the workspace (directories first). */
export function listWorkspaceFiles(maxFiles = 400, root = getRepoRoot()): WorkspaceEntry[] {
  const results: WorkspaceEntry[] = [];

  function walk(dir: string, depth: number) {
    if (depth > 5 || results.length >= maxFiles) return;
    let entries: fs.Dirent[] = [];
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    entries.sort((a, b) => {
      if (a.isDirectory() !== b.isDirectory()) return a.isDirectory() ? -1 : 1;
      return a.name.localeCompare(b.name);
    });
    for (const entry of entries) {
      if (results.length >= maxFiles) break;
      if (IGNORED_DIRS.has(entry.name)) continue;
      const full = path.join(dir, entry.name);
      const relativePath = path.relative(root, full);
      if (isBlockedRelativePath(relativePath)) continue;
      if (entry.isDirectory()) {
        results.push({ name: entry.name, relativePath, type: "dir", size: 0, language: "directory" });
        walk(full, depth + 1);
      } else if (entry.isFile()) {
        let size = 0;
        try {
          size = fs.statSync(full).size;
        } catch {
          size = 0;
        }
        results.push({ name: entry.name, relativePath, type: "file", size, language: detectLanguage(full) });
      }
    }
  }

  walk(root, 0);
  return results;
}

/** Read a workspace file as text (used for SFTP uploads and the editor's first load). */
export function readWorkspaceFile(target: string): {
  ok: boolean;
  path: string;
  relativePath: string;
  content: string;
  language: string;
  error?: string;
} {
  const root = getRepoRoot();
  let resolved: string;
  try {
    resolved = resolveWorkspacePath(target, root);
  } catch (err) {
    return {
      ok: false,
      path: target,
      relativePath: target,
      content: "",
      language: detectLanguage(target),
      error: err instanceof Error ? err.message : String(err),
    };
  }
  const relativePath = path.relative(root, resolved);
  if (!fs.existsSync(resolved) || fs.statSync(resolved).isDirectory()) {
    return {
      ok: false,
      path: resolved,
      relativePath,
      content: "",
      language: detectLanguage(resolved),
      error: `File not found: ${target}`,
    };
  }
  return {
    ok: true,
    path: resolved,
    relativePath,
    content: fs.readFileSync(resolved, "utf8"),
    language: detectLanguage(resolved),
  };
}
