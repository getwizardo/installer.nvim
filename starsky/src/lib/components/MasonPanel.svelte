<script lang="ts">
	import { onMount } from 'svelte';
	import { api, type ApiResult } from '#lib/client/api';

	interface MasonPackage {
		name: string;
		description: string;
		homepage?: string;
		categories: string[];
		languages: string[];
		lspconfig: string | null;
		bin: string[];
	}
	interface MasonList extends ApiResult {
		total: number;
		packages: MasonPackage[];
	}

	const CATEGORIES = ['ALL', 'LSP', 'DAP', 'Linter', 'Formatter', 'Runtime', 'Compiler'];
	const PAGE = 40;

	let q = $state('');
	let category = $state('ALL');
	let language = $state('');
	let limit = $state(PAGE);
	let total = $state(0);
	let packages = $state<MasonPackage[]>([]);
	let selected = $state<Set<string>>(new Set());
	let source = $state<string | null>(null);
	let banner = $state<{ kind: 'ok' | 'err'; text: string } | null>(null);
	let loading = $state(false);

	let searchTimer: ReturnType<typeof setTimeout> | undefined;

	async function search() {
		loading = true;
		const params = new URLSearchParams({ q, category, language });
		const res = await api<MasonList>(`/api/mason?${params}`);
		loading = false;
		if (res.ok) {
			total = res.total;
			packages = res.packages;
		} else {
			banner = { kind: 'err', text: res.error ?? 'Registry lookup failed' };
		}
	}

	function onQuery() {
		limit = PAGE;
		clearTimeout(searchTimer);
		searchTimer = setTimeout(search, 200);
	}

	function toggle(name: string) {
		const next = new Set(selected);
		if (next.has(name)) next.delete(name);
		else next.add(name);
		selected = next;
	}

	async function build(save: boolean) {
		const names = [...selected];
		if (names.length === 0) {
			banner = { kind: 'err', text: 'Select at least one package' };
			return;
		}
		const res = await api<ApiResult & { source?: string; saved?: ApiResult & { relativePath?: string } }>(
			'/api/mason',
			{ packages: names, save }
		);
		if (!res.ok) {
			banner = { kind: 'err', text: res.error ?? 'Could not build the spec' };
			return;
		}
		source = res.source ?? null;
		banner = save
			? res.saved?.ok
				? { kind: 'ok', text: `Saved ${res.saved.relativePath}` }
				: { kind: 'err', text: res.saved?.error ?? 'Save failed' }
			: { kind: 'ok', text: `Generated a spec for ${names.length} package(s)` };
	}

	onMount(search);
</script>

<div class="split">
	<section class="card wide">
		<div class="card-head">
			<div>
				<h2>Mason registry</h2>
				<p class="muted small" style:margin="0">{total} packages · built-in catalog, works offline</p>
			</div>
			<span class="badge ok">{selected.size} selected</span>
		</div>

		<div class="stack">
			<input type="search" placeholder="Search name, lspconfig, language…" bind:value={q} oninput={onQuery} aria-label="Search Mason packages" />
			<div class="row">
				{#each CATEGORIES as c (c)}
					<button
						type="button"
						class="chip small"
						aria-pressed={category === c}
						onclick={() => {
							category = c;
							limit = PAGE;
							search();
						}}
					>
						{c}
					</button>
				{/each}
			</div>
			<input type="text" placeholder="Language filter, e.g. lua" bind:value={language} oninput={onQuery} aria-label="Language filter" />
		</div>

		{#if banner}
			<p class="banner {banner.kind}" role="status" style:margin="0.75rem 0">{banner.text}</p>
		{/if}

		<ul class="list" style:margin-top="0.75rem">
			{#each packages.slice(0, limit) as pkg (pkg.name)}
				<li>
					<label class="list-item" style:cursor="pointer">
						<input
							type="checkbox"
							checked={selected.has(pkg.name)}
							onchange={() => toggle(pkg.name)}
							style:width="22px"
							style:min-height="22px"
							style:margin="0"
						/>
						<span class="name">
							<strong>{pkg.name}</strong>
							{#if pkg.lspconfig}<span class="badge">lspconfig: {pkg.lspconfig}</span>{/if}
							<br />
							<span class="small muted">{pkg.categories.join(' · ')} — {pkg.description}</span>
						</span>
					</label>
				</li>
			{:else}
				<li class="muted small">{loading ? 'Searching…' : 'No packages match.'}</li>
			{/each}
		</ul>

		{#if packages.length > limit}
			<button type="button" class="ghost" style:margin-top="0.5rem" onclick={() => (limit += PAGE)}>
				Show more ({packages.length - limit} left)
			</button>
		{/if}
	</section>

	<section class="card">
		<h2>ensure_installed spec</h2>
		<p class="muted small">Writes a mason.nvim + mason-lspconfig.nvim spec for the selected packages.</p>
		<div class="row" style:margin="0.6rem 0">
			<button type="button" class="primary" onclick={() => build(false)}>Generate</button>
			<button type="button" class="success" onclick={() => build(true)}>Save mason-servers.lua</button>
			<button type="button" class="ghost" onclick={() => (selected = new Set())}>Clear</button>
		</div>
		{#if source}
			<pre class="code">{source}</pre>
		{/if}
	</section>
</div>
