// Board generator — raw store → validated board-data (the determinism boundary).
// First cut: deterministic clustering + tiering + MECHANICAL card copy. The
// structure, enums, and rules here are the permanent contract; only the card
// prose is a placeholder for the model-produced step (Build & Run §3.1 layer 2).
// Everything it emits is validated against src/model/schema.mjs before return.
import { readFileSync, readdirSync, existsSync } from 'fs';
import { join } from 'path';
import { TIER, TIER_CAP, validateBoardData } from '../model/schema.mjs';

const PROTAGONIST = 'alex@stoneridge.example';
const INTERNAL_DOMAIN = 'stoneridge.example';
const PRINCIPALS = new Set(['m.chen@stoneridge.example']);
const URGENCY_LEX = /\b(expires?|deadline|by friday|by eod|EOQ|today|asap)\b/i;
const CORROBORATION_LEX = /\b(confirmed|clicked|reset|containment|in progress|purge)\b/i;
const ASK_LEX = /\b(can you|could you|please|need it|own this|weigh in|\?)/i;
const DATE_LEX = /\b(mon|tue|wed|thu|fri|today|tomorrow|\d{1,2}:\d{2}|aug \d|by \w+day)\b/i;

const addr = (raw) => (String(raw).match(/<([^>]+)>/)?.[1] || String(raw)).trim().toLowerCase();
const domain = (raw) => addr(raw).split('@')[1] || '';
const wsTag = (subject) => (String(subject).match(/^\[([^\]]+)\]/)?.[1] || null);
const trunc = (s, n) => { const w = String(s).trim().split(/\s+/); return w.slice(0, n).join(' '); };

function readRaw(storeRoot, surface) {
  const dir = join(storeRoot, 'raw', surface);
  if (!existsSync(dir)) return [];
  const out = [];
  for (const f of readdirSync(dir).filter((f) => f.endsWith('.jsonl'))) {
    for (const line of readFileSync(join(dir, f), 'utf8').split('\n')) {
      if (line.trim()) out.push(JSON.parse(line));
    }
  }
  return out;
}

// Cluster messages into threads, then threads into workstreams. First cut keys
// on native thread refs + the subject workstream tag; blind burst clustering is
// the M2 upgrade (flagged, not hidden).
function cluster(messages) {
  const threads = new Map();
  for (const m of messages) {
    const key = m.workspace_ref || m.source_ref?.threadId || m.id;
    if (!threads.has(key)) threads.set(key, { key, msgs: [], surface: m.surface });
    threads.get(key).msgs.push(m);
  }
  const streams = new Map();
  for (const th of threads.values()) {
    th.msgs.sort((a, b) => a.ts.localeCompare(b.ts));
    // Human-readable stream label; a raw channel id is not a workstream name.
    const chan = th.key.replace('slack-channel:', '').replace(/^C-/, '');
    const tag = th.msgs.map((m) => wsTag(m.subject)).find(Boolean)
      || (th.surface === 'slack'
        ? chan.charAt(0) + chan.slice(1).toLowerCase() + ' channel'
        : 'Unsorted');
    if (!streams.has(tag)) streams.set(tag, { name: tag, threads: [], surfaces: new Set() });
    streams.get(tag).threads.push(th);
    streams.get(tag).surfaces.add(th.surface);
  }
  return streams;
}

// Does this thread need the user AT ALL? The board shows what needs triage —
// most traffic needs nothing. Without this gate every thread becomes a card and
// the board is a second inbox (observed: 418 cards on a 5-day corpus). A thread
// earns a card only on a concrete actionable signal.
function needsUser(th, streamName) {
  const msgs = th.msgs;
  const senders = msgs.map((m) => addr(m.sender_raw));
  const body = msgs.map((m) => `${m.subject || ''} ${m.body || ''}`).join(' ');
  const others = senders.filter((s) => s && s !== PROTAGONIST);
  const myLastIdx = senders.lastIndexOf(PROTAGONIST);
  const repliedAfter = myLastIdx >= 0 && senders.slice(myLastIdx + 1).some((s) => s && s !== PROTAGONIST);
  // 1. my own ask, unanswered — the wedge
  if (myLastIdx >= 0 && !repliedAfter && ASK_LEX.test(body)) return 'delegation_silence';
  // 2. a principal is in the thread
  if (senders.some((s) => PRINCIPALS.has(s))) return 'principal';
  // 3. an explicit date/deadline was extracted
  if (DATE_LEX.test(body)) return 'date';
  // 4. external party asserting urgency
  if (others.some((s) => !s.endsWith('@' + INTERNAL_DOMAIN)) && URGENCY_LEX.test(body)) return 'external_urgency';
  // 5. incident traffic with internal corroboration
  if ((/incident|phish|sec/i.test(streamName) || th.key.includes('SECINC')) && CORROBORATION_LEX.test(body)) return 'incident';
  return null; // ambient — no card
}

