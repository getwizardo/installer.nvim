
export interface MusicStation {
  id: string;
  title: string;
  artist: string;
  genre: string;
  service: string;
  url: string;
  bitrate: string;
}

export interface NeovimMusicDevice {
  id: string;
  name: string;
  role: "server" | "client";
  addr: string;
  pid: number;
  connectedAt: string;
  active: boolean;
}

const EQ_FREQUENCIES = [
  "31Hz",
  "62Hz",
  "125Hz",
  "250Hz",
  "500Hz",
  "1kHz",
  "2kHz",
  "4kHz",
  "8kHz",
  "16kHz",
];

const EQ_PRESETS: Record<string, number[]> = {
  flat: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
  "bass-boost": [8, 7, 5, 2, 0, 0, 1, 2, 2, 1],
  "lofi-coding": [4, 5, 3, 1, -1, -2, -4, -5, -6, -7],
  synthwave: [6, 5, 2, -1, 1, 3, 5, 6, 7, 5],
  vocal: [-3, -2, 0, 3, 5, 5, 4, 2, 0, -1],
  electronic: [6, 5, 1, 0, -2, 2, 1, 3, 6, 7],
  classical: [4, 3, 2, 1, -1, -1, 0, 2, 3, 4],
  night: [-4, -2, 0, 2, 2, 1, 0, -2, -3, -5],
};

const STATIONS: MusicStation[] = [
  {
    id: "lofi-girl",
    title: "Lofi Girl · Beats to Code / Relax To",
    artist: "Lofi Girl Radio",
    genre: "Lo-Fi / Chillhop",
    service: "Internet Radio",
    url: "https://play.streamafrica.net/lofiradio",
    bitrate: "128 kbps",
  },
  {
    id: "somafm-groovesalad",
    title: "SomaFM · Groove Salad",
    artist: "SomaFM San Francisco",
    genre: "Ambient / Downtempo",
    service: "SomaFM Stream",
    url: "https://ice1.somafm.com/groovesalad-128-mp3",
    bitrate: "128 kbps",
  },
  {
    id: "somafm-defcon",
    title: "SomaFM · DEF CON Radio",
    artist: "SomaFM Hacker Stream",
    genre: "Electronic / Hacker",
    service: "SomaFM Stream",
    url: "https://ice1.somafm.com/defcon-128-mp3",
    bitrate: "128 kbps",
  },
  {
    id: "nightride-fm",
    title: "Nightride FM · Cyberpunk Synthwave",
    artist: "Nightride FM",
    genre: "Synthwave / Outrun",
    service: "Nightride Stream",
    url: "https://stream.nightride.fm/nightride.m4a",
    bitrate: "192 kbps",
  },
  {
    id: "coderadio-fcc",
    title: "freeCodeCamp · Code Radio 24/7",
    artist: "freeCodeCamp",
    genre: "Coding Beats",
    service: "CodeRadio Stream",
    url: "https://coderadio-admin-v2.freecodecamp.org/listen/coderadio/radio.mp3",
    bitrate: "128 kbps",
  },
  {
    id: "somafm-dronezone",
    title: "SomaFM · Drone Zone",
    artist: "SomaFM Ambient",
    genre: "Atmospheric / Space",
    service: "SomaFM Stream",
    url: "https://ice1.somafm.com/dronezone-128-mp3",
    bitrate: "128 kbps",
  },
  {
    id: "somafm-secretagent",
    title: "SomaFM · Secret Agent",
    artist: "SomaFM Lounge",
    genre: "Spy Jazz / Lounge",
    service: "SomaFM Stream",
    url: "https://ice1.somafm.com/secretagent-128-mp3",
    bitrate: "128 kbps",
  },
];

const STREAMING_SERVICES = [
  {
    id: "radio",
    name: "Internet Radio (Icecast / HLS)",
    status: "active",
    desc: "Direct live streaming from SomaFM, Lofi Girl, Nightride FM & CodeRadio",
  },
  {
    id: "spotify",
    name: "Spotify Connect (playerctl / spotifyd)",
    status: "ready",
    desc: "Control Spotify playback and sync track metadata via MPRIS / Spotify Connect",
  },
  {
    id: "youtube",
    name: "YouTube Kikru (yt-dlp + mpv)",
    status: "ready",
    desc: "Stream coding mixes and playlists from YouTube Kikru",
  },
  {
    id: "soundcloud",
    name: "SoundCloud Stream",
    status: "ready",
    desc: "Stream electronic, synthwave, and indie tracks from SoundCloud",
  },
  {
    id: "subsonic",
    name: "Subsonic / Navidrome Self-Hosted",
    status: "ready",
    desc: "Connect to your self-hosted Subsonic/Navidrome music server",
  },
  {
    id: "mpd",
    name: "MPD (Kikru Player Daemon)",
    status: "ready",
    desc: "Bridge to local or remote Kikru Player Daemon (`mpc`)",
  },
];

