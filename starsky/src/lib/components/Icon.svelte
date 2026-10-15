<script lang="ts">
	// Solar icon (CC-BY-4.0). Icons come from the generated subset in
	// `#lib/client/solar`; run `npm run icons` after adding a name.
	import { SOLAR_ICONS, type SolarIconName } from '#lib/client/solar';

	let {
		name,
		size = 20,
		label = ''
	}: { name: SolarIconName; size?: number; label?: string } = $props();

	const icon = $derived(SOLAR_ICONS[name]);
</script>

<svg
	class="solar-icon"
	xmlns="http://www.w3.org/2000/svg"
	viewBox={`0 0 ${icon.width} ${icon.height}`}
	width={size}
	height={size}
	fill="currentColor"
	role={label ? 'img' : undefined}
	aria-label={label || undefined}
	aria-hidden={label ? undefined : 'true'}
>
	{@html icon.body}
</svg>

<style>
	.solar-icon {
		display: inline-block;
		flex: none;
		vertical-align: middle;
	}
</style>
