
const NEOCODEIUM_SUGGESTIONS: Record<string, string[]> = {
  lua: [
    'require("neocodeium").setup({ manual = false, show_label = true })',
    'vim.keymap.set("i", "<A-f>", function() require("neocodeium").accept() end)',
    'require("kaeru").save({ repo = "monkoose/neocodeium", event = "VeryLazy" })',
  ],
  typescript: [
    "export const neocodeiumStatus = { engine: 'monkoose/neocodeium', active: true };",
    "customElements.define('starsky-code-editor', StarskyCodeEditorElement);",
    "await fetch('/api/spec/save', { method: 'POST', body: JSON.stringify({ form }) });",
  ],
  default: [
    "-- NeoCodeium (monkoose/neocodeium) inline ghost-text suggestion [1/3]",
    'return { "monkoose/neocodeium", event = "VeryLazy", opts = {} }',
  ],
};

const ASCII_LOGO_LINES = [
  "   _____ _______       _____   _____ _  ____     __  _   ___      _______ __  __ ",
  "  / ____|__   __|/\\   |  __ \\ / ____| |/ /\\ \\   / / | \\ | \\ \\    / /_   _|  \\/  |",
  " | (___    | |  /  \\  | |__) | (___ | ' /  \\ \\_/ /  |  \\| |\\ \\  / /  | | | \\  / |",
  "  \\___ \\   | | / /\\ \\ |  _  / \\___ \\|  <    \\   /   | . ` | \\ \\/ /   | | | |\\/| |",
  "  ____) |  | |/ ____ \\| | \\ \\ ____) | . \\    | |    | |\\  |  \\  /   _| |_| |  | |",
  " |_____/   |_/_/    \\_\\_|  \\_\\_____/|_|\\_\\   |_|    |_| \\_|   \\/   |_____|_|  |_|",
];

const BOOT_STEPS = [
  "Mounting lazy.nvim Spec Engine & Safe Validator ............... [  OK  ]",
  "Connecting GitHub Live Repository Autocomplete API ............ [  OK  ]",
  "Indexing https://mason-registry.dev (601 pkgs / 296 LSPs) ..... [  OK  ]",
  "Binding :Clina -> NeoCodeium (monkoose/neocodeium) ............ [  OK  ]",
  "Starting :Kikru 10-Band EQ & 2-Neovim TCP RPC ........... [  OK  ]",
  "Initializing Dual-Pane SFTP Studio & Custom Web Components .... [  OK  ]",
  "Mounting shadcn/ui + Vaul Drawer & Code IDE Workspace ......... [READY ]",
];

