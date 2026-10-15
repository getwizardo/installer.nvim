# kaeru.nvim

Add plugins to your [lazy.nvim](https://github.com/folke/lazy.nvim) config **from inside Neovim**.

- `:Kaeru` opens a modal — fill in the repository and any lazy.nvim spec fields (`event`, `cmd`, `ft`, `keys`, `opts`, …) with **context-aware autocomplete** (`omnifunc` / live popup).
- **Universal `README.md` & snippet parser** (`:Kaeru parse [owner/repo|README.md]`, `<C-r>` in modal, `p` in browser): parses installation snippets from **lazy.nvim, packer.nvim, vim-plug, pckr.nvim, mini.deps, vim.pack, paq-nvim, dein.vim, Vundle, rocks.nvim, `git clone`, `:MasonInstall`, and `require(...).setup(...)`** into a ready-to-install `lazy.nvim` spec.
- A `lua/plugins/<name>.lua` spec file is written for you.
- lazy.nvim reloads its specs and installs the plugin immediately, no restart needed.
- `:Kaeru browse` searches **all Neovim plugins on GitHub** (`topic:neovim-plugin`), with README preview, `p` to parse the README spec, and one-key install.
- **GitHub account**: sign in (gh CLI / token / device flow) for higher rate limits, starring and your starred list.
- **AI coding presets (`:Kaeru ai`)**: curated lazy.nvim specs for copilot.lua, codecompanion, avante, CopilotChat, supermaven, minuet, sidekick, claudecode, opencode, mcphub and NeoCodeium. AI coding is done by the Neovim plugins themselves; kaeru.nvim only writes their specs.
- **SFTP & SFTP Studio UI** (`:Kaeru sftp` / `:Kaeru sftp ui`): dual-pane floating Local Project ↔ Remote Server SFTP Studio UI inside Neovim and in the SvelteKit Webclient, plus parallel `sftp` workers, upload-on-save, every sftp command, remote file browser, and multiple SSH keys / ssh-config / ProxyJump.
- **`kaeru.yaml`**: all configuration in a global or per-project YAML file (built-in parser, no dependencies).
- **Mason (all 601 servers built-in)**: install LSP servers, DAP adapters, linters, formatters, compilers and runtimes from the [mason.nvim](https://github.com/mason-org/mason.nvim) registry (with built-in catalog of all 601 Mason packages & 296 `lspconfig` server mappings for offline/instant autocomplete), `ensure_installed` in `kaeru.yaml`, and one-command scaffolds for lspconfig / nvim-dap / conform + nvim-lint.
- **Autocomplete for *everything*** (`:Kaeru complete`, `complete.any`): fuzzy `:` command-line completion for `:Kaeru` and `:Kikru` — every subcommand, argument, repository, Mason package, radio station, EQ preset, filter, theme, playlist, file, directory, buffer, option, event, colorscheme, help tag and environment variable — with descriptions in the popup, live GitHub search, `<Tab>` cycling and ready-made [nvim-cmp](https://github.com/hrsh7th/nvim-cmp) / [blink.cmp](https://github.com/Saghen/blink.cmp) cmdline sources.
- **`:Kikru` — a Winamp-style player in Lua** (inspired by [cliamp](https://github.com/bjarneo/cliamp) and [NodeLink](https://github.com/PerformanC/NodeLink)): LCD marquee, FFT spectrum / wave / VU / matrix analyzers, 10-band EQ (31 Hz – 16 kHz) with per-band editing and presets, LavaLink-style filter chain (timescale, tremolo, vibrato, 8D rotation, karaoke, lowpass, echo, reverb, chorus, phaser, compressor, distortion, channel mix), internet radio (curated + 30 000 Radio Browser stations), synced **and word-level karaoke** lyrics ([lrc.red](https://lrc.red) · [LRCLIB](https://lrclib.net) · NetEase · SyncLRC · lyrics.ovh, with translations and a disk cache), M3U/PLS/TOML/JSON playlists, file-library indexing, MPRIS/MPD control, multi-engine backends (mpv · ffplay · VLC), a headless IPC daemon and 2-Neovim remote — all inside Neovim.
- **Cast YouTube & YouTube Music into Neovim**: `:Kikru cast <url|search>`, `:Kikru youtube …`, `:Kikru ytmusic …`, plus a built-in cast server (`:Kikru cast server`) with a phone/bookmarklet page, a `kikru://` URL-scheme handler for "Open with Kikru" and `:Kikru appcast`, which picks up whatever the YouTube/YT Music app (or any MPRIS player: Spotify, browser tab, VLC) is playing right now and continues it with your EQ.
- **`:Karu` — Google Cast, implemented in TypeScript** (`karu/`, no runtime dependencies): `karu receive` makes Neovim itself a Cast target that the **YouTube / YouTube Music / Chrome** apps can cast to (mDNS `_googlecast._tcp`, CASTV2 over TLS 8009, `CC1AD845` Default Media Receiver, device auth), and every cast is bridged straight into Kikru; the sender side (`:Karu discover` / `:Karu cast`) drives real Chromecasts on your LAN.
- **Integrations with the ecosystem you already use**: [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) extension (`:Telescope kaeru …`), [fzf-lua](https://github.com/ibhagwan/fzf-lua), [snacks.nvim](https://github.com/folke/snacks.nvim) picker, [mini.pick](https://github.com/echasnovski/mini.nvim), [lualine](https://github.com/nvim-lualine/lualine.nvim) component, [nvim-notify](https://github.com/rcarriga/nvim-notify), [fidget.nvim](https://github.com/j-hui/fidget.nvim), [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) jobs, plus detection of every external binary (`yt-dlp`, `mpv`, `ffmpeg`, `vlc`, `playerctl`, `mpc`, `gh`, `fzf`, `node`/`deno`/`bun`, …). `:Kaeru integrations` prints the report.
- **Plugin cache**: installed plugins archived as `cache/<name>.nvimpack` (zip, `.git` included) or `.pack` (git bundle for large repos) and restored before install — offline re-installs.
- **Starsky for Neovim Webclient** (`:Kaeru starsky` / `starsky/`): **SvelteKit 3 (Svelte 5, TypeScript, Vite 8, mobile-first)** web IDE on remote Neovim (open, save and `:` commands through the Node `neovim` client), Solar icons, the `:Kaeru` spec saver, SFTP Studio UI, all 601 Mason servers, 296 LSPconfig servers, and the universal 11-manager README parser.

```
╭──────────────────── kaeru.nvim · add a plugin to lazy.nvim ────────────────────╮
│  Repository    : folke/noice.nvim                                                  │
│  File          :  lua/plugins/<file>.lua  (auto from repo)                         │
│  Name          :  custom plugin name (optional)                                    │
│  Lazy          :  true / false                                                     │
│  Event         : VeryLazy                                                          │
│  Cmd           :  Telescope, Neotree ...  (lazy-load on command)                   │
│  Ft            :  lua, markdown ...  (lazy-load on filetype)                       │
│  Keys          :  <leader>ff, <C-n> ...  (lazy-load on keys)                       │
│  Dependencies  : MunifTanjim/nui.nvim, rcarriga/nvim-notify                        │
│  Version       :  semver range, * = latest release, false = branch head            │
│  ...                                                                               │
│  Opts          : { presets = { bottom_search = true } }                            │
│  Config        :  true, or `function` for a config() skeleton                      │
│                                                                                    │
│  <CR>/<C-s> write & install   <Tab>/<S-Tab> next/prev field   <C-b> browse GitHub  │
╰────────────────────────────────────────────────────────────────────────────────────╯
```

The form above generates `~/.config/nvim/lua/plugins/noice.lua`:

```lua
-- Generated by kaeru.nvim on 2026-10-14
-- Spec reference: https://lazy.folke.io/spec
return {
  "folke/noice.nvim",
  event = "VeryLazy",
  dependencies = {
    "MunifTanjim/nui.nvim",
    "rcarriga/nvim-notify",
  },
  opts = { presets = { bottom_search = true } },
}
```

## Requirements

- Neovim >= 0.8
- lazy.nvim using the [structured setup](https://lazy.folke.io/installation) (`spec = { { import = "plugins" } }`)
- `curl` (for the GitHub browser)

Optional — each one unlocks more, everything degrades gracefully without them:

| Binary | Unlocks |
| --- | --- |
| `mpv` (or `ffplay` / `vlc`) | Kikru playback, the EQ and the filter chain (`:Kikru engine` shows what is used) |
| `yt-dlp` | YouTube / YouTube Music / SoundCloud / Bandcamp / Mixcloud / Bilibili casting and search |
| `playerctl` | `:Kikru appcast` — continue the YouTube Music app, Spotify or a browser tab (MPRIS) |
| `mpc` | MPD control |
| `gh` | GitHub sign-in without pasting a token |
| `fzf`, `telescope.nvim`, `fzf-lua`, `snacks.nvim`, `mini.pick` | Picker backends for `:Kaeru pick`, `:Kaeru complete`, the Mason picker, … |
| `node` / `npm` | Starsky web client (`:Kaeru starsky`), SvelteKit + Vite |

## Installation

```lua
-- lua/plugins/kaeru.lua
return {
  "getwizardo/installer.nvim", -- repository slug; the plugin itself is kaeru.nvim
  cmd = { "Kaeru", "Kikru" },
  opts = {},
}
```

> **Name.** The plugin is *kaeru.nvim*: every module lives in `lua/kaeru`, the
> commands are `:Kaeru` / `:Kikru`, the help file is `doc/kaeru.txt`
> and augroups, sockets and state directories are all `kaeru*`. The GitHub
> repository keeps its historical slug `getwizardo/installer.nvim`, so that is
> what goes in the lazy.nvim spec.

## Usage

| Command                         | Description                                                            |
| ------------------------------- | ---------------------------------------------------------------------- |
| `:Kaeru`                    | Open the modal form                                                    |
| `:Kaeru owner/repo`         | Open the modal prefilled with a repository                             |
| `:Kaeru browse [query]`     | Browse Neovim plugins on GitHub                                        |
| `:Kaeru search [query]`     | Search GitHub and pick with `vim.ui.select` (telescope/fzf-lua/…)      |
| `:Kaeru add owner/repo`     | Write a bare `{ "owner/repo" }` spec and install right away            |
| `:Kaeru save owner/repo`    | Write a plugin spec file to `lua/plugins/<file>.lua` without installing |
| `:Kaeru parse [repo\|file]` | Parse any installer snippet from GitHub `README.md`, local file, or buffer |
| `:Kaeru dir`                | Show where spec files are written                                      |
| `:Kaeru ai [preset]`        | Curated AI coding plugins (NeoCodeium, Copilot, avante, …)              |
| `:Kaeru login\|logout\|whoami` | GitHub account                                                     |
| `:Kaeru sftp [action]`      | `ui` (dual-pane SFTP Studio), transfers, every sftp command, remote browser, shell |
| `:Kaeru config [...]`       | `edit`, `project`, `reload`, `show` — manage `kaeru.yaml`           |
| `:Kaeru cache [...]`        | `list`, `pack [name\|all]`, `restore <name>`, `remove`, `clean`, `dir`   |
| `:Kaeru mason [...]`        | Mason picker, `lsp\|dap\|linter\|formatter`, `install`, `ensure`, `export`, `scaffold` — see below |
| `:Kaeru starsky [...]`      | `start`, `stop`, `open`, `status`, `build`, `info` — SvelteKit TypeScript Starsky Webclient |
| `:Kaeru pick [source]`      | Open a picker (telescope / fzf-lua / snacks / mini.pick / `vim.ui.select`) over `plugins`, `mason`, `sftp`, `cache`, `radio`, `queue`, `cast` |
| `:Kaeru complete [partial]` | **Complete anything**: pick from every candidate for a partial command line and run it |
| `:Kaeru integrations`       | Report every detected picker, plugin and external binary |
| `:Kikru [...]`              | The player — see [Kikru](#:kikru--the-player) below |
| `:MusicPlayer [...]`        | Legacy alias of `:Kikru` (kept so old keymaps keep working) |

### Modal keys

| Key               | Action                                                       |
| ----------------- | ------------------------------------------------------------ |
| `<CR>` / `<C-s>`  | Write the spec file and install                              |
| `gs` / `<C-w>` / `:w` | Save the spec file (`lua/plugins/<file>.lua`) without installing |
| `<Tab>`/`<S-Tab>` | Next / previous completion item (when popup open) or field   |
| `<C-Space>`       | Trigger context-aware field autocomplete (`omnifunc`)        |
| `<C-r>` / `gp`    | Fetch & parse `README.md` for `Repository` and fill fields   |
| `<C-b>`           | Browse GitHub and fill the repository field                  |
| `dd`              | Clear the current field                                      |
| `q` / `<Esc>`     | Close                                                        |

### Browser keys

| Key           | Action                                                     |
| ------------- | ---------------------------------------------------------- |
| `<CR>`        | Open the modal prefilled with the selected plugin          |
| `p`           | Fetch & parse `README.md` and open modal with full spec    |
| `i`           | Quick install with a bare spec                             |
| `K`           | Preview the README                                         |
| `o`           | Open on GitHub                                             |
| `y`           | Yank `owner/repo`                                          |
| `]` / `[`     | Next / previous page                                       |
| `*`           | Star / unstar (needs `:Kaeru login`)                   |
| `S`           | Toggle your starred repositories                           |
| `s`           | Cycle sort: stars → updated → best-match                   |
| `t`           | Toggle scope: `topic:neovim-plugin` ↔ all of GitHub        |
| `/` / `<Tab>` | Focus the search prompt (`<C-n>`/`<C-p>` move while typing) |
| `q` / `<Esc>` | Close                                                      |

GitHub allows 10 unauthenticated searches per minute; signed-in users get 30.

## Autocomplete everything

kaeru.nvim ships its own completion engine — no dependency on cmp, blink or
anything else — and then *also* plugs into them.

**On the `:` command line** (for `:Kaeru` and `:Kikru`):

- fuzzy matching that ignores case and separators: `fole/laz` → `folke/lazy.nvim`,
  `ytm lo` → `:Kikru ytmusic lofi`
- every candidate carries a description (`menu`/`info`) shown in the popup
- contextual arguments: repositories (static list + **live GitHub search**, cached
  5 min), Mason packages by category, SFTP profiles, cache entries, AI presets,
  EQ presets, filter presets, visualizer modes, themes, engines, radio stations,
  queue/playlist actions, cast targets, playlists, and *paths* where a path makes
  sense
- live popup while typing (`CmdlineChanged`, 45 ms debounce), `<Tab>`/`<S-Tab>`
  cycling, and `wildoptions=pum,fuzzy` set for the `:` line
- **every built-in command** knows its own arguments (`:set`/`:setl`, `:au` and
  augroups, `:colorscheme`, `:help`, `:buffer`, `:lua`, `:syntax`,
  `:highlight`, `:sign`, `:packadd`, `:command`, `:let`, maps, file commands
  with `++enc=`/`++ff=`, `:cd`, `:make`/`:grep`, …)
- `complete.any` (on by default) extends the popup to **any** other `:` command
  through every `getcompletion` category (files, buffers, options, events,
  filetypes, colorschemes, help tags, mappings, environment variables, shell
  commands, augroups, tags) — a superset of Neovim's own `<Tab>`

```lua
require("kaeru").setup({
  complete = { cmdline = true, cmdline_tab = true, items = "dict", any = true },
})
```

**As a source for your completion plugin**

```lua
-- nvim-cmp
require("cmp").register_source("kaeru", require("kaeru.complete").cmp_source())

-- blink.cmp
require("blink.cmp").setup({
  cmdline = { sources = { "kaeru", "cmdline", "path" } },
  sources = {
    providers = { kaeru = require("kaeru.complete").blink_source() },
    default = { "lsp", "path", "buffer", "kaeru" },
  },
})
```

**Everywhere else** — the modal form uses the same engine as
`omnifunc`/`completefunc` (auto-triggered while typing, `<C-Space>` on demand)
including the live GitHub repository lookup.

**`:Kaeru complete`** is the escape hatch: it fuzzy-completes *anything*
(commands, files, options, our own subcommands, …) in a picker and runs the
chosen line — a discoverability browser for the whole editor:

```vim
:Kaeru complete Kikru ca        " → :Kikru cast … / :Kikru cast server …
:Kaeru complete Kaeru mason i   " → :Kaeru mason install …
```

## `:Kikru` — the player

`:Kikru` opens a floating, Winamp-2.x-inspired player (the layout and feature
set follow [cliamp](https://github.com/bjarneo/cliamp); the filter vocabulary
follows LavaLink/[NodeLink](https://github.com/PerformanC/NodeLink)).

```
╭─────────────── ── Kikru ──────────────────────────────╮
│  ▶ 1. Lofi Girl · Beats to Code / Relax To             │
│  03:12 ━━━━━━━━━━━━━━━━━━━╸─────────  ·  128 kbps      │
│  ▁▂▄▅▇█▇▅▄▃▂▁▂▃▅▇█▇▅▃▂▁▁▂▄▆█▆▄▂  spectrum             │
│  31  62 125 250 500 1k 2k 4k 8k 16k                    │
│  +2  +1   0  -1  -2   0  +1  +2  +3  +1   lofi-coding   │
╰────────────────────────────────────────────────────────╯
```

| Key | Action |
| --- | --- |
| `<Space>` | play / pause |
| `z` / `b` | next / previous track |
| `←` / `→` | seek ±5 s |
| `-` / `+` | volume down / up |
| `e` / `E` | 10-band EQ view / cycle presets |
| `f` | LavaLink-style filters (timescale, tremolo, 8D, karaoke, …) |
| `R` | radio browser (curated + Radio Browser search) |
| `/` | search (YouTube, YouTube Music, SoundCloud, …) |
| `P` | playlist / queue pane |
| `l` | lyrics pane — synced / word-level karaoke (lrc.red · LRCLIB · NetEase), translations |
| `c` | cast pane (link, server, appcast) |
| `?` | help · `q` close |

Command line:

```vim
:Kikru                                   " open the player
:Kikru play  <station|track|url>         " play anything
:Kikru queue add <url|dir>               " queue a track, a playlist or a folder
:Kikru library ~/Music                   " index a folder (recursive, tag reading)
:Kikru eq synthwave                      " EQ preset (flat, lofi-coding, bass-boost, …)
:Kikru band 1 4                          " band 1 → +4 dB (bands are 31 Hz…16 kHz)
:Kikru filter vaporwave                  " filter preset (nightcore, 8D, karaoke, …)
:Kikru visualizer spectrum               " spectrum | bars | wave | vu | matrix | starfield
:Kikru radio lofi                        " internet radio search
:Kikru playlist save coding.m3u          " M3U · PLS · TOML · JSON
:Kikru engine                            " which backends are installed
:Kikru daemon start                      " headless IPC daemon (socket)
:Kikru server 41999                      " 2-Neovim remote (control another Neovim)
:Kikru connect 192.168.1.20:41999        " …or be controlled by one
:Kikru lyrics                            " fetch + open the lyrics pane
:Kikru lyrics providers                  " the provider chain and what is enabled
:Kikru lyrics search <q> [provider]      " raw candidates (lrc.red match/search)
:Kikru lyrics refresh                    " forget the cache and look again
:Kikru lyrics save [file.lrc]            " write lyrics next to the audio file
:Kikru status --json                     " machine-readable state
```

State (volume, EQ, filters, queue, lyrics) is persisted to
`stdpath("data")/kaeru/kikru.json` when `kikru.persist = true`.

## Casting YouTube & YouTube Music

Three ways to get a link (or the app you are already playing) into Neovim:

```vim
" 1. paste a link, or just type a search
:Kikru cast https://music.youtube.com/watch?v=dQw4w9WgXcQ
:Kikru cast https://www.youtube.com/playlist?list=PL…      " whole playlist → queue
:Kikru cast lofi hip hop radio                             " → YouTube Music search
:Kikru youtube deep house mixes --queue                    " YouTube search → queue
:Kikru ytmusic daft punk discovery                         " YouTube Music search
:Kikru cast <url> --next                                   " insert after current track

" 2. cast from a phone / browser / Stream Deck: a tiny HTTP server
:Kikru cast server                                         " http://127.0.0.1:8722
```

Open `http://127.0.0.1:8722` in any browser (or on your phone, see below) to get
a cast box plus transport buttons. Endpoints (CORS-enabled, JSON):

| Endpoint | Purpose |
| --- | --- |
| `GET /cast?url=…&mode=play\|queue\|next` | cast a link or a search |
| `POST /cast {"url": "…"}` | same, for shortcuts/apps |
| `GET /ytm?q=…` · `GET /youtube?q=…` | search and play |
| `GET /appcast` | continue whatever MPRIS is playing |
| `GET /status` · `/queue` · `/eq?preset=…` · `/volume?value=70` | read/steer the player |
| `GET /play\|pause\|toggle\|next\|prev\|stop` · `/open` | transport |

```vim
:Kikru cast scheme        " install the kikru:// URL handler (+ ~/.local/bin/kaeru-cast)
:Kikru cast status        " server/scheme/yt-dlp report
:Kikru cast log           " recent casts
```

Once the scheme handler is installed, "Open with Kikru" / `xdg-open
"kikru://cast?url=<link>"` plays the link in Neovim.

**Cast the app that is playing** — no extension needed:

```vim
:Kikru appcast      " reads the current item of the YouTube Music app, a
                    " Chromium/Brave/Firefox tab, Spotify, VLC, … over MPRIS
                    " and continues it here (position, EQ and analyzer included)
```

YouTube Music specifics: `watch?v=…&list=RD…` mixes are treated as a video with
YouTube's radio following it, `playlist?list=PL…` expands to a full queue with
`yt-dlp --flat-playlist`, `shorts/`, `live/`, `youtu.be/`, `m.youtube.com`,
timestamps (`&t=1m30s`) and `@handle` / `channel/` links are all classified —
`:Kaeru complete Kikru cast` shows what is recognised.

```yaml
# kaeru.yaml
kikru:
  cast:
    port: 8722          # cast server (127.0.0.1)
    token: null        # optional shared secret → every request needs ?token=…
    auto_start: false  # start the server with the player
    ui: true           # focus the player when a cast arrives
```

Phone on the same Wi-Fi: the server binds `127.0.0.1` only. To reach it from a
phone, forward the port (`ssh -L 8722:127.0.0.1:8722 you@laptop`) or add an
iOS/Android shortcut that posts to the URL — or simply use the `kikru://`
handler on the machine that runs Neovim.

## `:Karu` — Google Cast, in TypeScript

`karu/` is a dependency-free TypeScript implementation of the protocol behind
Google Cast (the thing a Chromecast speaks). It works in **both directions**,
which is what makes casting into Neovim possible at all.

### Be a Cast device — cast from the YouTube app

```vim
:Karu receive                          " start the receiver (port 8009 + mDNS)
:Karu receive --name "Vim TV" --no-mdns
:Karu receive --fallback mpv           " play locally when Kikru is not running
:Karu off                              " stop the receiver
:Karu bridge                           " receiver + Kikru bridge status
```

Once it is running your machine shows up as a cast target (`Vim TV`) in the
**YouTube Music**, **YouTube**, **Chrome** and iOS Cast lists — the same list
your TV and speakers appear in. Tap the Cast button, pick `Vim TV`, and the
track is handed to Neovim: the URL goes through Kikru's yt-dlp pipeline, lands
in the queue and plays with your EQ, analyzer and lyrics. Transport buttons
(play / pause / stop / seek / the scrub bar) work from the phone; the receiver
mirrors them into mpv and reports the position back, which is why the phone's
progress bar follows the music.

What is implemented: mDNS advertisement of `_googlecast._tcp` (so apps *find*
you), CASTV2 over TLS on port 8009 with a self-signed ECDSA P-256 certificate,
the `tp.connection` / `tp.heartbeat` / `receiver` / `media` / `tp.deviceauth`
namespaces, the Default Media Receiver (`CC1AD845`) launch handshake, `LOAD` /
`PLAY` / `PAUSE` / `STOP` / `SEEK` / `GET_STATUS` / `SET_VOLUME`, and
`MEDIA_STATUS` broadcasts plus the `supportedMediaCommands` bitmask the apps
use to decide which controls to show.

```yaml
# kaeru.yaml
karu:
  enabled: true
  device_name: Karu · Neovim   # what the Cast list shows
  port: 8009                   # CASTV2 (fixed by the protocol)
  mdns: true                   # advertise _googlecast._tcp (needs a LAN, not a VPN)
  fallback: none               # mpv | ffplay | none — play locally when Kikru is down
  bridge: null                 # where casts are handed over (default 127.0.0.1:8722)
  autostart: false             # start the receiver with Neovim
  devices: []                  # extra host[:port] Cast devices to probe
```

### Cast to a real device — the sender side

```vim
:Karu discover                 " who is on the network (mDNS browse)
:Karu cast https://music.youtube.com/watch?v=… "Living room TV"
:Karu cast lofi hip hop radio  " a search is resolved with yt-dlp first
:Karu play | pause | toggle | quit | next | prev [dev]
:Karu seek 90 "Living room TV"
:Karu volume 70 | +10 | mute [dev]
:Karu status [dev]             " what the device is playing right now
:Karu probe 192.168.1.24:8009  " reachability + device status
:Karu info                     " protocol/environment report
```

`:Karu cast` launches the Default Media Receiver on the device, resolves the
target (a direct media URL, or a YouTube/YT Music search or link via `yt-dlp
-g`), and `LOAD`s it. That means a Neovim command can put a YouTube video on
the TV in the living room — and, because it is the same protocol, anything that
can cast can also *be* cast to.

### Requirements & notes

- Node ≥ 22.6 (the TypeScript is run directly — no build step). `:Karu info`
  prints the CLI, the Node version, the port and the namespaces.
- Nothing else: no `npm install` needed at runtime (dev dependencies are only
  TypeScript and `@types/node`). `karu/node_modules` is not required.
- The receiver and the sender can run at the same time (a receiver on 8009 plus
  outgoing control connections).
- The `:Karu` command is complete on the `:` line: subcommands, flags, device
  names from the last discovery, and hosts — `:Kaeru complete Karu ca` also works.

## Lyrics — lrc.red, karaoke & translations

The lyrics pane (`l`) resolves the current track through local sources first and
then a configurable provider chain:

```
tags (.flac/.mp3 USLT, Vorbis LYRICS)  →  <track>.lrc  →  cache  →  providers
```

| Provider | What it gives | API |
| --- | --- | --- |
| [**lrc.red**](https://lrc.red) | 29.8M tracks, 12.5M synced, **word-level timing**, TTML/LRC/YAML | `GET /match.json?track=&artist=&duration=` → ISRC → `GET /s/<ISRC>.lrc` |
| [LRCLIB](https://lrclib.net) | huge free synced/plain database | `GET /api/get` · `/api/search?q=` |
| NetEase Cloud Music | synced LRC + **translations** (`tlyric`) | `GET /api/search/get` → `/api/song/lyric` |
| [SyncLRC](https://synclrc.dev) | karaoke / synced / plain | `GET /api.synclrc.dev/lyrics?track=&artist=&format=lrc` |
| lyrics.ovh | plain text, last resort | `GET /api.lyrics.ovh/v1/<artist>/<title>` |

The chain stops at the first **synced** hit and remembers the first **plain**
hit as a fallback (`sync_first = false` takes the first hit of any kind). Every
provider is optional: `:Kikru lyrics providers` lists the chain and what is
enabled, and the pane footer shows where the current lyrics came from —
`lrc.red · Bohemian Rhapsody (word-synced, translated)`.

Because lrc.red, SyncLRC and many LRCLIB rows ship *enhanced* LRC
(`[00:03.73]<00:03.73>Is <00:04.14>this…`), the parser keeps the per-word timing
and the player turns it into a karaoke highlight; `Kikru` prints the sung part
of the current line while the rest of the line stays dim. Matching is
duration-aware (±3 s wins, ±10 s is preferred, >60 s is punished) and
order-insensitive, so `Bohemian Rhapsody (Remastered 2011)` lands on the right
ISRC. Results are cached under `stdpath("cache")/kaeru/lyrics` and can be
written next to the audio file:

```vim
:Kikru lyrics providers                    " provider chain + enabled flags
:Kikru lyrics search queen under pressure  " raw candidates (lrc.red / LRCLIB / NetEase)
:Kikru lyrics refresh                      " drop the cache and look again
:Kikru lyrics save ~/Music/Queen/bohemian.lrc
:Kikru lyrics save ~/Music/Queen/bohemian.ttml   " Apple-style TTML (needs Karu)
```

### TTML — Apple Music, QQ/NetEase and YouTube lyrics

`.ttml` files are first-class too. TTML carries what LRC cannot — per-syllable
timing, `<br/>` breaks, duet agents (`ttm:agent`, `itunes:songPart`), translation
and transliteration tracks, background vocals (`ttm:role="x-bg"`) — so the parser
lives in TypeScript (`karu/src/lyrics/ttml.ts`, built for
`itunes:timing="Word"|"Line"`, the AMLL/QQ/NetEase dialect, and YouTube's legacy
`<timedtext format="3">`) and normalises everything to enhanced LRC plus an
index-aligned translation track. The Lua pipeline then treats it exactly like an
lrc.red hit: word-level karaoke, translations in the pane, one cache, one
`describe()`.

```vim
" a sidecar file next to the audio is picked up automatically:
"   ~/Music/Queen/bohemian-would-be.flac
"   ~/Music/Queen/bohemian-would-be.ttml
:Kikru lyrics save ~/Music/Queen/bohemian.ttml   " write the current lyrics as TTML
```

TTML needs the Karu CLI (Node ≥ 22.6 or a compiled `karu`) — `:Kikru lyrics
providers` says whether it is available, and without it `.ttml` files are
skipped (never half-parsed). The converter is usable on its own:

```sh
karu lyrics song.ttml                  # → enhanced LRC (Kikru's karaoke format)
karu lyrics song.ttml --format ttml    # → normalised Apple-style TTML
karu lyrics song.ttml --format json    # → cues, per-word timings, translations
karu lyrics song.ttml --format srt --out song.srt   # lyrics as subtitles (mpv --sub-file)
karu lyrics - --format summary < x.lrc # → "35 lines · 00:13.13–03:10.12 · word-timed · 2 singers"
```

```lua
require("kaeru").setup({
  kikru = {
    lyrics = {
      providers = { "lrc.red", "lrclib", "netease", "synclrc", "lyrics.ovh" },
      sync_first = true,     -- keep looking for timed lyrics after a plain hit
      cache = true,          -- stdpath("cache")/kaeru/lyrics
      cache_dir = nil,       -- or your own directory
      save_sidecar = false,  -- also write <track>.lrc when lyrics came online
      translations = true,   -- show `tlyric` translations (NetEase)
      karaoke = true,        -- word-level highlight when the provider has it
    },
  },
})
```

The API is also usable directly:

```lua
local Lyrics = require("kaeru.kikru.lyrics")
Lyrics.resolve({ title = "Bohemian Rhapsody", artist = "Queen", path = "/music/br.flac" },
  { provider = "lrc.red" }, function(err, lyrics)
    print(lyrics.source, #lyrics.synced, lyrics.synced[1].words and "word-level" or "line-level")
  end)
```

## Integrations

```vim
:Kaeru integrations        " ✓ / · for every picker, plugin and binary
```

```lua
-- telescope
require("telescope").load_extension("kaeru")
-- :Telescope kaeru plugins | mason | sftp | cache | radio | queue | cast

-- lualine
require("kaeru.integrations").setup_lualine()          -- adds the now-playing component
-- or as a component: { require("kaeru.integrations").lualine(), cond = ... }

-- statusline without a plugin
require("kaeru.integrations").setup_statusline()

-- notifications & progress (nvim-notify, fidget)
require("kaeru.integrations").setup({ notify = true, scheme = true })
```

The Kikru theme follows your `:colorscheme` (tokyonight, nord, dracula, gruvbox,
catppuccin, …) unless you pin `kikru.theme`.

## GitHub account

```vim
:Kaeru login          " pick: GitHub CLI · paste a token · browser (device flow)
:Kaeru whoami         " user + remaining search quota
:Kaeru logout
```

Token resolution order: `github.token` → token saved by `:Kaeru login` → `$GITHUB_TOKEN`/`$GH_TOKEN` → `gh auth token`.
The browser device flow needs your own OAuth app (`github.client_id`, with *Device Flow* enabled). Starring requires the `public_repo` scope (or the fine-grained *Starring* permission).

## AI coding plugins (opt-in)

```lua
require("kaeru").setup({ ai = { enabled = true } })
```

`:Kaeru ai` lists ready-made lazy.nvim specs, grouped by what they do:

| Category | Presets |
| --- | --- |
| Inline completion | [neocodeium](https://github.com/monkoose/neocodeium), [copilot.lua](https://github.com/zbirenbaum/copilot.lua), [copilot.vim](https://github.com/github/copilot.vim), [supermaven-nvim](https://github.com/supermaven-inc/supermaven-nvim), [windsurf.nvim](https://github.com/Exafunction/windsurf.nvim), [minuet-ai.nvim](https://github.com/milanglacier/minuet-ai.nvim) |
| Chat & inline edits | [codecompanion.nvim](https://github.com/olimorris/codecompanion.nvim), [avante.nvim](https://github.com/avante-corp/avante.nvim), [CopilotChat.nvim](https://github.com/CopilotC-Nvim/CopilotChat.nvim), [gp.nvim](https://github.com/Robitx/gp.nvim), [parrot.nvim](https://github.com/frankroeder/parrot.nvim), [gen.nvim](https://github.com/David-Kunz/gen.nvim) |
| Coding agents | [sidekick.nvim](https://github.com/folke/sidekick.nvim), [claudecode.nvim](https://github.com/coder/claudecode.nvim), [opencode.nvim](https://github.com/nickjvandyke/opencode.nvim), [claude-code.nvim](https://github.com/greggh/claude-code.nvim), [nvim-aider](https://github.com/GeorgesAlkhouri/nvim-aider) |
| Add-ons | [mcphub.nvim](https://github.com/ravitemer/mcphub.nvim), [copilot-cmp](https://github.com/zbirenbaum/copilot-cmp), [blink-copilot](https://github.com/fang2hou/blink-copilot) |

`<CR>` opens the modal with the preset filled in so you can review it, `i` installs immediately, `K` shows the generated spec. Presets mirror each project's README install snippet (e.g. avante's `build = "make"`, CopilotChat's `make tiktoken`); API keys, CLIs and subscriptions remain yours to set up.

For NeoCodeium, pick the `neocodeium` preset, then use the plugin's own commands (`:NeoCodeium auth`, `:NeoCodeium toggle`). kaeru.nvim has no AI wrapper command.

## SFTP

```vim
" transfers
:Kaeru sftp init             " creates .nvim-sftp.json in the cwd
:Kaeru sftp upload [path]    " current file, or a file / directory
:Kaeru sftp upload-project   " all project files, N parallel sftp workers
:Kaeru sftp sync             " only files changed since the last sync
:Kaeru sftp download         " current file
:Kaeru sftp download-project " whole remote tree (scp -r)
:Kaeru sftp diff             " buffer vs remote copy (diffsplit)

" every sftp command — paths are relative to remotePath unless absolute
:Kaeru sftp ls [path]        :Kaeru sftp mkdir|rmdir|rm <path>
:Kaeru sftp rename <a> <b>   :Kaeru sftp chmod|chown|chgrp <v> <path>
:Kaeru sftp ln [-s] <a> <b>  :Kaeru sftp symlink <a> <b>
:Kaeru sftp df [path]        :Kaeru sftp pwd | version
:Kaeru sftp exec mkdir a; put x.txt a/x.txt     " raw sftp batch
:Kaeru sftp run tail -n 50 logs/app.log         " any command over ssh

" sessions & tools
:Kaeru sftp browse [path]    " remote file browser (open, download, upload, mkdir, rename, delete)
:Kaeru sftp shell | ssh      " interactive sftp / shell in a terminal split
:Kaeru sftp test             " connection test + the resolved command line
:Kaeru sftp status | select
```

```json
{
  "name": "production",
  "host": "example.com",
  "port": 22,
  "username": "deploy",
  "remotePath": "/var/www/app",
  "privateKeyPaths": ["~/.ssh/deploy_ed25519", "~/.ssh/id_rsa"],
  "identitiesOnly": true,
  "proxyJump": "bastion.example.com",
  "sshConfigFile": "~/.ssh/config",
  "options": { "ServerAliveInterval": 30 },
  "ignore": [".git", "node_modules", "dist"],
  "uploadOnSave": false
}
```

Keys are tried in order (`-i` each); `sftp.keys` / `sftp.options` in `kaeru.yaml` provide defaults for every profile, and `host` may be an alias from your ssh config. The file may be an array of profiles; profiles can also live in `sftp.profiles` (JSON or YAML). Uploads are git-aware (`git ls-files` + ignore globs), split round-robin across `sftp.concurrency` concurrent `sftp -b` processes, and create remote directories as needed. `password` works when `sshpass` is installed, but keys / ssh-agent are recommended. The config file is never uploaded — gitignore it if it holds secrets.

## Configuration — `kaeru.yaml`

Everything below can be written in YAML instead of Lua. `:Kaeru config` creates and opens the global file (`~/.config/nvim/kaeru.yaml`); `:Kaeru config project` creates `./kaeru.yaml` for the current project (read via `vim.secure.read`, so you trust it once). Precedence: defaults < global < project < `setup()` opts. `:Kaeru config reload` / `show` re-read and print the effective configuration.

```yaml
after_write: install
ai:
  enabled: true
github:
  client_id: Iv1.xxxxxxxx
cache:
  pack_threshold: 104857600   # 100 MiB
sftp:
  concurrency: 8
  keys: [~/.ssh/id_ed25519, ~/.ssh/id_rsa]
  options: {ServerAliveInterval: 30}
  profiles:
    prod:
      host: example.com
      username: deploy
      remotePath: /var/www/app
      localPath: ~/projects/app
      proxyJump: bastion.example.com
      uploadOnSave: true
```

## Plugin cache

Installed plugins are archived under `~/.cache/nvim/kaeru/`:

| File | Content | Used when |
| --- | --- | --- |
| `<name>.nvimpack` | zip of the whole plugin directory — every file and folder, `.git` included (tar.gz fallback) | default |
| `<name>.pack` | `git bundle --all` — only git objects, much smaller | directory larger than `cache.pack_threshold` (50 MiB) |
| `index.json` | format, size, commit, url, date | — |

`auto_pack` archives a plugin right after it is installed; `auto_restore` unpacks a cached plugin into the lazy.nvim root *before* `:Lazy install` runs, so re-installs need no network. Bundles get their `origin` reset to the real URL so `:Lazy update` keeps working.

```vim
:Kaeru cache list              " <CR> restore · p re-pack · D remove
:Kaeru cache pack all          " archive every installed plugin
:Kaeru cache restore <name>    " ! to overwrite an existing directory
:Kaeru cache clean             " drop archives of plugins no longer in the spec
```

## Mason (LSP / DAP / linters / formatters)

`:Kaeru mason` opens a picker over the whole [mason.nvim](https://github.com/mason-org/mason.nvim) registry (the registry is refreshed once per session). Requires mason.nvim; if it is missing, `:Kaeru mason scaffold lsp` adds it to your lazy.nvim specs.

```vim
:Kaeru mason                       " picker over every package
:Kaeru mason lsp|dap|linter|formatter|compiler|runtime [query]
:Kaeru mason ft                    " packages for the current filetype
:Kaeru mason install lua_ls stylua debugpy   " lspconfig names, aliases or Mason names
:Kaeru mason uninstall|update <name>
:Kaeru mason upgrade               " update the registry, reinstall outdated packages
:Kaeru mason ensure                " install everything in kaeru.yaml mason.ensure_installed
:Kaeru mason export                " write the installed packages back to kaeru.yaml
:Kaeru mason list                  " installed packages with versions
:Kaeru mason scaffold lsp|dap|tools
:Kaeru mason ui                    " plain :Mason
```

Picker keys: type to filter (name, lspconfig name, language, description), `<Tab>`/`/` switch between prompt and list, `<CR>`/`i` install, `x` uninstall, `u` update, `<Space>` mark several then `<CR>` to install them `concurrency` at a time, `f` cycle category, `l` filter by the filetype you came from, `t` installed only, `K` details, `o` homepage, `y` yank name, `U` refresh registry, `M` open `:Mason`, `?` help, `q` close.

Scaffolds write ready-to-use lazy.nvim specs into your plugins directory and install them:

| `scaffold` | File | Plugins |
| --- | --- | --- |
| `lsp` | `lua/plugins/mason.lua` | mason.nvim, mason-lspconfig.nvim, nvim-lspconfig (`ensure_installed` from `kaeru.yaml`) |
| `dap` | `lua/plugins/dap.lua` | nvim-dap, nvim-dap-ui, nvim-nio, mason-nvim-dap.nvim |
| `tools` | `lua/plugins/tools.lua` | mason-tool-installer.nvim, conform.nvim, nvim-lint |

```yaml
# kaeru.yaml
mason:
  ensure_installed: [lua-language-server, lua_ls, stylua, debugpy]  # Mason or lspconfig names
  auto_ensure: false        # run `ensure` after setup()
  refresh_registry: true
  concurrency: 2
  open_ui_on_install: false
```

## Configuration (Lua)

```lua
require("kaeru").setup({
  config = { global = vim.fn.stdpath("config") .. "/kaeru.yaml", project = "kaeru.yaml" },
  -- nil = auto-detect from lazy.nvim's `{ import = "plugins" }`,
  -- or a directory string / function returning one
  plugins_dir = nil,
  after_write = "install", -- "install" | "edit" | "none"
  confirm_overwrite = true,
  header = true,
  ui = { border = "rounded", width = 0.6, height = 0.7, winblend = 0 },
  github = {
    token = nil, -- falls back to $GITHUB_TOKEN / $GH_TOKEN
    topic_query = "topic:neovim-plugin",
    broad_query = "neovim in:name,description,topics",
    per_page = 30,
    sort = "stars", -- "stars" | "updated" | "best-match"
    debounce = 450,
    client_id = nil, -- OAuth app id for browser sign-in (device flow)
    auto_login = true, -- use any available token when the browser opens
  },
  ai = { enabled = false, exclude = {} },
  -- Live `:` autocomplete (see "Autocomplete everything")
  complete = { cmdline = true, cmdline_tab = true, items = "dict", any = true },
  -- The Kikru player (`:Kikru`); `music` is accepted as an alias of `kikru`
  kikru = {
    engine = "auto",                 -- auto | mpv | ffplay | vlc | mpd | mpris
    volume = 78,
    eq_preset = "lofi-coding",
    visualizer = "spectrum",
    theme = "winamp",
    persist = true,
    playlist_dir = nil,              -- nil = stdpath("data")/kaeru/playlists
    ipc_socket = nil,                -- nil = $XDG_RUNTIME_DIR/nvim-kaeru-kikru.sock
    daemon_on_start = false,
    cast = { port = 8722, token = nil, auto_start = false, ui = true },
    subsonic = { url = nil, user = nil, password = nil },
    ytdlp_cookies = nil,
    ytdlp_extra_args = {},
  },
  cache = {
    enabled = true,
    dir = vim.fn.stdpath("cache") .. "/kaeru",
    pack_threshold = 50 * 1024 * 1024,
    auto_pack = true,
    auto_restore = true,
  },
  sftp = {
    concurrency = 4,
    config_file = ".nvim-sftp.json",
    profiles = {}, -- global profiles keyed by name
    ignore = { ".git", "node_modules", ".DS_Store", "*.swp" },
    upload_on_save = false,
    keys = {}, -- default private keys, tried in order
    options = {}, -- default `ssh -o` options
    extra_args = {},
  },
})
```

## Lua API

```lua
local kaeru = require("kaeru")
kaeru.open({ repo = "folke/noice.nvim" })        -- modal
kaeru.browse({ query = "telescope" })            -- GitHub browser
kaeru.search("colorscheme")                      -- vim.ui.select picker
kaeru.add({ repo = "folke/todo-comments.nvim", event = "VeryLazy", opts = "{}" })
print(kaeru.preview({ repo = "folke/flash.nvim", keys = "s, S" }))
kaeru.account.login("gh")                        -- or "token" / "device"
kaeru.ai.pick()                                  -- AI presets picker
kaeru.sftp.upload_project()                      -- parallel upload
kaeru.sftp.run("git pull")                       -- command over ssh
kaeru.cache.pack("noice.nvim")                   -- archive a plugin
kaeru.config.dump()                              -- effective config as YAML

-- the player
local kikru = require("kaeru.kikru")
kikru.action("eq_preset", { preset = "synthwave" })
kikru.cast("https://music.youtube.com/watch?v=…")   -- cast a link
kikru.youtube_music("lofi beats")                   -- YT Music search → play
kikru.appcast()                                     -- continue the MPRIS app
kikru.cast_server(8722)                             -- start the cast server
kikru.get_snapshot()                                -- everything the UI/web needs

-- completion engine
local complete = require("kaeru.complete")
complete.complete_items("Kikru cast https://youtu.be/…", 30)  -- rich items
complete.everything("teles")                                  -- *everything* fuzzy
complete.cmp_source() / complete.blink_source()               -- cmp/blink providers

-- integrations
require("kaeru.integrations").pick(items, { title = "…", on_choice = fn })
require("kaeru.integrations").statusline({ width = 40 })
require("kaeru.integrations").job({ "yt-dlp", "-g", url }, {}, cb)  -- plenary when available
```

### Migrating from 1.x

| 1.x | 2.x |
| --- | --- |
| `installer.nvim`, `:Installer` | `kaeru.nvim`, `:Kaeru` |
| `:MusicPlayer`, `require("installer.music")` | `:Kikru`, `require("kaeru.kikru")` |
| `require("installer").music` | `require("kaeru").kikru` (alias `require("kaeru").music` remains) |
| `music:` in `kaeru.yaml` | `kikru:` (both accepted) |
| `:Installer music …` | `:Kikru …` (both accepted) |

Help tags, augroups, the `installed_kaeru_nvim` global, the spec directory and
the palette are all renamed accordingly; `:MusicPlayer` still works and simply
forwards to `:Kikru`.

## How it works

lazy.nvim merges every `lua/<module>/*.lua` file for each `{ import = "<module>" }` entry in your spec. kaeru.nvim

1. reads the import modules from `require("lazy.core.config").spec.modules` and resolves the first one inside `stdpath("config")` (usually `~/.config/nvim/lua/plugins`);
2. writes `<file>.lua` returning a single spec table;
3. calls `require("lazy.core.plugin").load()` so lazy.nvim re-reads its specs, then `require("lazy").install({ plugins = { name } })`, which opens the lazy.nvim UI and clones the plugin.

Generated files are plain lazy.nvim specs — edit them freely afterwards.

## Universal `README.md` Kaeru Parser

`:Kaeru parse` (or `:Kaeru readme`) parses installation blocks from any plugin's `README.md` (on GitHub, in a local file, or in the current buffer/visual selection) and converts them into a `lazy.nvim` spec:

- **lazy.nvim**: `{ "owner/repo", event = ..., opts = ..., dependencies = ... }`, `return { ... }`, `require("lazy").setup(...)`
- **packer.nvim**: `use 'owner/repo'`, `use { 'owner/repo', requires = ..., run = ..., opt = true, as = ... }`
- **vim-plug**: `Plug 'owner/repo', { 'do': '...', 'branch': '...', 'tag': '...', 'on': '...', 'for': [...] }` (including multi-`Plug` dependency blocks)
- **pckr.nvim**: `require('pckr').add{ { 'owner/repo', run = '...', cond = cmd('...') } }`
- **mini.deps**: `MiniDeps.add({ source = 'owner/repo', depends = {...}, checkout = '...', hooks = {...} })`
- **vim.pack** (Neovim 0.12): `vim.pack.add({ { src = 'https://github.com/owner/repo', version = '...' } })`
- **paq-nvim**: `require("paq")({ ... })`
- **dein.vim / Vundle**: `call dein#add('owner/repo', { ... })`, `Plugin 'owner/repo'`, `Bundle 'owner/repo'`
- **rocks.nvim / `git clone` / `:MasonInstall` / `require("...").setup({...})`**

```vim
:Kaeru parse folke/noice.nvim      " fetch GitHub README, parse spec, open modal
:Kaeru! parse folke/noice.nvim     " fetch GitHub README, parse spec, install immediately
:Kaeru parse ./README.md           " parse all plugin specs from a local README.md
:'<,'>Kaeru parse                  " parse selected snippet in current buffer
```

## `:Kikru` — Built-in Player with 10-Band EQ, Visualizer, Radio & 2-Neovim Device Controller

`:Kikru` provides a floating music & radio studio inside Neovim and in the Starsky Web IDE, including a **2-Neovim Device Controller (`Server <-> Client`)** over TCP (`vim.uv.new_tcp()`):

```vim
:Kikru                           " open the floating :Kikru studio (EQ, Visualizer, Radio)
:Kikru server 41999              " start the 2-Neovim TCP Server on Neovim Instance #1
:Kikru connect 127.0.0.1:41999   " connect Neovim Instance #2 as a synced Client
:Kikru eq synthwave              " apply a 10-band EQ preset (lofi-coding, synthwave, bass-boost, flat, ...)
:Kikru visualizer spectrum       " switch real-time ASCII visualizer (spectrum, wave, vu, matrix, starfield)
```

## `:Kaeru boot` — ASCII Boot Animation

```vim
:Kaeru boot                        " play the interactive STARSKY / INSTALLER.NVIM ASCII boot sequence
```

## ASCII welcome screen

When Neovim starts without file arguments, kaeru.nvim shows the same ASCII logo as a `nofile`, `nomodifiable` scratch buffer. `e` or `q` opens an empty buffer.

```lua
require("kaeru").setup({ welcome = { enabled = false } }) -- on by default
```

## Starsky Code IDE for Neovim (`starsky/`)

Starsky is the **SvelteKit 3 (Svelte 5 + TypeScript)** webclient for `kaeru.nvim`. It is mobile-first: a bottom tab bar on phones, a top bar with a two-column split from 768px, and the full IDE layout (file explorer | editor + terminal | NeoCodeium card) from 1100px.

- **Files the IDE never serves**: `.git/`, `.env*`, `.npmrc`, `.netrc`, `.pypirc`, `id_*` keys and `*.pem|key|p12|pfx`. They are hidden from the file list and refused on open, save, `:e` and read.
- **Remote Neovim**: the IDE edits through a Neovim session using the official **Node Neovim client (`neovim` npm package)**. By default Starsky starts its own headless Neovim (`nvim --embed --headless -n -i NONE -u NONE`). Set `STARSKY_NVIM_SOCKET=/path/to/nvim.sock` to attach to a Neovim you already run with `nvim --listen`; Starsky never starts or stops that instance.
- **Server routes (`starsky/src/routes/api/*/+server.ts`)**: `files` (repo file list), `nvim` (open, save and `:` commands), `spec`, `spec/save` (writes into the plugins dir, never overwrites without `overwrite`), `complete`, `github`, `mason`, `parse`, `sftp`, `music`, `status`.
- **Web terminal**: only a fixed set of Ex commands runs (`help`, `w`, `e`, `ls`, `Kaeru save <repo>`, `Kaeru dir`, `Kikru play|pause|next|prev`). Anything else (shell escapes such as `!id`) is refused.
- **Icons**: [Solar](https://icon-sets.iconify.design/solar/) by 480 Design, licensed CC-BY-4.0. A generated 40-icon subset lives in `starsky/src/lib/client/solar.ts` and is rendered by `Icon.svelte`. Regenerate with `npm run icons`.
- **Web Components (`starsky/src/lib/client/webComponents.ts`, registered in the browser only)**:
  - `<starsky-code-editor>`: Shadow DOM code editor with line numbers and a status bar. NeoCodeium inline ghost-text keys: `<A-f>` accept, `<A-w>` word, `<A-a>` line, `<A-e>` cycle.
  - `<starsky-ascii-boot>`: animated ASCII boot terminal.
  - `<starsky-eq-visualizer>`: 60fps canvas spectrum and waveform visualizer for `:Kikru`.
  - `<starsky-terminal>`: interactive Neovim Ex-command terminal (`help`, `w`, `e`, `ls`, `Kaeru save <repo>`, `Kikru play`).
- **Panels (`starsky/src/lib/components/`)**: Spec builder (mirrors the `:Kaeru` modal), Parser, GitHub search, Mason and LSP explorer (601 Mason packages, 296 `lspconfig` mappings), SFTP dual-pane studio, Music player, and the IDE with the NeoCodeium spec saver and keymap reference.
- **Live GitHub completions (`/api/complete`)**: queries `https://api.github.com/search/repositories` as you type in `repo` or `dependencies`.

```vim
:Kaeru starsky start               " start the SvelteKit dev server on 0.0.0.0:5173 and open the browser
:Kaeru starsky status              " check server status
:Kaeru starsky build               " npm run build (Vite + adapter-node) into starsky/build/
:Kaeru starsky stop                " stop the webclient
:Kaeru starsky info                " KIT splash: big pixel letters in a random color, animated pixel 3 (q closes)
```

Or from the shell:

```sh
cd starsky
npm install
npm run dev                        # development, http://localhost:5173
npm run build && node build        # production, serves on PORT (default 3000) and HOST
npm run check                      # svelte-check type checking
```

## Development

```sh
make test   # runs the spec tests with LuaJIT (no Neovim required)
```

## License

kaeru.nvim is MIT licensed.

Icons: [Solar](https://icon-sets.iconify.design/solar/) by 480 Design, CC-BY-4.0.
