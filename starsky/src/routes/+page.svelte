<script lang="ts">
	import { onMount } from 'svelte';
	import { api, type ApiResult } from '#lib/client/api';
	import IdePanel from '#lib/components/IdePanel.svelte';
	import MusicPanel from '#lib/components/MusicPanel.svelte';
	import SpecPanel from '#lib/components/SpecPanel.svelte';
	import MasonPanel from '#lib/components/MasonPanel.svelte';
	import SftpPanel from '#lib/components/SftpPanel.svelte';
	import ParserPanel from '#lib/components/ParserPanel.svelte';
	import GithubPanel from '#lib/components/GithubPanel.svelte';
	import Icon from '#lib/components/Icon.svelte';

	import { ui, type TabId } from '#lib/client/ui.svelte';
	import type { SolarIconName } from '#lib/client/solar';

	const TABS: { id: TabId; label: string; icon: SolarIconName }[] = [
		{ id: 'ide', label: 'IDE', icon: 'code-square-linear' },
		{ id: 'music', label: 'Music', icon: 'music-note-2-linear' },
		{ id: 'spec', label: 'Spec', icon: 'add-square-linear' },
		{ id: 'mason', label: 'Mason', icon: 'box-linear' },
		{ id: 'sftp', label: 'SFTP', icon: 'cloud-upload-linear' },
		{ id: 'parser', label: 'Parser', icon: 'document-text-linear' },
		{ id: 'github', label: 'GitHub', icon: 'global-linear' }
	];

	interface Status extends ApiResult {
		ok: boolean;
		service?: string;
		framework?: string;
		neovim?: { available: boolean; cmd: string | null; remote: string | null };
		repoRoot?: string;
		masonCount?: number;
		savedSpecsCount?: number;
		error?: string;
	}

	let status = $state<Status | null>(null);

	function select(id: TabId) {
		ui.tab = id;
		history.replaceState(null, '', `#${id}`);
	}

	onMount(() => {
		const fromHash = location.hash.replace('#', '') as TabId;
		if (TABS.some((t) => t.id === fromHash)) ui.tab = fromHash;
		api<Status>('/api/status').then((s) => (status = s));
	});
</script>

<svelte:head>
	<title>Starsky for Neovim · SvelteKit webclient</title>
	<meta
		name="description"
		content="Starsky for Neovim: mobile-first SvelteKit webclient for kaeru.nvim with a minimal web IDE on remote Neovim, Kikru music, lazy.nvim spec builder, Mason, SFTP, README parser and GitHub browser."
	/>
</svelte:head>

<div class="app">
	<header class="topbar">
		<div class="brand">
			Starsky for Neovim
			<small>{status?.framework ?? 'SvelteKit · TypeScript webclient'}</small>
		</div>
		{#if status?.ok}
			<span class="badge {status.neovim?.available ? 'ok' : 'warn'}" title={status.neovim?.cmd ?? ''}>
				{status.neovim?.remote ? 'remote nvim' : status.neovim?.available ? 'nvim · node client' : 'nvim missing · TS fallback'}
			</span>
		{:else if status && !status.ok}
			<span class="badge err">API offline</span>
		{/if}
	</header>

	<nav class="tabbar" aria-label="Sections">
		{#each TABS as tab (tab.id)}
			<button
				type="button"
				aria-current={ui.tab === tab.id ? 'page' : undefined}
				onclick={() => select(tab.id)}
			>
				<span class="ico"><Icon name={tab.icon} size={20} /></span>
				<span>{tab.label}</span>
			</button>
		{/each}
	</nav>

	<main class="stage">
		{#if ui.tab === 'ide'}
			<IdePanel />
		{:else if ui.tab === 'music'}
			<MusicPanel />
		{:else if ui.tab === 'spec'}
			<SpecPanel />
		{:else if ui.tab === 'mason'}
			<MasonPanel />
		{:else if ui.tab === 'sftp'}
			<SftpPanel />
		{:else if ui.tab === 'parser'}
			<ParserPanel />
		{:else}
			<GithubPanel />
		{/if}
	</main>
</div>
