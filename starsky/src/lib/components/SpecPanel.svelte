<script lang="ts">
	import { onMount } from 'svelte';
	import { api, type ApiResult } from '#lib/client/api';
	import type { KaeruForm, GeneratedSpec, SavedSpecFile } from '#lib/server/luaBridge';
	import { ui } from '#lib/client/ui.svelte';
	import Icon from '#lib/components/Icon.svelte';

	type Field = {
		key: keyof KaeruForm;
		label: string;
		hint: string;
		kind?: 'text' | 'bool' | 'lua';
	};

	// Mirrors the `:Kaeru` modal (lua/kaeru/form.lua), field by field.
	const FIELDS: Field[] = [
		{ key: 'repo', label: 'Repository', hint: 'owner/repo or a git URL (required)' },
		{ key: 'file', label: 'File', hint: 'lua/plugins/<file>.lua (auto from repo)' },
		{ key: 'name', label: 'Name', hint: 'custom plugin name (optional)' },
		{ key: 'lazy', label: 'Lazy', hint: 'true / false', kind: 'bool' },
		{ key: 'event', label: 'Event', hint: 'VeryLazy, BufReadPre, InsertEnter … (comma separated)' },
		{ key: 'cmd', label: 'Cmd', hint: 'Telescope, Neotree … (lazy-load on command)' },
		{ key: 'ft', label: 'Ft', hint: 'lua, markdown … (lazy-load on filetype)' },
		{ key: 'keys', label: 'Keys', hint: '<leader>ff, <C-n> … or a raw { { "<lhs>", fn } } table', kind: 'lua' },
		{ key: 'dependencies', label: 'Dependencies', hint: 'nvim-lua/plenary.nvim, … or a raw table', kind: 'lua' },
		{ key: 'version', label: 'Version', hint: '* latest release, false = branch head' },
		{ key: 'branch', label: 'Branch', hint: 'git branch' },
		{ key: 'tag', label: 'Tag', hint: 'git tag' },
		{ key: 'commit', label: 'Commit', hint: 'git commit' },
		{ key: 'priority', label: 'Priority', hint: 'number, e.g. 1000 for colorschemes' },
		{ key: 'build', label: 'Build', hint: ':TSUpdate, make …' },
		{ key: 'opts', label: 'Opts', hint: '{ theme = "dark" } Lua table → opts', kind: 'lua' },
		{ key: 'config', label: 'Config', hint: 'true, function (skeleton) or raw function(...) end', kind: 'lua' },
		{ key: 'init', label: 'Init', hint: 'raw function() … end, runs at startup', kind: 'lua' },
		{ key: 'pin', label: 'Pin', hint: 'true to exclude from updates', kind: 'bool' }
	];

	let form = $state<Record<string, string>>({
		repo: 'folke/noice.nvim',
		event: 'VeryLazy',
		opts: '{ presets = { bottom_search = true } }'
	});

	let preview = $state<GeneratedSpec | null>(null);
	let previewError = $state<string | null>(null);
	let banner = $state<{ kind: 'ok' | 'err'; text: string } | null>(null);
	let saving = $state(false);
	let saved = $state<SavedSpecFile[]>([]);
	let suggestions = $state<{ word: string; menu?: string }[]>([]);
	let suggestionSource = $state('local');
	let suggestKey = $state('');

	function set(key: string, value: string) {
		form = { ...form, [key]: value };
	}

	function payload(): KaeruForm {
		return { ...form } as unknown as KaeruForm;
	}

	// Live preview, debounced so typing stays smooth on phones.
	$effect(() => {
		const snapshot = JSON.stringify(form);
		const timer = setTimeout(() => {
			api<ApiResult & { generated?: GeneratedSpec }>('/api/spec/generate', { form: JSON.parse(snapshot) }).then(
				(res) => {
					if (res.ok && res.generated) {
						preview = res.generated;
						previewError = null;
					} else {
						preview = null;
						previewError = res.error ?? 'Invalid specification';
					}
				}
			);
		}, 150);
		return () => clearTimeout(timer);
	});

	let completeTimer: ReturnType<typeof setTimeout> | undefined;
	function complete(key: string, value: string) {
		clearTimeout(completeTimer);
		const last = key === 'repo' ? value.trim() : (value.split(',').pop() ?? '').trim();
		suggestKey = key;
		if (last.length < 2) {
			suggestions = [];
			return;
		}
		completeTimer = setTimeout(async () => {
			const res = await api<ApiResult & { items?: { word: string; menu?: string }[]; source?: string }>(
				`/api/complete?field=${encodeURIComponent(key)}&prefix=${encodeURIComponent(last)}&repo=${encodeURIComponent(form.repo ?? '')}`
			);
			if (res.ok) {
				suggestions = (res.items ?? []).slice(0, 12);
				suggestionSource = res.source ?? 'local';
			}
		}, 250);
	}

	function pick(key: string, word: string) {
		const current = form[key] ?? '';
		if (key === 'repo') {
			set(key, word);
		} else {
			const parts = current.split(',');
			parts[parts.length - 1] = ` ${word}`;
			set(key, parts.map((p) => p.trim()).filter(Boolean).join(', '));
		}
		suggestions = [];
	}

	async function refreshSaved() {
		const res = await api<ApiResult & { specs?: SavedSpecFile[] }>('/api/spec');
		if (res.ok) saved = res.specs ?? [];
	}

	async function save() {
		saving = true;
		banner = null;
		const res = await api<ApiResult & { relativePath?: string; file?: string }>('/api/spec/save', { form: payload() });
		saving = false;
		if (res.ok) {
			banner = { kind: 'ok', text: `Saved ${res.relativePath}. lazy.nvim will load it on the next start.` };
			refreshSaved();
		} else {
			banner = { kind: 'err', text: res.error ?? 'Save failed' };
		}
	}

	async function remove(file: string) {
		if (!confirm(`Delete lua/plugins/${file}.lua?`)) return;
		const res = await api<ApiResult & { specs?: SavedSpecFile[] }>('/api/spec', { action: 'delete', file });
		if (res.ok) {
			saved = res.specs ?? [];
			banner = { kind: 'ok', text: `Deleted ${file}.lua` };
		} else {
			banner = { kind: 'err', text: 'Could not delete the spec' };
		}
	}

	function reset() {
		form = { repo: '' };
		preview = null;
		previewError = null;
	}

	onMount(() => {
		// a draft handed over from the parser or the GitHub browser
		if (ui.draft) {
			form = { ...ui.draft };
			ui.draft = null;
		}
		refreshSaved();
	});
