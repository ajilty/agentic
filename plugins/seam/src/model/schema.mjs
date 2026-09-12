// Seam data model — the enums and the board-data contract.
// This is the determinism boundary (Build & Run §3.1): code + schema are fixed;
// model output lands only as *field content* inside these shapes, never as new
// structure. Every tag that was a loose string is pinned here so the generator,
// the linters, and the goldens all validate against one source of truth.

// Surface has two dimensions, deliberately (Build & Run §3.1 layer 3):
//   SURFACE_TYPE — abstract; what prompts and logic reason about. Never a product.
//   PRODUCT      — concrete; for display, logos, and profile bindings only.
// A new provider is a new PRODUCT entry + adapter, with zero prompt changes.
export const SURFACE_TYPE = ['email', 'chat', 'calendar', 'tracker', 'code', 'transcript'];
export const PRODUCT = ['gmail', 'outlook', 'slack', 'teams', 'gcal', 'jira', 'github', 'zoom'];
export const PRODUCT_TYPE = {
  gmail: 'email', outlook: 'email', slack: 'chat', teams: 'chat',
  gcal: 'calendar', jira: 'tracker', github: 'code', zoom: 'transcript',
};
// Display metadata — label + a logo slot (emoji placeholder until real marks land).
export const PRODUCT_META = {
  gmail: { label: 'Gmail', logo: '✉️' }, outlook: { label: 'Outlook', logo: '📧' },
  slack: { label: 'Slack', logo: '💬' }, teams: { label: 'Teams', logo: '👥' },
  gcal: { label: 'Google Calendar', logo: '📅' }, jira: { label: 'Jira', logo: '🗂️' },
  github: { label: 'GitHub', logo: '🐙' }, zoom: { label: 'Zoom', logo: '🎙️' },
};
// Back-compat: validation accepts either an abstract type or a known product as a
// source/freshness key while the operational pipeline migrates to the split.
export const SURFACE = [...SURFACE_TYPE, ...PRODUCT];

// Three urgency tiers. Action type is a separate lens, not a tier; "waiting on"
// is an action type (nudge), not a bucket.
export const TIER = ['critical_now', 'opportunity_now', 'over_the_horizon'];
export const TIER_LABEL = {
  critical_now: 'Critical Now', opportunity_now: 'Opportunity Now', over_the_horizon: 'Over the Horizon',
};
export const TIER_CAP = { critical_now: 5 }; // soft cap; overflow auto-demotes with reason

export const ACTION_TYPE = ['reply', 'nudge', 'review', 'approve', 'reconcile', 'confirm', 'filter', 'investigate'];
export const TIER_STATE = ['provisional', 'confirmed'];
export const URGENCY_ORIGIN = ['internal', 'external_unverified'];
export const EFFORT = ['S', 'M', 'L'];
export const WORKSTREAM_PROFILE = ['work', 'personal'];
// Identity confidence tiers (spec §3 lifecycle): auto_merged = same full email
// across surfaces; suspected = same name at a different domain, held, never
// merged on name alone; linked = unrelated handle tied by explicit evidence.
export const IDENTITY_TIER = ['auto_merged', 'suspected', 'linked'];
export const FRESHNESS = ['ok', 'dark'];

// Ledger event vocabulary (Build & Run §8) — the append-only envelope's `type`.
export const EVENT_TYPE = [
  'store_initialized', 'sync_requested', 'model_call',
  'pivot', 'pivot_block', 'config_opened', 'item_read', 'link_opened', 'claim_provenance_opened',
  'tier_assigned', 'tier_confirmed', 'tier_moved', 'tier_demoted',
  'action_scheduled', 'action_unscheduled', 'gap_accepted_as_block', 'meeting_prep_opened', 'prep_note_staged',
  'thread_confirmed', 'thread_split', 'workstream_corrected', 'followup_snoozed', 'escalation_armed',
  'action_done', 'action_dismissed', 'action_split_queued', 'action_snoozed', 'undo',
  'draft_staged', 'rollup_reviewed', 'rollup_requested',
  'fact_proposed', 'fact_promoted', 'fact_dismissed', 'wiki_update_staged',
  'identity_merge_confirmed', 'workspace_sanctioned', 'workspace_flag_kept',
  'anchor_link_started', 'cadence_edit_opened', 'external_urgency_flagged',
  'capture_added', 'wywa_dismissed', 'review_friday_opened', 'agent_activity_opened',
  'story_compiled', 'filter_proposed', 'filter_spec_staged',
  'filter_marked_applied', 'filter_dismissed', 'injection_attempt_logged',
];
export const EVENT_TYPE_SET = new Set(EVENT_TYPE);

