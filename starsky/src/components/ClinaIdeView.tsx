"use client";

import React, { useState, useEffect } from "react";
import {
  Bot,
  Sparkles,
  FolderTree,
  FileCode,
  Play,
  Check,
  GitCompare,
  Cpu,
  Wrench,
  Save,
  Plus,
  Terminal,
  ArrowRight,
  RefreshCw,
} from "lucide-react";

interface ClinaProvider {
  id: string;
  name: string;
  model: string;
  configured: boolean;
  description: string;
}

interface ClinaMcpTool {
  id: string;
  name: string;
  enabled: boolean;
  category: string;
  description: string;
}

interface ClinaFileNode {
  name: string;
  path: string;
  relativePath: string;
  type: "file" | "dir";
  size: number;
  language: string;
}

interface ClinaProposal {
  path: string;
  relativePath: string;
  language: string;
  originalCode: string;
  code: string;
  diff: string;
  description: string;
}

interface ClinaStep {
  tool: string;
  action: string;
  status: string;
  detail: string;
}

interface ClinaMessage {
  id: string;
  role: "user" | "assistant";
  mode: string;
  model: string;
  timestamp: string;
  content: string;
  steps?: ClinaStep[];
  proposal?: ClinaProposal;
  specForm?: Record<string, string>;
}

interface ClinaIdeViewProps {
  onLoadSpecIntoModal: (form: Record<string, string>) => void;
}

const QUICK_PROMPTS = [
  {
    label: "Synthesize lazy.nvim Spec",
    mode: "spec",
    prompt:
      "Create a lazy.nvim plugin spec for folke/snacks.nvim with event VeryLazy and opts = { notifier = { enabled = true } }",
  },
  {
    label: "Agent Refactor Module",
    mode: "agent",
    prompt:
      "Inspect the active file and add safe validation & documentation comments",
  },
  {
    label: "Inline Buffer Edit",
    mode: "edit",
    prompt: "Add a helper function to export current status diagnostics",
  },
  {
    label: "Explain Architecture",
    mode: "chat",
    prompt:
      "Explain how kaeru.nvim validates and saves lazy.nvim plugin specs",
  },
];

