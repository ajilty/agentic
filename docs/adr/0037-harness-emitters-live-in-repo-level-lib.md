# ADR-0037: Harness emitters live in a repo-level lib; the contract carries the wire map

- Status: active
- Date: 2026-08-03
- Context: plugins/orchestrate compiled its harness-neutral `agents.yaml` into
  three native surfaces via three self-contained generators. The hook wire list
  (which script fires on which event) was hand-copied into four places and had
  drifted three times (guard-merge-base CC-only and absent from the contract;
  shared-checkout/done-gate missing on OpenCode; heldout-read bypassable via
  bash there). The tier contract was silently dropped on OpenCode. Boilerplate
  (yq guard, frontmatter stripping, scope parsing, skill install) was duplicated
  verbatim across the generators.

## Decision

1. **The contract carries the wire map.** Each `agents.yaml` hook declares
   `script:` (the one name-to-file map; tests and every emitter read it there)
   and `watch:` (harness-neutral guard classes: `file-read`, `file-write`,
   `shell`, `dispatch`, `post-compaction`). Contract document order is the wire
   order. Guard classes name WHAT is watched, never a harness's tool or event
   vocabulary, so ADR-0007's harness-neutrality holds.
2. **Emitters are a repo-level lib, not plugin scripts.** `scripts/harness-lib/`
   holds `common.sh` (contract accessors, arg parsing, skill install) plus one
   file per harness (`claude-code.sh`, `codex.sh`, `opencode.sh`) mapping watch
   classes to native matchers/events exactly once, including the Codex
   hook-trust seeding machinery. Plugin scripts are thin drivers that name paths
   and plugin-specific content (addenda, summaries, extras like the CC-only
   warn-agent-teams wire and the ADR-0017 persona-lane bodies).
3. **Extraction happened before a second plugin exists, by operator decision.**
   The default rule (extract on second use) was considered and overridden: the
   lib is parameterized by `AGENTS`/`SKILL_DIR` globals and hardcodes no plugin
   names, so plugin #2 consumes it by setting globals and writing a driver.

## Consequences

- The lib is build/install-time only (ADR-0007 unchanged: committed CC
  artifacts, yq at build time, runtime is git + coreutils). A marketplace
  install never touches it. Because the lib lives OUTSIDE the plugin dir, a
  copied plugin tree cannot rebuild with the relative default; `HARNESS_LIB`
  overrides the location, and the drift-guard test sets it for its tmp rebuild.
- Parity is contract-driven end to end: test_build checks every declared hook
  has `script:` + `watch:`, is executable, and is wired in the committed
  hooks.json; test_install checks every declared hook lands in the emitted
  Codex hooks.json and the OpenCode plugin (dispatch class exempt on OpenCode,
  the documented ADR-0034 in-loop exception). The CC hooks.json emission was
  verified byte-identical across the refactor.
- Fixed drift rides along: merge_base_guard contracted and wired on all three
  harnesses; OpenCode gains shared-checkout, done-gate, and heldout-read-on-bash;
  OpenCode emits tier models (Anthropic ladder default,
  `ORCHESTRATE_OC_MODEL_*` overrides); the Codex printed reference config and
  OpenCode command descriptions are generated, not restated; SKILL §2a′ tier
  table is drift-checked against the contract.
- Supersedes nothing; extends ADR-0007/0016/0017/0034. The plan's D5 (Codex
  `.codex-plugin` packaging) remains deferred and unaffected.

## Amended by ADR-0041

OpenCode no longer emits tier models by default, and the `ORCHESTRATE_OC_MODEL_*`
overrides are gone. Standard and economy personas carry a model on Codex and
OpenCode only when `ORCHESTRATE_STANDARD_MODEL` or `ORCHESTRATE_ECONOMY_MODEL`
is set at install time; premium never does. The Codex and OpenCode hook wiring
listed above was removed separately by ADR-0040.
