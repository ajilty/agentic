// Append-only, actor-attributed event ledger (Build & Run §6.4, §8).
// Envelope: {ts: ISO-8601, actor: "user"|"agent", type, ...payload}
import { appendFileSync, readFileSync, readdirSync, existsSync, mkdirSync } from 'fs';
import { join } from 'path';
import { isEventType } from '../model/schema.mjs';

export function appendEvent(storeRoot, event) {
  if (event.actor !== 'user' && event.actor !== 'agent') {
    throw new Error(`ledger event rejected: actor must be "user" or "agent", got ${JSON.stringify(event.actor)}`);
  }
  if (!event.type) throw new Error('ledger event rejected: missing type');
  if (!isEventType(event.type)) {
    throw new Error(`ledger event rejected: type "${event.type}" not in the event enum (src/model/schema.mjs)`);
  }
  const full = { ts: event.ts ?? new Date().toISOString(), ...event };
  const dir = join(storeRoot, 'events');
  mkdirSync(dir, { recursive: true });
  const file = join(dir, `ledger-${full.ts.slice(0, 7)}.jsonl`);
  appendFileSync(file, JSON.stringify(full) + '\n');
  return full;
}

export function readEvents(storeRoot, { month, type, actor } = {}) {
  const dir = join(storeRoot, 'events');
  if (!existsSync(dir)) return [];
  const files = readdirSync(dir)
    .filter((f) => f.startsWith('ledger-') && f.endsWith('.jsonl'))
    .filter((f) => !month || f === `ledger-${month}.jsonl`)
    .sort();
  const events = [];
  for (const f of files) {
    for (const line of readFileSync(join(dir, f), 'utf8').split('\n')) {
      if (!line.trim()) continue;
      const e = JSON.parse(line);
      if (type && e.type !== type) continue;
      if (actor && e.actor !== actor) continue;
      events.push(e);
    }
  }
  return events;
}
