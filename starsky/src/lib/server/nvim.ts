// Node Neovim client (https://github.com/neovim/node-client) for Starsky.
//
// Starsky talks to a real headless Neovim that loads the kaeru.nvim Lua modules
// (`kaeru.spec`, `kaeru.parser`, `kaeru.complete`, …). The Lua side only ever
// receives and returns JSON strings, so the msgpack ↔ JS conversion never has
// to guess Lua table shapes.
import { spawn, type ChildProcess } from "node:child_process";
import { attach, findNvim, type NeovimClient } from "neovim";

const NVIM_ARGS = ["--embed", "--headless", "-n", "-i", "NONE", "-u", "NONE"];
const CALL_TIMEOUT_MS = 8000;

/**
 * Every call runs this prelude first: it puts the kaeru.nvim repository on
 * `package.path`, decodes the JSON payload and encodes the result (or an error)
 * back to JSON. The action body is inserted between the prelude and the epilogue.
 */
const PRELUDE = `
local root, raw = ...
package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
local payload = vim.fn.json_decode(raw)
local ok, result = pcall(function()
`;

const EPILOGUE = `
end)
if not ok then
  return vim.fn.json_encode({ ok = false, error = tostring(result) })
end
local encoded_ok, encoded = pcall(vim.fn.json_encode, result)
if not encoded_ok then
  return vim.fn.json_encode({ ok = false, error = "could not encode result: " .. tostring(encoded) })
end
return encoded
`;

/** Lua bodies for every bridge action. Each returns a Lua table. */
export const NVIM_ACTIONS = {
  spec_generate: `
    local g, err = require("kaeru.spec").generate(payload.form or {})
    if not g then return { ok = false, error = tostring(err) } end
    return { ok = true, generated = g }
  `,
  parse: `
    local items, err = require("kaeru.parser").parse_all(payload.text or "")
    if not items or #items == 0 then
      return { ok = false, error = tostring(err or "No plugin specs found"), items = {} }
    end
    return { ok = true, items = items }
  `,
  complete: `
    local items = require("kaeru.complete").complete_field(
      payload.key or "repo", payload.base or "", payload.form or {})
    return { ok = true, items = items or {} }
  `,
} as const;

export type NvimAction = keyof typeof NVIM_ACTIONS;

let client: NeovimClient | null = null;
let child: ChildProcess | null = null;
let starting: Promise<NeovimClient> | null = null;
let command: string[] | null | undefined;

/** Locate an `nvim` >= 0.9 binary, or `null` when none is installed. */
export function findNvimCommand(): string[] | null {
  if (command !== undefined) return command;
  try {
    const found = findNvim({ orderBy: "desc", minVersion: "0.9.0", firstMatch: true });
    command = found.matches[0] ? [...found.matches[0].cmd] : null;
  } catch {
    command = null;
  }
  return command;
}

export function nvimStatus(): { available: boolean; cmd: string | null } {
  const cmd = findNvimCommand();
  return { available: cmd !== null, cmd: cmd ? cmd.join(" ") : null };
}

async function startClient(): Promise<NeovimClient> {
  const cmd = findNvimCommand();
  if (!cmd) {
    throw new Error("nvim >= 0.9 was not found on PATH");
  }
  const [bin, ...args] = cmd;
  const proc = spawn(bin, [...args, ...NVIM_ARGS], { stdio: ["pipe", "pipe", "pipe"] });
  const nvim = attach({ proc });
  child = proc;
  const reset = () => {
    if (client === nvim) client = null;
    if (child === proc) child = null;
    starting = null;
  };
  proc.on("exit", reset);
  proc.on("error", reset);
  client = nvim;
  return nvim;
}

/** Returns the shared Neovim client, starting a headless instance on first use. */
export async function getNvim(): Promise<NeovimClient> {
  if (client) return client;
  if (!starting) {
    starting = startClient().catch((err) => {
      starting = null;
      throw err;
    });
  }
  return starting;
}

/** Run one bridge action inside the headless Neovim and decode its JSON result. */
export async function callNvim<T>(
  repoRoot: string,
  action: NvimAction,
  payload: Record<string, unknown>
): Promise<T> {
  const nvim = await getNvim();
  const code = PRELUDE + NVIM_ACTIONS[action] + EPILOGUE;
  const call = nvim.lua(code, [repoRoot, JSON.stringify(payload ?? {})]);
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(
      () => reject(new Error(`nvim ${action} timed out after ${CALL_TIMEOUT_MS}ms`)),
      CALL_TIMEOUT_MS
    );
  });
  try {
    const raw = await Promise.race([call, timeout]);
    if (typeof raw !== "string") {
      throw new Error(`nvim ${action} returned no JSON`);
    }
    return JSON.parse(raw) as T;
  } finally {
    if (timer) clearTimeout(timer);
  }
}

/** Stop the headless Neovim (used on shutdown and in tests). */
export function closeNvim(): void {
  if (child && !child.killed) {
    child.kill();
  }
  client = null;
  child = null;
  starting = null;
}

// Only hook `exit`: registering SIGINT/SIGTERM listeners would suppress the
// default termination of the Node server.
process.once("exit", () => closeNvim());
