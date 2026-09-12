// Calendar adapter. Fixture shape mirrors an event read:
// {summary, start: {dateTime}, attendees: [{email}], organizer?: {email}}
// Invites are Messages (spec §3); attendees are working-group evidence.
import { readdirSync, readFileSync, existsSync } from 'fs';
import { join } from 'path';
import { createHash } from 'crypto';
import { liveNotEnabled } from './index.mjs';

export function normalizeCalendarEvent(ev, sourceFile) {
  const ts = new Date(ev.start?.dateTime ?? ev.start?.date).toISOString();
  const attendees = (ev.attendees ?? []).map((a) => a.email);
  return [{
    id: `calendar:${ev.id ?? sourceFile}`,
    surface: 'calendar',
    workspace_ref: `calendar:${ev.calendarId ?? 'primary'}`,
    sender_raw: ev.organizer?.email ?? attendees[0] ?? '',
    ts,
    body: ev.summary ?? '',
    attendees,
    event_kind: ev.transparency === 'transparent' || /focus/i.test(ev.summary ?? '') ? 'focus' : 'meeting',
    source_ref: { surface: 'calendar', eventId: ev.id ?? sourceFile },
    fingerprint: createHash('sha256').update(`calendar|${ev.id ?? sourceFile}|${ts}|${ev.summary ?? ''}`).digest('hex').slice(0, 16),
  }];
}

export function calendarAdapter(cfg, ctx) {
  if (cfg.backend === 'live') {
    return { pull: liveNotEnabled('calendar'), fetchCurrent: liveNotEnabled('calendar'), stageDraft: liveNotEnabled('calendar'), stageHold: liveNotEnabled('calendar') };
  }
  const dir = join(ctx.fixturesRoot, 'calendar');
  return {
    pull(since) {
      if (!existsSync(dir)) return [];
      const out = [];
      for (const f of readdirSync(dir).filter((f) => f.endsWith('.json')).sort()) {
        out.push(...normalizeCalendarEvent(JSON.parse(readFileSync(join(dir, f), 'utf8')), f));
      }
      return out.filter((m) => !since || m.ts >= since).sort((a, b) => a.ts.localeCompare(b.ts));
    },
    fetchCurrent() { throw new Error('calendar fetchCurrent lands with anchors (wave 2)'); },
    stageDraft() { throw new Error('calendar stages holds, not drafts'); },
    stageHold() { throw new Error('hold staging is M4 — not yet implemented'); },
  };
}
