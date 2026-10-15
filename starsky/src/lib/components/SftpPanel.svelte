<script lang="ts">
	import { onMount } from 'svelte';
	import { api, formatBytes, type ApiResult } from '#lib/client/api';
	import type { SftpEntry, SftpProfile, SftpTransferRecord } from '#lib/server/sftpEngine';

	interface Listing {
		cwd: string;
		entries: SftpEntry[];
		mode?: string;
	}
	interface SftpState extends ApiResult {
		profiles: SftpProfile[];
		activeProfile: SftpProfile;
		local: Listing;
		remote: Listing;
		history: SftpTransferRecord[];
	}
	interface ActionResult extends ApiResult {
		message?: string;
		local?: Listing;
		remote?: Listing;
		stdout?: string;
	}

	let profiles = $state<SftpProfile[]>([]);
	let profile = $state('');
	let local = $state<Listing>({ cwd: '', entries: [] });
	let remote = $state<Listing>({ cwd: '', entries: [] });
	let history = $state<SftpTransferRecord[]>([]);
	let selectedLocal = $state('');
	let selectedRemote = $state('');
	let banner = $state<{ kind: 'ok' | 'err'; text: string } | null>(null);
	let busy = $state(false);
	let sshCommand = $state('ls -la');
	let sshOutput = $state('');

	function apply(res: Partial<SftpState> & ApiResult) {
		if (res.local) local = res.local;
		if (res.remote) remote = res.remote;
		if (res.profiles) profiles = res.profiles;
		if (res.history) history = res.history;
	}

	async function load(localDir?: string, remoteDir?: string) {
		const params = new URLSearchParams({ profile });
		if (localDir) params.set('localDir', localDir);
		if (remoteDir) params.set('remoteDir', remoteDir);
		const res = await api<SftpState>(`/api/sftp?${params}`);
		if (!res.ok) {
			banner = { kind: 'err', text: res.error ?? 'SFTP unavailable' };
			return;
		}
		profile = res.activeProfile.name;
		apply(res);
	}

	async function run(body: Record<string, unknown>, label: string) {
		busy = true;
		const res = await api<ActionResult>('/api/sftp', { profile, localDir: local.cwd, remoteDir: remote.cwd, ...body });
		busy = false;
		if (res.ok) {
			apply(res);
			banner = { kind: 'ok', text: res.message ?? label };
			return res;
		}
		banner = { kind: 'err', text: res.error ?? `${label} failed` };
		return res;
	}

	function parentOf(path: string): string {
		const trimmed = path.replace(/\/+$/, '');
		const idx = trimmed.lastIndexOf('/');
		return idx <= 0 ? '/' : trimmed.slice(0, idx);
	}

	function openLocal(entry: SftpEntry) {
		if (entry.type === 'dir') load(entry.path, remote.cwd);
		else selectedLocal = entry.path;
	}

	function openRemote(entry: SftpEntry) {
		if (entry.type === 'dir') load(local.cwd, entry.path);
		else selectedRemote = entry.path;
	}

	function mkdir(side: 'local' | 'remote') {
		const name = prompt('New folder name');
		if (!name) return;
		run({ action: 'mkdir', side, parentDir: side === 'local' ? local.cwd : remote.cwd, name }, `Created ${name}`);
	}

	function remove(side: 'local' | 'remote') {
		const target = side === 'local' ? selectedLocal : selectedRemote;
		if (!target || !confirm(`Delete ${target}?`)) return;
		run({ action: 'delete', side, targetPath: target }, 'Deleted');
		if (side === 'local') selectedLocal = '';
		else selectedRemote = '';
	}

	async function runSsh() {
		const res = await run({ action: 'ssh', command: sshCommand }, 'Command finished');
		sshOutput = res.stdout ?? res.error ?? '';
	}

	onMount(() => load());
</script>

