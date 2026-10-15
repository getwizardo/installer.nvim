// The web terminal's Ex commands. Only the commands listed here run; anything
// else is refused, so the browser can never run shell commands on the machine.
import { execEx, openInNvim } from "./editor";
import { nvimStatus } from "./nvim";
import { resolvePluginsDir, saveSpecToDisk } from "./luaBridge";
import { musicAction } from "./music";
import { resolveWorkspacePath } from "./workspace";

export interface ExResult {
  ok: boolean;
  lines: string[];
}

export const EX_HELP = [
  ":w                     write the current buffer",
  ":e <file>              open a workspace file in Neovim",
  ":ls                    list Neovim buffers",
  ":Kaeru save <owner/repo>  write a lazy.nvim spec file",
  ":Kaeru dir             show the spec directory",
  ":Kikru play|pause|next|prev|status",
  ":nvim                  show the Neovim connection",
  ":help                  this list",
];

function errorOf(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

export async function runWebEx(input: string): Promise<ExResult> {
  const command = input.trim().replace(/^:/, "");
  if (command === "") return { ok: true, lines: [] };
  const [head, ...rest] = command.split(/\s+/);
  const arg = rest.join(" ");

  try {
    if (head === "help") return { ok: true, lines: EX_HELP };

    if (head === "nvim") {
      const st = nvimStatus();
      return {
        ok: st.available,
        lines: [st.available ? `connected: ${st.cmd}` : "Neovim is not available (TypeScript fallback only)"],
      };
    }

    if (head === "w" || head === "write") {
      // Writes the buffer Neovim already holds (the last file the editor opened or saved).
      return { ok: true, lines: await execEx("silent write") };
    }

    if (head === "e" || head === "edit") {
      if (!arg) return { ok: false, lines: ["E471: argument required: :e <file>"] };
      const abs = resolveWorkspacePath(arg);
      const buf = await openInNvim(abs);
      return { ok: true, lines: [`"${arg}" ${buf.lines.length}L · filetype=${buf.filetype || "none"}`] };
    }

    if (head === "ls" || head === "buffers") {
      return { ok: true, lines: await execEx("ls") };
    }

    if (head === "Kaeru" && rest[0] === "save" && rest[1]) {
      const res = await saveSpecToDisk({ repo: rest[1] });
      return res.ok
        ? { ok: true, lines: [`[Kaeru] saved spec → ${res.relativePath}`] }
        : { ok: false, lines: [`[Kaeru] ${res.error}`] };
    }

    if (head === "Kaeru" && rest[0] === "dir") {
      return { ok: true, lines: [await resolvePluginsDir()] };
    }

    if (head === "Kikru") {
      const sub = rest[0] || "status";
      if (sub === "status") {
        return { ok: true, lines: ["[Kikru] open the Music tab for the full player"] };
      }
      const action = sub === "play" || sub === "pause" ? "toggle" : sub;
      if (!["toggle", "next", "prev"].includes(action)) {
        return { ok: false, lines: [`[Kikru] unknown action: ${sub}`] };
      }
      const res = musicAction({ action }) as { state?: { playing: boolean } };
      return { ok: true, lines: [`[Kikru] ${action} → ${res.state?.playing ? "playing" : "paused"}`] };
    }

    return {
      ok: false,
      lines: [`E492: not available in the web terminal: :${command} (try :help)`],
    };
  } catch (err) {
    return { ok: false, lines: [errorOf(err)] };
  }
}

