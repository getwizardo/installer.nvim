import { NextResponse } from "next/server";
import masonRegistry from "@/data/masonRegistry.json";
import { getRepoRoot, getDefaultPluginsDir, listSavedSpecs } from "@/lib/luaBridge";
import { getProviders, CLINA_MCP_TOOLS } from "@/lib/clina";
import { getSftpProfiles } from "@/lib/sftpEngine";

export const dynamic = "force-dynamic";

export async function GET() {
  const lspconfigCount = masonRegistry.packages.filter(
    (p) => Boolean(p.lspconfig)
  ).length;
  return NextResponse.json({
    ok: true,
    service: "Starsky for Neovim · Next.js TypeScript Webclient",
    framework: "Next.js 16 (App Router · TypeScript)",
    repoRoot: getRepoRoot(),
    pluginsDir: getDefaultPluginsDir(),
    masonCount: masonRegistry.total,
    lspconfigCount,
    savedSpecsCount: listSavedSpecs().length,
    clinaProviders: getProviders(),
    clinaMcpCount: CLINA_MCP_TOOLS.length,
    sftpProfilesCount: getSftpProfiles().length,
  });
}
