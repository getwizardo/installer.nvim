/**
 * Device discovery: mDNS first, configured addresses as a fallback, and a
 * cheap reachability probe (`CONNECT` + `GET_STATUS`) so a "device" in the
 * list is always something we can actually talk to.
 */
import { discoverDevices, type CastDevice } from "../net/mdns.ts";
import { CAST_PORT } from "../receiver/server.ts";
import { CastClient } from "./client.ts";

export interface DiscoveryOptions {
  timeoutMs?: number;
  /** Extra `host[:port]` entries to probe (from `karu.devices` in kaeru.yaml). */
  addresses?: string[];
  log?: (message: string) => void;
}

export interface DiscoveredDevice extends CastDevice {
  /** Extra detail from GET_STATUS when we probed it. */
  status?: { volume: number; muted: boolean; app?: string };
  reachable: boolean;
  error?: string;
}

export function parseAddress(entry: string): { host: string; port: number } {
  const trimmed = entry.trim();
  const match = trimmed.match(/^\[?([^\]:]+)\]?(?::(\d+))?$/);
  if (!match) return { host: trimmed, port: CAST_PORT };
  return { host: match[1] ?? trimmed, port: match[2] ? Number(match[2]) : CAST_PORT };
}

/** Does this selector name a host (rather than a device name/id/index)? */
export function looksLikeAddress(value: string): boolean {
  const trimmed = value.trim();
  if (/^\d{1,3}(\.\d{1,3}){3}(:\d+)?$/.test(trimmed)) return true; // 192.168.1.24[:8009]
  if (/^\[[0-9a-f:]+\](:\d+)?$/i.test(trimmed)) return true; // [fe80::1]:8009
  if (trimmed.includes(":") && /^[0-9a-f:]+$/i.test(trimmed)) return true; // bare IPv6
  if (/^[a-z0-9][a-z0-9.-]*\.local(:\d+)?$/i.test(trimmed)) return true; // tv.local[:8009]
  return false;
}

export async function probeAddress(host: string, port = CAST_PORT, timeoutMs = 4000): Promise<DiscoveredDevice> {
  const client = new CastClient({ host, port, timeoutMs });
  try {
    await client.connect();
    const status = await client.getStatus();
    const app = (status.applications ?? [])[0];
    return {
      id: `manual:${host}:${port}`,
      name: host,
      model: app?.displayName ?? "Cast device",
      address: host,
      port,
      host,
      txt: {},
      source: "manual",
      reachable: true,
      status: {
        volume: status.volume?.level ?? 0,
        muted: status.volume?.muted ?? false,
        ...(app?.displayName ? { app: app.displayName } : {}),
      },
    };
  } catch (error) {
    return {
      id: `manual:${host}:${port}`,
      name: host,
      model: "unreachable",
      address: host,
      port,
      host,
      txt: {},
      source: "manual",
      reachable: false,
      error: (error as Error).message,
    };
  } finally {
    client.close();
  }
}

export async function discover(options: DiscoveryOptions = {}): Promise<DiscoveredDevice[]> {
  const log = options.log ?? (() => {});
  const devices: DiscoveredDevice[] = [];

  try {
    const found = await discoverDevices({ timeoutMs: options.timeoutMs ?? 3000, log });
    for (const device of found) devices.push({ ...device, reachable: true });
  } catch (error) {
    log(`discovery: mDNS unavailable (${(error as Error).message})`);
  }

  for (const entry of options.addresses ?? []) {
    const { host, port } = parseAddress(entry);
    if (devices.some((device) => device.address === host && device.port === port)) continue;
    const probed = await probeAddress(host, port);
    if (probed.reachable) devices.push(probed);
    else log(`discovery: ${host}:${port}, ${probed.error}`);
  }

  return devices.sort((a, b) => a.name.localeCompare(b.name));
}

/** Find a device by name, id, address or index (1-based). */
export function selectDevice(devices: DiscoveredDevice[], query: string | undefined): DiscoveredDevice | null {
  if (devices.length === 0) return null;
  if (!query) return devices[0] ?? null;
  const trimmed = query.trim();
  const index = Number(trimmed);
  if (Number.isInteger(index) && index >= 1 && index <= devices.length) return devices[index - 1] ?? null;
  const lowered = trimmed.toLowerCase();
  const exact = devices.find((device) => device.name.toLowerCase() === lowered || device.id.toLowerCase() === lowered || device.address === trimmed);
  if (exact) return exact;
  const partial = devices.find(
    (device) => device.name.toLowerCase().includes(lowered) || device.id.toLowerCase().includes(lowered) || device.address.includes(trimmed)
  );
  return partial ?? null;
}
