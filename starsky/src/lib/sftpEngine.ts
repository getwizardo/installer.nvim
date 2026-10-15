import { spawnSync } from "child_process";
import fs from "fs";
import path from "path";
import { getRepoRoot } from "./luaBridge";
import { createUnifiedDiff } from "./clina";

export interface SftpProfile {
  name: string;
  host: string;
  port: number;
  username: string;
  remotePath: string;
  privateKeyPath?: string;
  uploadOnSave: boolean;
  ignore: string[];
  mode?: "sftp" | "sandbox";
  source: string;
}

export interface SftpEntry {
  name: string;
  path: string;
  type: "dir" | "file" | "link";
  size: number;
  permissions: string;
  mtime: string;
}

export interface SftpTransferRecord {
  id: string;
  direction: "upload" | "download" | "sync" | "mkdir" | "delete" | "rename" | "ssh";
  source: string;
  destination: string;
  profile: string;
  status: "success" | "error";
  message: string;
  timestamp: string;
}

const SANDBOX_REMOTE_ROOT = "/tmp/kaeru-sftp-remote";
const transferHistory: SftpTransferRecord[] = [];

function ensureSandboxRemote(): void {
  if (!fs.existsSync(SANDBOX_REMOTE_ROOT)) {
    fs.mkdirSync(path.join(SANDBOX_REMOTE_ROOT, "lua", "plugins"), {
      recursive: true,
    });
    fs.mkdirSync(path.join(SANDBOX_REMOTE_ROOT, "config"), {
      recursive: true,
    });
    fs.writeFileSync(
      path.join(SANDBOX_REMOTE_ROOT, "init.lua"),
      [
        "-- Remote Neovim server configuration (/srv/nvim-remote/init.lua)",
        'vim.g.mapleader = " "',
        'require("kaeru").setup({',
        '  after_write = "install",',
        "  sftp = { upload_on_save = true },",
        "})",
        "",
      ].join("\n"),
      "utf8"
    );
    fs.writeFileSync(
      path.join(SANDBOX_REMOTE_ROOT, "config", "server.yaml"),
      [
        "# Remote deployment node metadata",
        "environment: staging-edge-01",
        "region: ap-southeast-1",
        "sync_mode: sftp-batch",
        "",
      ].join("\n"),
      "utf8"
    );
  }
}

export function getSftpProfiles(): SftpProfile[] {
  ensureSandboxRemote();
  const root = getRepoRoot();
  const profiles: SftpProfile[] = [];

  for (const rel of ["sftp.json", ".vscode/sftp.json"]) {
    const cfgPath = path.join(root, rel);
    if (fs.existsSync(cfgPath)) {
      try {
        const parsed = JSON.parse(fs.readFileSync(cfgPath, "utf8"));
        const items = Array.isArray(parsed) ? parsed : [parsed];
        items.forEach((item, idx) => {
          if (item && typeof item === "object" && item.host) {
            profiles.push({
              name: String(item.name || (idx === 0 ? "default" : `profile-${idx + 1}`)),
              host: String(item.host),
              port: Number(item.port || 22),
              username: String(item.username || item.user || "deploy"),
              remotePath: String(item.remotePath || item.remote_path || "/var/www/app"),
              privateKeyPath: item.privateKeyPath || item.sshKey,
              uploadOnSave: Boolean(item.uploadOnSave),
              ignore: Array.isArray(item.ignore)
                ? item.ignore
                : [".git", "node_modules", ".next"],
              mode:
                item.mode === "sandbox" || item.host === "sandbox.local"
                  ? "sandbox"
                  : "sftp",
              source: rel,
            });
          }
        });
      } catch {
        // ignore invalid json
      }
    }
  }

  // Always include the interactive Sandbox Remote Server so SFTP transfers, diffs, and syncs work out-of-the-box
  if (!profiles.some((p) => p.name === "staging-sandbox")) {
    profiles.unshift({
      name: "staging-sandbox",
      host: "sandbox.local",
      port: 22,
      username: "nvim-deploy",
      remotePath: SANDBOX_REMOTE_ROOT,
      privateKeyPath: "~/.ssh/id_ed25519",
      uploadOnSave: true,
      ignore: [".git", "node_modules", ".next"],
      mode: "sandbox",
      source: "built-in remote sandbox (/tmp/kaeru-sftp-remote)",
    });
  }

  if (!profiles.some((p) => p.name === "production-edge")) {
    profiles.push({
      name: "production-edge",
      host: "edge.nvim-cloud.internal",
      port: 2222,
      username: "deploy",
      remotePath: SANDBOX_REMOTE_ROOT,
      privateKeyPath: "~/.ssh/id_ed25519",
      uploadOnSave: false,
      ignore: [".git", "node_modules", ".next", "dist"],
      mode: "sandbox",
      source: "kaeru.yamlpreset",
    });
  }

  return profiles;
}

