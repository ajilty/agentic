// Deterministic board renderer: board-data.json → static HTML. No model call in
// this path (Build & Run §3.1 layer 1). Every sender-derived field goes through
// esc()/escAttr() — the board renders attacker-influenced text into a page the
// user opens logged in, so escaping is the load-bearing render rule.
import { PRODUCT_META, PRODUCT_TYPE, TIER, TIER_LABEL, TIER_CAP, validateBoardData } from '../model/schema.mjs';

const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g,
  (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

// Surface → product display. Type is what logic reasons about; product carries
// the label and logo (founder call: model both).
const SURFACE_PRODUCT = { email: 'gmail', chat: 'slack', slack: 'slack', calendar: 'gcal' };
const productOf = (surface) => PRODUCT_META[SURFACE_PRODUCT[surface]] || { label: surface, logo: '•' };

const TYPE_CLASS = { nudge: 'nudge', reply: 'reply', review: 'review', investigate: 'investigate',
  approve: 'review', reconcile: 'review', confirm: 'review', filter: 'nudge' };
const TYPE_LABEL = { nudge: 'NUDGE · waiting', reply: 'REPLY', review: 'REVIEW',
  investigate: 'INVESTIGATE', approve: 'APPROVE', reconcile: 'RECONCILE', confirm: 'CONFIRM', filter: 'FILTER' };

function cardHtml(c) {
  const prov = c.tier_state === 'provisional';
  const tierWord = (TIER_LABEL[c.tier] || c.tier).replace(' Now', '').toUpperCase();
  const chips = [
    ...(c.claims || []).map((cl) =>
      `<button class="chip claim" data-ref="${esc(cl.ref)}" title="provenance: ${esc(cl.ref)}">${esc(cl.text)}</button>`),
    ...(c.external_marked ? ['<span class="chip warn">urgency claimed by sender — unverified</span>'] : []),
    ...(c.type === 'nudge' ? ['<span class="chip warn">mail-only — a reply in chat isn\'t seen</span>'] : []),
    ...(c.related_threads ? [`<span class="chip">+${c.related_threads} related threads</span>`] : []),
    `<span class="chip">${esc(c.effort)} effort</span>`,
    ...(c.signals || []).map((s) => `<span class="chip">${productOf(s).logo} ${esc(productOf(s).label)}</span>`),
  ].join('');
  const msgs = (c.msgs || []).map((m) =>
    `<div class="msg"><span class="who">${esc(String(m.from).replace(/<.*/, ''))}</span>
      <span class="q">"${esc(m.snip)}"</span>
      <a class="deep" href="#" data-ref="${esc(m.link)}">open</a></div>`).join('');
  return `<article class="card ${prov ? 'prov' : ''} t-${esc(c.type)}" id="${esc(c.id)}">
    <div class="hd">${c.unread ? '<span class="unread" title="new since last visit"></span>' : ''}
      <span class="badge ${TYPE_CLASS[c.type] || ''}">${esc(TYPE_LABEL[c.type] || c.type)}</span>
      ${prov
        ? `<button class="tchip" data-tier="${esc(tierWord)}">${esc(tierWord)} · provisional</button>`
        : `<span class="tchip conf">${esc(tierWord)} ✓</span>`}
      <span class="ws">${esc(c.workstream)}</span></div>
    <h3 class="ti">${esc(c.title)}</h3>
    <p class="ln"><span class="lbl">WHY NOW</span> ${esc(c.why_now)}</p>
    <p class="ln"><span class="lbl">CONTEXT</span> ${esc(c.context)}</p>
    ${c.demoted_reason ? `<p class="demote">↓ ${esc(c.demoted_reason)}</p>` : ''}
    <div class="sig">${chips}</div>
    <details class="msgs"><summary>${(c.msgs || []).length} messages</summary>
      <div class="exp">${msgs}</div></details>
  </article>`;
}

export function renderBoard(board, { bodyOnly = false } = {}) {
  const violations = validateBoardData(board);
  if (violations.length) throw new Error('refusing to render invalid board-data:\n' + violations.join('\n'));
  const fresh = Object.entries(board.freshness || {}).map(([s, f]) => {
    const p = productOf(s);
    return `<span class="chip ${f.state === 'dark' ? 'bad' : ''}">${p.logo} ${esc(p.label)} ${
      f.state === 'dark' ? 'dark' : esc(String(f.last_ok || '').slice(11, 16))}</span>`;
  }).join('');
  const tiers = TIER.map((t) => {
    const cs = board.tiers[t] || [];
    const cap = TIER_CAP[t] ? ` / cap ${TIER_CAP[t]}` : '';
    return `<section class="tier"><h2>${esc(TIER_LABEL[t])}
        <span class="ct">${cs.length}${esc(cap)}</span></h2>
      <div class="cards">${cs.length ? cs.map(cardHtml).join('')
        : '<div class="empty">Nothing here. That is a good morning.</div>'}</div></section>`;
  }).join('');
  const streams = (board.workstreams || []).map((w) =>
    `<button class="ws-btn" data-ws="${esc(w)}">${esc(w)}</button>`).join('');
  const c = board.counts || {};
  // The banner states the actual compilation state — never claims model-quality
  // prose when the copy is mechanical, and vice versa.
  const compileNote = board.compilation === 'model'
    ? `Card prose is <b>model-compiled</b>, accepted only after passing the word-budget, external-marking and fence-echo linters.`
    : board.compilation === 'mixed'
      ? `Card prose is <b>mixed</b> — ${board.compile_stats?.applied ?? 0} model-compiled, ${board.compile_stats?.kept_mechanical ?? 0} fell back to mechanical after failing a linter.`
      : `Card prose is <b>mechanical</b> (placeholder); structure, tiering and rules are real.`;
  const body = `
<div class="proto">Generated from the synthetic world — ${c.messages} messages → ${c.cards} cards.
  ${compileNote}</div>
<header class="top">
  <span class="wordmark">Seam</span>
  <div class="modes">
    <button class="mode" aria-selected="true">Operate <span class="b alert">${
      Object.values(board.tiers).flat().filter((x) => x.unread).length}</span></button>
    <button class="mode" aria-selected="false">Reflect <span class="b" title="designed — not in this build">0</span></button>
    <button class="mode" aria-selected="false">Know <span class="b" title="designed — not in this build">0</span></button>
  </div>
  <div class="fresh">${fresh}</div>
</header>
<div class="lens"><span class="lbl">Lens</span>
  <button class="lens-btn" aria-pressed="true" data-type="all">All</button>
  ${['reply', 'nudge', 'review', 'investigate'].map((t) =>
    `<button class="lens-btn" aria-pressed="false" data-type="${t}">${TYPE_LABEL[t]}</button>`).join('')}
  <span class="note">Action type filters across tiers — every item keeps its own urgency.</span></div>
<div class="wrap">
  <aside class="rail">
    <h3>Workstreams <span class="ct">${(board.workstreams || []).length}</span></h3>
    <div class="ws-list"><button class="ws-btn" aria-pressed="true" data-ws="">All</button>${streams}</div>
    <p class="note">${c.ambient_suppressed} threads carried no actionable signal and produced no card —
      the board shows what needs you, not everything that arrived.</p>
  </aside>
  <main>${tiers}
    <p class="note foot">Board generated ${esc(String(board.generated_at).slice(0, 16).replace('T', ' '))} ·
      profile ${esc(board.profile)} · compilation: ${esc(board.compilation)}</p>
  </main>
</div>`;
  return bodyOnly ? STYLE + body + SCRIPT : `<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'">
<title>Seam — board</title>${STYLE}</head><body>${body}${SCRIPT}</body></html>`;
}

const STYLE = `<style>
:root{--paper:#F4F7F6;--card:#FFF;--ink:#1B2431;--soft:#4A5563;--stitch:#A7B0BC;--line:#DCE2E6;
 --chip:#EDF1F0;--indigo:#4C5FD5;--moss:#4E7A52;--ochre:#B07A2E;--alert:#B3402F;--link:#3A4DC4;
 --warn-bg:#FBF3E4;--warn-ink:#8A5A16;--radius:6px;
 --sans:ui-sans-serif,system-ui,-apple-system,'Segoe UI',Roboto,sans-serif;
 --mono:ui-monospace,'SF Mono',Menlo,Consolas,monospace}
*{box-sizing:border-box}
body{margin:0;background:var(--paper);color:var(--ink);font-family:var(--sans);line-height:1.5;font-size:15px}
.proto{background:var(--warn-bg);border-bottom:1px solid #E8D6AE;color:var(--warn-ink);padding:7px 20px;font-size:12px;text-align:center}
.top{display:flex;align-items:center;gap:16px;padding:12px 20px;background:var(--card);border-bottom:1px solid var(--line);flex-wrap:wrap}
.wordmark{font-weight:800;font-size:19px;letter-spacing:-.02em}
.wordmark::after{content:"";display:inline-block;width:26px;border-top:2px dashed var(--stitch);margin-left:8px;vertical-align:6px}
.modes{display:flex;gap:2px;margin-left:8px}
.mode{font:inherit;font-size:13px;border:1px solid var(--line);background:var(--card);padding:5px 13px;cursor:pointer}
.mode:first-child{border-radius:var(--radius) 0 0 var(--radius)}.mode:last-child{border-radius:0 var(--radius) var(--radius) 0}
.mode[aria-selected="true"]{background:var(--ink);color:#fff;border-color:var(--ink)}
.mode .b{display:inline-block;min-width:16px;margin-left:6px;padding:0 4px;border-radius:8px;background:var(--chip);color:var(--soft);font-size:11px;font-weight:600}
.mode[aria-selected="true"] .b{background:rgba(255,255,255,.22);color:#fff}
.mode .b.alert{background:var(--alert);color:#fff}
.fresh{margin-left:auto;display:flex;gap:6px;flex-wrap:wrap}
.chip{display:inline-flex;align-items:center;gap:4px;background:var(--chip);border:1px solid var(--line);border-radius:999px;padding:2px 9px;font-size:11.5px;color:var(--soft);white-space:nowrap}
.chip.warn{background:var(--warn-bg);border-color:#E8D6AE;color:var(--warn-ink)}
.chip.bad{background:#FBEDEB;border-color:#E7C4BD;color:var(--alert)}
button.chip.claim{cursor:pointer;font:inherit;font-size:11.5px;border-bottom:1px dotted var(--link);color:var(--link)}
.lens{display:flex;gap:6px;align-items:center;padding:9px 20px;background:var(--card);border-bottom:1px solid var(--line);flex-wrap:wrap}
.lens .lbl,.rail .lbl{font-family:var(--mono);font-size:10.5px;text-transform:uppercase;letter-spacing:.08em;color:var(--stitch)}
.lens-btn,.ws-btn{font:inherit;font-size:12px;border:1px solid var(--line);background:var(--card);border-radius:999px;padding:2px 10px;cursor:pointer;color:var(--soft)}
.lens-btn[aria-pressed="true"],.ws-btn[aria-pressed="true"]{background:var(--ink);color:#fff;border-color:var(--ink)}
.wrap{display:grid;grid-template-columns:250px 1fr;gap:20px;padding:20px;align-items:start}
.rail h3{font-size:11px;text-transform:uppercase;letter-spacing:.08em;color:var(--soft);margin:0 0 8px;display:flex;gap:8px}
.rail h3 .ct{font-family:var(--mono);color:var(--stitch)}
.ws-list{display:flex;flex-direction:column;gap:5px;align-items:flex-start}
.tier{margin-bottom:24px}
.tier h2{font-size:13px;text-transform:uppercase;letter-spacing:.07em;display:flex;align-items:center;gap:9px;margin:0}
.tier h2 .ct{font-family:var(--mono);font-size:12px;color:var(--soft);font-weight:400}
.tier h2::after{content:"";flex:1;border-top:1px dashed var(--stitch)}
.cards{margin-top:10px;display:flex;flex-direction:column;gap:9px}
.card{background:var(--card);border:1px solid var(--line);border-left:3px solid var(--indigo);border-radius:var(--radius);padding:12px 14px}
.card.prov{border-style:dashed;border-left-style:solid}
.card.t-nudge{border-left-color:var(--ochre)}.card.t-investigate{border-left-color:var(--alert)}
.card.t-review{border-left-color:var(--moss)}
.hd{display:flex;align-items:center;gap:8px;margin-bottom:7px;flex-wrap:wrap}
.badge{font-family:var(--mono);font-size:10.5px;letter-spacing:.06em;border:1px solid var(--line);border-radius:3px;padding:1px 6px;background:var(--chip);color:var(--soft)}
.badge.reply{background:#EDF0FC;border-color:#C9D2F4;color:var(--indigo)}
.badge.review{background:#EDF3ED;border-color:#C6DAC8;color:var(--moss)}
.badge.nudge{background:var(--warn-bg);border-color:#E8D6AE;color:var(--warn-ink)}
.badge.investigate{background:#FBEDEB;border-color:#E7C4BD;color:var(--alert)}
.tchip{font:inherit;font-family:var(--mono);font-size:10.5px;border-radius:999px;padding:1px 8px;border:1px dashed var(--stitch);color:var(--soft);background:transparent;cursor:pointer}
.tchip.conf{border-style:solid;background:var(--chip);cursor:default}
.ws{margin-left:auto;font-size:11.5px;color:var(--stitch)}
.unread{width:7px;height:7px;border-radius:50%;background:var(--indigo);display:inline-block}
.ti{font-weight:600;font-size:15px;margin:0 0 6px}
.ln{font-size:13px;color:var(--soft);margin:0 0 3px}
.lbl{font-family:var(--mono);font-size:10px;letter-spacing:.08em;color:var(--stitch)}
.demote{font-size:12px;color:var(--warn-ink);margin:4px 0 0}
.sig{display:flex;gap:5px;flex-wrap:wrap;margin-top:9px}
.msgs{margin-top:9px;font-size:12.5px;color:var(--soft)}
.msgs summary{cursor:pointer}
.exp{margin-top:8px;border-left:2px solid var(--line);padding-left:10px}
.msg{padding:5px 0;font-size:12.5px;border-bottom:1px dotted var(--line)}
.msg:last-child{border:0}.msg .who{font-weight:600;color:var(--ink)}.msg .q{color:var(--soft);font-style:italic}
.deep{color:var(--link);text-decoration:none;border-bottom:1px dotted currentColor;margin-left:6px}
.deep::after{content:" ↗";font-size:.85em}
.empty{background:var(--card);border:1px dashed var(--stitch);border-radius:var(--radius);padding:14px;text-align:center;color:var(--soft);font-size:13px}
.note{font-size:12px;color:var(--soft);margin-top:8px}
.note.foot{border-top:1px dashed var(--stitch);padding-top:10px;font-family:var(--mono);font-size:11px}
.hidden{display:none}
@media(max-width:820px){.wrap{grid-template-columns:1fr}}
</style>`;

const SCRIPT = `<script>
document.querySelectorAll('.mode').forEach(function(m){m.addEventListener('click',function(){
  document.querySelectorAll('.mode').forEach(function(x){x.setAttribute('aria-selected','false');});
  m.setAttribute('aria-selected','true');});});
function applyFilters(){
  var type=document.querySelector('.lens-btn[aria-pressed="true"]').dataset.type;
  var ws=document.querySelector('.ws-btn[aria-pressed="true"]').dataset.ws;
  document.querySelectorAll('.card').forEach(function(c){
    var okT=(type==='all')||c.classList.contains('t-'+type);
    var okW=(!ws)||(c.querySelector('.ws').textContent.trim()===ws);
    c.classList.toggle('hidden',!(okT&&okW));});
  document.querySelectorAll('.tier').forEach(function(s){
    var vis=s.querySelectorAll('.card:not(.hidden)').length;
    var e=s.querySelector('.empty'); if(e) e.classList.toggle('hidden',vis>0);});
}
document.querySelectorAll('.lens-btn').forEach(function(b){b.addEventListener('click',function(){
  document.querySelectorAll('.lens-btn').forEach(function(x){x.setAttribute('aria-pressed','false');});
  b.setAttribute('aria-pressed','true');applyFilters();});});
document.querySelectorAll('.ws-btn').forEach(function(b){b.addEventListener('click',function(){
  document.querySelectorAll('.ws-btn').forEach(function(x){x.setAttribute('aria-pressed','false');});
  b.setAttribute('aria-pressed','true');applyFilters();});});
document.querySelectorAll('.tchip[data-tier]').forEach(function(t){t.addEventListener('click',function(){
  t.textContent=t.dataset.tier+' \\u2713';t.classList.add('conf');
  var c=t.closest('.card'); if(c) c.classList.remove('prov');});});
document.querySelectorAll('[data-ref]').forEach(function(el){el.addEventListener('click',function(ev){
  ev.preventDefault();
  if(el.dataset.shown) return; el.dataset.shown='1';
  var s=document.createElement('span'); s.className='note'; s.style.marginLeft='6px';
  s.textContent='\\u2192 source: '+el.dataset.ref; el.after(s);});});
</script>`;
