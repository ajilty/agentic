# Review rounds

## Plan review (T2, before any implementer)

For each plan-mode dispatch: mint the `dispatch_id`, pin the spec as it stands to
`tickets/<ticket>/verdicts/<ticket>.<dispatch_id>.spec.md`, journal
`dispatched`, then dispatch. On a plan-mode `REJECTED` (it spends no
implementer retry), re-dispatch the planner with that verdict file and pin
path, then a plan-mode verifier with the same verdict and pin, the most
recent round only: it re-reads in full the tasks the diff or a finding
touches and confirms the rest by the diff.

## Outcome review

An instructions change takes three verifiers, one lens
each (act: what an agent would do with it; fit: the rules around it; break:
what defeats it), each given the spec, the changed files, the diff, and
`request.md`. A narrow edit may take one verifier holding all three lenses.
Read the lens verdict files and journal one `verdict` per round: `REJECTED`
if any lens rejects, with the findings merged into
`verdicts/<ticket>.round<N>.md`, which you write. A retry carries the absolute path of the verdict file
(the merged round file on an instructions lane); attach only a file you
have read to its sentinel, else re-dispatch the verifier, not the
implementer. The next round is one verifier on either lane type (the lens
split is for the first review) given the fix diff and the files the
verdict named: it re-runs the commit check and the oracle, verdicts each
prior finding, reviews in full any path the fix touched that the verdict
did not name, and re-reads nothing else.
