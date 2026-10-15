import { NextRequest, NextResponse } from "next/server";
import {
  getSftpProfiles,
  saveSftpProfile,
  listLocalDirectory,
  listRemoteDirectory,
  uploadToRemote,
  downloadFromRemote,
  syncProjectToRemote,
  createSftpDirectory,
  deleteSftpEntry,
  renameSftpEntry,
  diffLocalAndRemote,
  executeRemoteSshCommand,
  getTransferHistory,
} from "@/lib/sftpEngine";
import { readWorkspaceFile } from "@/lib/clina";

export const dynamic = "force-dynamic";

export async function GET(req: NextRequest) {
  const sp = req.nextUrl.searchParams;
  const profileName = sp.get("profile") || "";
  const localDir = sp.get("localDir") || undefined;
  const remoteDir = sp.get("remoteDir") || undefined;

  const profiles = getSftpProfiles();
  const activeProfile =
    profiles.find((p) => p.name === profileName) || profiles[0];
  const local = listLocalDirectory(localDir);
  const remote = listRemoteDirectory(activeProfile, remoteDir);

  return NextResponse.json({
    ok: true,
    profiles,
    activeProfile,
    local,
    remote,
    history: getTransferHistory(),
  });
}

export async function POST(req: NextRequest) {
  try {
    const body = await req.json();
    const action = String(body.action || "");
    const profiles = getSftpProfiles();
    const profile =
      profiles.find((p) => p.name === body.profile) || profiles[0];

    if (action === "saveProfile") {
      const updated = saveSftpProfile(body.profileData || {});
      return NextResponse.json({
        ok: true,
        profiles: updated,
        message: `Saved SFTP profile "${body.profileData?.name || "default"}" to sftp.json`,
      });
    }

    if (action === "upload") {
      const res = uploadToRemote(
        profile,
        String(body.localPath || ""),
        String(body.remoteDir || profile.remotePath)
      );
      return NextResponse.json({
        ...res,
        remote: listRemoteDirectory(profile, body.remoteDir),
        history: getTransferHistory(),
      });
    }

    if (action === "download") {
      const res = downloadFromRemote(
        profile,
        String(body.remotePath || ""),
        String(body.localDir || "")
      );
      return NextResponse.json({
        ...res,
        local: listLocalDirectory(body.localDir),
        history: getTransferHistory(),
      });
    }

    if (action === "sync") {
      const res = syncProjectToRemote(
        profile,
        String(body.localDir || ""),
        String(body.remoteDir || profile.remotePath)
      );
      return NextResponse.json({
        ...res,
        remote: listRemoteDirectory(profile, body.remoteDir),
        history: getTransferHistory(),
      });
    }

    if (action === "mkdir") {
      const side = body.side === "remote" ? "remote" : "local";
      const res = createSftpDirectory(
        profile,
        side,
        String(body.parentDir || ""),
        String(body.name || "new-folder")
      );
      return NextResponse.json({
        ...res,
        local: listLocalDirectory(body.localDir),
        remote: listRemoteDirectory(profile, body.remoteDir),
        history: getTransferHistory(),
      });
    }

    if (action === "delete") {
      const side = body.side === "remote" ? "remote" : "local";
      const res = deleteSftpEntry(profile, side, String(body.targetPath || ""));
      return NextResponse.json({
        ...res,
        local: listLocalDirectory(body.localDir),
        remote: listRemoteDirectory(profile, body.remoteDir),
        history: getTransferHistory(),
      });
    }

    if (action === "rename") {
      const side = body.side === "remote" ? "remote" : "local";
      const res = renameSftpEntry(
        profile,
        side,
        String(body.targetPath || ""),
        String(body.newName || "")
      );
      return NextResponse.json({
        ...res,
        local: listLocalDirectory(body.localDir),
        remote: listRemoteDirectory(profile, body.remoteDir),
        history: getTransferHistory(),
      });
    }

    if (action === "diff") {
      return NextResponse.json(
        diffLocalAndRemote(
          String(body.localPath || ""),
          String(body.remotePath || "")
        )
      );
    }

    if (action === "read") {
      return NextResponse.json(readWorkspaceFile(String(body.path || "")));
    }

    if (action === "ssh") {
      const res = executeRemoteSshCommand(
        profile,
        String(body.command || "ls -la"),
        body.remoteDir
      );
      return NextResponse.json({
        ...res,
        remote: listRemoteDirectory(profile, body.remoteDir),
        history: getTransferHistory(),
      });
    }

    return NextResponse.json(
      { ok: false, error: `Unknown SFTP action: ${action}` },
      { status: 400 }
    );
  } catch (err) {
    return NextResponse.json(
      { ok: false, error: err instanceof Error ? err.message : String(err) },
      { status: 400 }
    );
  }
}