export function registerStarskyWebComponents(): void {
  if (typeof window === "undefined" || !window.customElements) {
    return;
  }

  // 1. <starsky-code-editor> Web Component
  if (!window.customElements.get("starsky-code-editor")) {
    class StarskyCodeEditorElement extends HTMLElement {
      static observedAttributes = ["code", "language", "filepath", "neocodeium"];
      private root: ShadowRoot;
      private textarea!: HTMLTextAreaElement;
      private gutter!: HTMLDivElement;
      private ghostText!: HTMLSpanElement;
      private statusLeft!: HTMLSpanElement;
      private statusRight!: HTMLSpanElement;
      private suggestionIdx = 0;

      constructor() {
        super();
        this.root = this.attachShadow({ mode: "open" });
        this.root.innerHTML = `
          <style>
            :host {
              display: flex;
              flex-direction: column;
              width: 100%;
              height: 100%;
              min-height: 440px;
              background: #070a12;
              border: 1px solid #26314d;
              border-radius: 9px;
              overflow: hidden;
              font-family: "JetBrains Mono", "Fira Code", monospace;
            }
            .neocodeium-bar {
              display: flex;
              align-items: center;
              justify-content: space-between;
              padding: 6px 12px;
              background: linear-gradient(90deg, rgba(88,166,255,0.12), rgba(188,140,255,0.12));
              border-bottom: 1px solid #26314d;
              font-size: 11.5px;
              color: #9ba7b8;
              gap: 8px;
              flex-wrap: wrap;
            }
            .nc-badge {
              color: #3fb950;
              font-weight: 700;
              display: inline-flex;
              align-items: center;
              gap: 6px;
            }
            .nc-ghost-preview {
              color: #79c0ff;
              font-style: italic;
              opacity: 0.85;
              overflow: hidden;
              text-overflow: ellipsis;
              white-space: nowrap;
              max-width: 420px;
            }
            .nc-actions {
              display: flex;
              gap: 5px;
            }
            .nc-btn {
              background: #171e31;
              border: 1px solid #2e3c5e;
              color: #e6edf3;
              font-family: inherit;
              font-size: 10.5px;
              padding: 2px 7px;
              border-radius: 4px;
              cursor: pointer;
            }
            .nc-btn:hover {
              border-color: #58a6ff;
              color: #58a6ff;
            }
            .editor-core {
              display: grid;
              grid-template-columns: 48px 1fr;
              flex: 1;
              position: relative;
              overflow: hidden;
            }
            .gutter {
              background: #0b0f1c;
              border-right: 1px solid #1c253b;
              padding: 12px 6px;
              text-align: right;
              color: #4b5873;
              font-size: 12px;
              line-height: 1.55;
              user-select: none;
              overflow: hidden;
              white-space: pre;
            }
            textarea {
              width: 100%;
              height: 100%;
              min-height: 360px;
              background: transparent;
              color: #e6edf3;
              border: none;
              padding: 12px 14px;
              font-family: inherit;
              font-size: 12.5px;
              line-height: 1.55;
              outline: none;
              resize: none;
              tab-size: 2;
            }
            .statusbar {
              display: flex;
              align-items: center;
              justify-content: space-between;
              padding: 5px 12px;
              background: #111624;
              border-top: 1px solid #26314d;
              font-size: 11px;
              color: #9ba7b8;
            }
            .mode-pill {
              background: #58a6ff;
              color: #070a12;
              font-weight: 800;
              padding: 1px 6px;
              border-radius: 3px;
              margin-right: 8px;
            }
          </style>
          <div class="neocodeium-bar">
            <div>
              <span class="nc-badge">⚡ :Clina · NeoCodeium (monkoose/neocodeium)</span>
              <span class="nc-ghost-preview" id="ghost-text"></span>
            </div>
            <div class="nc-actions">
              <button class="nc-btn" id="btn-accept" title="neocodeium.accept()">Accept &lt;A-f&gt;</button>
              <button class="nc-btn" id="btn-word" title="neocodeium.accept_word()">Word &lt;A-w&gt;</button>
              <button class="nc-btn" id="btn-line" title="neocodeium.accept_line()">Line &lt;A-a&gt;</button>
              <button class="nc-btn" id="btn-cycle" title="neocodeium.cycle_or_complete()">Cycle &lt;A-e&gt;</button>
            </div>
          </div>
          <div class="editor-core">
            <div class="gutter" id="gutter">1</div>
            <textarea id="code-area" spellcheck="false"></textarea>
          </div>
          <div class="statusbar">
            <span id="status-left"><span class="mode-pill">NORMAL</span> lua/kaeru/spec.lua</span>
            <span id="status-right">NeoCodeium [1/3] · UTF-8 · Ln 1, Col 1</span>
          </div>
        `;
      }

      connectedCallback() {
        this.textarea = this.root.getElementById("code-area") as HTMLTextAreaElement;
        this.gutter = this.root.getElementById("gutter") as HTMLDivElement;
        this.ghostText = this.root.getElementById("ghost-text") as HTMLSpanElement;
        this.statusLeft = this.root.getElementById("status-left") as HTMLSpanElement;
        this.statusRight = this.root.getElementById("status-right") as HTMLSpanElement;

        this.textarea.value = this.getAttribute("code") || "";
        this.updateGutterAndStatus();
        this.updateGhostSuggestion();

        this.textarea.addEventListener("input", () => {
          this.updateGutterAndStatus();
          this.dispatchEvent(
            new CustomEvent("code-change", {
              detail: { code: this.textarea.value },
              bubbles: true,
              composed: true,
            })
          );
        });

        this.textarea.addEventListener("scroll", () => {
          this.gutter.scrollTop = this.textarea.scrollTop;
        });

        this.textarea.addEventListener("click", () => this.updateGutterAndStatus());
        this.textarea.addEventListener("keyup", () => this.updateGutterAndStatus());

        this.textarea.addEventListener("keydown", (e: KeyboardEvent) => {
          if (e.altKey && e.key.toLowerCase() === "f") {
            e.preventDefault();
            this.acceptSuggestion("full");
          } else if (e.altKey && e.key.toLowerCase() === "w") {
            e.preventDefault();
            this.acceptSuggestion("word");
          } else if (e.altKey && e.key.toLowerCase() === "e") {
            e.preventDefault();
            this.cycleSuggestion();
          } else if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "s") {
            e.preventDefault();
            this.dispatchEvent(
              new CustomEvent("code-save", {
                detail: { code: this.textarea.value },
                bubbles: true,
                composed: true,
              })
            );
          }
        });

        this.root.getElementById("btn-accept")?.addEventListener("click", () => this.acceptSuggestion("full"));
        this.root.getElementById("btn-word")?.addEventListener("click", () => this.acceptSuggestion("word"));
        this.root.getElementById("btn-line")?.addEventListener("click", () => this.acceptSuggestion("line"));
        this.root.getElementById("btn-cycle")?.addEventListener("click", () => this.cycleSuggestion());
      }

      attributeChangedCallback(name: string, oldVal: string | null, newVal: string | null) {
        if (oldVal === newVal || !this.textarea) return;
        if (name === "code" && newVal !== null && this.textarea.value !== newVal) {
          this.textarea.value = newVal;
          this.updateGutterAndStatus();
        } else if (name === "language" || name === "filepath") {
          this.updateGutterAndStatus();
          this.updateGhostSuggestion();
        }
      }

      private getSuggestions(): string[] {
        const lang = (this.getAttribute("language") || "lua").toLowerCase();
        return NEOCODEIUM_SUGGESTIONS[lang] || NEOCODEIUM_SUGGESTIONS.default;
      }

      private updateGhostSuggestion() {
        if (!this.ghostText) return;
        const list = this.getSuggestions();
        const current = list[this.suggestionIdx % list.length];
        this.ghostText.textContent = `  ↳ ${current}`;
      }

      private cycleSuggestion() {
        const list = this.getSuggestions();
        this.suggestionIdx = (this.suggestionIdx + 1) % list.length;
        this.updateGhostSuggestion();
        this.updateGutterAndStatus();
      }

      private acceptSuggestion(kind: "full" | "word" | "line") {
        const list = this.getSuggestions();
        const raw = list[this.suggestionIdx % list.length] || "";
        const toInsert =
          kind === "word"
            ? raw.split(/\s+/)[0] + " "
            : kind === "line"
            ? raw.split("\n")[0]
            : raw;
        const pos = this.textarea.selectionStart || this.textarea.value.length;
        const before = this.textarea.value.slice(0, pos);
        const after = this.textarea.value.slice(pos);
        const sep = before.endsWith("\n") || before === "" ? "" : "\n";
        this.textarea.value = `${before}${sep}${toInsert}${after}`;
        this.updateGutterAndStatus();
        this.dispatchEvent(
          new CustomEvent("code-change", {
            detail: { code: this.textarea.value },
            bubbles: true,
            composed: true,
          })
        );
      }

      private updateGutterAndStatus() {
        if (!this.textarea || !this.gutter) return;
        const lines = (this.textarea.value || "").split("\n");
        const count = Math.max(1, lines.length);
        const nums: string[] = [];
        for (let i = 1; i <= count; i++) {
          nums.push(String(i));
        }
        this.gutter.textContent = nums.join("\n");

        const filepath = this.getAttribute("filepath") || "lua/kaeru/spec.lua";
        const lang = (this.getAttribute("language") || "lua").toUpperCase();
        const upto = this.textarea.value.slice(0, this.textarea.selectionStart || 0).split("\n");
        const ln = upto.length;
        const col = (upto[upto.length - 1] || "").length + 1;
        const list = this.getSuggestions();
        if (this.statusLeft) {
          this.statusLeft.innerHTML = `<span class="mode-pill">WEB-COMPONENT</span> ${filepath} (${count} lines)`;
        }
        if (this.statusRight) {
          this.statusRight.textContent = `NeoCodeium [${(this.suggestionIdx % list.length) + 1}/${list.length}] · ${lang} · Ln ${ln}, Col ${col}`;
        }
      }
    }
    window.customElements.define("starsky-code-editor", StarskyCodeEditorElement);
  }

  // 2. <starsky-ascii-boot> Web Component
  if (!window.customElements.get("starsky-ascii-boot")) {
    class StarskyAsciiBootElement extends HTMLElement {
      private root: ShadowRoot;
      private timer: ReturnType<typeof setInterval> | null = null;
      private step = 0;

      constructor() {
        super();
        this.root = this.attachShadow({ mode: "open" });
      }

      connectedCallback() {
        this.step = 0;
        this.renderFrame();
        this.timer = setInterval(() => {
          this.step++;
          this.renderFrame();
          if (this.step > BOOT_STEPS.length + 1) {
            if (this.timer) clearInterval(this.timer);
          }
        }, 160);
      }

      disconnectedCallback() {
        if (this.timer) clearInterval(this.timer);
      }

      private renderFrame() {
        const pct = Math.min(100, Math.round((this.step / BOOT_STEPS.length) * 100));
        const barWidth = 42;
        const filled = Math.round((pct / 100) * barWidth);
        const bar = "█".repeat(filled) + "░".repeat(Math.max(0, barWidth - filled));

        const stepRows = BOOT_STEPS.map((line, i) => {
          if (i < this.step) {
            return `<div class="step done">  [✓] ${line}</div>`;
          }
          if (i === this.step) {
            return `<div class="step active">  [⟳] ${line}</div>`;
          }
          return `<div class="step pending">  [·] ${line}</div>`;
        }).join("");

        this.root.innerHTML = `
          <style>
            :host {
              display: block;
              background: #060911;
              border: 1px solid #304269;
              border-radius: 11px;
              padding: 18px 22px;
              font-family: "JetBrains Mono", "Fira Code", monospace;
              color: #58a6ff;
              box-shadow: 0 18px 48px rgba(0, 0, 0, 0.75);
            }
            pre.logo {
              margin: 0 0 10px 0;
              font-size: 11px;
              line-height: 1.22;
              color: #79c0ff;
              text-shadow: 0 0 12px rgba(88, 166, 255, 0.45);
              overflow-x: auto;
            }
            .subtitle {
              color: #bc8cff;
              font-size: 11.5px;
              font-weight: 700;
              margin-bottom: 10px;
            }
            .progress {
              color: #3fb950;
              font-size: 12px;
              margin-bottom: 10px;
            }
            .step {
              font-size: 11.5px;
              line-height: 1.55;
            }
            .step.done { color: #3fb950; }
            .step.active { color: #d29922; font-weight: 700; }
            .step.pending { color: #48546e; }
          </style>
          <pre class="logo">${ASCII_LOGO_LINES.join("\n")}</pre>
          <div class="subtitle">★ STARSKY OS · INSTALLER.NVIM · NEOCODEIUM (:CLINA) · MASON-REGISTRY.DEV · :MUSICPLAYER ★</div>
          <div class="progress">BOOTING SUBSYSTEMS [${bar}] ${pct}%</div>
          <div>${stepRows}</div>
        `;
      }
    }
    window.customElements.define("starsky-ascii-boot", StarskyAsciiBootElement);
  }

  // 3. <starsky-eq-visualizer> Web Component
  if (!window.customElements.get("starsky-eq-visualizer")) {
    class StarskyEqVisualizerElement extends HTMLElement {
      static observedAttributes = ["playing", "mode", "bands", "volume"];
      private root: ShadowRoot;
      private canvas!: HTMLCanvasElement;
      private rafId = 0;
      private tick = 0;

      constructor() {
        super();
        this.root = this.attachShadow({ mode: "open" });
        this.root.innerHTML = `
          <style>
            :host {
              display: block;
              width: 100%;
              background: #070a12;
              border: 1px solid #26314d;
              border-radius: 8px;
              overflow: hidden;
            }
            canvas {
              width: 100%;
              height: 116px;
              display: block;
            }
          </style>
          <canvas width="640" height="116"></canvas>
        `;
      }

      connectedCallback() {
        this.canvas = this.root.querySelector("canvas") as HTMLCanvasElement;
        const loop = () => {
          this.tick++;
          this.draw();
          this.rafId = requestAnimationFrame(loop);
        };
        this.rafId = requestAnimationFrame(loop);
      }

      disconnectedCallback() {
        cancelAnimationFrame(this.rafId);
      }

      private draw() {
        if (!this.canvas) return;
        const ctx = this.canvas.getContext("2d");
        if (!ctx) return;
        const w = this.canvas.width;
        const h = this.canvas.height;
        ctx.fillStyle = "#070a12";
        ctx.fillRect(0, 0, w, h);

        const playing = this.getAttribute("playing") !== "false";
        const mode = this.getAttribute("mode") || "spectrum";
        const vol = Number(this.getAttribute("volume") || 78) / 100;
        let bands = [4, 5, 3, 1, -1, -2, -4, -5, -6, -7];
        try {
          const parsed = JSON.parse(this.getAttribute("bands") || "[]");
          if (Array.isArray(parsed) && parsed.length === 10) bands = parsed;
        } catch {
          // use default
        }

        if (mode === "wave") {
          ctx.strokeStyle = "#58a6ff";
          ctx.lineWidth = 2.2;
          ctx.beginPath();
          for (let x = 0; x < w; x += 4) {
            const amp = playing
              ? (Math.sin(x * 0.03 + this.tick * 0.12) * 28 +
                  Math.cos(x * 0.07 - this.tick * 0.08) * 14) *
                vol
              : 2;
            const y = h / 2 + amp;
            if (x === 0) ctx.moveTo(x, y);
            else ctx.lineTo(x, y);
          }
          ctx.stroke();
          return;
        }

        const barCount = 36;
        const barW = (w - 24) / barCount;
        for (let i = 0; i < barCount; i++) {
          const eqIdx = Math.min(9, Math.floor((i / barCount) * 10));
          const eqBoost = (bands[eqIdx] || 0) / 12;
          const energy = playing
            ? Math.max(
                0.08,
                Math.min(
                  1,
                  (0.45 +
                    0.32 * Math.sin(this.tick * 0.11 + i * 0.45) +
                    0.2 * Math.cos(this.tick * 0.17 - i * 0.25) +
                    eqBoost * 0.28) *
                    vol
                )
              )
            : 0.07;
          const barH = energy * (h - 22);
          const x = 12 + i * barW;
          const y = h - 8 - barH;
          const grad = ctx.createLinearGradient(x, y, x, h - 8);
          grad.addColorStop(0, "#bc8cff");
          grad.addColorStop(0.5, "#58a6ff");
          grad.addColorStop(1, "#3fb950");
          ctx.fillStyle = grad;
          ctx.fillRect(x, y, barW - 3, barH);
        }
      }
    }
    window.customElements.define("starsky-eq-visualizer", StarskyEqVisualizerElement);
  }

  // 4. <starsky-terminal> Web Component
  if (!window.customElements.get("starsky-terminal")) {
    class StarskyTerminalElement extends HTMLElement {
      private root: ShadowRoot;
      private outputEl!: HTMLDivElement;
      private inputEl!: HTMLInputElement;

      constructor() {
        super();
        this.root = this.attachShadow({ mode: "open" });
        this.root.innerHTML = `
          <style>
            :host {
              display: flex;
              flex-direction: column;
              background: #060810;
              border: 1px solid #26314d;
              border-radius: 8px;
              font-family: "JetBrains Mono", "Fira Code", monospace;
              font-size: 11.5px;
              color: #e6edf3;
              overflow: hidden;
            }
            .term-out {
              padding: 8px 12px;
              max-height: 115px;
              overflow-y: auto;
              white-space: pre-wrap;
              color: #9ba7b8;
              line-height: 1.45;
            }
            .term-in-row {
              display: flex;
              align-items: center;
              border-top: 1px solid #1d2740;
              padding: 5px 10px;
              background: #0b0f1c;
            }
            .prompt-char {
              color: #3fb950;
              font-weight: 700;
              margin-right: 6px;
            }
            input {
              flex: 1;
              background: transparent;
              border: none;
              color: #e6edf3;
              font-family: inherit;
              font-size: 11.5px;
              outline: none;
            }
          </style>
          <div class="term-out" id="term-out">[Starsky Neovim Ex-Command Terminal · Custom Web Component &lt;starsky-terminal&gt;]
Type :Kaeru, :Clina, :NeoCodeium auth, :Kikru server, or :Mason and press Enter.</div>
          <div class="term-in-row">
            <span class="prompt-char">:</span>
            <input id="term-in" placeholder="Clina status | Kikru server 41999 | Kaeru save folke/noice.nvim" />
          </div>
        `;
      }

      connectedCallback() {
        this.outputEl = this.root.getElementById("term-out") as HTMLDivElement;
        this.inputEl = this.root.getElementById("term-in") as HTMLInputElement;
        this.inputEl.addEventListener("keydown", (e: KeyboardEvent) => {
          if (e.key === "Enter") {
            const raw = this.inputEl.value.trim().replace(/^:/, "");
            if (!raw) return;
            this.inputEl.value = "";
            this.appendLine(`:${raw}`);
            this.dispatchEvent(
              new CustomEvent("ex-command", {
                detail: { command: raw },
                bubbles: true,
                composed: true,
              })
            );
          }
        });
      }

      public appendLine(text: string) {
        if (!this.outputEl) return;
        this.outputEl.textContent += `\n${text}`;
        this.outputEl.scrollTop = this.outputEl.scrollHeight;
      }
    }
    window.customElements.define("starsky-terminal", StarskyTerminalElement);
  }
}
