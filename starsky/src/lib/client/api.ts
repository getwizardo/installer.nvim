// Tiny JSON client for the Starsky API routes. Every route answers with
// `{ ok: boolean, error?: string, ... }`, including on HTTP 400/500, so callers
// only have to look at `ok`.
export interface ApiResult {
	ok: boolean;
	error?: string;
	[key: string]: unknown;
}

export async function api<T extends ApiResult = ApiResult>(
	path: string,
	body?: unknown,
	method?: 'GET' | 'POST'
): Promise<T> {
	const verb = method ?? (body === undefined ? 'GET' : 'POST');
	try {
		const res = await fetch(path, {
			method: verb,
			headers: body === undefined ? undefined : { 'content-type': 'application/json' },
			body: body === undefined ? undefined : JSON.stringify(body)
		});
		const data = (await res.json().catch(() => null)) as T | null;
		if (!data) {
			return { ok: false, error: `HTTP ${res.status}` } as T;
		}
		return data;
	} catch (err) {
		return { ok: false, error: err instanceof Error ? err.message : String(err) } as T;
	}
}

/** Human readable size, e.g. 1536 -> "1.5 KB". */
export function formatBytes(n: number): string {
	if (!Number.isFinite(n) || n < 1024) return `${n || 0} B`;
	if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
	return `${(n / 1024 / 1024).toFixed(1)} MB`;
}

/** Format a star count the way GitHub does, e.g. 12400 -> "12.4k". */
export function formatStars(n: number): string {
	if (n >= 1000) return `${(n / 1000).toFixed(1)}k`;
	return String(n);
}
