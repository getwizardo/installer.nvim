<script lang="ts">
	import { onMount } from 'svelte';
	import { api, type ApiResult } from '#lib/client/api';
	import { registerStarskyWebComponents } from '#lib/client/webComponents';
	import type { WorkspaceEntry } from '#lib/server/workspace';
	import Icon from '#lib/components/Icon.svelte';

	// Minimal web IDE. Editor buffers live in the remote Neovim session (see
	// /api/nvim): opening a file creates a buffer there, saving writes it with :w,
	// and the terminal runs an allow-listed set of Ex commands.

	interface FilesReply extends ApiResult {
		files: WorkspaceEntry[];
	}
	interface NvimOpen extends ApiResult {
		path: string;
		filetype: string;
		content: string;
	}
	interface NvimSave extends ApiResult {
		relativePath: string;
		size: number;
	}
	interface NvimStatus extends ApiResult {
		neovim: { available: boolean; cmd: string | null; remote: string | null };
	}
	type Banner = { kind: 'ok' | 'err'; text: string };

	const NEOCODEIUM_FORM = {
		repo: 'monkoose/neocodeium',
		event: 'VeryLazy',
		cmd: 'NeoCodeium',
		opts: 'manual = false, show_label = true'
	};
	const NEOCODEIUM_KEYMAPS: [string, string][] = [
		['<A-f>', 'accept()'],
		['<A-w>', 'accept_word()'],
		['<A-a>', 'accept_line()'],
		['<A-e>', 'cycle_or_complete()'],
		['<A-r>', 'cycle_or_complete(-1)'],
		['<A-c>', 'clear()']
	];

	let files = $state<WorkspaceEntry[]>([]);
	let nvim = $state<NvimStatus['neovim'] | null>(null);
	let activePath = $state('');
	let filetype = $state('text');
	let content = $state(''); // what the editor currently shows
	let loadedText = $state(''); // what Neovim last loaded or wrote
	let dirty = $state(false);
	let openTabs = $state<string[]>([]);
	let banner = $state<Banner | null>(null);
	let explorerOpen = $state(false);
	let busy = $state(false);

	let editorEl = $state<HTMLElement>();
	let terminalEl = $state<HTMLElement & { appendLine?: (s: string) => void }>();

	const fileEntries = $derived(files.filter((f) => f.type === 'file'));

	function say(kind: Banner['kind'], text: string) {
		banner = { kind, text };
	}

	async function refresh() {
		const [list, status] = await Promise.all([
			api<FilesReply>('/api/files'),
			api<NvimStatus>('/api/nvim')
		]);
		if (list.ok) files = list.files;
		else say('err', list.error ?? 'Could not list the workspace');
		if (status.ok) nvim = status.neovim;
	}

	async function openFile(relativePath: string) {
		if (dirty && !confirm(`Discard unsaved changes in ${activePath}?`)) return;
		busy = true;
		const res = await api<NvimOpen>('/api/nvim', { action: 'open', path: relativePath });
		busy = false;
		if (!res.ok) return say('err', res.error ?? `Cannot open ${relativePath}`);
		activePath = res.path;
		filetype = res.filetype || 'text';
		content = res.content;
		loadedText = res.content;
		dirty = false;
		explorerOpen = false;
		if (!openTabs.includes(res.path)) openTabs = [...openTabs, res.path];
		say('ok', `Opened ${res.path} in Neovim`);
	}

	async function saveFile(text: string = content) {
		if (!activePath) return say('err', 'Open a file first');
		busy = true;
		const res = await api<NvimSave>('/api/nvim', {
			action: 'save',
			path: activePath,
			content: text
		});
		busy = false;
		if (res.ok) {
			loadedText = text;
			content = text;
			dirty = false;
			say('ok', `Saved ${res.relativePath} (${res.size} bytes) with :w`);
		} else {
			say('err', res.error ?? 'Save failed');
		}
	}

	async function saveNeoCodeiumSpec() {
		const res = await api<ApiResult & { relativePath?: string; exists?: boolean }>('/api/spec/save', {
			form: NEOCODEIUM_FORM
		});
		if (res.ok) say('ok', `Saved ${res.relativePath ?? 'neocodeium.lua'}`);
		else if (res.exists) say('err', `${res.error} Use :Kaeru save with overwrite to replace it.`);
		else say('err', res.error ?? 'Save failed');
	}

	// Terminal: the Ex commands the web terminal accepts. The server runs them
	// in the Neovim session and returns their output lines.
	async function runEx(command: string) {
		const out = (text: string) => terminalEl?.appendLine?.(text);
		const res = await api<ApiResult & { lines?: string[] }>('/api/nvim', { action: 'ex', command });
		const lines = res.lines ?? (res.error ? [res.error] : []);
		if (lines.length === 0) return out(`:${command.replace(/^:/, '')}`);
		for (const line of lines) out(line);
		// keep the editor in step after :w and :e so the browser shows the buffer Neovim holds
		if (res.ok && /^:?(e|edit)\s/.test(command)) {
			const target = command.replace(/^:?(e|edit)\s+/, '').trim();
			if (target) await openFile(target);
		}
	}

	onMount(() => {
		registerStarskyWebComponents();
		refresh();
	});

	// Editor and terminal custom events.
	$effect(() => {
		const editor = editorEl;
		if (!editor) return;
		const onChange = (e: Event) => {
			const code = (e as CustomEvent<{ code: string }>).detail?.code;
			if (typeof code === 'string') {
				content = code;
				dirty = code !== loadedText;
			}
		};
		const onSave = (e: Event) => {
			const code = (e as CustomEvent<{ code: string }>).detail?.code;
			saveFile(typeof code === 'string' ? code : content);
		};
		editor.addEventListener('code-change', onChange);
		editor.addEventListener('code-save', onSave);
		return () => {
			editor.removeEventListener('code-change', onChange);
			editor.removeEventListener('code-save', onSave);
		};
	});

	$effect(() => {
		const term = terminalEl;
		if (!term) return;
		const onEx = (e: Event) => {
			const command = (e as CustomEvent<{ command: string }>).detail?.command ?? '';
			runEx(command);
		};
		term.addEventListener('ex-command', onEx);
		return () => term.removeEventListener('ex-command', onEx);
	});