</script>

<div class="split">
	<section class="card wide">
		<div class="card-head">
			<div>
				<h2>Spec builder</h2>
				<p class="muted small" style:margin="0">Fields map 1:1 to the lazy.nvim spec.</p>
			</div>
			<button type="button" class="ghost" onclick={reset}>Clear</button>
		</div>

		<form
			class="stack"
			onsubmit={(e) => {
				e.preventDefault();
				save();
			}}
		>
			{#each FIELDS as field (field.key)}
				<label class="field">
					<span>{field.label}</span>
					{#if field.kind === 'bool'}
						<select value={form[field.key] ?? ''} onchange={(e) => set(field.key, e.currentTarget.value)}>
							<option value="">—</option>
							<option value="true">true</option>
							<option value="false">false</option>
						</select>
					{:else if field.kind === 'lua'}
						<textarea
							rows={field.key === 'config' || field.key === 'init' ? 3 : 2}
							value={form[field.key] ?? ''}
							placeholder={field.hint}
							oninput={(e) => set(field.key, e.currentTarget.value)}
						></textarea>
					{:else}
						<input
							type="text"
							autocomplete="off"
							autocapitalize="off"
							spellcheck="false"
							value={form[field.key] ?? ''}
							placeholder={field.hint}
							oninput={(e) => {
								set(field.key, e.currentTarget.value);
								if (field.key === 'repo' || field.key === 'event' || field.key === 'cmd' || field.key === 'ft' || field.key === 'dependencies') {
									complete(field.key, e.currentTarget.value);
								}
							}}
						/>
						<small>{field.hint}</small>
					{/if}
				</label>
				{#if suggestions.length && suggestKey === field.key}
					<div class="row" aria-label="Suggestions for {field.label}">
						{#each suggestions as s (s.word)}
							<button type="button" class="chip small" title={s.menu ?? ''} onclick={() => pick(field.key, s.word)}>{s.word}</button>
						{/each}
						<span class="small muted">{suggestionSource}</span>
					</div>
				{/if}
			{/each}

			<div class="row">
				<button class="primary" type="submit" disabled={saving || !form.repo?.trim()}>
					{saving ? 'Saving…' : 'Save spec file'}
				</button>
			</div>
		</form>

		{#if banner}
			<p class="banner {banner.kind}" role="status" style:margin-top="0.75rem">{banner.text}</p>
		{/if}
	</section>

	<section class="card">
		<div class="card-head">
			<h2>Generated Lua</h2>
			{#if preview}<span class="badge ok">{preview.file}.lua</span>{/if}
		</div>
		{#if previewError}
			<p class="banner err">{previewError}</p>
		{:else if preview}
			<pre class="code">{preview.source}</pre>
		{:else}
			<p class="muted small">Enter a repository to see the spec.</p>
		{/if}
	</section>

	<section class="card">
		<div class="card-head">
			<h2>Saved specs</h2>
			<span class="badge">{saved.length}</span>
		</div>
		<ul class="list" style:max-height="420px" style:overflow="auto">
			{#each saved as spec (spec.file)}
				<li class="row" style:flex-wrap="nowrap" style:align-items="center">
					<div style:flex="1" style:min-width="0">
						<div class="name" style:overflow-wrap="anywhere">{spec.repo}</div>
						<div class="small muted">{spec.relativePath} · {spec.size} B</div>
					</div>
					<button type="button" class="danger" aria-label="Delete {spec.file}" onclick={() => remove(spec.file)}><Icon name="trash-bin-trash-linear" /></button>
				</li>
			{:else}
				<li class="muted small">No saved specs yet.</li>
			{/each}
		</ul>
	</section>
</div>