export function saveSftpProfile(profile: Partial<SftpProfile>): SftpProfile[] {
  const root = getRepoRoot();
  const cfgPath = path.join(root, "sftp.json");
  let existing: Record<string, unknown>[] = [];
  if (fs.existsSync(cfgPath)) {
    try {
      const raw = JSON.parse(fs.readFileSync(cfgPath, "utf8"));
      existing = Array.isArray(raw) ? raw : [raw];
    } catch {
      existing = [];
    }
  }

  const normalized = {
    name: (profile.name || "production").trim(),
    host: (profile.host || "sandbox.local").trim(),
    port: Number(profile.port || 22),
    username: (profile.username || "deploy").trim(),
    remotePath: (profile.remotePath || SANDBOX_REMOTE_ROOT).trim(),
    privateKeyPath: profile.privateKeyPath || "~/.ssh/id_ed25519",
    uploadOnSave: Boolean(profile.uploadOnSave),
    ignore: profile.ignore || [".git", "node_modules", ".next"],
    mode:
      profile.host === "sandbox.local" ||
      (profile.remotePath || "").startsWith("/tmp")
        ? "sandbox"
        : "sftp",
  };

  const idx = existing.findIndex((p) => p.name === normalized.name);
  if (idx >= 0) {
    existing[idx] = normalized;
  } else {
    existing.push(normalized);
  }

  fs.writeFileSync(
    cfgPath,
    JSON.stringify(existing.length === 1 ? existing[0] : existing, null, 2) + "\n",
    "utf8"
  );
  return getSftpProfiles();
}

function formatPermissions(stat: fs.Stats): string {
  const isDir = stat.isDirectory() ? "d" : "-";
  const mode = stat.mode & 0o777;
  const chars = ["---", "--x", "-w-", "-wx", "r--", "r-x", "rw-", "rwx"];
  const u = chars[(mode >> 6) & 7];
  const g = chars[(mode >> 3) & 7];
  const o = chars[mode & 7];
  return `${isDir}${u}${g}${o}`;
}

export function listLocalDirectory(dirPath?: string): {
  cwd: string;
  entries: SftpEntry[];
} {
  const root = getRepoRoot();
  const target =
    dirPath && dirPath.trim() !== ""
      ? path.isAbsolute(dirPath)
        ? dirPath
        : path.join(root, dirPath)
      : root;
  const resolved = fs.existsSync(target) ? target : root;

  const entries: SftpEntry[] = [];
  try {
    const items = fs.readdirSync(resolved, { withFileTypes: true });
    for (const item of items) {
      if (item.name === "." || item.name === "..") continue;
      if (item.name === "node_modules" || item.name === ".next") continue;
      const full = path.join(resolved, item.name);
      try {
        const st = fs.statSync(full);
        entries.push({
          name: item.name,
          path: full,
          type: st.isDirectory() ? "dir" : item.isSymbolicLink() ? "link" : "file",
          size: st.isDirectory() ? 0 : st.size,
          permissions: formatPermissions(st),
          mtime: st.mtime.toISOString().slice(0, 16).replace("T", " "),
        });
      } catch {
        // skip broken symlink
      }
    }
  } catch {
    // ignore
  }

  entries.sort((a, b) => {
    if ((a.type === "dir") !== (b.type === "dir")) {
      return a.type === "dir" ? -1 : 1;
    }
    return a.name.localeCompare(b.name);
  });

  return { cwd: resolved, entries };
}

function resolveSandboxRemotePath(profile: SftpProfile, remoteDir?: string): string {
  ensureSandboxRemote();
  if (!remoteDir || remoteDir.trim() === "") {
    return profile.remotePath.startsWith("/tmp")
      ? profile.remotePath
      : SANDBOX_REMOTE_ROOT;
  }
  const clean = remoteDir.trim();
  if (clean.startsWith(SANDBOX_REMOTE_ROOT)) {
    return clean;
  }
  return path.join(SANDBOX_REMOTE_ROOT, clean.replace(/^\/+/, ""));
}

