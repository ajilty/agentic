// Chat (Slack-shaped) adapter. Fixture shape mirrors a channel read:
// {channel, messages: [{user, ts, text}]} — ts is epoch.seq.
import { readdirSync, readFileSync, existsSync } from 'fs';
import { join } from 'path';
import { createHash } from 'crypto';
import { liveNotEnabled } from './index.mjs';

export function normalizeSlackRead(read) {
  return (read.messages ?? []).map((m) => {
    const ts = new Date(parseFloat(m.ts) * 1000).toISOString();
    return {
      id: `slack:${read.channel}:${m.ts}`,
      surface: 'slack',
      workspace_ref: `slack-channel:${read.channel}`,
      sender_raw: m.user,
      ts,
      body: m.text ?? '',
      thread_ts: m.thread_ts ?? null,
      source_ref: { surface: 'slack', channel: read.channel, ts: m.ts },
      fingerprint: createHash('sha256').update(`slack|${read.channel}|${m.ts}|${m.text ?? ''}`).digest('hex').slice(0, 16),
    };
  });
}

export function slackAdapter(cfg, ctx) {
  if (cfg.backend === 'live') {
    return { pull: liveNotEnabled('slack'), fetchCurrent: liveNotEnabled('slack'), stageDraft: liveNotEnabled('slack'), stageHold: liveNotEnabled('slack') };
  }
  const dir = join(ctx.fixturesRoot, 'slack');
  return {
    pull(since) {
      if (!existsSync(dir)) return [];
      const out = [];
      for (const f of readdirSync(dir).filter((f) => f.endsWith('.json')).sort()) {
        out.push(...normalizeSlackRead(JSON.parse(readFileSync(join(dir, f), 'utf8'))));
      }
      return out.filter((m) => !since || m.ts >= since).sort((a, b) => a.ts.localeCompare(b.ts));
    },
    fetchCurrent() { throw new Error('slack has no fetchCurrent objects in v1'); },
    stageDraft() { throw new Error('draft staging is M4 — not yet implemented'); },
    stageHold() { throw new Error('slack does not stage holds'); },
  };
}
