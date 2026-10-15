import { json } from '@sveltejs/kit';
import masonRegistry from '#lib/server/data/masonRegistry.json';
import { getRepoRoot, getDefaultPluginsDir, listSavedSpecs } from '#lib/server/luaBridge';
import { getProviders, CLINA_MCP_TOOLS } from '#lib/server/clina';
import { getSftpProfiles } from '#lib/server/sftpEngine';
import { nvimStatus } from '#lib/server/nvim';

export const prerender = false;

export function GET() {
	const lspconfigCount = masonRegistry.packages.filter((p) => Boolean(p.lspconfig)).length;
	return json({
		ok: true,
		service: 'Starsky for Neovim · SvelteKit TypeScript Webclient',
		framework: 'SvelteKit 3 (Vite · TypeScript · adapter-node)',
		neovim: nvimStatus(),
		repoRoot: getRepoRoot(),
		pluginsDir: getDefaultPluginsDir(),
		masonCount: masonRegistry.total,
		lspconfigCount,
		savedSpecsCount: listSavedSpecs().length,
		clinaProviders: getProviders(),
		clinaMcpCount: CLINA_MCP_TOOLS.length,
		sftpProfilesCount: getSftpProfiles().length
	});
}
