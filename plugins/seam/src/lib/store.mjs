// Store layout + residency guardrail (Build & Run §3, §6.6).
// A store belongs to exactly one profile; a marker file enforces it.
import { mkdirSync, writeFileSync, readFileSync, existsSync } from 'fs';
import { join } from 'path';

const DIRS = [
  'raw/email', 'raw/slack', 'raw/calendar',
  'entities/workstreams', 'entities/people', 'entities/facts',
  'events', 'state', 'learning', 'board/inbox',
];

const MARKER = '.seam-store.json';

export function initStore(storeRoot, profileName) {
  const markerPath = join(storeRoot, MARKER);
  if (existsSync(markerPath)) {
    assertResidency(storeRoot, profileName);
  }
  for (const d of DIRS) mkdirSync(join(storeRoot, d), { recursive: true });
  if (!existsSync(markerPath)) {
    writeFileSync(markerPath, JSON.stringify({ profile: profileName, created: new Date().toISOString(), layout: 1 }, null, 2) + '\n');
  }
  const wm = join(storeRoot, 'state', 'watermarks.json');
  if (!existsSync(wm)) writeFileSync(wm, '{}\n');
  return storeRoot;
}

export function assertResidency(storeRoot, profileName) {
  const markerPath = join(storeRoot, MARKER);
  if (!existsSync(markerPath)) {
    throw new Error(`store at ${storeRoot} is not initialized — run \`seam init\`.`);
  }
  const marker = JSON.parse(readFileSync(markerPath, 'utf8'));
  if (marker.profile !== profileName) {
    throw new Error(`residency violation: store at ${storeRoot} belongs to profile "${marker.profile}", active profile is "${profileName}". Refusing to run.`);
  }
}

export function readWatermarks(storeRoot) {
  return JSON.parse(readFileSync(join(storeRoot, 'state', 'watermarks.json'), 'utf8'));
}

export function writeWatermarks(storeRoot, wm) {
  writeFileSync(join(storeRoot, 'state', 'watermarks.json'), JSON.stringify(wm, null, 2) + '\n');
}