// Story word budgets (spec §5.8 / review): enforced, not advisory.
export const BUDGET = { title: 12, why_now: 14, context: 18 };
const words = (s) => String(s || '').trim().split(/\s+/).filter(Boolean).length;
const inEnum = (v, e) => e.includes(v);

// Validate one compiled card. Returns an array of violation strings (empty = ok).
export function validateCard(c) {
  const v = [];
  if (!c.id) v.push('card missing id');
  if (!inEnum(c.type, ACTION_TYPE)) v.push(`${c.id}: action type "${c.type}" not in enum`);
  if (!inEnum(c.tier, TIER)) v.push(`${c.id}: tier "${c.tier}" not in enum`);
  if (!inEnum(c.tier_state, TIER_STATE)) v.push(`${c.id}: tier_state "${c.tier_state}" not in enum`);
  if (c.urgency_origin && !inEnum(c.urgency_origin, URGENCY_ORIGIN)) v.push(`${c.id}: urgency_origin "${c.urgency_origin}" not in enum`);
  if (c.effort && !inEnum(c.effort, EFFORT)) v.push(`${c.id}: effort "${c.effort}" not in enum`);
  if (words(c.title) > BUDGET.title) v.push(`${c.id}: title over budget (${words(c.title)}>${BUDGET.title})`);
  if (words(c.why_now) > BUDGET.why_now) v.push(`${c.id}: why_now over budget (${words(c.why_now)}>${BUDGET.why_now})`);
  if (words(c.context) > BUDGET.context) v.push(`${c.id}: context over budget (${words(c.context)}>${BUDGET.context})`);
  // provenance-on-claim: every claim resolves to a source ref
  for (const cl of c.claims || []) if (!cl.ref) v.push(`${c.id}: claim "${cl.text}" has no provenance ref`);
  // external-origin rule: sender-claimed urgency alone can never be Critical
  if (c.urgency_origin === 'external_unverified' && c.tier === 'critical_now' && !c.internal_corroboration) {
    v.push(`${c.id}: external_unverified urgency in critical_now without internal corroboration`);
  }
  return v;
}

// Validate a whole board-data document.
export function validateBoardData(b) {
  const v = [];
  if (!b || typeof b !== 'object') return ['board-data is not an object'];
  if (!inEnum(b.profile, WORKSTREAM_PROFILE)) v.push(`board profile "${b.profile}" not in enum`);
  for (const [surface, f] of Object.entries(b.freshness || {})) {
    if (!inEnum(surface, SURFACE)) v.push(`freshness surface "${surface}" not in enum`);
    if (!inEnum(f.state, FRESHNESS)) v.push(`freshness state "${f.state}" not in enum`);
  }
  const tiers = b.tiers || {};
  for (const t of Object.keys(tiers)) if (!inEnum(t, TIER)) v.push(`tier key "${t}" not in enum`);
  for (const t of TIER) for (const c of tiers[t] || []) {
    if (c.tier !== t) v.push(`${c.id}: filed under ${t} but card.tier=${c.tier}`);
    v.push(...validateCard(c));
  }
  const crit = (tiers.critical_now || []).length;
  if (crit > TIER_CAP.critical_now) v.push(`critical_now over soft cap (${crit}>${TIER_CAP.critical_now}) — demote with reason`);
  return v;
}

export function isEventType(t) { return EVENT_TYPE_SET.has(t); }