const musicState = {
  playing: true,
  stationIdx: 0,
  serviceId: "radio",
  volume: 78,
  eqPreset: "lofi-coding",
  eqBands: [...EQ_PRESETS["lofi-coding"]],
  visualizer: "spectrum" as "spectrum" | "wave" | "vu" | "matrix" | "starfield",
  role: "server" as "server" | "client",
  port: 41999,
  devices: [
    {
      id: "nvim-server-1",
      name: "Neovim Instance #1 (:Kikru server)",
      role: "server",
      addr: "127.0.0.1:41999",
      pid: 4101,
      connectedAt: "02:50:12",
      active: true,
    },
    {
      id: "nvim-client-2",
      name: "Neovim Instance #2 (:Kikru connect)",
      role: "client",
      addr: "127.0.0.1:54812 → :41999",
      pid: 4829,
      connectedAt: "02:50:19",
      active: false,
    },
  ] as NeovimMusicDevice[],
  rpcLog: [
    "[RPC 127.0.0.1:41999] Neovim #1 started :Kikru TCP Server",
    "[RPC 127.0.0.1:41999] Neovim #2 connected via `:Kikru connect 127.0.0.1:41999`",
    "[RPC Broadcast] Synced 10-band EQ preset `lofi-coding` to all paired Neovim clients",
  ],
};

function logRpc(entry: string) {
  musicState.rpcLog.unshift(
    `[${new Date().toISOString().slice(11, 19)}] ${entry}`
  );
  if (musicState.rpcLog.length > 20) musicState.rpcLog.pop();
}

export function getMusicSnapshot() {
  return {
    ok: true,
    state: musicState,
    station: STATIONS[musicState.stationIdx] || STATIONS[0],
    stations: STATIONS,
    services: STREAMING_SERVICES,
    eqFrequencies: EQ_FREQUENCIES,
    eqPresets: EQ_PRESETS,
  };
}

export function musicAction(body: Record<string, any>) {
    const action = String(body.action || "");

    if (action === "toggle") {
      musicState.playing = !musicState.playing;
      logRpc(
        `Server<->Client RPC: Playback ${
          musicState.playing ? "RESUMED" : "PAUSED"
        }`
      );
    } else if (action === "next") {
      musicState.stationIdx = (musicState.stationIdx + 1) % STATIONS.length;
      logRpc(
        `Server<->Client RPC: Switched station → ${
          STATIONS[musicState.stationIdx].title
        }`
      );
    } else if (action === "prev") {
      musicState.stationIdx =
        (musicState.stationIdx - 1 + STATIONS.length) % STATIONS.length;
      logRpc(
        `Server<->Client RPC: Switched station → ${
          STATIONS[musicState.stationIdx].title
        }`
      );
    } else if (action === "station") {
      const idx = Number(body.index ?? 0);
      if (STATIONS[idx]) {
        musicState.stationIdx = idx;
        musicState.playing = true;
        logRpc(
          `Server<->Client RPC: Selected station ${STATIONS[idx].title}`
        );
      }
    } else if (action === "volume") {
      musicState.volume = Math.max(0, Math.min(100, Number(body.volume ?? 78)));
      logRpc(`Server<->Client RPC: Volume synced to ${musicState.volume}%`);
    } else if (action === "eqPreset") {
      const preset = String(body.preset || "flat");
      if (EQ_PRESETS[preset]) {
        musicState.eqPreset = preset;
        musicState.eqBands = [...EQ_PRESETS[preset]];
        logRpc(`Server<->Client RPC: Applied 10-band EQ preset "${preset}"`);
      }
    } else if (action === "eqBand") {
      const idx = Number(body.bandIndex ?? 0);
      const gain = Number(body.gain ?? 0);
      if (idx >= 0 && idx < 10) {
        musicState.eqBands[idx] = Math.max(-12, Math.min(12, gain));
        musicState.eqPreset = "custom";
        logRpc(
          `Server<->Client RPC: Band ${EQ_FREQUENCIES[idx]} set to ${
            gain >= 0 ? "+" : ""
          }${gain}dB`
        );
      }
    } else if (action === "visualizer") {
      musicState.visualizer = body.mode || "spectrum";
      logRpc(
        `Server<->Client RPC: Visualizer mode → ${musicState.visualizer}`
      );
    } else if (action === "service") {
      musicState.serviceId = String(body.serviceId || "radio");
      logRpc(
        `Server<->Client RPC: Streaming connector → ${musicState.serviceId}`
      );
    } else if (action === "handoffDevice") {
      const targetId = String(body.deviceId || "");
      musicState.devices = musicState.devices.map((d) => ({
        ...d,
        active: d.id === targetId,
      }));
      logRpc(
        `2-Neovim Device Handoff: Active audio output routed to ${targetId}`
      );
    } else if (action === "pairClient") {
      const clientNum = musicState.devices.length + 1;
      const newDev: NeovimMusicDevice = {
        id: `nvim-client-${clientNum}`,
        name:
          body.name ||
          `Neovim Instance #${clientNum} (:Kikru connect 127.0.0.1:${musicState.port})`,
        role: "client",
        addr: `127.0.0.1:${55000 + clientNum} → :${musicState.port}`,
        pid: 5000 + clientNum * 37,
        connectedAt: new Date().toISOString().slice(11, 19),
        active: false,
      };
      musicState.devices.push(newDev);
      logRpc(`2-Neovim RPC: Paired new client ${newDev.name}`);
    }

  return getMusicSnapshot();
}