// Decide action type, tier, urgency origin for a thread. Deterministic rules,
// each traceable to a spec guardrail.
function triage(th, streamName) {
  const msgs = th.msgs;
  const last = msgs[msgs.length - 1];
  const senders = msgs.map((m) => addr(m.sender_raw));
  const external = senders.some((s) => s && !s.endsWith('@' + INTERNAL_DOMAIN));
  const fromMe = senders.filter((s) => s === PROTAGONIST).length;
  const others = senders.filter((s) => s && s !== PROTAGONIST);
  const body = msgs.map((m) => `${m.subject || ''} ${m.body || ''}`).join(' ');
  const principal = senders.some((s) => PRINCIPALS.has(s));
  const incident = /incident|phish|sec/i.test(streamName) || th.key.includes('SECINC');

  // delegation-silence: my own ask, no reply after it from someone else
  const myLastIdx = senders.lastIndexOf(PROTAGONIST);
  const repliedAfter = myLastIdx >= 0 && others.some((_, i) => i > myLastIdx);
  if (fromMe > 0 && !repliedAfter && ASK_LEX.test(body)) {
    return { type: 'nudge', tier: 'opportunity_now', urgency_origin: 'internal',
      internal_corroboration: true, reason: 'your ask, no reply' };
  }
  // external-claimed urgency: never Critical alone
  if (external && URGENCY_LEX.test(body)) {
    const internalUrgency = msgs.some((m) => addr(m.sender_raw).endsWith('@' + INTERNAL_DOMAIN) && URGENCY_LEX.test(m.body || ''));
    return { type: 'reply', tier: internalUrgency ? 'critical_now' : 'opportunity_now',
      urgency_origin: 'external_unverified', internal_corroboration: internalUrgency,
      reason: internalUrgency ? 'external deadline + internal corroboration' : 'sender-claimed urgency, uncorroborated' };
  }
  // incident with internal corroboration → investigate, Critical
  if (incident && CORROBORATION_LEX.test(body)) {
    return { type: 'investigate', tier: 'critical_now', urgency_origin: 'internal',
      internal_corroboration: true, reason: 'internal incident corroboration' };
  }
  // principal sender or near-term date → review, elevated
  if (principal || DATE_LEX.test(body)) {
    return { type: 'review', tier: principal ? 'critical_now' : 'opportunity_now', urgency_origin: 'internal',
      internal_corroboration: principal, reason: principal ? 'principal sender' : 'extracted date' };
  }
  return { type: 'review', tier: 'over_the_horizon', urgency_origin: 'internal', reason: 'no near-term signal' };
}

