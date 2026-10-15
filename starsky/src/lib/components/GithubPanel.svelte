<script lang="ts">
	import { onMount } from 'svelte';
	import { api, formatStars, type ApiResult } from '#lib/client/api';
	import { openSpecDraft } from '#lib/client/ui.svelte';
	import Icon from '#lib/components/Icon.svelte';

	interface RepoItem {
		full_name: string;
		description: string;
		stars: number;
		html_url: string;
		topics: string[];
		updated_at: string;
	}
	interface SearchResult extends ApiResult {
		items?: RepoItem[];
	}

	let query = $state('');
	let items = $state<RepoItem[]>([]);
	let readme = $state<{ repo: string; text: string } | null>(null);
	let banner = $state<{ kind: 'ok' | 'err'; text: string } | null>(null);
	let loading = $state(false);

	async function search() {
		loading = true;
		banner = null;
		const q = query.trim() || 'topic:neovim-plugin';
		const res = await api<SearchResult>(`/api/github?action=search&q=${encodeURIComponent(q)}`);
		loading = false;
		if (res.ok) {
			items = res.items ?? [];
			if (items.length === 0) banner = { kind: 'err', text: 'No repositories found' };
		} else {
			banner = { kind: 'err', text: res.error ?? 'GitHub search failed' };
		}
	}

	async function showReadme(repo: string) {
		loading = true;
		const res = await api<ApiResult & { readme?: string }>(`/api/github?action=readme&repo=${encodeURIComponent(repo)}`);
		loading = false;
		if (res.ok && res.readme) {
			readme = { repo, text: res.readme.slice(0, 6000) };
		} else {
			banner = { kind: 'err', text: res.error ?? `No README for ${repo}` };
		}
	}

	onMount(search);
</script>

<div class="split">
	<section class="card wide">
		<form
			class="row"
			onsubmit={(e) => {
				e.preventDefault();
				search();
			}}
		>
			<input type="search" placeholder="Search Neovim plugins (default: topic:neovim-plugin)" bind:value={query} aria-label="Search GitHub" style:flex="1" style:min-width="0" />
			<button class="primary" type="submit" disabled={loading}>{loading ? 'Searching…' : 'Search'}</button>
		</form>
		{#if banner}
			<p class="banner {banner.kind}" role="status" style:margin-top="0.75rem">{banner.text}</p>
		{/if}
	</section>

	<section class="card">
		<h2>Results</h2>
		<ul class="list" style:max-height="560px" style:overflow="auto">
			{#each items as item (item.full_name)}
				<li class="card" style:padding="0.6rem">
					<div class="card-head" style:margin="0">
						<strong style:overflow-wrap="anywhere">{item.full_name}</strong>
						<span class="badge"><Icon name="star-linear" size={14} /> {formatStars(item.stars)}</span>
					</div>
					<p class="small muted" style:margin="0.25rem 0 0.5rem">{item.description}</p>
					<div class="row">
						<button type="button" class="success" onclick={() => openSpecDraft({ repo: item.full_name })}>Spec</button>
						<button type="button" onclick={() => showReadme(item.full_name)}>README</button>
						<a class="small" href={item.html_url} target="_blank" rel="noreferrer noopener">GitHub ↗</a>
					</div>
				</li>
			{/each}
		</ul>
	</section>

	<section class="card">
		<h2>README preview</h2>
		{#if readme}
			<p class="small muted" style:margin="0 0 0.5rem">{readme.repo} · first 6000 characters</p>
			<pre class="code" style:max-height="560px">{readme.text}</pre>
		{:else}
			<p class="muted small">Pick a repository and tap README.</p>
		{/if}
	</section>
</div>
