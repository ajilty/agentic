// Email adapter. Fixture shape mirrors a Gmail-style thread read:
// {threadId, messages: [{id, payload: {headers: [{name, value}]}, snippet}]}
// (fixture walkthrough §1.0; reconcile against captured live shapes at setup).
import { readdirSync, readFileSync, existsSync } from 'fs';
import { join } from 'path';
import { createHash } from 'crypto';
import { liveNotEnabled } from './index.mjs';

function header(msg, name) {
  return msg.payload?.headers?.find((h) => h.name.toLowerCase() === name.toLowerCase())?.value ?? '';
}

export function normalizeEmailThread(thread) {
  return (thread.messages ?? []).map((m) => {
    const ts = new Date(header(m, 'Date')).toISOString();
    const body = m.snippet ?? '';
    return {
      id: `email:${m.id}`,
      surface: 'email',
      workspace_ref: `email-thread:${thread.threadId}`,
      sender_raw: header(m, 'From'),
      // Recipients are load-bearing: a delegation nudge must name who owes you,
      // which is the recipient of your ask, not its sender.
      recipients: [header(m, 'To'), header(m, 'Cc')].filter(Boolean)
        .flatMap((v) => v.split(',').map((x) => x.trim())).filter(Boolean),
      ts,
      body,
      subject: header(m, 'Subject'),
      headers: { precedence: header(m, 'Precedence'), list_unsubscribe: header(m, 'List-Unsubscribe') },
      source_ref: { surface: 'email', threadId: thread.threadId, messageId: m.id },
      // Identity keys on stable fields only. `snippet` (the body source here) is a
      // provider-generated truncation and mutates under us; keying on it would
      // re-fingerprint the corpus and silently re-append. id + ts is the durable key.
      fingerprint: createHash('sha256').update(`email|${m.id}|${ts}`).digest('hex').slice(0, 16),
    };
  });
}

export function emailAdapter(cfg, ctx) {
  if (cfg.backend === 'live') {
    return { pull: liveNotEnabled('email'), fetchCurrent: liveNotEnabled('email'), stageDraft: liveNotEnabled('email'), stageHold: liveNotEnabled('email') };
  }
  const dir = join(ctx.fixturesRoot, 'email');
  return {
    pull(since) {
      if (!existsSync(dir)) return [];
      const out = [];
      for (const f of readdirSync(dir).filter((f) => f.endsWith('.json')).sort()) {
        const thread = JSON.parse(readFileSync(join(dir, f), 'utf8'));
        out.push(...normalizeEmailThread(thread));
      }
      return out.filter((m) => !since || m.ts >= since).sort((a, b) => a.ts.localeCompare(b.ts));
    },
    fetchCurrent() { throw new Error('email has no fetchCurrent objects in v1'); },
    stageDraft() { throw new Error('draft staging is M4 — not yet implemented'); },
    stageHold() { throw new Error('email does not stage holds'); },
  };
}
