// The web IDE's editor runs on the same Neovim session as the Lua bridge: opening
// a file creates a buffer there, saving replaces the buffer text and `:write`s it,
// and the terminal runs a short list of Ex commands (see ex.ts).
import { getNvim } from "./nvim";

const TIMEOUT_MS = 8000;

function withTimeout<T>(work: Promise<T>, label: string): Promise<T> {
  let timer: ReturnType<typeof setTimeout> | undefined;
  const timeout = new Promise<never>((_, reject) => {
    timer = setTimeout(() => reject(new Error(`${label} timed out after ${TIMEOUT_MS}ms`)), TIMEOUT_MS);
  });
  return Promise.race([work, timeout]).finally(() => {
    if (timer) clearTimeout(timer);
  });
}

export interface EditorBuffer {
  bufnr: number;
  path: string;
  filetype: string;
  lines: string[];
}

/** Open (or switch to) a file in the Neovim session and return its buffer. */
export async function openInNvim(absPath: string): Promise<EditorBuffer> {
  const nvim = await getNvim();
  const escaped = String(await nvim.call("fnameescape", [absPath]));
  await withTimeout(nvim.command(`silent edit ${escaped}`), "edit");
  const buf = await nvim.buffer;
  const lines = await withTimeout(buf.lines, "read");
  // `-u NONE` leaves filetype detection off, so ask Neovim's filetype matcher directly.
  const filetype = String(
    await nvim.lua('local name = ...; return vim.filetype.match({ filename = name }) or ""', [absPath])
  );
  return { bufnr: buf.id, path: absPath, filetype, lines };
}

/** Replace the buffer text for `absPath` with `content`, then `:write` it. */
export async function writeBufferInNvim(absPath: string, content: string): Promise<{ bytes: number }> {
  const nvim = await getNvim();
  const current = String(await (await nvim.buffer).name);
  if (current !== absPath) {
    const escaped = String(await nvim.call("fnameescape", [absPath]));
    await withTimeout(nvim.command(`silent edit ${escaped}`), "edit");
  }
  const buf = await nvim.buffer;
  await withTimeout(
    buf.setLines(content.split("\n"), { start: 0, end: -1, strictIndexing: false }),
    "setLines"
  );
  await withTimeout(nvim.command("silent write"), "write");
  return { bytes: Buffer.byteLength(content, "utf8") };
}

/** Run one Ex command in the Neovim session and return its captured output lines. */
export async function execEx(command: string): Promise<string[]> {
  const nvim = await getNvim();
  const result = (await withTimeout(nvim.request("nvim_exec2", [command, { output: true }]), "ex")) as {
    output?: string;
  };
  return (result?.output ?? "").split("\n").filter((line) => line.length > 0);
}