</script>

<div class="ide">
	<!-- Toolbar: current buffer, Neovim connection, save -->
	<section class="card ide-bar">
		<div class="row ide-title">
			<Icon name="code-square-linear" size={18} />
			<span class="mono small ide-path">{activePath || 'No file open'}</span>
			{#if dirty}<span class="badge warn" aria-label="unsaved changes">unsaved</span>{/if}
		</div>
		<div class="row">
			<span class="badge {nvim?.available ? 'ok' : 'warn'}" title={nvim?.cmd ?? ''}>
				{nvim?.remote ? 'remote nvim' : nvim?.available ? 'nvim' : 'nvim offline'}
			</span>
			<button class="ghost" type="button" aria-expanded={explorerOpen} onclick={() => (explorerOpen = !explorerOpen)}>
				<Icon name="folder-open-linear" size={18} /> {explorerOpen ? 'Hide files' : 'Files'}
			</button>
			<button class="success" type="button" disabled={!activePath || busy} onclick={() => saveFile()}>
				<Icon name="diskette-linear" size={18} /> Save
			</button>
		</div>
	</section>

	{#if banner}
		<p class="banner {banner.kind}" role="status">{banner.text}</p>
	{/if}

	<div class="ide-grid">
		<!-- Explorer: a drawer on phones, a column on wide screens -->
		<section class="card explorer-card">
			<div class="card-head">
				<h2>Workspace</h2>
				<span class="badge">{fileEntries.length} files</span>
			</div>
			<ul class="list explorer" class:open={explorerOpen}>
				{#each fileEntries as file (file.relativePath)}
					<li>
						<button
							type="button"
							class="list-item"
							class:active={activePath === file.relativePath}
							onclick={() => openFile(file.relativePath)}
						>
							<Icon name="file-linear" size={16} />
							<span class="name">{file.relativePath}</span>
						</button>
					</li>
				{:else}
					<li class="muted small">No files in the workspace.</li>
				{/each}
			</ul>
		</section>

		<section class="card editor-card">
			<div class="tabs-row">
				{#each openTabs as tab (tab)}
					<button type="button" class="chip small" aria-pressed={activePath === tab} onclick={() => openFile(tab)}>
						{tab.split('/').pop()}{dirty && activePath === tab ? ' •' : ''}
					</button>
				{:else}
					<span class="muted small">Open a file from the workspace</span>
				{/each}
			</div>
			<starsky-code-editor
				bind:this={editorEl}
				code={loadedText}
				language={filetype}
				filepath={activePath || 'untitled.txt'}
			></starsky-code-editor>
		</section>
	</div>

	<!-- Terminal: remote Neovim Ex commands -->
	<section class="card">
		<div class="card-head">
			<h2>Terminal</h2>
			<span class="muted small">:e file · :w · :ls · :Kaeru save owner/repo · :Kikru play · :help</span>
		</div>
		<starsky-terminal bind:this={terminalEl}></starsky-terminal>
	</section>

	<!-- NeoCodeium is a plain Neovim plugin: save its spec and show its keys -->
	<section class="card">
		<div class="card-head">
			<div>
				<h2>NeoCodeium</h2>
				<p class="muted small">Neovim plugin · monkoose/neocodeium · ghost-text AI completion</p>
			</div>
			<Icon name="bolt-linear" size={20} />
		</div>
		<button class="success" type="button" onclick={saveNeoCodeiumSpec}>
			<Icon name="diskette-linear" size={18} /> Save neocodeium spec
		</button>
		<h3>Keymaps</h3>
		<ul class="list keymaps">
			{#each NEOCODEIUM_KEYMAPS as [key, call] (key)}
				<li><code>{key}</code> <code>require("neocodeium").{call}</code></li>
			{/each}
		</ul>
	</section>
</div>

<style>
	.ide {
		display: grid;
		gap: 0.75rem;
	}
	.ide-bar {
		display: flex;
		flex-wrap: wrap;
		gap: 0.5rem;
		justify-content: space-between;
		align-items: center;
	}
	.ide-title {
		min-width: 0;
	}
	.ide-path {
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}
	.ide-grid {
		display: grid;
		gap: 0.75rem;
	}
	.explorer-card {
		min-width: 0;
	}
	.editor-card {
		min-width: 0;
	}
	.tabs-row {
		display: flex;
		gap: 0.4rem;
		overflow-x: auto;
		margin-bottom: 0.5rem;
		flex-wrap: nowrap;
	}
	@media (min-width: 1100px) {
		.ide-grid {
			grid-template-columns: 240px 1fr;
			align-items: start;
		}
	}
</style>
