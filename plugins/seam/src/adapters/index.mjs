// Adapter contract (Build & Run §1): one interface regardless of backend.
//   pull(since) → Message[]   fetchCurrent(ref) → Object
//   stageDraft(d) → ref       stageHold(block) → ref
// Backends: `fixture` (plugin fixtures dir) and `live` (MCP, via the harness).
// Code above this layer never knows which backend it is talking to, and never
// names a concrete product — that lives in profile YAML bindings.
import { emailAdapter } from './email.mjs';
import { slackAdapter } from './slack.mjs';
import { calendarAdapter } from './calendar.mjs';

const SURFACES = { email: emailAdapter, slack: slackAdapter, calendar: calendarAdapter };

export function makeAdapter(sourceCfg, ctx) {
  const factory = SURFACES[sourceCfg.surface];
  if (!factory) throw new Error(`no adapter for surface "${sourceCfg.surface}"`);
  if (sourceCfg.backend !== 'fixture' && sourceCfg.backend !== 'live') {
    throw new Error(`surface ${sourceCfg.surface}: backend must be "fixture" or "live"`);
  }
  return factory(sourceCfg, ctx);
}

// Live pulls run inside a Claude Code session where MCP tools are first-class;
// the adapter surfaces a request descriptor the session executes, then feeds
// the raw response back through `normalize`. Until a surface is flipped live
// (after allowlist confirmation + shape capture), live pulls fail closed.
export function liveNotEnabled(surface) {
  return () => {
    throw new Error(`surface ${surface}: live backend not enabled — capture sanitized shapes and pass the M1 gate first (Build & Run §4 M1).`);
  };
}