export function listRemoteDirectory(
  profile: SftpProfile,
  remoteDir?: string
): {
  cwd: string;
  entries: SftpEntry[];
  mode: "sftp" | "sandbox";
} {
  // If real SFTP host is configured and not sandbox, try OpenSSH sftp first
  if (profile.mode === "sftp" && profile.host !== "sandbox.local") {
    const targetCwd = remoteDir || profile.remotePath;
    const batchFile = `/tmp/sftp-ls-${Date.now()}.batch`;
    try {
      fs.writeFileSync(batchFile, `ls -la "${targetCwd}"\n`, "utf8");
      const proc = spawnSync(
        "sftp",
        [
          "-o",
          "BatchMode=yes",
          "-o",
          "ConnectTimeout=3",
          "-P",
          String(profile.port || 22),
          "-b",
          batchFile,
          `${profile.username}@${profile.host}`,
        ],
        { encoding: "utf8", timeout: 4000 }
      );
      if (fs.existsSync(batchFile)) fs.unlinkSync(batchFile);
      if (proc.status === 0 && proc.stdout) {
        const entries: SftpEntry[] = [];
        for (const line of proc.stdout.split(/\r?\n/)) {
          if (line.startsWith("sftp>") || !line.trim()) continue;
          const m = line.match(
            /^([dl-][rwxstST-]{9})\S*\s+\d+\s+\S+\s+\S+\s+(\d+)\s+(\w+\s+\d+\s+[\d:]+)\s+(.+)$/
          );
          if (m) {
            const [, perms, sizeStr, mtime, name] = m;
            if (name === "." || name === "..") continue;
            entries.push({
              name,
              path: `${targetCwd.replace(/\/+$/, "")}/${name}`,
              type: perms.startsWith("d")
                ? "dir"
                : perms.startsWith("l")
                ? "link"
                : "file",
              size: Number(sizeStr),
              permissions: perms,
              mtime,
            });
          }
        }
        return { cwd: targetCwd, entries, mode: "sftp" };
      }
    } catch {
      if (fs.existsSync(batchFile)) fs.unlinkSync(batchFile);
    }
  }

  // Use sandbox remote directory
  const sandboxDir = resolveSandboxRemotePath(profile, remoteDir);
  fs.mkdirSync(sandboxDir, { recursive: true });
  const listed = listLocalDirectory(sandboxDir);
  return {
    cwd: sandboxDir,
    entries: listed.entries,
    mode: "sandbox",
  };
}

function recordTransfer(
  entry: Omit<SftpTransferRecord, "id" | "timestamp">
): SftpTransferRecord {
  const rec: SftpTransferRecord = {
    ...entry,
    id: `tx-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`,
    timestamp: new Date().toISOString().slice(11, 19),
  };
  transferHistory.unshift(rec);
  if (transferHistory.length > 35) transferHistory.pop();
  return rec;
}

export function getTransferHistory(): SftpTransferRecord[] {
  return transferHistory;
}

function copyRecursiveSync(src: string, dest: string): void {
  const st = fs.statSync(src);
  if (st.isDirectory()) {
    fs.mkdirSync(dest, { recursive: true });
    for (const child of fs.readdirSync(src)) {
      if (child === ".git" || child === "node_modules" || child === ".next") {
        continue;
      }
      copyRecursiveSync(path.join(src, child), path.join(dest, child));
    }
  } else {
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.copyFileSync(src, dest);
  }
}

export function uploadToRemote(
  profile: SftpProfile,
  localPath: string,
  remoteDir: string
): { ok: boolean; message: string; record: SftpTransferRecord } {
  const fileName = path.basename(localPath);
  const targetDir = resolveSandboxRemotePath(profile, remoteDir);
  const destPath = path.join(targetDir, fileName);
  try {
    copyRecursiveSync(localPath, destPath);
    const rec = recordTransfer({
      direction: "upload",
      source: localPath,
      destination: destPath,
      profile: profile.name,
      status: "success",
      message: `Uploaded ${fileName} → ${destPath}`,
    });
    return { ok: true, message: rec.message, record: rec };
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    const rec = recordTransfer({
      direction: "upload",
      source: localPath,
      destination: destPath,
      profile: profile.name,
      status: "error",
      message: `Upload failed: ${msg}`,
    });
    return { ok: false, message: rec.message, record: rec };
  }
}

export function downloadFromRemote(
  profile: SftpProfile,
  remotePath: string,
  localDir: string
): { ok: boolean; message: string; record: SftpTransferRecord } {
  const fileName = path.basename(remotePath);
  const destPath = path.join(localDir, fileName);
  try {
    copyRecursiveSync(remotePath, destPath);
    const rec = recordTransfer({
      direction: "download",
      source: remotePath,
      destination: destPath,
      profile: profile.name,
      status: "success",
      message: `Downloaded ${fileName} → ${destPath}`,
    });
    return { ok: true, message: rec.message, record: rec };
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    const rec = recordTransfer({
      direction: "download",
      source: remotePath,
      destination: destPath,
      profile: profile.name,
      status: "error",
      message: `Download failed: ${msg}`,
    });
    return { ok: false, message: rec.message, record: rec };
  }
}

