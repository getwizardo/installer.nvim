import adapter from '@sveltejs/adapter-node';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

// Starsky is built and run through the CLI only:
//   npm run dev      -> vite dev   (used by `:Kaeru starsky start`)
//   npm run build    -> vite build (used by `:Kaeru starsky build`)
//   npm start        -> node build (standalone Node server, PORT / HOST env)
export default defineConfig({
	plugins: [sveltekit({ adapter: adapter() })],
	server: {
		host: '0.0.0.0',
		port: 5173,
		// Allow the e2b preview proxy (https://<port>-<sandbox>.e2b.app) and localhost.
		allowedHosts: ['.e2b.app', 'localhost', '127.0.0.1']
	},
	preview: {
		host: '0.0.0.0',
		port: 4174,
		allowedHosts: ['.e2b.app', 'localhost', '127.0.0.1']
	}
});
