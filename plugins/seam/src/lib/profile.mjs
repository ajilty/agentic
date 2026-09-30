// Profile loader: instance config from $SEAM_HOME/profiles/<name>.yaml.
// Guardrails enforced here, not by convention (Build & Run §6):
//   - refuse to run when store_root is missing or belongs to another profile
//   - warn on keys the plugin's template doesn't know (template drift)
import { readFileSync, existsSync } from 'fs';
import { homedir } from 'os';
import { join } from 'path';
import { parseYaml } from './yaml.mjs';

const KNOWN_TOP = new Set(['profile', 'enabled', 'store_root', 'urgency_profile', 'quiet_hours', 'principals', 'sources']);
const KNOWN_SOURCE = new Set(['surface', 'mcp', 'backend', 'read', 'write', 'cadence_min']);

export function seamHome() {
  return process.env.SEAM_HOME || join(homedir(), '.seam');
}

export function profilePath(name) {
  return join(seamHome(), 'profiles', `${name}.yaml`);
}

export function activeProfileName() {
  const name = process.env.SEAM_PROFILE;
  if (!name) throw new Error('SEAM_PROFILE is not set — refusing to guess a persona.');
  return name;
}

export function loadProfile(name) {
  const path = profilePath(name);
  if (!existsSync(path)) {
    throw new Error(`profile not found: ${path} — run \`seam init --profile ${name}\` first.`);
  }
  const profile = parseYaml(readFileSync(path, 'utf8'));
  const warnings = [];
  for (const k of Object.keys(profile)) if (!KNOWN_TOP.has(k)) warnings.push(`unknown profile key: ${k}`);
  for (const src of profile.sources ?? []) {
    for (const k of Object.keys(src)) if (!KNOWN_SOURCE.has(k)) warnings.push(`unknown source key: ${src.surface ?? '?'}.${k}`);
  }
  if (profile.profile !== name) {
    throw new Error(`profile file ${path} declares profile "${profile.profile}", expected "${name}" — never mix stores.`);
  }
  if (profile.enabled === false) {
    throw new Error(`profile "${name}" is disabled — enable it in ${path} once its permissions are confirmed.`);
  }
  if (!profile.store_root || typeof profile.store_root !== 'string') {
    throw new Error(`profile "${name}" has no store_root — set it in ${path}.`);
  }
  return { profile, warnings, path };
}
