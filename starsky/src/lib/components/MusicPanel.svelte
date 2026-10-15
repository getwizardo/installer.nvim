<script lang="ts">
	import { onMount } from 'svelte';
	import { api, type ApiResult } from '#lib/client/api';
	import type { MusicStation, NeovimMusicDevice } from '#lib/server/music';
	import Icon from '#lib/components/Icon.svelte';

	interface MusicState {
		playing: boolean;
		stationIdx: number;
		serviceId: string;
		volume: number;
		eqPreset: string;
		eqBands: number[];
		visualizer: string;
		role: string;
		port: number;
		devices: NeovimMusicDevice[];
		rpcLog: string[];
	}
	interface Snapshot extends ApiResult {
		state: MusicState;
		station: MusicStation;
		stations: MusicStation[];
		services: { id: string; name: string; status: string; desc: string }[];
		eqFrequencies: string[];
		eqPresets: Record<string, number[]>;
	}

	const VISUALIZERS = ['spectrum', 'wave', 'vu', 'matrix', 'starfield'];

	let snap = $state<Snapshot | null>(null);
	let error = $state<string | null>(null);
	let busy = $state(false);

	async function load() {
		const res = await api<Snapshot>('/api/music');
		if (res.ok) {
			snap = res;
			error = null;
		} else {
			error = res.error ?? 'Could not load the player';
		}
	}

	async function send(action: string, extra: Record<string, unknown> = {}) {
		busy = true;
		const res = await api<Snapshot>('/api/music', { action, ...extra });
		busy = false;
		if (res.ok) {
			snap = res;
			error = null;
		} else {
			error = res.error ?? 'Player action failed';
		}
	}

	onMount(load);
</script>

<div class="split">
	{#if error}
		<p class="banner err wide">{error}</p>
	{/if}

	{#if snap}
		<section class="card wide">
			<div class="card-head">
				<div>
					<h2>Now playing</h2>
					<p class="muted small" style:margin="0">
						{snap.station.service} · {snap.station.bitrate}
					</p>
				</div>
				<span class="badge {snap.state.playing ? 'ok' : ''}">{snap.state.playing ? '● live' : 'paused'}</span>
			</div>

			<p style:margin="0 0 0.25rem" style:font-size="1.15rem" style:font-weight="700" style:overflow-wrap="anywhere">
				{snap.station.title}
			</p>
			<p class="muted" style:margin="0 0 0.9rem">{snap.station.artist} · {snap.station.genre}</p>

			<div class="row" style:justify-content="center">
				<button type="button" aria-label="Previous station" disabled={busy} onclick={() => send('prev')}><Icon name="skip-previous-linear" /></button>
				<button
					type="button"
					class="primary"
					style:min-width="88px"
					disabled={busy}
					onclick={() => send('toggle')}
				>
					<Icon name={snap.state.playing ? 'pause-linear' : 'play-linear'} size={16} />
					{snap.state.playing ? 'Pause' : 'Play'}
				</button>
				<button type="button" aria-label="Next station" disabled={busy} onclick={() => send('next')}><Icon name="skip-next-linear" /></button>
			</div>

			<label class="field" style:margin-top="1rem">
				<span>Volume · {snap.state.volume}%</span>
				<input
					type="range"
					min="0"
					max="100"
					value={snap.state.volume}
					onchange={(e) => send('volume', { volume: Number(e.currentTarget.value) })}
				/>
			</label>
		</section>

		<section class="card">
			<h2>Stations</h2>
			<ul class="list" style:max-height="360px" style:overflow="auto">
				{#each snap.stations as station, i (station.id)}
					<li>
						<button
							type="button"
							class="list-item"
							class:active={i === snap.state.stationIdx}
							onclick={() => send('station', { index: i })}
						>
							<span class="name">{station.title}</span>
							<span class="small muted">{station.bitrate}</span>
						</button>
					</li>
				{/each}
			</ul>
		</section>

		<section class="card">
			<h2>10-band EQ</h2>
			<div class="row" style:margin-bottom="0.6rem">
				{#each Object.keys(snap.eqPresets) as preset (preset)}
					<button
						type="button"
						class="chip small"
						aria-pressed={snap.state.eqPreset === preset}
						onclick={() => send('eqPreset', { preset })}
					>
						{preset}
					</button>
				{/each}
			</div>
			<div class="eq" style:display="grid" style:grid-template-columns="repeat(5, minmax(0, 1fr))" style:gap="0.5rem">
				{#each snap.state.eqBands as gain, band (band)}
					<label class="field" style:text-align="center">
						<span class="small">{snap.eqFrequencies[band]}</span>
						<input
							type="range"
							min="-12"
							max="12"
							step="1"
							value={gain}
							aria-label="{snap.eqFrequencies[band]} gain"
							onchange={(e) => send('eqBand', { bandIndex: band, gain: Number(e.currentTarget.value) })}
						/>
						<small>{gain > 0 ? '+' : ''}{gain} dB</small>
					</label>
				{/each}
			</div>
		</section>

		<section class="card">
			<h2>Visualizer &amp; connector</h2>
			<div class="row" style:margin-bottom="0.6rem">
				{#each VISUALIZERS as mode (mode)}
					<button type="button" class="chip small" aria-pressed={snap.state.visualizer === mode} onclick={() => send('visualizer', { mode })}>
						{mode}
					</button>
				{/each}
			</div>
			<ul class="list">
				{#each snap.services as service (service.id)}
					<li>
						<button type="button" class="list-item" class:active={snap.state.serviceId === service.id} onclick={() => send('service', { serviceId: service.id })}>
							<span class="name">{service.name}</span>
							<span class="badge {service.status === 'active' ? 'ok' : ''}">{service.status}</span>
						</button>
					</li>
				{/each}
			</ul>
		</section>

		<section class="card wide">
			<div class="card-head">
				<h2>2-Neovim devices</h2>
				<button type="button" onclick={() => send('pairClient', { name: `Neovim client (port ${snap?.state.port})` })}>Pair client</button>
			</div>
			<ul class="list">
				{#each snap.state.devices as device (device.id)}
					<li>
						<button type="button" class="list-item" class:active={device.active} onclick={() => send('handoffDevice', { deviceId: device.id })}>
							<span class="name">{device.name}</span>
							<span class="small muted">{device.role} · {device.addr}</span>
						</button>
					</li>
				{/each}
			</ul>
			<details style:margin-top="0.6rem">
				<summary class="small">RPC log</summary>
				<pre class="code">{snap.state.rpcLog.join('\n')}</pre>
			</details>
		</section>
	{:else if !error}
		<p class="muted">Loading player…</p>
	{/if}
</div>
