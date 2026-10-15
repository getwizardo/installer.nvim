"use client";

import React, { useState, useEffect, useCallback, useRef } from "react";
import { registerStarskyWebComponents } from "@/components/webComponents";
import {
  Drawer,
  DrawerTrigger,
  DrawerContent,
  DrawerHeader,
  DrawerTitle,
  DrawerDescription,
  DrawerClose,
} from "@/components/ui/drawer";
import { Button, Badge } from "@/components/ui/shadcn";

type TabId = "ide" | "music" | "spec" | "parser" | "mason" | "sftp" | "github";

interface SpecForm {
  repo: string;
  name: string;
  branch: string;
  tag: string;
  commit: string;
  version: string;
  pin: string;
  lazy: string;
  priority: string;
  event: string;
  cmd: string;
  ft: string;
  keys: string;
  dependencies: string;
  build: string;
  opts: string;
  config: string;
  init: string;
  cond: string;
  enabled: string;
}

interface CompletionItem {
  word: string;
  kind: string;
  menu: string;
}

interface ParsedSnippet {
  repo: string;
  manager: string;
  spec: SpecForm;
  lua: string;
}

interface MasonPackage {
  name: string;
  description: string;
  categories: string[];
  languages: string[];
  homepage: string;
  licenses: string[];
  source_id: string;
  bin: string[];
  lspconfig: string | null;
}

interface SavedSpecFile {
  filename: string;
  path: string;
  size: number;
  updatedAt: string;
  content: string;
}

interface ClinaFileNode {
  name: string;
  path: string;
  relativePath: string;
  type: "file" | "dir";
  size: number;
  language: string;
}

interface ClinaCodeProposal {
  path: string;
  relativePath: string;
  language: string;
  originalCode: string;
  code: string;
  diff: string;
  description: string;
}

interface ClinaAgentStep {
  tool: string;
  action: string;
  status: "done" | "running";
  detail: string;
}

interface ClinaChatTurn {
  role: "user" | "assistant";
  mode: string;
  provider: string;
  model: string;
  text: string;
  steps?: ClinaAgentStep[];
  proposal?: ClinaCodeProposal;
  specForm?: Partial<SpecForm>;
  timestamp: string;
}

interface MusicStation {
  id: string;
  title: string;
  artist: string;
  genre: string;
  service: string;
  url: string;
  bitrate: string;
}

interface NeovimMusicDevice {
  id: string;
  name: string;
  role: "server" | "client";
  addr: string;
  pid: number;
  connectedAt: string;
  active: boolean;
}

interface MusicState {
  playing: boolean;
  stationIdx: number;
  serviceId: string;
  volume: number;
  eqPreset: string;
  eqBands: number[];
  visualizer: "spectrum" | "wave" | "vu" | "matrix" | "starfield";
  role: "server" | "client";
  port: number;
  devices: NeovimMusicDevice[];
  rpcLog: string[];
}

interface SftpServerProfile {
  name: string;
  host: string;
  port: number;
  user: string;
  remote_path: string;
  local_path: string;
  key: string;
  sync_on_save: boolean;
  exclude: string[];
}

interface SftpEntry {
  name: string;
  path: string;
  type: "file" | "dir";
  size: number;
  mtime: string;
  permissions: string;
}

interface SftpTransferLog {
  id: string;
  timestamp: string;
  direction: "upload" | "download" | "sync" | "exec" | "mkdir" | "rm";
  localPath: string;
  remotePath: string;
  status: "ok" | "simulated" | "error";
  message: string;
}

const DEFAULT_FORM: SpecForm = {
  repo: "monkoose/neocodeium",
  name: "",
  branch: "",
  tag: "",
  commit: "",
  version: "",
  pin: "false",
  lazy: "true",
  priority: "",
  event: "VeryLazy",
  cmd: "NeoCodeium",
  ft: "",
  keys: "<A-f>:Accept NeoCodeium,<A-w>:Accept Word,<A-e>:Cycle Completion",
  dependencies: "",
  build: "",
  opts: "manual = false, show_label = true, debounce = false",
  config: "",
  init: "",
  cond: "",
  enabled: "true",
};

const SAMPLE_SNIPPETS: Record<string, { label: string; snippet: string }> = {
  neocodeium: {
    label: "NeoCodeium (:Clina)",
    snippet: `-- NeoCodeium (:Clina primary AI engine)
{
  "monkoose/neocodeium",
  event = "VeryLazy",
  config = function()
    local neocodeium = require("neocodeium")
    neocodeium.setup()
    vim.keymap.set("i", "<A-f>", neocodeium.accept)
  end,
}`,
  },
  lazy: {
    label: "lazy.nvim",
    snippet: `{
  "nvim-telescope/telescope.nvim",
  tag = "0.1.8",
  cmd = "Telescope",
  dependencies = { "nvim-lua/plenary.nvim" },
  opts = { defaults = { layout_strategy = "horizontal" } },
}`,
  },
  packer: {
    label: "packer.nvim",
    snippet: `use {
  'nvim-treesitter/nvim-treesitter',
  run = ':TSUpdate',
  event = 'BufReadPost',
  requires = { 'nvim-treesitter/nvim-treesitter-textobjects' }
}`,
  },
  vimplug: {
    label: "vim-plug",
    snippet: `Plug 'junegunn/fzf', { 'do': { -> fzf#install() } }
Plug 'junegunn/fzf.vim', { 'on': ['Files', 'Rg', 'Commits'] }`,
  },
  vimpack: {
    label: "vim.pack (0.12)",
    snippet: `vim.pack.add({
  { src = "https://github.com/neovim/nvim-lspconfig", version = "v1.0.0" },
  "https://github.com/mason-org/mason.nvim",
})`,
  },
  mini: {
    label: "mini.deps",
    snippet: `MiniDeps.add({
  source = "echasnovski/mini.pick",
  depends = { "echasnovski/mini.icons" },
  checkout = "main",
})`,
  },
};

const FORM_FIELDS: {
  key: keyof SpecForm;
  label: string;
  placeholder: string;
  multiline?: boolean;
}[] = [
  {
    key: "repo",
    label: "Repository (Live GitHub API Autocomplete)",
    placeholder: "owner/repo (e.g. monkoose/neocodeium)",
  },
  { key: "name", label: "Custom Name", placeholder: "optional plugin alias" },
  {
    key: "event",
    label: "Lazy Events (event)",
    placeholder: "VeryLazy, BufReadPost, LspAttach",
  },
  {
    key: "cmd",
    label: "User Commands (cmd)",
    placeholder: "NeoCodeium, Clina, Kikru",
  },
  {
    key: "ft",
    label: "Filetypes (ft)",
    placeholder: "lua, typescript, python, rust",
  },
  {
    key: "keys",
    label: "Keymaps (keys)",
    placeholder: "<A-f>:Accept NeoCodeium,<leader>ff:Find files",
  },
  {
    key: "dependencies",
    label: "Dependencies (Live GitHub API Autocomplete)",
    placeholder: "nvim-lua/plenary.nvim, MunifTanjim/nui.nvim",
  },
  {
    key: "build",
    label: "Build Hook (build)",
    placeholder: ":TSUpdate, make, npm install",
  },
  { key: "branch", label: "Git Branch", placeholder: "main, master, v2" },
  { key: "tag", label: "Git Tag", placeholder: "v1.4.0, *" },
  { key: "version", label: "Semver Version", placeholder: "^1.0.0, *" },
  { key: "lazy", label: "Lazy Load (lazy)", placeholder: "true / false" },
  { key: "priority", label: "Priority", placeholder: "1000, 500, 50" },
  { key: "pin", label: "Pin Version (pin)", placeholder: "true / false" },
  { key: "enabled", label: "Enabled", placeholder: "true / false" },
  {
    key: "opts",
    label: "Plugin Options (opts)",
    placeholder: "key = value or { ... }",
    multiline: true,
  },
  {
    key: "config",
    label: "Config Body (config = function(_, opts) ... end)",
    placeholder: 'require("neocodeium").setup(opts)',
    multiline: true,
  },
];