export default function ClinaIdeView({
  onLoadSpecIntoModal,
}: ClinaIdeViewProps) {
  const [providers, setProviders] = useState<ClinaProvider[]>([]);
  const [selectedProvider, setSelectedProvider] = useState<string>("clina-ts");
  const [mode, setMode] = useState<"agent" | "chat" | "edit" | "spec">("agent");
  const [mcpTools, setMcpTools] = useState<ClinaMcpTool[]>([]);
  const [files, setFiles] = useState<ClinaFileNode[]>([]);
  const [contextFiles, setContextFiles] = useState<string[]>([
    "lua/kaeru/spec.lua",
  ]);
  const [activeFile, setActiveFile] = useState<string>(
    "lua/kaeru/spec.lua"
  );
  const [editorContent, setEditorContent] = useState<string>("");
  const [editorLanguage, setEditorLanguage] = useState<string>("lua");
  const [editorStatus, setEditorStatus] = useState<string>("");
  const [centerTab, setCenterTab] = useState<"editor" | "diff">("editor");
  const [activeProposal, setActiveProposal] = useState<ClinaProposal | null>(
    null
  );
  const [prompt, setPrompt] = useState<string>("");
  const [busy, setBusy] = useState<boolean>(false);
  const [messages, setMessages] = useState<ClinaMessage[]>([
    {
      id: "welcome",
      role: "assistant",
      mode: "agent",
      model: "clina-coder-ts-v1",
      timestamp: "Ready",
      content:
        "Welcome to **:Clina** — the TypeScript AI Coding IDE for Neovim (`starsky/src/lib/clina.ts` & `:Clina`).\n\nSelect any workspace file on the left, pin `@context` files, choose **Agent / Chat / Edit / Spec** mode, and run multi-step coding tasks with live unified diffs.",
    },
  ]);

  const loadWorkspace = async () => {
    try {
      const res = await fetch("/api/clina");
      const data = await res.json();
      if (data.ok) {
        setProviders(data.providers || []);
        setMcpTools(data.mcpTools || []);
        setFiles(data.files || []);
      }
    } catch {
      // ignore
    }
  };

  const openFileInEditor = async (relPath: string) => {
    setActiveFile(relPath);
    try {
      const res = await fetch(`/api/clina?file=${encodeURIComponent(relPath)}`);
      const data = await res.json();
      if (data.ok) {
        setEditorContent(data.content || "");
        setEditorLanguage(data.language || "plaintext");
        setCenterTab("editor");
      }
    } catch {
      // ignore
    }
  };

  useEffect(() => {
    loadWorkspace();
    openFileInEditor("lua/kaeru/spec.lua");
  }, []);

  const toggleContextFile = (relPath: string) => {
    setContextFiles((prev) =>
      prev.includes(relPath)
        ? prev.filter((f) => f !== relPath)
        : [...prev, relPath]
    );
  };

  const toggleMcp = (id: string) => {
    setMcpTools((prev) =>
      prev.map((t) => (t.id === id ? { ...t, enabled: !t.enabled } : t))
    );
  };

  const saveActiveBuffer = async () => {
    setEditorStatus("Saving…");
    try {
      const res = await fetch("/api/clina", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          action: "write",
          path: activeFile,
          content: editorContent,
        }),
      });
      const data = await res.json();
      if (data.ok) {
        setEditorStatus(`Saved ${data.relativePath} (${data.size} B)`);
        if (data.files) setFiles(data.files);
      } else {
        setEditorStatus(`Error: ${data.error || "save failed"}`);
      }
    } catch (err) {
      setEditorStatus(`Error: ${String(err)}`);
    }
  };

  const sendPrompt = async (customPrompt?: string, customMode?: string) => {
    const text = (customPrompt ?? prompt).trim();
    if (!text) return;
    const runMode = (customMode || mode) as "agent" | "chat" | "edit" | "spec";
    const providerObj =
      providers.find((p) => p.id === selectedProvider) || providers[0];

    const userMsg: ClinaMessage = {
      id: `u-${Date.now()}`,
      role: "user",
      mode: runMode,
      model: providerObj?.model || "clina-coder-ts-v1",
      timestamp: new Date().toLocaleTimeString(),
      content: text,
    };
    setMessages((prev) => [...prev, userMsg]);
    if (!customPrompt) setPrompt("");
    setBusy(true);

    try {
      const res = await fetch("/api/clina", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          action: "run",
          prompt: text,
          mode: runMode,
          provider: selectedProvider,
          model: providerObj?.model,
          active_file: activeFile,
          active_content: editorContent,
          context_files: contextFiles,
          mcp_tools: mcpTools.filter((t) => t.enabled).map((t) => t.id),
        }),
      });
      const data = await res.json();
      if (data.proposal) {
        setActiveProposal(data.proposal);
        setCenterTab("diff");
      }
      const replyMsg: ClinaMessage = {
        id: `a-${Date.now()}`,
        role: "assistant",
        mode: data.mode || runMode,
        model: data.model || "clina-coder-ts-v1",
        timestamp: new Date().toLocaleTimeString(),
        content: data.reply || "Completed.",
        steps: data.steps,
        proposal: data.proposal,
        specForm: data.specForm,
      };
      setMessages((prev) => [...prev, replyMsg]);
    } catch (err) {
      setMessages((prev) => [
        ...prev,
        {
          id: `err-${Date.now()}`,
          role: "assistant",
          mode: runMode,
          model: "clina-coder-ts-v1",
          timestamp: new Date().toLocaleTimeString(),
          content: `Error communicating with Clina TypeScript engine: ${String(err)}`,
        },
      ]);
    } finally {
      setBusy(false);
    }
  };

  const applyProposal = async (proposal: ClinaProposal) => {
    setEditorStatus("Applying Clina patch…");
    try {
      const res = await fetch("/api/clina", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          action: "apply",
          path: proposal.relativePath || proposal.path,
          code: proposal.code,
        }),
      });
      const data = await res.json();
      if (data.ok) {
        setActiveFile(data.relativePath);
        setEditorContent(proposal.code);
        setCenterTab("editor");
        setEditorStatus(`Applied Clina patch to ${data.relativePath}`);
        if (data.files) setFiles(data.files);
      }
    } catch (err) {
      setEditorStatus(`Apply failed: ${String(err)}`);
    }
  };

  const fileItems = files.filter((f) => f.type === "file");

  return (
    <div className="clina-ide-layout">
      {/* LEFT SIDEBAR: Provider, Mode, Workspace Tree & MCP Servers */}
      <aside className="clina-sidebar card">
        <div className="card-header">
          <span className="card-title">
            <Cpu size={15} /> :Clina TypeScript Engine
          </span>
          <span className="badge badge-accent">TS v1</span>
        </div>

        <div className="clina-sidebar-body">
          <label className="clina-field-label">AI Model Provider</label>
          <select
            className="select-input"
            style={{ width: "100%", marginBottom: "0.65rem" }}
            value={selectedProvider}
            onChange={(e) => setSelectedProvider(e.target.value)}
          >
            {providers.map((p) => (
              <option key={p.id} value={p.id}>
                {p.name} ({p.model})
              </option>
            ))}
          </select>

          <label className="clina-field-label">IDE Execution Mode</label>
          <div className="clina-mode-pills">
            {(["agent", "chat", "edit", "spec"] as const).map((m) => (
              <button
                key={m}
                className={`pill ${mode === m ? "active" : ""}`}
                onClick={() => setMode(m)}
              >
                {m.toUpperCase()}
              </button>
            ))}
          </div>

          <div className="clina-section-header">
            <span>
              <FolderTree size={13} /> Workspace Files ({fileItems.length})
            </span>
            <button
              className="btn-icon"
              title="Refresh workspace tree"
              onClick={loadWorkspace}
            >
              <RefreshCw size={12} />
            </button>
          </div>

          <div className="clina-file-tree">
            {fileItems.slice(0, 40).map((f) => {
              const isPinned = contextFiles.includes(f.relativePath);
              const isCurrent = activeFile === f.relativePath;
              return (
                <div
                  key={f.relativePath}
                  className={`clina-file-row ${isCurrent ? "active" : ""}`}
                >
                  <button
                    className="clina-file-open"
                    onClick={() => openFileInEditor(f.relativePath)}
                    title={f.relativePath}
                  >
                    <FileCode size={13} />
                    <span>{f.relativePath}</span>
                  </button>
                  <button
                    className={`clina-pin-btn ${isPinned ? "pinned" : ""}`}
                    onClick={() => toggleContextFile(f.relativePath)}
                    title={
                      isPinned
                        ? "Remove from @context"
                        : "Attach file to @context"
                    }
                  >
                    {isPinned ? "@ctx" : "+"}
                  </button>
                </div>
              );
            })}
          </div>

          <div className="clina-section-header" style={{ marginTop: "0.75rem" }}>
            <span>
              <Wrench size={13} /> MCP Tool Servers
            </span>
          </div>
          <div className="clina-mcp-list">
            {mcpTools.map((t) => (
              <label key={t.id} className="clina-mcp-item" title={t.description}>
                <input
                  type="checkbox"
                  checked={t.enabled}
                  onChange={() => toggleMcp(t.id)}
                />
                <span className="clina-mcp-name">{t.name}</span>
              </label>
            ))}
          </div>
        </div>
      </aside>

      {/* CENTER PANE: Code Editor & Unified Diff Inspector */}
      <section className="clina-editor-pane card">
        <div className="card-header">
          <div style={{ display: "flex", alignItems: "center", gap: "0.5rem" }}>
            <button
              className={`pill ${centerTab === "editor" ? "active" : ""}`}
              onClick={() => setCenterTab("editor")}
            >
              <FileCode size={13} /> {activeFile}
            </button>
            <button
              className={`pill ${centerTab === "diff" ? "active" : ""}`}
              onClick={() => setCenterTab("diff")}
            >
              <GitCompare size={13} /> Unified Diff{" "}
              {activeProposal ? `(${activeProposal.relativePath})` : ""}
            </button>
          </div>
          <div style={{ display: "flex", alignItems: "center", gap: "0.45rem" }}>
            {editorStatus && (
              <span className="badge badge-green">{editorStatus}</span>
            )}
            {centerTab === "editor" && (
              <button className="btn btn-sm btn-primary" onClick={saveActiveBuffer}>
                <Save size={13} /> Save (:w)
              </button>
            )}
            {activeProposal && (
              <button
                className="btn btn-sm btn-primary"
                onClick={() => applyProposal(activeProposal)}
              >
                <Check size={13} /> Apply Patch (ga)
              </button>
            )}
          </div>
        </div>

        {centerTab === "editor" ? (
          <div className="clina-editor-wrapper">
            <div className="clina-editor-meta">
              <span>
                Language: <strong>{editorLanguage}</strong> · Context pinned:{" "}
                <strong>{contextFiles.length} file(s)</strong>
              </span>
              <span>Neovim cmd: `:Clina edit &lt;instruction&gt;`</span>
            </div>
            <textarea
              className="clina-code-textarea"
              value={editorContent}
              onChange={(e) => setEditorContent(e.target.value)}
              spellCheck={false}
            />
          </div>
        ) : (
          <div className="clina-diff-wrapper">
            {activeProposal ? (
              <>
                <div className="clina-editor-meta">
                  <span>
                    Target: <strong>{activeProposal.relativePath}</strong> —{" "}
                    {activeProposal.description}
                  </span>
                  <button
                    className="btn btn-sm btn-primary"
                    onClick={() => applyProposal(activeProposal)}
                  >
                    <Check size={13} /> Write Patch to{" "}
                    {activeProposal.relativePath}
                  </button>
                </div>
                <pre className="code-block clina-diff-pre">
                  {activeProposal.diff.split("\n").map((line, i) => {
                    const cls = line.startsWith("+")
                      ? "diff-add"
                      : line.startsWith("-")
                      ? "diff-del"
                      : line.startsWith("@@")
                      ? "diff-hunk"
                      : "";
                    return (
                      <div key={i} className={cls}>
                        {line}
                      </div>
                    );
                  })}
                </pre>
              </>
            ) : (
              <div className="empty-state">
                Run a `:Clina` task on the right to generate a live unified diff
                and code patch.
              </div>
            )}
          </div>
        )}
      </section>

      {/* RIGHT PANE: Clina Agent Stream & Prompt Composer */}
      <section className="clina-chat-pane card">
        <div className="card-header">
          <span className="card-title">
            <Bot size={16} /> :Clina Agent Stream
          </span>
          <span className="badge badge-purple">{mode.toUpperCase()} MODE</span>
        </div>

        <div className="clina-quick-bar">
          {QUICK_PROMPTS.map((q) => (
            <button
              key={q.label}
              className="pill"
              onClick={() => sendPrompt(q.prompt, q.mode)}
            >
              <Sparkles size={11} /> {q.label}
            </button>
          ))}
        </div>

        <div className="clina-messages">
          {messages.map((m) => (
            <div key={m.id} className={`clina-msg clina-msg-${m.role}`}>
              <div className="clina-msg-header">
                <strong>
                  {m.role === "user" ? "You" : ":Clina TypeScript Agent"}
                </strong>
                <span>
                  {m.mode.toUpperCase()} · {m.model} · {m.timestamp}
                </span>
              </div>
              {m.steps && m.steps.length > 0 && (
                <div className="clina-steps">
                  {m.steps.map((s, idx) => (
                    <div key={idx} className="clina-step-chip">
                      <Terminal size={11} /> <code>[{s.tool}]</code> {s.detail}
                    </div>
                  ))}
                </div>
              )}
              <pre className="clina-msg-body">{m.content}</pre>
              <div className="clina-msg-actions">
                {m.proposal && (
                  <>
                    <button
                      className="btn btn-sm"
                      onClick={() => {
                        setActiveProposal(m.proposal!);
                        setCenterTab("diff");
                      }}
                    >
                      <GitCompare size={12} /> Inspect Diff
                    </button>
                    <button
                      className="btn btn-sm btn-primary"
                      onClick={() => applyProposal(m.proposal!)}
                    >
                      <Check size={12} /> Apply to {m.proposal.relativePath}
                    </button>
                  </>
                )}
                {m.specForm && (
                  <button
                    className="btn btn-sm"
                    onClick={() => onLoadSpecIntoModal(m.specForm!)}
                  >
                    <Plus size={12} /> Open in :Kaeru Spec Modal
                  </button>
                )}
              </div>
            </div>
          ))}
          {busy && (
            <div className="clina-msg clina-msg-assistant">
              ⏳ Clina TypeScript Agent is analyzing workspace and synthesizing
              patch…
            </div>
          )}
        </div>

        <div className="clina-composer">
          <div className="clina-context-bar">
            {contextFiles.map((cf) => (
              <span key={cf} className="badge badge-accent">
                @{cf.split("/").pop()}
              </span>
            ))}
          </div>
          <div className="clina-input-row">
            <textarea
              className="clina-prompt-input"
              rows={2}
              placeholder="Ask :Clina to write code, refactor the active buffer, or synthesize a lazy.nvim plugin spec…"
              value={prompt}
              onChange={(e) => setPrompt(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
                  e.preventDefault();
                  sendPrompt();
                }
              }}
            />
            <button
              className="btn btn-primary"
              disabled={busy}
              onClick={() => sendPrompt()}
            >
              <Play size={14} /> Run
              <ArrowRight size={13} />
            </button>
          </div>
        </div>
      </section>
    </div>
  );
}
