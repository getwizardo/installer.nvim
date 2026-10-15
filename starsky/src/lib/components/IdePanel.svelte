<script lang="ts">
	import { onMount } from 'svelte';
	import { api, type ApiResult } from '#lib/client/api';
	import { registerStarskyWebComponents } from '#lib/client/webComponents';
	import type {
		ClinaCodeProposal,
		ClinaFileNode,
		ClinaMode,
		ClinaProviderInfo,
		ClinaAgentStep
	} from '#lib/server/clina';

	interface ClinaStatus extends ApiResult {
		providers: ClinaProviderInfo[];
		files: ClinaFileNode[];
	}
	interface ClinaReply extends ApiResult {
		mode: ClinaMode;
		provider: string;
		model: string;
		reply: string;
		steps: ClinaAgentStep[];
		proposal?: ClinaCodeProposal;
	}
	interface FileRead extends ApiResult {
		path: string;
		relativePath: string;
		content: string;
		language: string;
	}
	interface Message {
		role: 'user' | 'assistant';
		text: string;
		steps?: ClinaAgentStep[];
		proposal?: ClinaCodeProposal;
	}
	type Banner = { kind: 'ok' | 'err'; text: string };

	const MODES: ClinaMode[] = ['agent', 'chat', 'edit', 'spec'];

	let files = $state<ClinaFileNode[]>([]);
	let providers = $state<ClinaProviderInfo[]>([]);
	let provider = $state('clina-ts');
	let mode = $state<ClinaMode>('agent');

	let activePath = $state('');
	let content = $state(''); // what the user is editing
	let loadedText = $state(''); // what the editor was last loaded/saved with
	let lang = $state('lua');
	let dirty = $state(false);
	let openTabs = $state<string[]>([]);
	let banner = $state<Banner | null>(null);

	let prompt = $state('');
	let running = $state(false);
	let chat = $state<Message[]>([]);
	let explorerOpen = $state(false);

	let editorEl = $state<HTMLElement>();
	let terminalEl = $state<HTMLElement & { appendLine?: (s: string) => void }>();

	function say(kind: Banner['kind'], text: string) {
		banner = { kind, text };
	}

	async function refresh() {
		const res = await api<ClinaStatus>('/api/clina');
		if (res.ok) {
			files = res.files;
			providers = res.providers;
			const configured = res.providers.find((p) => p.configured);
			if (configured && !res.providers.some((p) => p.id === provider && p.configured)) {
				provider = configured.id;
			}
		} else {
			say('err', res.error ?? 'Could not load the workspace');
		}
	}

	async function openFile(relativePath: string) {
		if (dirty && !confirm(`Discard unsaved changes in ${activePath}?`)) return;
		const res = await api<FileRead>(`/api/clina?file=${encodeURIComponent(relativePath)}`);
		if (!res.ok) return say('err', res.error ?? `Cannot open ${relativePath}`);
		activePath = res.relativePath;
		lang = res.language || 'text';
		content = res.content;
		loadedText = res.content;
		dirty = false;
		explorerOpen = false;
		if (!openTabs.includes(res.relativePath)) openTabs = [...openTabs, res.relativePath];
	}

	async function saveFile(text: string = content) {
		if (!activePath) return say('err', 'Open a file first');
		const res = await api<ApiResult & { relativePath?: string; size?: number }>('/api/clina', {
			action: 'write',
			path: activePath,
			content: text
		});
		if (res.ok) {
			loadedText = text;
			content = text;
			dirty = false;
			say('ok', `Saved ${res.relativePath} (${res.size ?? text.length} bytes)`);
		} else {
			say('err', res.error ?? 'Save failed');
		}
	}

	async function ask() {
		const text = prompt.trim();
		if (!text || running) return;
		running = true;
		chat = [...chat, { role: 'user', text }];
		prompt = '';
		const res = await api<ClinaReply>('/api/clina', {
			prompt: text,
			mode,
			provider,
			active_file: activePath,
			active_content: content
		});
		running = false;
		if (res.ok) {
			chat = [
				...chat,
				{ role: 'assistant', text: res.reply, steps: res.steps, proposal: res.proposal }
			];
		} else {
			chat = [...chat, { role: 'assistant', text: `Error: ${res.error ?? 'request failed'}` }];
		}
	}

	const NEOCODEIUM_FORM = {
		repo: 'monkoose/neocodeium',
		event: 'VeryLazy',
		cmd: 'NeoCodeium',
		opts: 'manual = false, show_label = true'
	};
	const NEOCODEIUM_KEYMAPS = [
		['<A-f>', 'accept()'],
		['<A-w>', 'accept_word()'],
		['<A-a>', 'accept_line()'],
		['<A-e>', 'cycle_or_complete()'],
		['<A-r>', 'cycle_or_complete(-1)'],
		['<A-c>', 'clear()']
	];

	async function saveNeoCodeiumSpec() {
		const res = await api<ApiResult & { relativePath?: string }>('/api/spec/save', { form: NEOCODEIUM_FORM });
		banner = res.ok
			? { kind: 'ok', text: `Saved ${res.relativePath ?? 'neocodeium.lua'} to lua/plugins/` }
			: { kind: 'err', text: res.error ?? 'Save failed' };
	}

	async function applyProposal(p: ClinaCodeProposal) {
		const res = await api<ApiResult & { relativePath?: string }>('/api/clina', {
			action: 'apply',
			path: p.relativePath,
			content: p.code
		});
		if (!res.ok) return say('err', res.error ?? 'Apply failed');
		say('ok', `Applied patch to ${res.relativePath ?? p.relativePath}`);
		if (activePath === p.relativePath) {
			content = p.code;
			loadedText = p.code;
			dirty = false;
		}
		await refresh();
	}

	/** Lines of a unified diff, classed for colouring. */
	function diffLines(diff: string) {
		return diff.split('\n').map((line) => ({
			text: line,
			kind: line.startsWith('+') && !line.startsWith('+++')
				? 'add'
				: line.startsWith('-') && !line.startsWith('---')
					? 'del'
					: 'ctx'
		}));
	}

	// Terminal: the Ex commands that map onto Starsky actions. Everything else is
	// echoed, so the terminal never runs arbitrary commands on the server.
	async function runEx(command: string) {
		const line = (text: string) => terminalEl?.appendLine?.(text);
		const [head, ...rest] = command.split(/\s+/);
		if (head === 'Kaeru' && rest[0] === 'save' && rest[1]) {
			const res = await api<ApiResult & { relativePath?: string }>('/api/spec/save', {
				form: { repo: rest[1] }
			});
			return line(res.ok ? `[Kaeru] saved spec → ${res.relativePath}` : `[Kaeru] ${res.error}`);
		}
		if (head === 'Kikru') {
			const action = rest[0] === 'play' || rest[0] === 'pause' ? 'toggle' : rest[0] || 'status';
			if (action === 'status') return line('[Kikru] open the Music tab for the full player');
			const res = await api<ApiResult & { state?: { playing: boolean } }>('/api/music', { action });
			return line(res.ok ? `[Kikru] ${action} → ${res.state?.playing ? 'playing' : 'paused'}` : `[Kikru] ${res.error}`);
		}
		if (head === 'Clina') {
			return line(`[Clina] ${providers.filter((p) => p.configured).length} provider(s) configured · mode ${mode}`);
		}
		line(`[Starsky] :${command} is not wired to the webclient (echoed only)`);
	}

	onMount(() => {
		registerStarskyWebComponents();
		refresh();
	});

	// attach the custom element events once the elements exist
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
			const command = String((e as CustomEvent<{ command: string }>).detail?.command ?? '').trim();
			if (command) runEx(command);
		};
		term.addEventListener('ex-command', onEx);
		return () => term.removeEventListener('ex-command', onEx);
	});
