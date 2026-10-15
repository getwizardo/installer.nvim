<script lang="ts">
	import { api, type ApiResult } from '#lib/client/api';
	import { openSpecDraft } from '#lib/client/ui.svelte';

	interface ParsedItem {
		form: Record<string, string>;
		spec_source: string;
	}
	interface ParseResult extends ApiResult {
		items?: ParsedItem[];
	}

	let snippet = $state('');
	let repo = $state('');
	let items = $state<ParsedItem[]>([]);
	let banner = $state<{ kind: 'ok' | 'err'; text: string } | null>(null);
	let busy = $state(false);

	async function parse(body: { text?: string; repo?: string }) {
		busy = true;
		banner = null;
		const res = await api<ParseResult>('/api/parse', body);
		busy = false;
		if (res.ok && res.items?.length) {
			items = res.items;
			banner = { kind: 'ok', text: `Found ${res.items.length} plugin spec(s)` };
		} else {
			items = [];
			banner = { kind: 'err', text: res.error ?? 'No plugin specs found' };
		}
	}

	function parsePaste() {
		if (!snippet.trim()) return;
		parse({ text: snippet });
	}

	function parseRepo() {
		if (!repo.includes('/')) {
			banner = { kind: 'err', text: 'Use owner/repo' };
			return;
		}
		parse({ repo: repo.trim() });
	}
</script>

<div class="split">
	<section class="card wide">
		<h2>Installer snippet parser</h2>
		<p class="muted small">
			Understands lazy.nvim, packer, vim-plug, pckr, mini.deps, vim.pack, paq, dein, Vundle, rocks.nvim,
			<code>git clone</code>, <code>:MasonInstall</code> and <code>require(...).setup(...)</code>.
		</p>

		<div class="split" style:margin-top="0.6rem">
			<form
				class="stack"
				onsubmit={(e) => {
					e.preventDefault();
					parseRepo();
				}}
			>
				<label class="field">
					<span>GitHub README</span>
					<input type="text" placeholder="owner/repo" bind:value={repo} autocapitalize="off" />
				</label>
				<button type="submit" disabled={busy || !repo.trim()}>Fetch &amp; parse README</button>
			</form>

			<form
				class="stack"
				onsubmit={(e) => {
					e.preventDefault();
					parsePaste();
				}}
			>
				<label class="field">
					<span>Pasted snippet</span>
					<textarea rows="6" class="mono" placeholder={'{ "folke/noice.nvim", event = "VeryLazy" }'} bind:value={snippet}></textarea>
				</label>
				<button class="primary" type="submit" disabled={busy || !snippet.trim()}>{busy ? 'Parsing…' : 'Parse snippet'}</button>
			</form>
		</div>

		{#if banner}
			<p class="banner {banner.kind}" role="status" style:margin-top="0.75rem">{banner.text}</p>
		{/if}
	</section>

	{#each items as item, i (i)}
		<section class="card">
			<div class="card-head">
				<h3>{item.form.repo ?? 'plugin'}</h3>
				<button type="button" class="success" onclick={() => openSpecDraft(item.form)}>Open in spec builder</button>
			</div>
			<pre class="code">{item.spec_source}</pre>
		</section>
	{/each}
</div>
