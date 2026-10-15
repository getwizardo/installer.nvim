// Shared client state: the active tab and a spec draft handed from one tab to
// another (e.g. the parser or GitHub browser → the spec builder).
export type TabId = 'ide' | 'music' | 'spec' | 'mason' | 'sftp' | 'parser' | 'github';

export const ui = $state({
	tab: 'ide' as TabId,
	draft: null as Record<string, string> | null
});

/** Open a spec draft in the spec builder tab. */
export function openSpecDraft(form: Record<string, string>): void {
	ui.draft = form;
	ui.tab = 'spec';
}