</script>

<div class="ide">
	<!-- Workspace explorer: a drawer on phones, a column on desktop -->
	<section class="card">
		<div class="card-head">
			<h2>Workspace</h2>
			<span class="badge">{files.length} files</span>
		</div>
		<button class="ghost" type="button" aria-expanded={explorerOpen} onclick={() => (explorerOpen = !explorerOpen)}>
			{explorerOpen ? 'Hide files' : 'Browse files'}
		</button>
		<ul class="list explorer" class:open={explorerOpen}>
			{#each files as file (file.relativePath)}
				<li>
					<button
						type="button"
						class="list-item"
						class:active={activePath === file.relativePath}
						onclick={() => openFile(file.relativePath)}
					>
						<span aria-hidden="true">{file.language === 'lua' ? '🌙' : file.language === 'typescript' ? '🔷' : '📄'}</span>
						<span class="name">{file.relativePath}</span>
					</button>
				</li>
			{:else}
				<li class="muted small">No files in the workspace.</li>
			{/each}
		</ul>
	</section>

	<!-- Editor + Ex terminal -->
	<div class="stack">
		<section class="card">
			<div class="row" style:justify-content="space-between">
				<div class="row" style:overflow-x="auto" style:flex-wrap="nowrap" style:max-width="100%">
					{#each openTabs as tab (tab)}
						<button
							type="button"
							class="chip small"
							aria-pressed={activePath === tab}
							onclick={() => openFile(tab)}
						>
							{tab.split('/').pop()}{dirty && activePath === tab ? ' •' : ''}
						</button>
					{:else}
						<span class="muted small">Open a file from the workspace</span>
					{/each}
				</div>
				<button class="success" type="button" disabled={!activePath} onclick={() => saveFile()}>Save (:w)</button>
			</div>

			{#if banner}
				<p class="banner {banner.kind}" style:margin="0.6rem 0" role="status">{banner.text}</p>
			{/if}

			<div style:margin-top="0.6rem">
				<starsky-code-editor
					bind:this={editorEl}
					code={loadedText}
					language={lang}
					filepath={activePath || 'lua/kaeru/spec.lua'}
				></starsky-code-editor>
			</div>
		</section>

		<section class="card">
			<h2>Ex terminal</h2>
			<p class="muted small">Try <code>Kaeru save folke/which-key.nvim</code>, <code>Kikru play</code> or <code>Clina</code>.</p>
			<starsky-terminal bind:this={terminalEl}></starsky-terminal>
		</section>
	</div>

	<!-- NeoCodeium (:Clina primary engine): spec saver + keymap reference -->
	<section class="card">
		<div class="card-head">
			<div>
				<h2>:Clina · NeoCodeium</h2>
				<p class="muted small">Engine: <code>monkoose/neocodeium</code> · Windsurf ghost-text</p>
			</div>
			<span class="badge">NeoCodeium</span>
		</div>
		<button class="success" type="button" onclick={saveNeoCodeiumSpec}>💾 Save neocodeium.lua spec</button>
		<h3>NeoCodeium Lua API &amp; keymaps</h3>
		<ul class="list keymaps">
			{#each NEOCODEIUM_KEYMAPS as [key, call] (key)}
				<li><code>{key}</code> <code>require("neocodeium").{call}</code></li>
			{/each}
		</ul>
	</section>

	<!-- Clina assistant -->
	<section class="card">
		<div class="card-head">
			<div>
				<h2>:Clina assistant</h2>
				<p class="muted small" style:margin="0">TypeScript AI Coding IDE · {mode}</p>
			</div>
			<span class="badge ok">{providers.filter((p) => p.configured).length} ready</span>
		</div>

		<div class="stack">
			<div class="split" style:grid-template-columns="1fr 1fr" style:gap="0.5rem">
				<label class="field">
					<span>Provider</span>
					<select bind:value={provider}>
						{#each providers as p (p.id)}
							<option value={p.id} disabled={!p.configured && p.id !== 'clina-ts'}>
								{p.name}{p.configured ? '' : ' (no key)'}
							</option>
						{/each}
					</select>
				</label>
				<label class="field">
					<span>Mode</span>
					<select bind:value={mode}>
						{#each MODES as m (m)}
							<option value={m}>{m}</option>
						{/each}
					</select>
				</label>
			</div>

			<div class="chat" aria-live="polite" style:display="grid" style:gap="0.5rem" style:max-height="50vh" style:overflow="auto">
				{#each chat as msg, i (i)}
					<div class="msg {msg.role}" style:padding="0.6rem" style:border-radius="10px" style:background={msg.role === 'user' ? 'var(--panel-2)' : 'transparent'} style:border="1px solid var(--border)">
						<div class="small muted">{msg.role === 'user' ? 'you' : 'clina'}</div>
						<div style:white-space="pre-wrap" style:overflow-wrap="anywhere">{msg.text}</div>
						{#if msg.steps?.length}
							<ol class="small muted" style:margin="0.4rem 0 0" style:padding-left="1.1rem">
								{#each msg.steps as step, j (j)}
									<li>{step.tool} · {step.action} — {step.detail}</li>
								{/each}
							</ol>
						{/if}
						{#if msg.proposal}
							<details open style:margin-top="0.5rem">
								<summary>Patch for <code>{msg.proposal.relativePath}</code></summary>
								<pre class="code">{#each diffLines(msg.proposal.diff) as line, k (k)}<span style:color={line.kind === 'add' ? 'var(--green)' : line.kind === 'del' ? 'var(--red)' : 'inherit'}>{line.text}
</span>{/each}</pre>
								<button class="primary" type="button" style:margin-top="0.5rem" onclick={() => applyProposal(msg.proposal!)}>
									Apply patch
								</button>
							</details>
						{/if}
					</div>
				{:else}
					<p class="muted small">Ask for a spec, an edit or an explanation. Unsaved editor contents are sent as context.</p>
				{/each}
			</div>

			<form
				class="stack"
				onsubmit={(e) => {
					e.preventDefault();
					ask();
				}}
			>
				<textarea rows="3" bind:value={prompt} placeholder="e.g. add a keymap for <leader>ff to the open spec" aria-label="Prompt for Clina"></textarea>
				<button class="primary" type="submit" disabled={running || !prompt.trim()}>
					{running ? 'Thinking…' : 'Send to Clina'}
				</button>
			</form>
		</div>
	</section>
</div>
