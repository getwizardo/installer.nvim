# Starsky for Neovim (SvelteKit webclient)

Mobile-first web client for kaeru.nvim: spec builder, parser, GitHub search,
Mason/LSP explorer, SFTP studio, music, and the code IDE with the `:Clina`
NeoCodeium assistant.

Built with SvelteKit 3, Svelte 5, TypeScript, and Vite 8. Production builds use
`@sveltejs/adapter-node`. The server talks to Neovim through the Node Neovim
client (`neovim` npm package).

## Getting started

```bash
npm install
npm run dev          # http://localhost:5173 (bound to 0.0.0.0)
```

From Neovim: `:Kaeru starsky start`.

## Scripts

| Command           | What it does                                          |
| ----------------- | ----------------------------------------------------- |
| `npm run dev`     | Vite dev server with hot reload                        |
| `npm run build`   | Production build into `build/` (adapter-node)          |
| `npm start`       | Run the production server (`node build`)               |
| `npm run check`   | `svelte-check` type checking                           |
| `npm run clina`   | Run the `:Clina` CLI (`bin/clina.ts`)                   |

## Layout

- `src/routes/`: tabbed shell (`+page.svelte`) and `api/*/+server.ts` routes
- `src/lib/components/`: IDE, Spec, Parser, GitHub, Mason, SFTP, and Music panels
- `src/lib/server/`: Neovim bridge (`nvim.ts`, `luaBridge.ts`), Clina, SFTP, music
- `src/lib/client/`: browser helpers and Web Components (registered in `onMount`)

Imports use the `#lib/*` alias (declared in `package.json` `imports` and `tsconfig.json` `paths`).