// Mechanical card compilation — placeholder prose under the real word budgets.
function compileCard(th, streamName, tri, idx) {
  const last = th.msgs[th.msgs.length - 1];
  // For a nudge the subject is whoever owes YOU — never the protagonist
  // ("chase yourself" is a bug). Prefer the last participant who isn't me;
  // for a one-sided ask, fall back to the recipient the ask was sent to.
  const clean = (v) => trunc(String(v || '').replace(/<.*/, '').replace(/["']/g, '').split('@')[0].replace(/[._]/g, ' ') || 'them', 3);
  const other = [...th.msgs].reverse().find((m) => addr(m.sender_raw) !== PROTAGONIST);
  const myAsk = [...th.msgs].reverse().find((m) => addr(m.sender_raw) === PROTAGONIST && (m.recipients || []).length);
  const owed = other ? clean(other.sender_raw)
    : clean((myAsk?.recipients || []).find((r) => addr(r) !== PROTAGONIST));
  const who = tri.type === 'nudge' ? owed : clean(last.sender_raw);
  const titles = {
    nudge: `Chase ${who} on ${trunc(streamName, 4)}`,
    reply: `Reply on ${trunc(streamName, 5)}`,
    investigate: `Triage ${trunc(streamName, 5)} and confirm scope`,
    review: `Review ${trunc(streamName, 6)}`,
  };
  const claims = [];
  if (tri.urgency_origin === 'external_unverified') claims.push({ text: 'deadline claimed by sender', ref: last.id });
  if (tri.reason.includes('date')) claims.push({ text: 'date extracted', ref: last.id });
  claims.push({ text: `${th.msgs.length} messages`, ref: th.msgs[0].id });
  return {
    id: `card_${idx}`,
    type: tri.type,
    tier: tri.tier,
    tier_state: 'provisional',
    urgency_origin: tri.urgency_origin,
    internal_corroboration: !!tri.internal_corroboration,
    title: trunc(titles[tri.type] || `Handle ${trunc(streamName, 5)}`, 12),
    why_now: trunc(tri.reason, 14),
    context: trunc(`${streamName}: ${last.subject || last.body || ''}`, 18),
    claims,
    signals: [...new Set(th.msgs.map((m) => m.surface))],
    workstream: streamName,
    effort: th.msgs.length > 4 ? 'L' : th.msgs.length > 2 ? 'M' : 'S',
    unread: idx < 3,
    external_marked: tri.urgency_origin === 'external_unverified',
    msgs: th.msgs.slice(0, 4).map((m) => ({ from: m.sender_raw, snip: trunc(m.body || '', 20), link: m.id })),
  };
}

export function generateBoard({ storeRoot, profile = 'personal', watermarks = {} }) {
  const messages = ['email', 'slack', 'calendar'].flatMap((s) => readRaw(storeRoot, s));
  const streams = cluster(messages);
  const cards = [];
  let idx = 0;
  let ambient = 0;
  for (const stream of streams.values()) {
    // Consolidate: within a workstream, threads sharing an action type are one
    // card (the newest thread leads, the rest are folded in as related). Without
    // this the board repeats the same story once per thread.
    const byType = new Map();
    for (const th of stream.threads) {
      if (th.key.includes('auto-') || /noreply|newsletter|status\.example/i.test(th.msgs[0]?.sender_raw || '')) continue;
      if (!needsUser(th, stream.name)) { ambient += 1; continue; }
      const tri = triage(th, stream.name);
      const key = `${tri.type}|${tri.tier}`;
      if (!byType.has(key)) byType.set(key, { tri, threads: [] });
      byType.get(key).threads.push(th);
    }
    for (const { tri, threads } of byType.values()) {
      threads.sort((a, b) => b.msgs[b.msgs.length - 1].ts.localeCompare(a.msgs[a.msgs.length - 1].ts));
      const lead = threads[0];
      const card = compileCard(lead, stream.name, tri, idx++);
      card.related_threads = threads.length - 1;
      card.msgs = threads.flatMap((t) => t.msgs).sort((a, b) => b.ts.localeCompare(a.ts)).slice(0, 4)
        .map((m) => ({ from: m.sender_raw, snip: trunc(m.body || '', 20), link: m.id }));
      cards.push(card);
    }
  }
  // File into tiers; enforce Critical soft cap by demoting the lowest-signal overflow.
  const tiers = { critical_now: [], opportunity_now: [], over_the_horizon: [] };
  for (const c of cards) tiers[c.tier].push(c);
  if (tiers.critical_now.length > TIER_CAP.critical_now) {
    // keep principal/corroborated first; demote the rest with a visible reason
    tiers.critical_now.sort((a, b) => (b.internal_corroboration - a.internal_corroboration));
    const overflow = tiers.critical_now.splice(TIER_CAP.critical_now);
    for (const c of overflow) { c.tier = 'opportunity_now'; c.demoted_reason = 'Critical over cap — lower signal'; tiers.opportunity_now.push(c); }
  }
  const board = {
    generated_at: messages.reduce((mx, m) => (m.ts > mx ? m.ts : mx), ''),
    profile,
    compilation: 'mechanical',   // honest: card prose is placeholder, not model-produced
    freshness: Object.fromEntries(Object.entries(watermarks).map(([s, w]) => [s, { state: w.dark ? 'dark' : 'ok', last_ok: w.last_ok }])),
    workstreams: [...streams.keys()].filter((k) => k !== 'untagged'),
    tiers,
    counts: { messages: messages.length, cards: cards.length, workstreams: streams.size, ambient_suppressed: ambient },
  };
  const violations = validateBoardData(board);
  if (violations.length) throw new Error('board-data failed schema validation:\n' + violations.join('\n'));
  return board;
}