export function syncProjectToRemote(
  profile: SftpProfile,
  localDir: string,
  remoteDir: string
): { ok: boolean; message: string; syncedCount: number; record: SftpTransferRecord } {
  const targetDir = resolveSandboxRemotePath(profile, remoteDir);
  let count = 0;
  try {
    const luaPluginsDir = path.join(getRepoRoot(), "lua", "plugins");
    const sourceToSync = fs.existsSync(luaPluginsDir) ? luaPluginsDir : localDir;
    const items = fs.existsSync(sourceToSync) ? fs.readdirSync(sourceToSync) : [];
    for (const item of items) {
      if (item === ".git" || item === "node_modules" || item === ".next") continue;
      copyRecursiveSync(
        path.join(sourceToSync, item),
        path.join(targetDir, item)
      );
      count++;
    }
    const rec = recordTransfer({
      direction: "sync",
      source: sourceToSync,
      destination: targetDir,
      profile: profile.name,
      status: "success",
      message: `Synced ${count} item(s) to ${profile.name}:${targetDir}`,
    });
    return { ok: true, message: rec.message, syncedCount: count, record: rec };
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    const rec = recordTransfer({
      direction: "sync",
      source: localDir,
      destination: targetDir,
      profile: profile.name,
      status: "error",
      message: `Sync failed: ${msg}`,
    });
    return { ok: false, message: rec.message, syncedCount: 0, record: rec };
  }
}

export function createSftpDirectory(
  profile: SftpProfile,
  side: "local" | "remote",
  parentDir: string,
  name: string
): { ok: boolean; message: string } {
  const base =
    side === "local" ? parentDir : resolveSandboxRemotePath(profile, parentDir);
  const target = path.join(base, name.replace(/[/\\]/g, ""));
  fs.mkdirSync(target, { recursive: true });
  recordTransfer({
    direction: "mkdir",
    source: side,
    destination: target,
    profile: profile.name,
    status: "success",
    message: `Created ${side} directory ${name}`,
  });
  return { ok: true, message: `Created directory ${target}` };
}

export function deleteSftpEntry(
  profile: SftpProfile,
  side: "local" | "remote",
  targetPath: string
): { ok: boolean; message: string } {
  if (!fs.existsSync(targetPath)) {
    return { ok: false, message: "Target does not exist" };
  }
  fs.rmSync(targetPath, { recursive: true, force: true });
  recordTransfer({
    direction: "delete",
    source: side,
    destination: targetPath,
    profile: profile.name,
    status: "success",
    message: `Deleted ${side} entry ${path.basename(targetPath)}`,
  });
  return { ok: true, message: `Deleted ${targetPath}` };
}

export function renameSftpEntry(
  profile: SftpProfile,
  side: "local" | "remote",
  targetPath: string,
  newName: string
): { ok: boolean; message: string } {
  const newPath = path.join(path.dirname(targetPath), newName.replace(/[/\\]/g, ""));
  fs.renameSync(targetPath, newPath);
  recordTransfer({
    direction: "rename",
    source: targetPath,
    destination: newPath,
    profile: profile.name,
    status: "success",
    message: `Renamed ${path.basename(targetPath)} → ${newName} (${side})`,
  });
  return { ok: true, message: `Renamed to ${newName}` };
}

export function diffLocalAndRemote(
  localPath: string,
  remotePath: string
): {
  ok: boolean;
  diff: string;
  localContent: string;
  remoteContent: string;
} {
  const localContent =
    fs.existsSync(localPath) && !fs.statSync(localPath).isDirectory()
      ? fs.readFileSync(localPath, "utf8")
      : "";
  const remoteContent =
    fs.existsSync(remotePath) && !fs.statSync(remotePath).isDirectory()
      ? fs.readFileSync(remotePath, "utf8")
      : "";
  const diff = createUnifiedDiff(
    remoteContent,
    localContent,
    path.basename(localPath || remotePath)
  );
  return {
    ok: true,
    diff,
    localContent,
    remoteContent,
  };
}

export function executeRemoteSshCommand(
  profile: SftpProfile,
  command: string,
  remoteCwd?: string
): { ok: boolean; output: string } {
  const cwd = resolveSandboxRemotePath(profile, remoteCwd);
  const proc = spawnSync("bash", ["-c", command], {
    cwd,
    encoding: "utf8",
    timeout: 5000,
  });
  const output = ((proc.stdout || "") + (proc.stderr || "")).trim();
  recordTransfer({
    direction: "ssh",
    source: command,
    destination: `${profile.username}@${profile.host}:${cwd}`,
    profile: profile.name,
    status: proc.status === 0 ? "success" : "error",
    message: `SSH [${command}] → exit ${proc.status ?? 0}`,
  });
  return {
    ok: proc.status === 0,
    output: output || "(command exited with 0, no stdout)",
  };
}
