# Seam — Where changes persist

Seam runs as one plugin installed on many machines, each machine running one or
more *instances* (persona × profile). The same design must serve all of them
without forking, so every change made while operating Seam lands in exactly one
of three homes. This is Build & Run §3.1 layer 3 made operational.

## The three homes

| Home | Location | Synced by | Contains |
|---|---|---|---|
| **Plugin** | this repo, `plugins/seam/` | git (clone/pull on each machine) | code, prompts, adapters, fixtures, goldens, linters, board template, profile *templates*, docs |
| **Instance config** | `$SEAM_HOME` (default `~/.seam/`) | never synced; created per machine by `seam init` | real `profiles/<name>.yaml` — MCP server bindings, tool-name allowlists, store roots, principals, quiet hours |
| **Store** | `store_root` from the active profile | the profile's own cloud folder (or nothing, for a local personal store) | raw JSONL, entities, ledger, learning, board output |

## The routing rule

When a session learns something or changes behavior, ask: **would every persona
on every machine want this?**

- **Yes → plugin.** Inference thresholds, story-compilation prompts, new adapter
  backends, fixture/golden additions, bug fixes, board template changes, event
  schema additions. Commit on a branch in the plugin repo, push, PR. Other
  machines pick it up on `git pull` + plugin reinstall. Instructions stay
  persona-generic: they name abstract surfaces (email, chat, calendar), never
  products or people.
- **No, it's this persona's binding → instance config.** Which MCP servers
  exist here, real tool names, the write allowlist, principals, store root,
  cadences. Edit `$SEAM_HOME/profiles/<profile>.yaml`. Never committed — it
  contains personal data (principals) and machine-specific bindings.
- **No, it's learned state → store.** Sender weights, durable grouping
  constraints, effort calibration, identity registry, corrections. These live in
  `learning/` and `entities/` under the store root and travel with the store's
  own cloud sync, not with git.

## Making the pattern stick

1. **Templates are the contract.** `profiles/*.yaml.template` in the plugin
   defines every key an instance profile may set. `seam init` copies the
   template; the loader warns on unknown keys, so template drift is caught the
   first time an old instance meets a new plugin version.
2. **The repo lint refuses personal data.** CI greps `plugins/seam/` for
   send-capable tool names (Build & Run §6.1) and for anything that looks like
   a real principal list or store path. If it's personal, it doesn't merge.
3. **Session-end reflex.** When a working session ends with a change worth
   keeping, the operating agent states which home it wrote to and why. A change
   that generalizes but only landed in an instance is a bug to flag.
4. **New machine bootstrap:** install plugin → `seam init --profile <name>` →
   fill in the generated profile (tool introspection assists) → confirm the
   write allowlist explicitly → capture sanitized real responses → goldens →
   live flag. Same path every time; documented in Build & Run §9.