export default function StarskyCodeIdePage() {
  const [activeTab, setActiveTab] = useState<TabId>("ide");
  const [showAsciiBoot, setShowAsciiBoot] = useState<boolean>(false);

  // Register W3C Custom Elements (<starsky-code-editor>, <starsky-ascii-boot>, <starsky-eq-visualizer>, <starsky-terminal>)
  useEffect(() => {
    registerStarskyWebComponents();
  }, []);

  // --- Spec Builder & Disk Saver State ---
  const [form, setForm] = useState<SpecForm>(DEFAULT_FORM);
  const [generatedLua, setGeneratedLua] = useState<string>("");
  const [specError, setSpecError] = useState<string | null>(null);
  const [activeField, setActiveField] = useState<keyof SpecForm>("repo");
  const [completions, setCompletions] = useState<CompletionItem[]>([]);
  const [completionSource, setCompletionSource] = useState<string>("github+local");
  const [copied, setCopied] = useState<boolean>(false);
  const [savedSpecs, setSavedSpecs] = useState<SavedSpecFile[]>([]);
  const [saveBanner, setSaveBanner] = useState<string | null>(null);
  const [savingSpec, setSavingSpec] = useState<boolean>(false);

  // --- Code IDE & :Clina (NeoCodeium) State ---
  const [clinaFiles, setClinaFiles] = useState<ClinaFileNode[]>([]);
  const [openTabs, setOpenTabs] = useState<string[]>([
    "lua/kaeru/clina.lua",
    "lua/kaeru/kikru.lua",
    "lua/kaeru/complete.lua",
  ]);
  const [clinaActiveFile, setClinaActiveFile] = useState<string>(
    "lua/kaeru/clina.lua"
  );
  const [clinaFileContent, setClinaFileContent] = useState<string>("");
  const [clinaFileLang, setClinaFileLang] = useState<string>("lua");
  const [clinaPrompt, setClinaPrompt] = useState<string>(
    "Configure monkoose/neocodeium with <A-f> accept and <A-e> cycle"
  );
  const [clinaRunning, setClinaRunning] = useState<boolean>(false);
  const [clinaHistory, setClinaHistory] = useState<ClinaChatTurn[]>([]);
  const [clinaBanner, setClinaBanner] = useState<string | null>(null);
  const codeEditorRef = useRef<HTMLElement | null>(null);
  const terminalRef = useRef<HTMLElement | null>(null);

  // --- :Kikru State ---
  const [musicState, setMusicState] = useState<MusicState | null>(null);
  const [musicStation, setMusicStation] = useState<MusicStation | null>(null);
  const [musicStations, setMusicStations] = useState<MusicStation[]>([]);
  const [musicServices, setMusicServices] = useState<
    { id: string; name: string; status: string; desc: string }[]
  >([]);
  const [eqFrequencies, setEqFrequencies] = useState<string[]>([
    "31Hz",
    "62Hz",
    "125Hz",
    "250Hz",
    "500Hz",
    "1kHz",
    "2kHz",
    "4kHz",
    "8kHz",
    "16kHz",
  ]);
  const [eqPresets, setEqPresets] = useState<Record<string, number[]>>({});
  const [pairClientName, setPairClientName] = useState<string>(
    "Neovim Instance #3 (:Kikru connect 127.0.0.1:41999)"
  );
  const audioRef = useRef<HTMLAudioElement | null>(null);

  // --- Universal Parser State ---
  const [rawSnippet, setRawSnippet] = useState<string>(
    SAMPLE_SNIPPETS.neocodeium.snippet
  );
  const [parsedResults, setParsedResults] = useState<ParsedSnippet[]>([]);
  const [readmeRepoInput, setReadmeRepoInput] = useState<string>(
    "monkoose/neocodeium"
  );
  const [loadingReadme, setLoadingReadme] = useState<boolean>(false);

  // --- https://mason-registry.dev/ Explorer State ---
  const [masonPackages, setMasonPackages] = useState<MasonPackage[]>([]);
  const [masonTotal, setMasonTotal] = useState<number>(601);
  const [masonCategories, setMasonCategories] = useState<Record<string, number>>({});
  const [masonQuery, setMasonQuery] = useState<string>("");
  const [masonCategory, setMasonCategory] = useState<string>("ALL");
  const [masonLanguage, setMasonLanguage] = useState<string>("");
  const [selectedMason, setSelectedMason] = useState<string[]>([
    "lua_ls",
    "ts_ls",
    "pyright",
    "rust_analyzer",
  ]);
  const [masonPreviewPkg, setMasonPreviewPkg] = useState<MasonPackage | null>(null);

  // --- SFTP Studio State ---
  const [sftpServers, setSftpServers] = useState<SftpServerProfile[]>([]);
  const [sftpActiveIdx, setSftpActiveIdx] = useState<number>(0);
  const [sftpLocalDir, setSftpLocalDir] = useState<string>("");
  const [sftpRemoteDir, setSftpRemoteDir] = useState<string>("/var/www/app");
  const [sftpLocalEntries, setSftpLocalEntries] = useState<SftpEntry[]>([]);
  const [sftpRemoteEntries, setSftpRemoteEntries] = useState<SftpEntry[]>([]);
  const [sftpLogs, setSftpLogs] = useState<SftpTransferLog[]>([]);
  const [sftpCmdInput, setSftpCmdInput] = useState<string>("ls -la /var/www/app");
  const [sftpCmdOutput, setSftpCmdOutput] = useState<string>("");
  const [sftpBanner, setSftpBanner] = useState<string | null>(null);

  // --- GitHub Live Search State ---
  const [ghQuery, setGhQuery] = useState<string>("neovim neocodeium");
  const [ghResults, setGhResults] = useState<
    {
      full_name: string;
      description: string;
      stargazers_count: number;
      html_url: string;
      topics?: string[];
    }[]
  >([]);
  const [ghLoading, setGhLoading] = useState<boolean>(false);

  // 1. Live Spec Generation + Disk Saved Specs
  const fetchSavedSpecs = useCallback(async () => {
    try {
      const res = await fetch("/api/spec/save");
      const data = await res.json();
      if (data.ok && data.files) setSavedSpecs(data.files);
    } catch {
      // ignore
    }
  }, []);

  useEffect(() => {
    const timer = setTimeout(async () => {
      try {
        const res = await fetch("/api/spec/generate", {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify(form),
        });
        const data = await res.json();
        if (data.ok) {
          setGeneratedLua(data.lua);
          setSpecError(null);
        } else {
          setSpecError(data.error || "Invalid specification");
        }
      } catch (err) {
        setSpecError(String(err));
      }
    }, 100);
    return () => clearTimeout(timer);
  }, [form]);

  useEffect(() => {
    fetchSavedSpecs();
  }, [fetchSavedSpecs]);

  const handleSaveSpecToDisk = async (targetForm?: Partial<SpecForm>) => {
    const payloadForm = targetForm ? { ...DEFAULT_FORM, ...targetForm } : form;
    setSavingSpec(true);
    setSaveBanner(null);
    try {
      const res = await fetch("/api/spec/save", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ form: payloadForm, force: true }),
      });
      const data = await res.json();
      if (data.ok) {
        setSaveBanner(`✓ Saved ${data.filename} to ${data.path}`);
        fetchSavedSpecs();
      } else {
        setSaveBanner(`✗ Error: ${data.error}`);
      }
    } catch (err) {
      setSaveBanner(`✗ Error: ${String(err)}`);
    } finally {
      setSavingSpec(false);
    }
  };

  // 2. Live GitHub API Autocomplete + Local Lua Bridge Completion
  const fetchCompletions = useCallback(
    async (field: keyof SpecForm, currentValue: string) => {
      const lastToken =
        field === "repo"
          ? currentValue.trim()
          : (currentValue.split(",").pop() || "").trim();
      try {
        const res = await fetch(
          `/api/complete?field=${encodeURIComponent(
            field
          )}&prefix=${encodeURIComponent(lastToken)}`
        );
        const data = await res.json();
        if (data.ok) {
          setCompletions(data.items || []);
          setCompletionSource(data.source || "github+local");
        }
      } catch {
        setCompletions([]);
      }
    },
    []
  );

  useEffect(() => {
    const timer = setTimeout(() => {
      fetchCompletions(activeField, form[activeField] || "");
    }, 180);
    return () => clearTimeout(timer);
  }, [activeField, form, fetchCompletions]);

  const applyCompletion = (word: string) => {
    const current = form[activeField] || "";
    if (
      activeField === "repo" ||
      activeField === "lazy" ||
      activeField === "pin" ||
      activeField === "enabled" ||
      activeField === "priority" ||
      activeField === "branch"
    ) {
      setForm((prev) => ({ ...prev, [activeField]: word }));
    } else {
      const parts = current
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean);
      if (
        parts.length > 0 &&
        !current.trim().endsWith(",") &&
        word.toLowerCase().startsWith(parts[parts.length - 1].toLowerCase())
      ) {
        parts[parts.length - 1] = word;
      } else if (!parts.includes(word)) {
        parts.push(word);
      }
      setForm((prev) => ({ ...prev, [activeField]: parts.join(", ") }));
    }
  };

  // 3. Code IDE File Explorer & Web Component Event Wiring
  const loadClinaFile = useCallback(async (relPath: string) => {
    try {
      const res = await fetch(`/api/clina?file=${encodeURIComponent(relPath)}`);
      const data = await res.json();
      if (data.ok && data.file) {
        setClinaActiveFile(relPath);
        setClinaFileContent(data.file.content);
        setClinaFileLang(data.file.language || "lua");
        setOpenTabs((prev) => (prev.includes(relPath) ? prev : [...prev, relPath]));
      }
    } catch {
      // ignore
    }
  }, []);

  useEffect(() => {
    fetch("/api/clina")
      .then((r) => r.json())
      .then((data) => {
        if (data.ok) {
          setClinaFiles(data.files || []);
        }
      })
      .catch(() => {});
    loadClinaFile("lua/kaeru/clina.lua");
  }, [loadClinaFile]);

  const saveActiveCodeFile = useCallback(
    async (overrideCode?: string) => {
      const contentToSave = overrideCode !== undefined ? overrideCode : clinaFileContent;
      try {
        const res = await fetch("/api/clina", {
          method: "PUT",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            path: clinaActiveFile,
            content: contentToSave,
          }),
        });
        const data = await res.json();
        if (data.ok) {
          setClinaBanner(`✓ Saved ${data.path} (${data.bytes} bytes)`);
        }
      } catch (err) {
        setClinaBanner(`✗ Error: ${String(err)}`);
      }
    },
    [clinaActiveFile, clinaFileContent]
  );

  // Wire Custom DOM Events from <starsky-code-editor> and <starsky-terminal>
  useEffect(() => {
    const editorEl = codeEditorRef.current;
    if (!editorEl) return;
    const onCodeChange = (e: Event) => {
      const detail = (e as CustomEvent).detail;
      if (detail && typeof detail.code === "string") {
        setClinaFileContent(detail.code);
      }
    };
    const onCodeSave = (e: Event) => {
      const detail = (e as CustomEvent).detail;
      saveActiveCodeFile(detail?.code);
    };
    editorEl.addEventListener("code-change", onCodeChange);
    editorEl.addEventListener("code-save", onCodeSave);
    return () => {
      editorEl.removeEventListener("code-change", onCodeChange);
      editorEl.removeEventListener("code-save", onCodeSave);
    };
  }, [saveActiveCodeFile]);

  useEffect(() => {
    const termEl = terminalRef.current as
      | (HTMLElement & { appendLine?: (msg: string) => void })
      | null;
    if (!termEl) return;
    const onExCommand = async (e: Event) => {
      const cmd = String((e as CustomEvent).detail?.command || "").trim();
      if (!cmd) return;
      if (cmd.startsWith("Kikru")) {
        const sub = cmd.replace(/^Kikru\s*/, "").trim() || "status";
        await dispatchMusicAction(sub === "play" || sub === "pause" ? "toggle" : sub);
        termEl.appendLine?.(
          `[Kikru] Executed :${cmd} (2-Neovim Server 127.0.0.1:41999)`
        );
      } else if (cmd.startsWith("Clina") || cmd.startsWith("NeoCodeium")) {
        termEl.appendLine?.(
          `[:Clina NeoCodeium] monkoose/neocodeium active · Windsurf ghost-text engine ready`
        );
      } else if (cmd.startsWith("Kaeru save")) {
        const repo = cmd.replace(/^Kaeru\s+save\s+/, "").trim();
        if (repo) {
          await handleSaveSpecToDisk({ repo });
          termEl.appendLine?.(`[Kaeru] Saved spec for ${repo} to lua/plugins/`);
        }
      } else {
        termEl.appendLine?.(`[Starsky Neovim] Executed :${cmd}`);
      }
    };
    termEl.addEventListener("ex-command", onExCommand);
    return () => termEl.removeEventListener("ex-command", onExCommand);
  });

  const handleRunClina = async (promptOverride?: string) => {
    const promptText = (promptOverride ?? clinaPrompt).trim();
    if (!promptText) return;
    setClinaRunning(true);
    setClinaHistory((prev) => [
      ...prev,
      {
        role: "user",
        mode: "neocodeium",
        provider: "monkoose/neocodeium",
        model: "windsurf-neocodeium",
        text: promptText,
        timestamp: new Date().toLocaleTimeString(),
      },
    ]);
    try {
      const res = await fetch("/api/clina", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          prompt: promptText,
          mode: "agent",
          provider: "neocodeium",
          active_file: clinaActiveFile,
          active_content: clinaFileContent,
        }),
      });
      const data = await res.json();
      if (data.ok) {
        setClinaHistory((prev) => [
          ...prev,
          {
            role: "assistant",
            mode: data.mode,
            provider: "monkoose/neocodeium",
            model: "windsurf-neocodeium",
            text: data.reply,
            steps: data.steps,
            proposal: data.proposal,
            specForm: data.specForm,
            timestamp: new Date().toLocaleTimeString(),
          },
        ]);
      }
    } finally {
      setClinaRunning(false);
    }
  };

  // 4. :Kikru API + Live Audio Stream
  const fetchMusicState = useCallback(async () => {
    try {
      const res = await fetch("/api/music");
      const data = await res.json();
      if (data.ok) {
        setMusicState(data.state);
        setMusicStation(data.station);
        setMusicStations(data.stations || []);
        setMusicServices(data.services || []);
        setEqFrequencies(data.eqFrequencies || []);
        setEqPresets(data.eqPresets || {});
      }
    } catch {
      // ignore
    }
  }, []);

  useEffect(() => {
    fetchMusicState();
  }, [fetchMusicState]);

  const dispatchMusicAction = async (
    action: string,
    payload: Record<string, unknown> = {}
  ) => {
    try {
      const res = await fetch("/api/music", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ action, ...payload }),
      });
      const data = await res.json();
      if (data.ok) {
        setMusicState(data.state);
        setMusicStation(data.station);
      }
    } catch {
      // ignore
    }
  };

  // 5. Universal Parser
  const handleParseSnippet = useCallback(async (text: string) => {
    if (!text.trim()) {
      setParsedResults([]);
      return;
    }
    try {
      const res = await fetch("/api/parse", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ content: text }),
      });
      const data = await res.json();
      if (data.ok) setParsedResults(data.results || []);
    } catch {
      // ignore
    }
  }, []);

  useEffect(() => {
    if (activeTab === "parser") handleParseSnippet(rawSnippet);
  }, [activeTab, rawSnippet, handleParseSnippet]);

  const handleFetchGithubReadme = async () => {
    if (!readmeRepoInput.trim()) return;
    setLoadingReadme(true);
    try {
      const res = await fetch(
        `/api/github?action=readme&repo=${encodeURIComponent(
          readmeRepoInput.trim()
        )}`
      );
      const data = await res.json();
      if (data.ok && data.readme) {
        setRawSnippet(data.readme);
        handleParseSnippet(data.readme);
      }
    } finally {
      setLoadingReadme(false);
    }
  };

  // 6. https://mason-registry.dev/ Explorer
  useEffect(() => {
    const timer = setTimeout(async () => {
      const params = new URLSearchParams();
      if (masonQuery) params.set("q", masonQuery);
      if (masonCategory && masonCategory !== "ALL")
        params.set("category", masonCategory);
      if (masonLanguage) params.set("lang", masonLanguage);
      params.set("limit", "150");
      try {
        const res = await fetch(`/api/mason?${params.toString()}`);
        const data = await res.json();
        if (data.ok) {
          setMasonPackages(data.packages || []);
          setMasonTotal(data.total || 601);
          setMasonCategories(data.categories || {});
        }
      } catch {
        // ignore
      }
    }, 120);
    return () => clearTimeout(timer);
  }, [masonQuery, masonCategory, masonLanguage]);

  // 7. SFTP Studio
  const loadSftpState = useCallback(
    async (localDir?: string, remoteDir?: string, serverIdx?: number) => {
      const params = new URLSearchParams();
      if (localDir) params.set("localDir", localDir);
      if (remoteDir) params.set("remoteDir", remoteDir);
      if (serverIdx !== undefined) params.set("serverIndex", String(serverIdx));
      try {
        const res = await fetch(`/api/sftp?${params.toString()}`);
        const data = await res.json();
        if (data.ok) {
          setSftpServers(data.servers || []);
          setSftpActiveIdx(data.activeIndex || 0);
          setSftpLocalDir(data.localDir || "");
          setSftpRemoteDir(data.remoteDir || "/var/www/app");
          setSftpLocalEntries(data.localEntries || []);
          setSftpRemoteEntries(data.remoteEntries || []);
          setSftpLogs(data.logs || []);
        }
      } catch {
        // ignore
      }
    },
    []
  );

  useEffect(() => {
    if (activeTab === "sftp") loadSftpState();
  }, [activeTab, loadSftpState]);

  const runSftpAction = async (
    action: string,
    payload: Record<string, unknown> = {}
  ) => {
    try {
      const res = await fetch("/api/sftp", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          action,
          serverIndex: sftpActiveIdx,
          remoteDir: sftpRemoteDir,
          ...payload,
        }),
      });
      const data = await res.json();
      if (data.ok) {
        if (data.log) setSftpBanner(`✓ ${data.log.message}`);
        if (data.output) setSftpCmdOutput(data.output);
        loadSftpState(sftpLocalDir, sftpRemoteDir, sftpActiveIdx);
      }
    } catch (err) {
      setSftpBanner(`✗ SFTP Error: ${String(err)}`);
    }
  };

  // 8. GitHub Search
  const handleGithubSearch = useCallback(async (q: string) => {
    if (!q.trim()) return;
    setGhLoading(true);
    try {
      const res = await fetch(
        `/api/github?action=search&q=${encodeURIComponent(q)}`
      );
      const data = await res.json();
      if (data.ok) setGhResults(data.items || []);
    } finally {
      setGhLoading(false);
    }
  }, []);

  useEffect(() => {
    if (activeTab === "github" && ghResults.length === 0) {
      handleGithubSearch(ghQuery);
    }
  }, [activeTab, ghQuery, ghResults.length, handleGithubSearch]);

  const copyToClipboard = (text: string) => {
    navigator.clipboard.writeText(text);
    setCopied(true);
    setTimeout(() => setCopied(false), 1800);
  };

  return (
    <div className="app-shell">
      {/* ASCII Boot Animation Modal (<starsky-ascii-boot> Web Component) */}
      {showAsciiBoot && (
        <div
          className="boot-modal-backdrop"
          onClick={() => setShowAsciiBoot(false)}
        >
          <div
            className="boot-modal-box"
            onClick={(e) => e.stopPropagation()}
          >
            {React.createElement("starsky-ascii-boot", {})}
            <div
              style={{
                display: "flex",
                justifyContent: "space-between",
                marginTop: "0.75rem",
              }}
            >
              <Badge variant="green">
                Custom Element: &lt;starsky-ascii-boot&gt; · :Kaeru boot
              </Badge>
              <Button size="sm" onClick={() => setShowAsciiBoot(false)}>
                Enter Starsky Code IDE →
              </Button>
            </div>
          </div>
        </div>
      )}

      {/* Hidden HTML5 Audio element for live Internet Radio playback */}
      {musicStation && (
        <audio
          ref={audioRef}
          src={musicStation.url}
          preload="none"
          style={{ display: "none" }}
        />
      )}

      {/* Top IDE Header Bar with Vaul Drawer Triggers */}
      <header className="top-bar">
        <div className="brand">
          <div className="brand-badge">★</div>
          <div>
            <div className="brand-title">
              Starsky Code IDE{" "}
              <span style={{ color: "var(--accent)", fontSize: "0.76rem" }}>
                for kaeru.nvim
              </span>
            </div>
            <div className="brand-subtitle">
              Web Components · shadcn/ui + Vaul Drawer · :Clina (NeoCodeium) ·
              :Kikru 2-Nvim RPC · mason-registry.dev
            </div>
          </div>
        </div>

        <nav className="nav-tabs">
          <button
            className={`nav-tab ${activeTab === "ide" ? "active" : ""}`}
            onClick={() => setActiveTab("ide")}
          >
            💻 Code IDE &amp; :Clina
          </button>
          <button
            className={`nav-tab ${activeTab === "music" ? "active" : ""}`}
            onClick={() => setActiveTab("music")}
          >
            🎵 :Kikru (2-Nvim)
          </button>
          <button
            className={`nav-tab ${activeTab === "spec" ? "active" : ""}`}
            onClick={() => setActiveTab("spec")}
          >
            ⚡ Spec Saver &amp; GitHub Complete
          </button>
          <button
            className={`nav-tab ${activeTab === "mason" ? "active" : ""}`}
            onClick={() => setActiveTab("mason")}
          >
            🧱 mason-registry.dev ({masonTotal})
          </button>
          <button
            className={`nav-tab ${activeTab === "sftp" ? "active" : ""}`}
            onClick={() => setActiveTab("sftp")}
          >
            🛰️ SFTP UI
          </button>
          <button
            className={`nav-tab ${activeTab === "parser" ? "active" : ""}`}
            onClick={() => setActiveTab("parser")}
          >
            📄 README Parser
          </button>
          <button
            className={`nav-tab ${activeTab === "github" ? "active" : ""}`}
            onClick={() => setActiveTab("github")}
          >
            🔭 GitHub Search
          </button>
        </nav>

        <div style={{ display: "flex", gap: "0.45rem", alignItems: "center" }}>
          <Button
            size="sm"
            variant="secondary"
            onClick={() => setShowAsciiBoot(true)}
          >
            🚀 ASCII Boot
          </Button>

          {/* Vaul Drawer #1: :Kikru Quick Studio Drawer */}
          <Drawer>
            <DrawerTrigger asChild>
              <Button size="sm" variant="default">
                🎛️ :Kikru Drawer
              </Button>
            </DrawerTrigger>
            <DrawerContent>
              <DrawerHeader>
                <div>
                  <DrawerTitle>
                    🎵 :Kikru · 10-Band EQ, Visualizer, Radio &amp;
                    2-Neovim Controller (Vaul Drawer)
                  </DrawerTitle>
                  <DrawerDescription>
                    Built on shadcn/ui + Vaul Drawer · Custom Web Component
                    &lt;starsky-eq-visualizer&gt; · Server &lt;-&gt; Client TCP
                    RPC
                  </DrawerDescription>
                </div>
                <DrawerClose asChild>
                  <Button size="sm" variant="secondary">
                    Close Drawer
                  </Button>
                </DrawerClose>
              </DrawerHeader>
              <div className="vaul-drawer-body">
                {musicState && musicStation && (
                  <div className="grid-2">
                    <div className="card">
                      <div className="card-header">
                        <span className="card-title">
                          {musicState.playing ? "▶ PLAYING" : "⏸ PAUSED"} ·{" "}
                          {musicStation.title}
                        </span>
                        <Badge variant="green">{musicStation.bitrate}</Badge>
                      </div>
                      <div className="card-body">
                        {React.createElement("starsky-eq-visualizer", {
                          playing: String(musicState.playing),
                          mode: musicState.visualizer,
                          bands: JSON.stringify(musicState.eqBands),
                          volume: String(musicState.volume),
                        })}
                        <div
                          style={{
                            display: "flex",
                            gap: "0.5rem",
                            marginTop: "0.75rem",
                            flexWrap: "wrap",
                          }}
                        >
                          <Button
                            size="sm"
                            onClick={() => dispatchMusicAction("prev")}
                          >
                            ⏮ Prev
                          </Button>
                          <Button
                            size="sm"
                            variant="success"
                            onClick={() => dispatchMusicAction("toggle")}
                          >
                            {musicState.playing ? "⏸ Pause" : "▶ Play"}
                          </Button>
                          <Button
                            size="sm"
                            onClick={() => dispatchMusicAction("next")}
                          >
                            ⏭ Next
                          </Button>
                          <Button
                            size="sm"
                            variant="secondary"
                            onClick={() =>
                              dispatchMusicAction("visualizer", {
                                mode:
                                  musicState.visualizer === "spectrum"
                                    ? "wave"
                                    : "spectrum",
                              })
                            }
                          >
                            📊 Mode: {musicState.visualizer}
                          </Button>
                        </div>
                      </div>
                    </div>

                    <div className="card">
                      <div className="card-header">
                        <span className="card-title">
                          🔗 2-Neovim Device Controller (Server &lt;-&gt; Client)
                        </span>
                        <Badge variant="purple">127.0.0.1:{musicState.port}</Badge>
                      </div>
                      <div className="card-body">
                        {musicState.devices.map((dev) => (
                          <div
                            key={dev.id}
                            className={`device-card ${
                              dev.active ? "active" : ""
                            }`}
                          >
                            <div>
                              <div
                                style={{
                                  fontWeight: 700,
                                  fontSize: "0.8rem",
                                }}
                              >
                                {dev.role === "server" ? "🟢" : "🔵"} {dev.name}
                              </div>
                              <div
                                style={{
                                  fontSize: "0.71rem",
                                  color: "var(--text-secondary)",
                                }}
                              >
                                {dev.addr} · PID {dev.pid}
                              </div>
                            </div>
                            <Button
                              size="sm"
                              variant={dev.active ? "success" : "secondary"}
                              onClick={() =>
                                dispatchMusicAction("handoffDevice", {
                                  deviceId: dev.id,
                                })
                              }
                            >
                              {dev.active ? "Active Output" : "Route Here"}
                            </Button>
                          </div>
                        ))}
                      </div>
                    </div>
                  </div>
                )}
              </div>
            </DrawerContent>
          </Drawer>

          {/* Vaul Drawer #2: Quick :Kaeru Spec Saver Drawer */}
          <Drawer>
            <DrawerTrigger asChild>
              <Button size="sm" variant="secondary">
                ⚡ Quick Spec Drawer
              </Button>
            </DrawerTrigger>
            <DrawerContent>
              <DrawerHeader>
                <div>
                  <DrawerTitle>
                    ⚡ :Kaeru Plugin Spec Builder &amp; Live GitHub API
                    Autocomplete (Vaul Drawer)
                  </DrawerTitle>
                  <DrawerDescription>
                    Type any GitHub owner/repo to trigger live GitHub API
                    autocomplete and save directly to lua/plugins/*.lua
                  </DrawerDescription>
                </div>
                <DrawerClose asChild>
                  <Button size="sm" variant="secondary">
                    Close
                  </Button>
                </DrawerClose>
              </DrawerHeader>
              <div className="vaul-drawer-body">
                <div className="grid-2">
                  <div>
                    <div className="field-group">
                      <label className="field-label">
                        Repository (Live GitHub API Search)
                      </label>
                      <input
                        className="field-input"
                        value={form.repo}
                        onFocus={() => setActiveField("repo")}
                        onChange={(e) =>
                          setForm((p) => ({ ...p, repo: e.target.value }))
                        }
                      />
                    </div>
                    <div className="completion-list">
                      {completions.slice(0, 8).map((item) => (
                        <div
                          key={item.word}
                          className="completion-item"
                          onClick={() => applyCompletion(item.word)}
                        >
                          <span className="completion-word">{item.word}</span>
                          <span className="completion-menu">{item.menu}</span>
                        </div>
                      ))}
                    </div>
                  </div>
                  <div>
                    <pre className="code-block">{generatedLua}</pre>
                    <Button
                      variant="success"
                      onClick={() => handleSaveSpecToDisk()}
                      style={{ marginTop: "0.6rem" }}
                    >
                      💾 Save Spec to lua/plugins/
                    </Button>
                  </div>
                </div>
              </div>
            </DrawerContent>
          </Drawer>
        </div>
      </header>

      <main className="main-area">
        {/* ============================================================
            TAB 1: CODE IDE (Web Components + :Clina NeoCodeium)
           ============================================================ */}
        {activeTab === "ide" && (
          <div className="code-ide-grid">
            {/* Left Sidebar: Workspace File Explorer + NeoCodeium Quick Actions */}
            <div className="card">
              <div className="card-header">
                <span className="card-title">📁 Workspace Explorer</span>
                <Badge>{clinaFiles.length} files</Badge>
              </div>
              <div
                className="card-body"
                style={{
                  padding: "0.45rem",
                  maxHeight: "430px",
                  overflowY: "auto",
                }}
              >
                {clinaFiles.map((f) => (
                  <div
                    key={f.relativePath}
                    className={`clina-file-item ${
                      clinaActiveFile === f.relativePath ? "active" : ""
                    }`}
                    onClick={() => loadClinaFile(f.relativePath)}
                  >
                    <span className="clina-file-icon">
                      {f.language === "lua"
                        ? "🌙"
                        : f.language === "typescript"
                        ? "🔷"
                        : "📄"}
                    </span>
                    <span className="clina-file-name">{f.relativePath}</span>
                  </div>
                ))}
              </div>
              <div
                style={{
                  padding: "0.75rem",
                  borderTop: "1px solid var(--border-color)",
                }}
              >
                <div
                  style={{
                    fontSize: "0.74rem",
                    fontWeight: 700,
                    marginBottom: "0.4rem",
                    color: "var(--green)",
                  }}
                >
                  ⚡ :Clina NeoCodeium Integration
                </div>
                <div
                  style={{
                    fontSize: "0.72rem",
                    color: "var(--text-secondary)",
                    marginBottom: "0.55rem",
                  }}
                >
                  Engine: <code>monkoose/neocodeium</code>
                </div>
                <Button
                  size="sm"
                  variant="success"
                  onClick={() =>
                    handleSaveSpecToDisk({
                      repo: "monkoose/neocodeium",
                      event: "VeryLazy",
                      cmd: "NeoCodeium",
                      opts: "manual = false, show_label = true",
                    })
                  }
                  style={{ width: "100%" }}
                >
                  💾 Save neocodeium.lua Spec
                </Button>
              </div>
            </div>

            {/* Center: Multi-Tab Code Editor Web Component (<starsky-code-editor>) + Terminal (<starsky-terminal>) */}
            <div style={{ display: "flex", flexDirection: "column", gap: "0.8rem" }}>
              <div className="card">
                <div className="ide-tab-strip">
                  {openTabs.map((tabPath) => (
                    <div
                      key={tabPath}
                      className={`ide-tab ${
                        clinaActiveFile === tabPath ? "active" : ""
                      }`}
                      onClick={() => loadClinaFile(tabPath)}
                    >
                      <span>🌙 {tabPath.split("/").pop()}</span>
                    </div>
                  ))}
                  <div style={{ marginLeft: "auto", display: "flex", gap: "0.4rem" }}>
                    <Badge variant="purple">
                      &lt;starsky-code-editor&gt;
                    </Badge>
                    <Button
                      size="sm"
                      variant="success"
                      onClick={() => saveActiveCodeFile()}
                    >
                      💾 Save (:w)
                    </Button>
                  </div>
                </div>

                {clinaBanner && (
                  <div
                    style={{
                      padding: "0.4rem 0.9rem",
                      background: "rgba(63, 185, 80, 0.14)",
                      color: "var(--green)",
                      fontSize: "0.76rem",
                      borderBottom: "1px solid var(--border-color)",
                    }}
                  >
                    {clinaBanner}
                  </div>
                )}

                <div style={{ padding: "0.65rem" }}>
                  {React.createElement("starsky-code-editor", {
                    ref: codeEditorRef,
                    code: clinaFileContent,
                    language: clinaFileLang,
                    filepath: clinaActiveFile,
                  })}
                </div>
              </div>

              {/* Integrated Neovim Ex-Command Terminal Web Component (<starsky-terminal>) */}
              {React.createElement("starsky-terminal", {
                ref: terminalRef,
              })}
            </div>

            {/* Right Panel: :Clina NeoCodeium Assistant & Keymap Reference */}
            <div className="card">
              <div className="card-header">
                <div>
                  <span className="card-title">
                    🤖 :Clina · NeoCodeium Studio
                  </span>
                  <div
                    style={{
                      fontSize: "0.71rem",
                      color: "var(--text-secondary)",
                    }}
                  >
                    monkoose/neocodeium · Windsurf Ghost-Text + Chat
                  </div>
                </div>
                <Badge variant="green">NeoCodeium</Badge>
              </div>
              <div className="card-body">
                <div
                  style={{
                    background: "var(--bg-primary)",
                    border: "1px solid var(--border-color)",
                    borderRadius: "8px",
                    padding: "0.65rem",
                    marginBottom: "0.75rem",
                    fontSize: "0.74rem",
                    fontFamily: "var(--font-mono)",
                  }}
                >
                  <div style={{ color: "var(--accent)", fontWeight: 700 }}>
                    NeoCodeium Lua API &amp; Keymaps (:Clina)
                  </div>
                  <div>&lt;A-f&gt; require(&quot;neocodeium&quot;).accept()</div>
                  <div>&lt;A-w&gt; require(&quot;neocodeium&quot;).accept_word()</div>
                  <div>&lt;A-a&gt; require(&quot;neocodeium&quot;).accept_line()</div>
                  <div>&lt;A-e&gt; require(&quot;neocodeium&quot;).cycle_or_complete()</div>
                  <div>&lt;A-r&gt; require(&quot;neocodeium&quot;).cycle_or_complete(-1)</div>
                  <div>&lt;A-c&gt; require(&quot;neocodeium&quot;).clear()</div>
                </div>

                <div
                  className="clina-chat-stream"
                  style={{ maxHeight: "260px", marginBottom: "0.7rem" }}
                >
                  {clinaHistory.length === 0 ? (
                    <div
                      style={{
                        fontSize: "0.76rem",
                        color: "var(--text-secondary)",
                      }}
                    >
                      Ask <code>:Clina</code> (NeoCodeium) to generate code,
                      refactor the active buffer, or build a lazy.nvim spec:
                    </div>
                  ) : (
                    clinaHistory.map((turn, idx) => (
                      <div
                        key={idx}
                        className={`clina-turn clina-turn-${turn.role}`}
                      >
                        <div className="clina-turn-header">
                          <Badge
                            variant={turn.role === "user" ? "default" : "green"}
                          >
                            {turn.role === "user" ? "YOU" : ":CLINA NEOCODEIUM"}
                          </Badge>
                          <span className="clina-turn-meta">
                            {turn.timestamp}
                          </span>
                        </div>
                        <pre className="clina-turn-text">{turn.text}</pre>
                      </div>
                    ))
                  )}
                </div>

                <textarea
                  className="field-textarea"
                  rows={2}
                  value={clinaPrompt}
                  onChange={(e) => setClinaPrompt(e.target.value)}
                  placeholder="Ask :Clina (NeoCodeium) or type a plugin name…"
                />
                <div
                  style={{
                    display: "flex",
                    gap: "0.45rem",
                    marginTop: "0.5rem",
                  }}
                >
                  <Button
                    variant="default"
                    onClick={() => handleRunClina()}
                    disabled={clinaRunning}
                    style={{ flex: 1 }}
                  >
                    {clinaRunning ? "Running…" : "⚡ Run :Clina (NeoCodeium)"}
                  </Button>
                </div>
              </div>
            </div>
          </div>
        )}

        {/* ============================================================
            TAB 2: :MUSICPLAYER (10-Band EQ, Visualizer, Radio & 2-Neovim Controller)
           ============================================================ */}
        {activeTab === "music" && musicState && musicStation && (
          <div style={{ display: "flex", flexDirection: "column", gap: "1rem" }}>
            <div className="grid-2">
              {/* Left: Deck, Visualizer (<starsky-eq-visualizer>), and 10-Band Equalizer */}
              <div className="card">
                <div className="card-header">
                  <div>
                    <span className="card-title">
                      🎵 :Kikru Studio · {musicStation.title}
                    </span>
                    <div
                      style={{
                        fontSize: "0.74rem",
                        color: "var(--text-secondary)",
                      }}
                    >
                      {musicStation.artist} · {musicStation.genre} ·{" "}
                      {musicStation.service} ({musicStation.bitrate})
                    </div>
                  </div>
                  <Badge variant={musicState.playing ? "green" : "amber"}>
                    {musicState.playing ? "▶ PLAYING" : "⏸ PAUSED"}
                  </Badge>
                </div>

                <div
                  className="card-body"
                  style={{
                    display: "flex",
                    flexDirection: "column",
                    gap: "0.9rem",
                  }}
                >
                  {/* Custom Web Component <starsky-eq-visualizer> */}
                  {React.createElement("starsky-eq-visualizer", {
                    playing: String(musicState.playing),
                    mode: musicState.visualizer,
                    bands: JSON.stringify(musicState.eqBands),
                    volume: String(musicState.volume),
                  })}

                  {/* Transport & Visualizer Controls */}
                  <div
                    style={{
                      display: "flex",
                      alignItems: "center",
                      justifyContent: "space-between",
                      flexWrap: "wrap",
                      gap: "0.5rem",
                    }}
                  >
                    <div style={{ display: "flex", gap: "0.45rem" }}>
                      <Button
                        size="sm"
                        onClick={() => dispatchMusicAction("prev")}
                      >
                        ⏮ Prev
                      </Button>
                      <Button
                        size="sm"
                        variant="success"
                        onClick={() => {
                          dispatchMusicAction("toggle");
                          if (audioRef.current) {
                            if (musicState.playing) audioRef.current.pause();
                            else audioRef.current.play().catch(() => {});
                          }
                        }}
                      >
                        {musicState.playing ? "⏸ Pause" : "▶ Play"}
                      </Button>
                      <Button
                        size="sm"
                        onClick={() => dispatchMusicAction("next")}
                      >
                        ⏭ Next
                      </Button>
                    </div>

                    <div
                      style={{
                        display: "flex",
                        alignItems: "center",
                        gap: "0.45rem",
                      }}
                    >
                      <span
                        style={{
                          fontSize: "0.74rem",
                          color: "var(--text-secondary)",
                        }}
                      >
                        🔊 Vol {musicState.volume}%
                      </span>
                      <input
                        type="range"
                        min={0}
                        max={100}
                        value={musicState.volume}
                        onChange={(e) =>
                          dispatchMusicAction("volume", {
                            volume: Number(e.target.value),
                          })
                        }
                      />
                    </div>

                    <div style={{ display: "flex", gap: "0.35rem" }}>
                      {(["spectrum", "wave"] as const).map((m) => (
                        <Button
                          key={m}
                          size="sm"
                          variant={
                            musicState.visualizer === m
                              ? "default"
                              : "secondary"
                          }
                          onClick={() =>
                            dispatchMusicAction("visualizer", { mode: m })
                          }
                        >
                          📊 {m}
                        </Button>
                      ))}
                    </div>
                  </div>

                  {/* 10-Band Graphic Equalizer + Presets */}
                  <div>
                    <div
                      style={{
                        display: "flex",
                        justifyContent: "space-between",
                        alignItems: "center",
                        marginBottom: "0.5rem",
                        flexWrap: "wrap",
                        gap: "0.4rem",
                      }}
                    >
                      <span
                        style={{
                          fontSize: "0.78rem",
                          fontWeight: 700,
                        }}
                      >
                        🎚️ 10-Band Graphic Equalizer (Preset:{" "}
                        <code style={{ color: "var(--accent)" }}>
                          {musicState.eqPreset}
                        </code>
                        )
                      </span>
                      <div
                        style={{
                          display: "flex",
                          gap: "0.3rem",
                          flexWrap: "wrap",
                        }}
                      >
                        {Object.keys(eqPresets).map((preset) => (
                          <button
                            key={preset}
                            className={`btn btn-sm ${
                              musicState.eqPreset === preset
                                ? "btn-primary"
                                : ""
                            }`}
                            onClick={() =>
                              dispatchMusicAction("eqPreset", { preset })
                            }
                          >
                            {preset}
                          </button>
                        ))}
                      </div>
                    </div>

                    <div className="eq-sliders-grid">
                      {eqFrequencies.map((freq, idx) => {
                        const gain = musicState.eqBands[idx] ?? 0;
                        return (
                          <div key={freq} className="eq-band-col">
                            <span className="eq-gain-label">
                              {gain >= 0 ? `+${gain}` : gain}dB
                            </span>
                            <input
                              type="range"
                              min={-12}
                              max={12}
                              step={1}
                              value={gain}
                              className="eq-band-slider"
                              onChange={(e) =>
                                dispatchMusicAction("eqBand", {
                                  bandIndex: idx,
                                  gain: Number(e.target.value),
                                })
                              }
                            />
                            <span className="eq-freq-label">{freq}</span>
                          </div>
                        );
                      })}
                    </div>
                  </div>
                </div>
              </div>

              {/* Right: 2-Neovim Device Controller (Server <-> Client) & Radio / Streaming */}
              <div
                style={{
                  display: "flex",
                  flexDirection: "column",
                  gap: "1rem",
                }}
              >
                <div className="card">
                  <div className="card-header">
                    <div>
                      <span className="card-title">
                        🔗 2-Neovim Device Controller (Server &lt;-&gt; Client
                        TCP RPC)
                      </span>
                      <div
                        style={{
                          fontSize: "0.72rem",
                          color: "var(--text-secondary)",
                        }}
                      >
                        Neovim #1 runs <code>:Kikru server 41999</code> ·
                        Neovim #2 runs{" "}
                        <code>:Kikru connect 127.0.0.1:41999</code>
                      </div>
                    </div>
                    <Badge variant="green">
                      {musicState.devices.length} Paired Neovim Instances
                    </Badge>
                  </div>
                  <div className="card-body">
                    {musicState.devices.map((dev) => (
                      <div
                        key={dev.id}
                        className={`device-card ${dev.active ? "active" : ""}`}
                      >
                        <div>
                          <div style={{ fontWeight: 700, fontSize: "0.82rem" }}>
                            {dev.role === "server" ? "🟢 SERVER" : "🔵 CLIENT"} ·{" "}
                            {dev.name}
                          </div>
                          <div
                            style={{
                              fontSize: "0.72rem",
                              color: "var(--text-secondary)",
                              fontFamily: "var(--font-mono)",
                            }}
                          >
                            {dev.addr} · PID {dev.pid} · Connected{" "}
                            {dev.connectedAt}
                          </div>
                        </div>
                        <Button
                          size="sm"
                          variant={dev.active ? "success" : "secondary"}
                          onClick={() =>
                            dispatchMusicAction("handoffDevice", {
                              deviceId: dev.id,
                            })
                          }
                        >
                          {dev.active ? "🔊 Active Output" : "Route Output"}
                        </Button>
                      </div>
                    ))}

                    <div
                      style={{
                        display: "flex",
                        gap: "0.45rem",
                        marginTop: "0.65rem",
                      }}
                    >
                      <input
                        className="field-input"
                        value={pairClientName}
                        onChange={(e) => setPairClientName(e.target.value)}
                        placeholder="Neovim Client Name…"
                      />
                      <Button
                        size="sm"
                        onClick={() =>
                          dispatchMusicAction("pairClient", {
                            name: pairClientName,
                          })
                        }
                      >
                        + Pair Neovim Client
                      </Button>
                    </div>

                    <div
                      style={{
                        marginTop: "0.75rem",
                        background: "#070a12",
                        border: "1px solid var(--border-color)",
                        borderRadius: "7px",
                        padding: "0.6rem",
                        fontFamily: "var(--font-mono)",
                        fontSize: "0.71rem",
                        color: "var(--text-secondary)",
                        maxHeight: "105px",
                        overflowY: "auto",
                      }}
                    >
                      {musicState.rpcLog.map((line, i) => (
                        <div key={i}>{line}</div>
                      ))}
                    </div>
                  </div>
                </div>

                {/* Internet Radio Stations & Streaming Service Connectors */}
                <div className="card">
                  <div className="card-header">
                    <span className="card-title">
                      📻 Internet Radio &amp; Streaming Services
                    </span>
                    <Badge>{musicStations.length} Live Streams</Badge>
                  </div>
                  <div className="card-body">
                    <div
                      style={{
                        display: "flex",
                        gap: "0.35rem",
                        flexWrap: "wrap",
                        marginBottom: "0.7rem",
                      }}
                    >
                      {musicServices.map((srv) => (
                        <button
                          key={srv.id}
                          className={`btn btn-sm ${
                            musicState.serviceId === srv.id ? "btn-primary" : ""
                          }`}
                          onClick={() =>
                            dispatchMusicAction("service", {
                              serviceId: srv.id,
                            })
                          }
                        >
                          📡 {srv.name.split(" (")[0]}
                        </button>
                      ))}
                    </div>

                    {musicStations.map((st, idx) => (
                      <div
                        key={st.id}
                        className={`device-card ${
                          musicState.stationIdx === idx ? "active" : ""
                        }`}
                        style={{ cursor: "pointer" }}
                        onClick={() =>
                          dispatchMusicAction("station", { index: idx })
                        }
                      >
                        <div>
                          <div style={{ fontWeight: 700, fontSize: "0.8rem" }}>
                            {musicState.stationIdx === idx ? "▶ " : "· "}
                            {st.title}
                          </div>
                          <div
                            style={{
                              fontSize: "0.71rem",
                              color: "var(--text-secondary)",
                            }}
                          >
                            {st.genre} · {st.service} · {st.bitrate}
                          </div>
                        </div>
                        <Badge
                          variant={
                            musicState.stationIdx === idx ? "green" : "default"
                          }
                        >
                          {musicState.stationIdx === idx ? "ON AIR" : "Tune In"}
                        </Badge>
                      </div>
                    ))}
                  </div>
                </div>
              </div>
            </div>
          </div>
        )}

        {/* ============================================================
            TAB 3: SPEC BUILDER, DISK SAVER & LIVE GITHUB API AUTOCOMPLETE
           ============================================================ */}
        {activeTab === "spec" && (
          <div className="grid-2">
            <div className="card">
              <div className="card-header">
                <span className="card-title">
                  ⚡ lazy.nvim Spec Builder (Live GitHub API Autocomplete)
                </span>
                <div style={{ display: "flex", gap: "0.4rem" }}>
                  <Button
                    size="sm"
                    variant="secondary"
                    onClick={() => setForm(DEFAULT_FORM)}
                  >
                    Reset
                  </Button>
                  <Button
                    size="sm"
                    variant="success"
                    onClick={() => handleSaveSpecToDisk()}
                    disabled={savingSpec}
                  >
                    💾 Save Spec to Disk
                  </Button>
                </div>
              </div>
              <div className="card-body">
                {saveBanner && (
                  <div
                    style={{
                      marginBottom: "0.8rem",
                      padding: "0.55rem 0.75rem",
                      borderRadius: "7px",
                      background: saveBanner.startsWith("✓")
                        ? "rgba(63, 185, 80, 0.14)"
                        : "rgba(248, 81, 73, 0.14)",
                      color: saveBanner.startsWith("✓")
                        ? "var(--green)"
                        : "var(--red)",
                      fontSize: "0.78rem",
                      fontFamily: "var(--font-mono)",
                    }}
                  >
                    {saveBanner}
                  </div>
                )}

                <div className="form-grid">
                  {FORM_FIELDS.map((f) => (
                    <div
                      key={f.key}
                      className={`field-group ${f.multiline ? "full" : ""}`}
                    >
                      <label className="field-label">
                        <span>{f.label}</span>
                        <span className="field-key">{f.key}</span>
                      </label>
                      {f.multiline ? (
                        <textarea
                          className="field-textarea"
                          value={form[f.key]}
                          placeholder={f.placeholder}
                          onFocus={() => setActiveField(f.key)}
                          onChange={(e) =>
                            setForm((prev) => ({
                              ...prev,
                              [f.key]: e.target.value,
                            }))
                          }
                        />
                      ) : (
                        <input
                          className="field-input"
                          value={form[f.key]}
                          placeholder={f.placeholder}
                          onFocus={() => setActiveField(f.key)}
                          onChange={(e) =>
                            setForm((prev) => ({
                              ...prev,
                              [f.key]: e.target.value,
                            }))
                          }
                        />
                      )}
                    </div>
                  ))}
                </div>
              </div>
            </div>

            <div style={{ display: "flex", flexDirection: "column", gap: "1rem" }}>
              <div className="card">
                <div className="card-header">
                  <span className="card-title">
                    📄 Generated Lua Spec (
                    <code>
                      lua/plugins/
                      {(form.repo.split("/")[1] || "plugin")
                        .replace(/\.nvim$/, "")
                        .toLowerCase()}
                      .lua
                    </code>
                    )
                  </span>
                  <div style={{ display: "flex", gap: "0.4rem" }}>
                    <Button
                      size="sm"
                      variant="secondary"
                      onClick={() => copyToClipboard(generatedLua)}
                    >
                      {copied ? "✓ Copied!" : "Copy Lua"}
                    </Button>
                    <Button
                      size="sm"
                      variant="success"
                      onClick={() => handleSaveSpecToDisk()}
                    >
                      💾 Save Spec
                    </Button>
                  </div>
                </div>
                <div className="card-body">
                  {specError ? (
                    <div style={{ color: "var(--red)", fontSize: "0.82rem" }}>
                      {specError}
                    </div>
                  ) : (
                    <pre className="code-block">{generatedLua}</pre>
                  )}
                </div>
              </div>

              <div className="card">
                <div className="card-header">
                  <span className="card-title">
                    ✨ Live GitHub API Autocomplete for{" "}
                    <code style={{ color: "var(--accent)" }}>{activeField}</code>
                  </span>
                  <Badge variant="green">
                    {completionSource} · {completions.length} items
                  </Badge>
                </div>
                <div className="card-body">
                  <div className="completion-list">
                    {completions.map((item) => (
                      <div
                        key={item.word}
                        className="completion-item"
                        onClick={() => applyCompletion(item.word)}
                      >
                        <div>
                          <span className="completion-word">{item.word}</span>
                          <span
                            className="badge badge-purple"
                            style={{ marginLeft: "0.5rem" }}
                          >
                            {item.kind}
                          </span>
                        </div>
                        <span className="completion-menu">{item.menu}</span>
                      </div>
                    ))}
                  </div>
                </div>
              </div>

              <div className="card">
                <div className="card-header">
                  <span className="card-title">
                    💾 Saved Plugin Specs on Disk (<code>lua/plugins/*.lua</code>
                    )
                  </span>
                  <Badge variant="green">{savedSpecs.length} saved</Badge>
                </div>
                <div className="card-body">
                  {savedSpecs.length === 0 ? (
                    <div
                      style={{
                        color: "var(--text-muted)",
                        fontSize: "0.78rem",
                      }}
                    >
                      No saved specs in <code>lua/plugins/</code> yet. Click{" "}
                      <b>💾 Save Spec</b> above to write one!
                    </div>
                  ) : (
                    savedSpecs.map((f) => (
                      <div key={f.filename} className="saved-spec-row">
                        <div>
                          <strong style={{ fontFamily: "var(--font-mono)" }}>
                            {f.filename}
                          </strong>
                          <span
                            style={{
                              fontSize: "0.71rem",
                              color: "var(--text-secondary)",
                              marginLeft: "0.5rem",
                            }}
                          >
                            ({f.size} B)
                          </span>
                        </div>
                        <Button
                          size="sm"
                          variant="secondary"
                          onClick={() => {
                            setRawSnippet(f.content);
                            setActiveTab("parser");
                          }}
                        >
                          Inspect
                        </Button>
                      </div>
                    ))
                  )}
                </div>
              </div>
            </div>
          </div>
        )}

        {/* ============================================================
            TAB 4: https://mason-registry.dev/ EXPLORER (All 601 Packages)
           ============================================================ */}
        {activeTab === "mason" && (
          <div>
            <div className="card" style={{ marginBottom: "1rem" }}>
              <div className="card-header">
                <div>
                  <span className="card-title">
                    🧱 Official{" "}
                    <a
                      href="https://mason-registry.dev/"
                      target="_blank"
                      rel="noreferrer"
                      style={{ color: "var(--accent)", textDecoration: "underline" }}
                    >
                      https://mason-registry.dev/
                    </a>{" "}
                    Catalog ({masonTotal} Servers &amp; Tools)
                  </span>
                  <div
                    style={{
                      fontSize: "0.73rem",
                      color: "var(--text-secondary)",
                    }}
                  >
                    Synced with{" "}
                    <a
                      href="https://mason-registry.dev/registry/list"
                      target="_blank"
                      rel="noreferrer"
                      style={{ color: "var(--cyan)" }}
                    >
                      https://mason-registry.dev/registry/list
                    </a>{" "}
                    · 331 LSP · 32 DAP · 147 Linter · 151 Formatter · 15
                    Compiler · 15 Runtime
                  </div>
                </div>
                <div style={{ display: "flex", gap: "0.45rem" }}>
                  <a
                    href="https://mason-registry.dev/registry/list"
                    target="_blank"
                    rel="noreferrer"
                    className="btn btn-sm"
                  >
                    🌐 Open mason-registry.dev ↗
                  </a>
                  <Button
                    size="sm"
                    variant="success"
                    onClick={() =>
                      handleSaveSpecToDisk({
                        repo: "mason-org/mason-lspconfig.nvim",
                        name: "mason-servers",
                        event: "BufReadPre, BufNewFile",
                        dependencies:
                          "mason-org/mason.nvim, neovim/nvim-lspconfig",
                        opts: `ensure_installed = { ${selectedMason
                          .map((s) => `"${s}"`)
                          .join(", ")} }, automatic_installation = true`,
                      })
                    }
                  >
                    💾 Save mason-servers.lua ({selectedMason.length})
                  </Button>
                </div>
              </div>
              <div className="card-body">
                <div className="filter-bar" style={{ marginBottom: 0 }}>
                  <input
                    className="search-input"
                    value={masonQuery}
                    onChange={(e) => setMasonQuery(e.target.value)}
                    placeholder="Search 601 mason-registry.dev packages by name, lspconfig id, language, or binary…"
                  />
                  {(
                    [
                      "ALL",
                      "LSP",
                      "DAP",
                      "Linter",
                      "Formatter",
                      "Compiler",
                      "Runtime",
                    ] as const
                  ).map((cat) => (
                    <button
                      key={cat}
                      className={`btn btn-sm ${
                        masonCategory === cat ? "btn-primary" : ""
                      }`}
                      onClick={() => setMasonCategory(cat)}
                    >
                      {cat}
                      {cat !== "ALL" && masonCategories[cat]
                        ? ` (${masonCategories[cat]})`
                        : ""}
                    </button>
                  ))}
                  <input
                    className="field-input"
                    style={{ width: "140px" }}
                    value={masonLanguage}
                    onChange={(e) => setMasonLanguage(e.target.value)}
                    placeholder="Filter language…"
                  />
                </div>
              </div>
            </div>

            {masonPreviewPkg && (
              <div className="card" style={{ marginBottom: "1rem" }}>
                <div className="card-header">
                  <span className="card-title">
                    📦 {masonPreviewPkg.name} ·{" "}
                    <a
                      href={`https://mason-registry.dev/registry/list#/${masonPreviewPkg.name}`}
                      target="_blank"
                      rel="noreferrer"
                      style={{ color: "var(--accent)" }}
                    >
                      mason-registry.dev/registry/list#/{masonPreviewPkg.name} ↗
                    </a>
                  </span>
                  <Button
                    size="sm"
                    variant="secondary"
                    onClick={() => setMasonPreviewPkg(null)}
                  >
                    Close
                  </Button>
                </div>
                <div className="card-body">
                  <div style={{ fontSize: "0.8rem", marginBottom: "0.4rem" }}>
                    {masonPreviewPkg.description}
                  </div>
                  <div
                    style={{
                      fontSize: "0.74rem",
                      color: "var(--text-secondary)",
                      fontFamily: "var(--font-mono)",
                    }}
                  >
                    Source: <code>{masonPreviewPkg.source_id}</code> · Binaries:{" "}
                    <code>{(masonPreviewPkg.bin || []).join(", ") || "n/a"}</code>
                  </div>
                </div>
              </div>
            )}

            <div className="mason-grid">
              {masonPackages.map((pkg) => {
                const key = pkg.lspconfig || pkg.name;
                const isSelected = selectedMason.includes(key);
                return (
                  <div
                    key={pkg.name}
                    className="mason-card"
                    style={{
                      borderColor: isSelected ? "var(--green)" : undefined,
                    }}
                  >
                    <div className="mason-card-top">
                      <div>
                        <div className="mason-name">{pkg.name}</div>
                        {pkg.lspconfig && (
                          <span
                            className="badge badge-green"
                            style={{ marginTop: "0.2rem" }}
                          >
                            lspconfig: {pkg.lspconfig}
                          </span>
                        )}
                      </div>
                      <div style={{ display: "flex", gap: "0.3rem" }}>
                        <Button
                          size="sm"
                          variant="secondary"
                          onClick={() => setMasonPreviewPkg(pkg)}
                        >
                          Info
                        </Button>
                        <Button
                          size="sm"
                          variant={isSelected ? "success" : "default"}
                          onClick={() =>
                            setSelectedMason((prev) =>
                              prev.includes(key)
                                ? prev.filter((x) => x !== key)
                                : [...prev, key]
                            )
                          }
                        >
                          {isSelected ? "✓ Added" : "+ Add"}
                        </Button>
                      </div>
                    </div>
                    <div className="mason-desc">{pkg.description}</div>
                    <div className="mason-tags">
                      {pkg.categories.map((c) => (
                        <span key={c} className="badge badge-accent">
                          {c}
                        </span>
                      ))}
                      {pkg.languages.slice(0, 4).map((l) => (
                        <span key={l} className="badge badge-purple">
                          {l}
                        </span>
                      ))}
                    </div>
                  </div>
                );
              })}
            </div>
          </div>
        )}

        {/* ============================================================
            TAB 5: SFTP STUDIO UI
           ============================================================ */}
        {activeTab === "sftp" && (
          <div style={{ display: "flex", flexDirection: "column", gap: "1rem" }}>
            <div className="card">
              <div className="card-header">
                <div>
                  <span className="card-title">
                    🛰️ SFTP Studio (Dual-Pane Local &lt;-&gt; Remote Explorer)
                  </span>
                </div>
                <div style={{ display: "flex", gap: "0.4rem" }}>
                  <Button
                    size="sm"
                    onClick={() => runSftpAction("test")}
                  >
                    🔌 Test SSH
                  </Button>
                  <Button
                    size="sm"
                    variant="success"
                    onClick={() => runSftpAction("sync")}
                  >
                    🔄 Sync Project
                  </Button>
                </div>
              </div>
              {sftpBanner && (
                <div
                  style={{
                    padding: "0.45rem 1rem",
                    background: "rgba(63, 185, 80, 0.14)",
                    color: "var(--green)",
                    fontSize: "0.76rem",
                    fontFamily: "var(--font-mono)",
                  }}
                >
                  {sftpBanner}
                </div>
              )}
            </div>

            <div className="grid-2">
              <div className="card">
                <div className="card-header">
                  <span className="card-title">
                    💻 Local Workspace ({sftpLocalDir || "."})
                  </span>
                </div>
                <div className="card-body sftp-pane">
                  {sftpLocalEntries.map((entry) => (
                    <div key={entry.path} className="sftp-entry-row">
                      <div
                        className="sftp-entry-main"
                        onClick={() => {
                          if (entry.type === "dir") {
                            loadSftpState(entry.path, sftpRemoteDir, sftpActiveIdx);
                          }
                        }}
                      >
                        <span>{entry.type === "dir" ? "📁" : "📄"}</span>
                        <span>{entry.name}</span>
                      </div>
                      <div className="sftp-entry-meta">
                        <Button
                          size="sm"
                          onClick={() =>
                            runSftpAction("upload", {
                              localPath: entry.path,
                              remotePath: `${sftpRemoteDir.replace(
                                /\/$/,
                                ""
                              )}/${entry.name}`,
                            })
                          }
                        >
                          ⬆ Upload
                        </Button>
                      </div>
                    </div>
                  ))}
                </div>
              </div>

              <div className="card">
                <div className="card-header">
                  <span className="card-title">
                    🌐 Remote Server ({sftpRemoteDir})
                  </span>
                </div>
                <div className="card-body sftp-pane">
                  {sftpRemoteEntries.map((entry) => (
                    <div key={entry.path} className="sftp-entry-row">
                      <div className="sftp-entry-main">
                        <span>{entry.type === "dir" ? "📁" : "📄"}</span>
                        <span>{entry.name}</span>
                      </div>
                      <div className="sftp-entry-meta">
                        <span>{entry.permissions}</span>
                        <Button
                          size="sm"
                          variant="secondary"
                          onClick={() =>
                            runSftpAction("download", {
                              remotePath: entry.path,
                              localPath: entry.name,
                            })
                          }
                        >
                          ⬇ Download
                        </Button>
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            </div>

            <div className="grid-2">
              <div className="card">
                <div className="card-header">
                  <span className="card-title">⌨️ Remote SSH Command Runner</span>
                </div>
                <div className="card-body">
                  <div style={{ display: "flex", gap: "0.45rem" }}>
                    <input
                      className="field-input"
                      value={sftpCmdInput}
                      onChange={(e) => setSftpCmdInput(e.target.value)}
                    />
                    <Button
                      size="sm"
                      onClick={() =>
                        runSftpAction("exec", { command: sftpCmdInput })
                      }
                    >
                      Run SSH
                    </Button>
                  </div>
                  {sftpCmdOutput && (
                    <pre
                      className="code-block"
                      style={{ marginTop: "0.6rem" }}
                    >
                      {sftpCmdOutput}
                    </pre>
                  )}
                </div>
              </div>

              <div className="card">
                <div className="card-header">
                  <span className="card-title">📜 SFTP Transfer Log</span>
                </div>
                <div className="card-body">
                  {sftpLogs.slice(0, 6).map((l) => (
                    <div key={l.id} className="sftp-log-row">
                      <Badge variant="green">{l.direction}</Badge>
                      <span className="sftp-log-msg">{l.message}</span>
                      <span className="sftp-log-time">{l.timestamp}</span>
                    </div>
                  ))}
                </div>
              </div>
            </div>
          </div>
        )}

        {/* ============================================================
            TAB 6: UNIVERSAL README & SNIPPET PARSER (11 Formats)
           ============================================================ */}
        {activeTab === "parser" && (
          <div className="grid-2">
            <div className="card">
              <div className="card-header">
                <span className="card-title">
                  📄 Universal Plugin Snippet &amp; README.md Parser
                </span>
                <div style={{ display: "flex", gap: "0.3rem", flexWrap: "wrap" }}>
                  {Object.entries(SAMPLE_SNIPPETS).map(([k, v]) => (
                    <button
                      key={k}
                      className="btn btn-sm"
                      onClick={() => setRawSnippet(v.snippet)}
                    >
                      {v.label}
                    </button>
                  ))}
                </div>
              </div>
              <div className="card-body">
                <div
                  style={{
                    display: "flex",
                    gap: "0.45rem",
                    marginBottom: "0.75rem",
                  }}
                >
                  <input
                    className="field-input"
                    value={readmeRepoInput}
                    onChange={(e) => setReadmeRepoInput(e.target.value)}
                    placeholder="Fetch live GitHub README (e.g. monkoose/neocodeium)"
                  />
                  <Button
                    size="sm"
                    onClick={handleFetchGithubReadme}
                    disabled={loadingReadme}
                  >
                    {loadingReadme ? "Fetching…" : "Fetch README"}
                  </Button>
                </div>
                <textarea
                  className="field-textarea"
                  style={{ minHeight: "300px" }}
                  value={rawSnippet}
                  onChange={(e) => setRawSnippet(e.target.value)}
                />
              </div>
            </div>

            <div className="card">
              <div className="card-header">
                <span className="card-title">
                  🔍 Extracted lazy.nvim Specs ({parsedResults.length})
                </span>
              </div>
              <div className="card-body">
                {parsedResults.map((res, idx) => (
                  <div
                    key={`${res.repo}-${idx}`}
                    className="card"
                    style={{ marginBottom: "0.75rem" }}
                  >
                    <div className="card-header">
                      <div>
                        <strong>{res.repo}</strong>{" "}
                        <Badge variant="purple">{res.manager}</Badge>
                      </div>
                      <div style={{ display: "flex", gap: "0.4rem" }}>
                        <Button
                          size="sm"
                          variant="success"
                          onClick={() => handleSaveSpecToDisk(res.spec)}
                        >
                          💾 Save Spec
                        </Button>
                        <Button
                          size="sm"
                          onClick={() => {
                            setForm({ ...DEFAULT_FORM, ...res.spec });
                            setActiveTab("spec");
                          }}
                        >
                          Open in Builder →
                        </Button>
                      </div>
                    </div>
                    <div className="card-body">
                      <pre className="code-block">{res.lua}</pre>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          </div>
        )}

        {/* ============================================================
            TAB 7: GITHUB NEOVIM PLUGIN SEARCH
           ============================================================ */}
        {activeTab === "github" && (
          <div>
            <div className="filter-bar">
              <input
                className="search-input"
                value={ghQuery}
                onChange={(e) => setGhQuery(e.target.value)}
                onKeyDown={(e) =>
                  e.key === "Enter" && handleGithubSearch(ghQuery)
                }
                placeholder="Search GitHub Neovim plugins…"
              />
              <Button
                onClick={() => handleGithubSearch(ghQuery)}
                disabled={ghLoading}
              >
                {ghLoading ? "Searching…" : "Search GitHub"}
              </Button>
            </div>
            <div className="mason-grid">
              {ghResults.map((repo) => (
                <div key={repo.full_name} className="mason-card">
                  <div className="mason-card-top">
                    <div className="mason-name">{repo.full_name}</div>
                    <Badge variant="amber">★ {repo.stargazers_count}</Badge>
                  </div>
                  <div className="mason-desc">{repo.description}</div>
                  <div style={{ display: "flex", gap: "0.4rem" }}>
                    <Button
                      size="sm"
                      variant="success"
                      onClick={() =>
                        handleSaveSpecToDisk({ repo: repo.full_name })
                      }
                    >
                      💾 Save Spec
                    </Button>
                    <Button
                      size="sm"
                      onClick={() => {
                        setForm({ ...DEFAULT_FORM, repo: repo.full_name });
                        setActiveTab("spec");
                      }}
                    >
                      Configure →
                    </Button>
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}
      </main>
    </div>
  );
}
