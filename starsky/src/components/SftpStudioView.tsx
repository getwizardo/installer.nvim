"use client";

import React, { useState, useEffect } from "react";
import {
  HardDrive,
  Globe,
  Upload,
  Download,
  RefreshCw,
  FolderPlus,
  Trash2,
  GitCompare,
  Terminal,
  Folder,
  FileText,
  ArrowUp,
  Plus,
  Check,
  Edit3,
} from "lucide-react";

interface SftpProfile {
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

interface SftpEntry {
  name: string;
  path: string;
  type: "dir" | "file" | "link";
  size: number;
  permissions: string;
  mtime: string;
}

interface SftpTransferRecord {
  id: string;
  direction: string;
  source: string;
  destination: string;
  profile: string;
  status: "success" | "error";
  message: string;
  timestamp: string;
}

export default function SftpStudioView() {
  const [profiles, setProfiles] = useState<SftpProfile[]>([]);
  const [selectedProfile, setSelectedProfile] =
    useState<string>("staging-sandbox");
  const [localCwd, setLocalCwd] = useState<string>("");
  const [remoteCwd, setRemoteCwd] = useState<string>("");
  const [localEntries, setLocalEntries] = useState<SftpEntry[]>([]);
  const [remoteEntries, setRemoteEntries] = useState<SftpEntry[]>([]);
  const [history, setHistory] = useState<SftpTransferRecord[]>([]);
  const [statusMessage, setStatusMessage] = useState<string>(
    "Connected to SFTP Studio"
  );
  const [diffOutput, setDiffOutput] = useState<string>("");
  const [sshCommand, setSshCommand] = useState<string>("ls -la");
  const [sshOutput, setSshOutput] = useState<string>("");
  const [showProfileEditor, setShowProfileEditor] = useState<boolean>(false);
  const [newProfile, setNewProfile] = useState({
    name: "production-server",
    host: "sandbox.local",
    port: "22",
    username: "deploy",
    remotePath: "/tmp/kaeru-sftp-remote",
    uploadOnSave: true,
  });

  const loadSftpState = async (
    prof = selectedProfile,
    lDir = localCwd,
    rDir = remoteCwd
  ) => {
    try {
      const qs = new URLSearchParams({
        profile: prof,
        ...(lDir ? { localDir: lDir } : {}),
        ...(rDir ? { remoteDir: rDir } : {}),
      });
      const res = await fetch(`/api/sftp?${qs.toString()}`);
      const data = await res.json();
      if (data.ok) {
        setProfiles(data.profiles || []);
        if (data.local) {
          setLocalCwd(data.local.cwd);
          setLocalEntries(data.local.entries || []);
        }
        if (data.remote) {
          setRemoteCwd(data.remote.cwd);
          setRemoteEntries(data.remote.entries || []);
        }
        setHistory(data.history || []);
      }
    } catch {
      // ignore
    }
  };

  useEffect(() => {
    loadSftpState("staging-sandbox", "", "");
  }, []);

  const currentProfileObj =
    profiles.find((p) => p.name === selectedProfile) || profiles[0];

  const handleUpload = async (entry: SftpEntry) => {
    setStatusMessage(`Uploading ${entry.name}…`);
    const res = await fetch("/api/sftp", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        action: "upload",
        profile: selectedProfile,
        localPath: entry.path,
        remoteDir: remoteCwd,
      }),
    });
    const data = await res.json();
    setStatusMessage(data.message || "Upload finished");
    if (data.remote) setRemoteEntries(data.remote.entries || []);
    if (data.history) setHistory(data.history);
  };

  const handleDownload = async (entry: SftpEntry) => {
    setStatusMessage(`Downloading ${entry.name}…`);
    const res = await fetch("/api/sftp", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        action: "download",
        profile: selectedProfile,
        remotePath: entry.path,
        localDir: localCwd,
      }),
    });
    const data = await res.json();
    setStatusMessage(data.message || "Download finished");
    if (data.local) setLocalEntries(data.local.entries || []);
    if (data.history) setHistory(data.history);
  };

  const handleSync = async () => {
    setStatusMessage("Syncing lua/plugins specs to remote server…");
    const res = await fetch("/api/sftp", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        action: "sync",
        profile: selectedProfile,
        localDir: localCwd,
        remoteDir: remoteCwd,
      }),
    });
    const data = await res.json();
    setStatusMessage(data.message || "Sync complete");
    if (data.remote) setRemoteEntries(data.remote.entries || []);
    if (data.history) setHistory(data.history);
  };

  const handleMkdir = async (side: "local" | "remote") => {
    const folderName = `dir-${Math.floor(100 + Math.random() * 900)}`;
    const res = await fetch("/api/sftp", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        action: "mkdir",
        profile: selectedProfile,
        side,
        parentDir: side === "local" ? localCwd : remoteCwd,
        localDir: localCwd,
        remoteDir: remoteCwd,
        name: folderName,
      }),
    });
    const data = await res.json();
    setStatusMessage(data.message || `Created ${folderName}`);
    if (data.local) setLocalEntries(data.local.entries || []);
    if (data.remote) setRemoteEntries(data.remote.entries || []);
    if (data.history) setHistory(data.history);
  };

  const handleDelete = async (side: "local" | "remote", entry: SftpEntry) => {
    const res = await fetch("/api/sftp", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        action: "delete",
        profile: selectedProfile,
        side,
        targetPath: entry.path,
        localDir: localCwd,
        remoteDir: remoteCwd,
      }),
    });
    const data = await res.json();
    setStatusMessage(data.message || `Deleted ${entry.name}`);
    if (data.local) setLocalEntries(data.local.entries || []);
    if (data.remote) setRemoteEntries(data.remote.entries || []);
    if (data.history) setHistory(data.history);
  };

  const handleDiff = async (entry: SftpEntry, side: "local" | "remote") => {
    const localTarget =
      side === "local" ? entry.path : `${localCwd}/${entry.name}`;
    const remoteTarget =
      side === "remote" ? entry.path : `${remoteCwd}/${entry.name}`;
    const res = await fetch("/api/sftp", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        action: "diff",
        localPath: localTarget,
        remotePath: remoteTarget,
      }),
    });
    const data = await res.json();
    if (data.ok) {
      setDiffOutput(data.diff);
      setStatusMessage(`Compared local vs remote for ${entry.name}`);
    }
  };

  const handleRunSsh = async () => {
    if (!sshCommand.trim()) return;
    const res = await fetch("/api/sftp", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        action: "ssh",
        profile: selectedProfile,
        command: sshCommand,
        remoteDir: remoteCwd,
      }),
    });
    const data = await res.json();
    setSshOutput(data.output || "");
    if (data.remote) setRemoteEntries(data.remote.entries || []);
    if (data.history) setHistory(data.history);
  };

  const handleSaveProfile = async () => {
    const res = await fetch("/api/sftp", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        action: "saveProfile",
        profileData: {
          name: newProfile.name,
          host: newProfile.host,
          port: Number(newProfile.port || 22),
          username: newProfile.username,
          remotePath: newProfile.remotePath,
          uploadOnSave: newProfile.uploadOnSave,
        },
      }),
    });
    const data = await res.json();
    if (data.ok) {
      setProfiles(data.profiles || []);
      setSelectedProfile(newProfile.name);
      setShowProfileEditor(false);
      setStatusMessage(data.message);
      loadSftpState(newProfile.name, localCwd, newProfile.remotePath);
    }
  };

  const goUp = (side: "local" | "remote") => {
    if (side === "local") {
      const parent = localCwd.split("/").slice(0, -1).join("/") || "/";
      loadSftpState(selectedProfile, parent, remoteCwd);
    } else {
      const parent = remoteCwd.split("/").slice(0, -1).join("/") || "/";
      loadSftpState(selectedProfile, localCwd, parent);
    }
  };

  return (
    <div className="sftp-studio-container">
      {/* TOP BAR: Profile Selector, Connection Info & Actions */}
      <div className="card sftp-top-bar">
        <div className="sftp-profile-row">
          <div style={{ display: "flex", alignItems: "center", gap: "0.6rem" }}>
            <Globe size={16} color="var(--accent)" />
            <strong>SFTP Profile:</strong>
            <select
              className="select-input"
              value={selectedProfile}
              onChange={(e) => {
                setSelectedProfile(e.target.value);
                loadSftpState(e.target.value, localCwd, "");
              }}
            >
              {profiles.map((p) => (
                <option key={p.name} value={p.name}>
                  {p.name} ({p.username}@{p.host}:{p.port} → {p.remotePath})
                </option>
              ))}
            </select>
            {currentProfileObj && (
              <span className="badge badge-green">
                {currentProfileObj.uploadOnSave
                  ? "uploadOnSave: ON"
                  : "uploadOnSave: OFF"}
              </span>
            )}
          </div>

          <div style={{ display: "flex", alignItems: "center", gap: "0.5rem" }}>
            <span className="badge badge-accent">{statusMessage}</span>
            <button className="btn btn-sm btn-primary" onClick={handleSync}>
              <Upload size={13} /> Sync Plugins → Remote
            </button>
            <button
              className="btn btn-sm"
              onClick={() => setShowProfileEditor(!showProfileEditor)}
            >
              <Plus size={13} /> {showProfileEditor ? "Close" : "Add / Edit sftp.json"}
            </button>
            <button
              className="btn btn-sm"
              onClick={() => loadSftpState(selectedProfile, localCwd, remoteCwd)}
            >
              <RefreshCw size={13} /> Refresh
            </button>
          </div>
        </div>

        {showProfileEditor && (
          <div className="sftp-profile-editor">
            <input
              className="search-input"
              placeholder="Profile name"
              value={newProfile.name}
              onChange={(e) =>
                setNewProfile({ ...newProfile, name: e.target.value })
              }
            />
            <input
              className="search-input"
              placeholder="Host (e.g. example.com)"
              value={newProfile.host}
              onChange={(e) =>
                setNewProfile({ ...newProfile, host: e.target.value })
              }
            />
            <input
              className="search-input"
              style={{ width: "80px" }}
              placeholder="Port"
              value={newProfile.port}
              onChange={(e) =>
                setNewProfile({ ...newProfile, port: e.target.value })
              }
            />
            <input
              className="search-input"
              placeholder="Username"
              value={newProfile.username}
              onChange={(e) =>
                setNewProfile({ ...newProfile, username: e.target.value })
              }
            />
            <input
              className="search-input"
              placeholder="Remote path"
              value={newProfile.remotePath}
              onChange={(e) =>
                setNewProfile({ ...newProfile, remotePath: e.target.value })
              }
            />
            <button className="btn btn-sm btn-primary" onClick={handleSaveProfile}>
              <Check size={13} /> Save to sftp.json
            </button>
          </div>
        )}
      </div>

      {/* DUAL PANE EXPLORER: Left Local Project <-> Right Remote SFTP Server */}
      <div className="sftp-dual-grid">
        {/* LEFT PANE: LOCAL PROJECT */}
        <div className="card sftp-pane">
          <div className="card-header">
            <span className="card-title">
              <HardDrive size={15} /> Local Project Explorer
            </span>
            <div style={{ display: "flex", gap: "0.35rem" }}>
              <button
                className="btn btn-sm"
                onClick={() => goUp("local")}
                title="Parent directory (-)"
              >
                <ArrowUp size={12} /> Up
              </button>
              <button
                className="btn btn-sm"
                onClick={() => handleMkdir("local")}
                title="Create local directory (m)"
              >
                <FolderPlus size={12} /> Mkdir
              </button>
            </div>
          </div>

          <div className="sftp-path-bar">{localCwd}</div>

          <div className="sftp-entry-list">
            {localEntries.map((entry) => (
              <div key={entry.path} className="sftp-entry-row">
                <div
                  className="sftp-entry-main"
                  onClick={() => {
                    if (entry.type === "dir") {
                      loadSftpState(selectedProfile, entry.path, remoteCwd);
                    }
                  }}
                >
                  {entry.type === "dir" ? (
                    <Folder size={14} color="var(--accent)" />
                  ) : (
                    <FileText size={14} color="var(--text-secondary)" />
                  )}
                  <span className="sftp-entry-name">
                    {entry.name}
                    {entry.type === "dir" ? "/" : ""}
                  </span>
                </div>

                <div className="sftp-entry-meta">
                  <code>{entry.permissions}</code>
                  <span>
                    {entry.type === "dir" ? "DIR" : `${entry.size} B`}
                  </span>
                  <button
                    className="btn btn-sm btn-primary"
                    title="Upload to Remote Server (u)"
                    onClick={() => handleUpload(entry)}
                  >
                    <Upload size={11} /> Upload
                  </button>
                  {entry.type === "file" && (
                    <button
                      className="btn btn-sm"
                      title="Diff against Remote counterpart (D)"
                      onClick={() => handleDiff(entry, "local")}
                    >
                      <GitCompare size={11} />
                    </button>
                  )}
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* RIGHT PANE: REMOTE SERVER */}
        <div className="card sftp-pane">
          <div className="card-header">
            <span className="card-title">
              <Globe size={15} /> Remote SFTP Server (
              {currentProfileObj?.host || "remote"})
            </span>
            <div style={{ display: "flex", gap: "0.35rem" }}>
              <button
                className="btn btn-sm"
                onClick={() => goUp("remote")}
                title="Parent remote directory (-)"
              >
                <ArrowUp size={12} /> Up
              </button>
              <button
                className="btn btn-sm"
                onClick={() => handleMkdir("remote")}
                title="Create remote directory (m)"
              >
                <FolderPlus size={12} /> Mkdir
              </button>
            </div>
          </div>

          <div className="sftp-path-bar">{remoteCwd}</div>

          <div className="sftp-entry-list">
            {remoteEntries.map((entry) => (
              <div key={entry.path} className="sftp-entry-row">
                <div
                  className="sftp-entry-main"
                  onClick={() => {
                    if (entry.type === "dir") {
                      loadSftpState(selectedProfile, localCwd, entry.path);
                    }
                  }}
                >
                  {entry.type === "dir" ? (
                    <Folder size={14} color="var(--green)" />
                  ) : (
                    <FileText size={14} color="var(--text-secondary)" />
                  )}
                  <span className="sftp-entry-name">
                    {entry.name}
                    {entry.type === "dir" ? "/" : ""}
                  </span>
                </div>

                <div className="sftp-entry-meta">
                  <code>{entry.permissions}</code>
                  <span>
                    {entry.type === "dir" ? "DIR" : `${entry.size} B`}
                  </span>
                  <button
                    className="btn btn-sm"
                    title="Download to Local Project (d)"
                    onClick={() => handleDownload(entry)}
                  >
                    <Download size={11} /> Download
                  </button>
                  {entry.type === "file" && (
                    <button
                      className="btn btn-sm"
                      title="Diff against Local counterpart (D)"
                      onClick={() => handleDiff(entry, "remote")}
                    >
                      <GitCompare size={11} />
                    </button>
                  )}
                  <button
                    className="btn btn-sm"
                    title="Delete remote entry (x)"
                    onClick={() => handleDelete("remote", entry)}
                  >
                    <Trash2 size={11} />
                  </button>
                </div>
              </div>
            ))}
          </div>
        </div>
      </div>

      {/* BOTTOM ROW: Remote SSH Runner, Diff Output & Transfer Activity Log */}
      <div className="sftp-bottom-grid">
        <div className="card">
          <div className="card-header">
            <span className="card-title">
              <Terminal size={15} /> Remote SSH Command Runner & Diff Inspector
            </span>
            <span className="badge badge-purple">:Kaeru sftp ui</span>
          </div>
          <div className="card-body">
            <div style={{ display: "flex", gap: "0.5rem", marginBottom: "0.6rem" }}>
              <input
                className="search-input"
                style={{ flex: 1 }}
                value={sshCommand}
                onChange={(e) => setSshCommand(e.target.value)}
                placeholder="Remote shell command (e.g. ls -la, uname -a, df -h)"
                onKeyDown={(e) => e.key === "Enter" && handleRunSsh()}
              />
              <button className="btn btn-primary btn-sm" onClick={handleRunSsh}>
                <Terminal size={13} /> Execute SSH
              </button>
            </div>
            <pre className="code-block" style={{ maxHeight: "150px" }}>
              {diffOutput ||
                sshOutput ||
                "Click Upload/Download/Diff above or run an SSH command to inspect output."}
            </pre>
          </div>
        </div>

        <div className="card">
          <div className="card-header">
            <span className="card-title">
              <Edit3 size={15} /> SFTP Transfer Queue & Audit Log ({history.length})
            </span>
          </div>
          <div
            className="card-body"
            style={{ maxHeight: "195px", overflowY: "auto" }}
          >
            {history.length === 0 ? (
              <div style={{ color: "var(--text-muted)", fontSize: "0.8rem" }}>
                No transfers yet in this session — click Upload, Download, or
                Sync Plugins above.
              </div>
            ) : (
              history.map((item) => (
                <div key={item.id} className="sftp-log-row">
                  <span
                    className={`badge ${
                      item.status === "success" ? "badge-green" : "badge-amber"
                    }`}
                  >
                    {item.direction.toUpperCase()}
                  </span>
                  <span className="sftp-log-msg">{item.message}</span>
                  <span className="sftp-log-time">{item.timestamp}</span>
                </div>
              ))
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