<div class="stack">
	<section class="card">
		<div class="card-head">
			<div>
				<h2>SFTP Studio</h2>
				<p class="muted small" style:margin="0">Local project ↔ remote server. Stack on phones, side by side on desktop.</p>
			</div>
			<label class="field" style:min-width="140px">
				<span class="small">Profile</span>
				<select
					bind:value={profile}
					onchange={() => {
						selectedLocal = '';
						selectedRemote = '';
						load();
					}}
				>
					{#each profiles as p (p.name)}
						<option value={p.name}>{p.name}</option>
					{/each}
				</select>
			</label>
		</div>
		{#if banner}
			<p class="banner {banner.kind}" role="status">{banner.text}</p>
		{/if}
	</section>

	<div class="split">
		<section class="card">
			<div class="card-head">
				<h3>Local · <span class="mono small">{local.cwd}</span></h3>
				<button type="button" class="ghost" onclick={() => load(parentOf(local.cwd), remote.cwd)}>↑ Up</button>
			</div>
			<ul class="list" style:max-height="340px" style:overflow="auto">
				{#each local.entries as entry (entry.path)}
					<li>
						<button type="button" class="list-item" class:active={selectedLocal === entry.path} onclick={() => openLocal(entry)}>
							<span aria-hidden="true">{entry.type === 'dir' ? '📁' : '📄'}</span>
							<span class="name">{entry.name}</span>
							<span class="small muted">{entry.type === 'dir' ? '' : formatBytes(entry.size)}</span>
						</button>
					</li>
				{/each}
			</ul>
			<div class="row" style:margin-top="0.6rem">
				<button type="button" class="primary" disabled={busy || !selectedLocal} onclick={() => run({ action: 'upload', localPath: selectedLocal, remoteDir: remote.cwd }, 'Uploaded')}>
					Upload ↑
				</button>
				<button type="button" disabled={busy} onclick={() => mkdir('local')}>New folder</button>
				<button type="button" class="danger" disabled={busy || !selectedLocal} onclick={() => remove('local')}>Delete</button>
			</div>
		</section>

		<section class="card">
			<div class="card-head">
				<h3>Remote · <span class="mono small">{remote.cwd}</span></h3>
				<button type="button" class="ghost" onclick={() => load(local.cwd, parentOf(remote.cwd))}>↑ Up</button>
			</div>
			<ul class="list" style:max-height="340px" style:overflow="auto">
				{#each remote.entries as entry (entry.path)}
					<li>
						<button type="button" class="list-item" class:active={selectedRemote === entry.path} onclick={() => openRemote(entry)}>
							<span aria-hidden="true">{entry.type === 'dir' ? '📁' : '📄'}</span>
							<span class="name">{entry.name}</span>
							<span class="small muted">{entry.type === 'dir' ? '' : formatBytes(entry.size)}</span>
						</button>
					</li>
				{/each}
			</ul>
			<div class="row" style:margin-top="0.6rem">
				<button type="button" class="success" disabled={busy || !selectedRemote} onclick={() => run({ action: 'download', remotePath: selectedRemote, localDir: local.cwd }, 'Downloaded')}>
					Download ↓
				</button>
				<button type="button" disabled={busy} onclick={() => mkdir('remote')}>New folder</button>
				<button type="button" class="danger" disabled={busy || !selectedRemote} onclick={() => remove('remote')}>Delete</button>
			</div>
		</section>
	</div>

	<div class="split">
		<section class="card">
			<h3>Sync</h3>
			<p class="muted small">Upload the whole local folder to the remote path of the profile.</p>
			<button type="button" class="primary" disabled={busy} onclick={() => run({ action: 'sync' }, 'Synced project')}>Sync project</button>
		</section>

		<section class="card">
			<h3>Remote command</h3>
			<form
				class="stack"
				onsubmit={(e) => {
					e.preventDefault();
					runSsh();
				}}
			>
				<input type="text" bind:value={sshCommand} autocapitalize="off" aria-label="Remote command" class="mono" />
				<button type="submit" disabled={busy}>Run over SSH</button>
			</form>
			{#if sshOutput}
				<pre class="code">{sshOutput}</pre>
			{/if}
		</section>

		<section class="card wide">
			<h3>Transfer history</h3>
			<ul class="list">
				{#each history.slice(0, 20) as record (record.id)}
					<li class="small">
						<span class="badge {record.status === 'success' ? 'ok' : 'err'}">{record.status}</span>
						{record.direction} · {record.source} → {record.destination}
					</li>
				{:else}
					<li class="muted small">No transfers yet.</li>
				{/each}
			</ul>
		</section>
	</div>
</div>
