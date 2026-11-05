// jsdom smoke validator for the board template — adopted from the prototype's
// seam-board-validate.mjs with the hardcoded input path fixed to the repo
// location. Requires jsdom (dev-only) and src/board/template.html, which
// graduates from prototype v7. NOTE: seam-board-v7.html was missing from the
// handoff folder; this validator is inert until that file is recovered or the
// template is rebuilt at M3.
import {JSDOM} from 'jsdom';
import {readFileSync, existsSync} from 'fs';
import {fileURLToPath} from 'url';
import {join, dirname} from 'path';
const templatePath = join(dirname(fileURLToPath(import.meta.url)), 'template.html');
if (!existsSync(templatePath)) {
  console.error(`validate: ${templatePath} does not exist yet — graduate prototype v7 first (M3).`);
  process.exit(2);
}
const html=readFileSync(templatePath,'utf8');
const errors=[];
const dom=new JSDOM(html,{runScripts:'dangerously',resources:'usable',
  beforeParse(w){w.addEventListener('error',e=>errors.push(e.message));
    w.scrollTo=()=>{};w.HTMLElement.prototype.scrollIntoView=()=>{};}});
await new Promise(r=>setTimeout(r,400));
const w=dom.window,d=w.document;
const q=(sel)=>d.querySelectorAll(sel).length;
const t=(id)=>d.getElementById(id)?.textContent??'(missing)';
const results=[];
const check=(name,cond)=>{results.push((cond?'PASS':'FAIL')+' '+name);};
check('no load errors: '+(errors[0]||''),errors.length===0);
check('operate cards >=8 (got '+q('#tiers .card')+')',q('#tiers .card')>=8);
check('reflect rolls =4 (got '+q('#reflectWrap .roll')+')',q('#reflectWrap .roll')===4);
check('know facts =4 (got '+q('#knowWrap .fact')+')',q('#knowWrap .fact')===4);
check('badges O/R/K/A = '+[t('bOperate'),t('bReflect'),t('bKnow'),t('bAgent')].join('/'),
      t('bReflect')==='2'&&t('bKnow')==='2');
w.pivot('phish');
check('pivot phish: cards=3 (got '+q('#tiers .card')+')',q('#tiers .card')===3);
check('pivot phish: rolls=1 (got '+q('#reflectWrap .roll')+')',q('#reflectWrap .roll')===1);
check('pivot phish: facts=1 (got '+q('#knowWrap .fact')+')',q('#knowWrap .fact')===1);
w.clearFilters();
w.pivotPerson('dana');
check('person dana: cards>=2 (got '+q('#tiers .card')+')',q('#tiers .card')>=2);
w.clearFilters();
w.resolveFact('okta','promoted');
check('promote fact: pending know badge=1 (got '+t('bKnow')+')',t('bKnow')==='1');
w.undoKn(0);
check('undo fact: badge back to 2 (got '+t('bKnow')+')',t('bKnow')==='2');
w.resolveRoll('roll_iam');
check('review rollup: reflect badge=1 (got '+t('bReflect')+')',t('bReflect')==='1');
w.confirmTier('act_101');
check('confirm tier via chip fn: event logged',JSON.stringify([...w.document.querySelectorAll('#ledgerBody')].length)==='1');
w.assignBlock('act_103','cal_f1');
check('schedule: card left board',!d.getElementById('act_103')||d.getElementById('cal_f1').textContent.includes('1'));
w.openReview();
check('review friday modal opens',d.getElementById('overlay').classList.contains('open'));

// Escape-by-default guard: no sender-derived field may reach innerHTML or an on*
// attribute raw. Fails on the round-2 defect class (title/whyNow/context/attachment
// concatenated unescaped). Any new raw interpolation of these must go through esc/escAttrJs.
const src=readFileSync(templatePath,'utf8');
const rawPats=[
  /\+it\.(title|whyNow|context|type)\b(?!\s*\))/,        // it.title etc not wrapped
  /openLink\('\s*\+\s*(a\[|it\.|f\.|m\.)/,             // openLink(' + rawvar  (unescaped url in onclick)
];
const rawHits=[];
for(const re of rawPats){ if(re.test(src)) rawHits.push(String(re)); }
// Flag a sender-derived field only when it sits BETWEEN two string literals —
// the HTML-sandwich signature ( '...'+field+'...' ) — and is not wrapped in
// esc()/escAttrJs(). This excludes ledger/log value strings like `"+f.val,`.
const fields='it\\.title|it\\.whyNow|it\\.context|a\\[1\\]|a\\[0\\]|f\\.name|f\\.val|f\\.prov|f\\.anchor|f\\.anchorLabel|m\\.snip|m\\.link';
const bad=[...src.matchAll(new RegExp("['\"]\\s*\\+\\s*("+fields+")\\s*\\+\\s*['\"]",'g'))]
  .filter(m=>{const pre=src.slice(Math.max(0,m.index-11),m.index); return !/esc\(|escAttrJs\(/.test(pre);});
check('XSS guard: no raw sender-derived field in render paths ('+bad.length+' raw)', bad.length===0);

console.log(results.join('\n'));
process.exit(results.some(r=>r.startsWith('FAIL'))?1:0);
