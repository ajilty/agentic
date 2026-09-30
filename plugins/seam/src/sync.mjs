// /sync pipeline, M1 slice: pull all profile sources → append-only raw JSONL
// with per-source watermarks + content fingerprints. Idempotent by design:
// re-encountered messages resolve in one fingerprint comparison.
// One dark source never fails the whole sync (Build & Run §5).
import { appendFileSync, readFileSync, readdirSync, existsSync, mkdirSync } from 'fs';
import { join } from 'path';
import { makeAdapter } from './adapters/index.mjs';
import { readWatermarks, writeWatermarks } from './lib/store.mjs';
import { appendEvent } from './lib/ledger.mjs';

function knownFingerprints(storeRoot, surface) {
  const dir = join(storeRoot, 'raw', surface);
  const set = new Set();
  if (!existsSync(dir)) return set;
  for (const f of readdirSync(dir).filter((f) => f.endsWith('.jsonl'))) {
    for (const line of readFileSync(join(dir, f), 'utf8').split('\n')) {
      if (!line.trim()) continue;
      set.add(JSON.parse(line).fingerprint);
    }
  }
  return set;
}

export function syncOnce({ profile, storeRoot, fixturesRoot, now = () => new Date().toISOString() }) {
  const results = {};
  const wm = readWatermarks(storeRoot);
  for (const src of profile.sources ?? []) {
    const surface = src.surface;
    try {
      const adapter = makeAdapter(src, { fixturesRoot });
      const since = wm[surface]?.high_water ?? null;
      const pulled = adapter.pull(since);
      const known = knownFingerprints(storeRoot, surface);
      let appended = 0;
      let high = since;
      for (const msg of pulled) {
        if (!known.has(msg.fingerprint)) {
          const day = msg.ts.slice(0, 10);
          const dir = join(storeRoot, 'raw', surface);
          mkdirSync(dir, { recursive: true });
          appendFileSync(join(dir, `${day}.jsonl`), JSON.stringify(msg) + '\n');
          known.add(msg.fingerprint);
          appended += 1;
        }
        if (!high || msg.ts > high) high = msg.ts;
      }
      wm[surface] = { ...(wm[surface] ?? {}), high_water: high, last_ok: now(), dark: false };
      results[surface] = { ok: true, pulled: pulled.length, appended };
    } catch (err) {
      // Dark source: record the window start, pause its signals, keep going.
      wm[surface] = { ...(wm[surface] ?? {}), dark: true, dark_since: wm[surface]?.dark_since ?? now(), last_error: String(err.message ?? err) };
      results[surface] = { ok: false, error: String(err.message ?? err) };
    }
  }
  writeWatermarks(storeRoot, wm);
  appendEvent(storeRoot, { actor: 'agent', type: 'sync_requested', result: results });
  return results;
}
