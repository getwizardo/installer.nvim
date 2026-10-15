import { json } from '@sveltejs/kit';
import masonRegistry from '#lib/server/data/masonRegistry.json';
import { getRepoRoot, resolvePluginsDir, listSavedSpecs } from '#lib/server/luaBridge';
import { getSftpProfiles } from '#lib/server/sftpEngine';
import { nvimStatus } from '#lib/server/nvim';

export const prerender = false;

export async function GET() {
	const lspconfigCount = masonRegistry.packages.filter((p) => Boolean(p.lspconfig)).length;
	return json({
		ok: true,
		service: 'Starsky for Neovim · SvelteKit TypeScript Webclient',
		framework: 'SvelteKit 3 (Vite · TypeScript · adapter-node)',
		neovim: nvimStatus(),
		repoRoot: getRepoRoot(),
		pluginsDir: await resolvePluginsDir(),
		masonCount: masonRegistry.total,
		lspconfigCount,
		savedSpecsCount: (await listSavedSpecs()).length,
		sftpProfilesCount: getSftpProfiles().length
	});
}
