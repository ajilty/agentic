#!/usr/bin/env node
// Seam CLI. Instance-side entry point; all logic lives in src/.
//   seam init --profile <name>   copy template to $SEAM_HOME, init store if store_root set
//   seam sync                    run one sync pass for $SEAM_PROFILE
//   seam ledger [--type t]       print ledger events for the active profile
import { copyFileSync, existsSync, mkdirSync, writeFileSync, readFileSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';
import { seamHome, profilePath, activeProfileName, loadProfile } from '../src/lib/profile.mjs';
import { initStore, assertResidency } from '../src/lib/store.mjs';
import { appendEvent, readEvents } from '../src/lib/ledger.mjs';
import { syncOnce } from '../src/sync.mjs';
import { generateCorpus } from '../src/corpus/generate.mjs';
import { generateBoard } from '../src/board/generate.mjs';
import { renderBoard } from '../src/board/render.mjs';

const pluginRoot = join(dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
const cmd = args[0];

function flag(name) {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : undefined;
}

try {
  if (cmd === 'init') {
    const name = flag('profile') ?? activeProfileName();
    const dest = profilePath(name);
    if (!existsSync(dest)) {
      const template = join(pluginRoot, 'profiles', `${name}.yaml.template`);
      if (!existsSync(template)) throw new Error(`no template for profile "${name}" in the plugin`);
      mkdirSync(dirname(dest), { recursive: true });
      copyFileSync(template, dest);
      console.log(`created ${dest} — fill in store_root and MCP bindings, then re-run \`seam init\`.`);
      process.exit(0);
    }
    const { profile, warnings } = loadProfile(name);
    warnings.forEach((w) => console.warn(`warn: ${w}`));
    initStore(profile.store_root, name);
    appendEvent(profile.store_root, { actor: 'agent', type: 'store_initialized', profile: name });
    console.log(`store ready at ${profile.store_root} for profile "${name}".`);
  } else if (cmd === 'sync') {
    const name = activeProfileName();
    const { profile, warnings } = loadProfile(name);
    warnings.forEach((w) => console.warn(`warn: ${w}`));
    assertResidency(profile.store_root, name);
    const results = syncOnce({ profile, storeRoot: profile.store_root, fixturesRoot: join(pluginRoot, 'fixtures') });
    console.log(JSON.stringify(results, null, 2));
  } else if (cmd === 'corpus') {
    // Materialize the synthetic UAT world (reproducible from seed). Canonical
    // acceptance corpus is seed 42 / 5 days / 300 per-day. Output is gitignored.
    const outDir = flag('out') ?? join(pluginRoot, 'corpus-out');
    const m = generateCorpus({
      outDir,
      days: parseInt(flag('days') ?? '5', 10),
      seed: parseInt(flag('seed') ?? '42', 10),
      perDay: parseInt(flag('per-day') ?? '300', 10),
    });
    console.log(`synthetic world written to ${outDir}`);
    console.log(JSON.stringify(m, null, 2));
    console.log(`to ingest: point a sync at it — fixturesRoot=${outDir}`);
  } else if (cmd === 'board') {
    // Regenerate the static board from the store (deterministic; no model call).
    const name = activeProfileName();
    const { profile } = loadProfile(name);
    assertResidency(profile.store_root, name);
    const board = generateBoard({ storeRoot: profile.store_root, profile: name,
      watermarks: JSON.parse(readFileSync(join(profile.store_root, 'state', 'watermarks.json'), 'utf8')) });
    const out = flag('out') ?? join(profile.store_root, 'board', 'index.html');
    mkdirSync(dirname(out), { recursive: true });
    writeFileSync(out, renderBoard(board));
    writeFileSync(join(profile.store_root, 'board', 'board-data.json'), JSON.stringify(board, null, 2));
    appendEvent(profile.store_root, { actor: 'agent', type: 'story_compiled', cards: board.counts.cards });
    console.log(`board written to ${out} — ${board.counts.cards} cards from ${board.counts.messages} messages`);
  } else if (cmd === 'ledger') {
    const name = activeProfileName();
    const { profile } = loadProfile(name);
    assertResidency(profile.store_root, name);
    for (const e of readEvents(profile.store_root, { type: flag('type'), actor: flag('actor') })) {
      console.log(JSON.stringify(e));
    }
  } else {
    console.log('usage: seam <init|sync|corpus|board|ledger> [--profile name] [--out dir] [--days N] [--seed N] [--per-day N] [--type t] [--actor a]');
    process.exit(cmd ? 1 : 0);
  }
} catch (err) {
  console.error(`seam: ${err.message}`);
  process.exit(1);
}
