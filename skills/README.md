# Skills library

This is one instance of the repo's primitive-library pattern: top-level
libraries (`skills/`, and `agents/` etc. once their first artifact lands) are
source of truth; plugins are symlink views. Wiring rule for every primitive
type: symlink directories, never files — file symlinks are skipped by
component discovery. See ADR-0036.

Source of truth for every portable skill in this repo, organized by category:

```
skills/<category>/<skill-name>/SKILL.md
```

Plugins are views over this tree. A plugin ships a skill by symlinking it:

```sh
ln -s ../../../skills/<category>/<skill-name> plugins/<plugin>/skills/<skill-name>
```

Claude Code dereferences symlinks when copying a plugin to its install cache
(verified empirically 2026-08-03: installed cache contains real directories,
and the skill appears in the plugin's component inventory), so distributed
plugins are self-contained. Git preserves the symlinks in the repo itself.

## Categories

| Category | Contents | Ships in |
|----------|----------|----------|
| `meta` | workflows about working itself (grill, retro, harvest) | playbooks; edges links `harvest`, `harvest-author`, `harvest-review` |
| `office` | comms, calendar, planning workflows (day-prep) | playbooks |
| `coding` | engineering workflows (assignment, research, plan, brief, build, verify, tdd, review) | playbooks; orchestrate links the craft phases |
| `security` | security workflows (threat-model) | playbooks |
| `knowledge` | `working-with-<tool>` sharp-edge notes | edges |

Categories exist for browsing and maintenance; routing is done by skill
descriptions (auto-invoked) or by the name you type (user-invoked). A skill's
category is where it lives; which plugins link it is a separate, per-skill
choice.

## Rules

- **Search here, not in `plugins/`.** `rg` and `grep -r` do not follow
  directory symlinks by default, so searching a plugin's `skills/` finds
  nothing. This tree is the source; edit and search it directly.
- **No user or company references, ever.** This repo is public. Skills that
  cannot be written without naming a person or employer belong in private
  harness config, not here.
- **Plugin-internal skills stay in their plugin.** orchestrate's skills are
  implementation detail of a versioned product, not library content; they do
  not move into this tree.
- Skill directories are kebab-case; workflow skills are the imperative phrase
  typed after `/`; knowledge skills are `working-with-<tool>`.
- **Name for bare invocation.** Unique names resolve without the plugin
  prefix, so check new workflow names against Claude Code built-ins (`/review`,
  `/init`, `/code-review`, ...) and installed plugins; a collision forces
  `/playbooks:<name>` forever. Prefer a distinct name; accept the prefix only
  when the semantic name is worth it.
- **Knowledge skills carry what docs don't.** Docs lookup is already served
  (context7, vendor plugins); `working-with-<tool>` holds sharp edges only —
  gotchas, failure modes, misleading flags. The description is the API for
  auto-invoked skills: write "use when" triggers with concrete error strings,
  command names, and jargon the model will actually see.
