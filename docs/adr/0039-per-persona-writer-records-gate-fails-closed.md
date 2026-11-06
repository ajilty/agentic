# Writer records are per persona; the pre-apply gate fails closed on a missing record

ADR-0006 bridged per-dispatch context to the hooks through one on-disk record,
`active-writer.json`, and noted that one record was sufficient only under a
strict single writer. SKILL §6 and §6a nonetheless permit an Implementer and an
Actuator (disjoint mutation targets) or two proven-independent Implementers to
overlap, and `writer-ctx set` overwrote the slot unconditionally. Measured on
2026-11-06 in a live run: (1) a second builder's registration overwrote the
first's assigned branch, so the first builder's commit was refused and its lane
stalled 23 minutes while the write-ahead journaled the second builder under the
first's ticket; (2) an Actuator was dispatched while a builder's record was in
force, so `gate-prod-apply.sh` resolved an empty `prod_targets` and allowed every
command. Reproduced in a scratch repo: overwriting or clearing the record while an
unacked Actuator runs turns the "hard floor" into an allow. No ack marker exists
anywhere in that repo's run history, so the gate had in practice never engaged.

**Decision.**

1. One record per persona: `active-writer.<persona>.json`. `writer-ctx set`
   writes the dispatched persona's file; `get` takes the persona
   (`get <persona> <key>`); `clear [persona]` removes one file, or all of them
   plus the legacy slot when no persona is given. `keep-on-branch.sh` reads only
   the implementer record, `gate-prod-apply.sh` only the actuator record, and
   `on-writer-dispatch.sh` the record of the persona being dispatched.
2. The gate fails closed: an Actuator whose ticket resolves from neither env nor
   its own record is denied on every command and journals `gate-blocked` with
   `key=unregistered`. A registered Actuator with no prod targets is declared
   safe and runs freely, which keeps "absent" and "safe" distinguishable.
3. The legacy `active-writer.json` is never read as context. `reground` HALTs on
   it, as on any per-persona record, so an upgrade mid-run cannot drop a writer.
4. The Implementer is registered too, immediately before its dispatch, and the
   skill says so (§9b); the branch-guard and the builder write-ahead were already
   reading the record, but only the Actuator flow was documented.

## Status

accepted. Extends ADR-0006 (the record remains the bridge; its "one record is
sufficient" consequence no longer holds) and ADR-0011 (the write-ahead reads the
dispatched persona's record).

## Considered options

- **Refuse an overwrite from a different ticket** — surfaces the collision at
  dispatch instead of at commit, but still serializes builder and Actuator, and a
  `clear` from the other lane still blanks the gate. Rejected as insufficient.
- **Per-ticket records with the hooks consulting all of them** — the only option
  that makes two builders hook-safe, but it needs a per-dispatch selector that
  the dispatch-time payload does not carry (the router would have to put a
  marker in the prompt), and the gate must be conservative across records.
  Deferred: builders overlap in 2 to 7 percent of runs, and the safety defect is
  cross-persona, which per-persona records close.
- **Leave the gate fail-open on a missing record** — keeps Codex and OpenCode
  Actuators running when the router skips registration, at the cost of the gate
  being a convention. Rejected: the floor is the point.

## Consequences

- A builder lane can no longer blank or retarget the Actuator's gate context,
  and the Actuator's record cannot deny a builder's commit.
- A skipped `writer-ctx set … actuator` now stalls the Actuator on its first
  command instead of running it ungated. On Codex and OpenCode, whose launchers
  pass no `TICKET`/`PROD_TARGETS` env, registration is the only way the gate
  arms; an Actuator denied on everything means the step was skipped.
- Two registered builders still share one record (KNOWN-LIMITATIONS); the skill
  tells the router to run registered builders one at a time.
- The gate still sees only Actuator subagents. An apply the router runs inline is
  ungated; the skill now says so rather than implying otherwise.
- Tests: `tests/test_writer_ctx.sh` covers cross-persona isolation, fail-closed
  denial, the legacy file, and reground on each record; `tests/test_hooks_safety.sh`
  expects the unregistered-Actuator denial.
