<script lang="ts">
	import '../app.css';

	let { children } = $props();
</script>

<svelte:head>
	<meta name="theme-color" content="#070a12" />
	<link rel="icon" href="/favicon.svg" />
</svelte:head>

{@render children()}
