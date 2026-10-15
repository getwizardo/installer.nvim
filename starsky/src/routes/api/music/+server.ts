import { json, type RequestEvent } from '@sveltejs/kit';
import { getMusicSnapshot, musicAction } from '#lib/server/music';

export const prerender = false;

export function GET() {
	return json(getMusicSnapshot());
}

export async function POST({ request }: RequestEvent) {
	try {
		const body = await request.json();
		return json(musicAction(body));
	} catch (err) {
		return json({ ok: false, error: err instanceof Error ? err.message : String(err) }, { status: 400 });
	}
}
