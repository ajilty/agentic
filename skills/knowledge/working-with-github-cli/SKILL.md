---
name: working-with-github-cli
description: "gh CLI (gh search, gh api, gh pr, GraphQL) across a SAML-protected GitHub enterprise. Load before the first gh call in a session; covers search-index undercounts, scope and SAML 403s, review-inbox and workflow-history queries. Also when a user's activity numbers look implausibly low."
---

# Working with the GitHub CLI — sharp edges (enterprise hunting)

How to drive `gh` across SAML-protected orgs for fan-out hunting, inventory, and per-user
activity lookups.

## Token scopes — know which endpoint needs what

| Endpoint | Required scope |
|---|---|
| `/orgs/<org>/audit-log` | `admin:org` **+** `read:audit_log` (classic PAT) |
| `/orgs/<org>/dependabot/alerts` | `security_events` |
| `/orgs/<org>/packages` | `read:packages` |
| `/orgs/<org>/actions/runners` | `admin:org` |

- Add scopes with `gh auth refresh -h github.com -s <scope>` (interactive — the user completes
  the browser/device step).
- **SAML wall:** orgs return `403 "protected by organization SAML enforcement"` even with the
  right scope until the PAT is **SSO-authorized per org** (GitHub → Developer settings → PAT →
  Configure SSO → Authorize, per org). Authorizing is what flips it: on one account, team
  listings stopped 403ing and membership resolved for **21 of 23 orgs** with no change but
  per-org SSO authorization. Some orgs also 403 simply because the caller is not an admin there.
  Record which orgs were queryable vs blocked.
- **That 403 is genuinely ambiguous, because `gh` prints BOTH diagnoses at once.** A single
  `gh api orgs/<org>/teams` call emits the SAML message
  (`Resource protected by organization SAML enforcement. You must grant your OAuth token access
  to this organization.`) *and*, on the next line,
  `gh: This API operation needs the "admin:org" scope. To request it, run:  gh auth refresh -h
  github.com -s admin:org`. Neither can be ruled out without fixing one and retrying — **do not
  report it as settled SAML.**
- **Team membership resolves through GraphQL on a `read:org`-only token**, where the REST teams
  endpoint 403s:
  `gh api graphql -f query='query{organization(login:"<ORG>"){teams(userLogins:["<user>"],first:100){nodes{slug}}}}'`.
  It answered for most orgs on a token with only `read:org`. Where it *also* fails, you have a
  genuine coverage gap rather than a scope inconvenience — which is the distinction worth
  reporting.
- **Audit-log bypass:** if your org streams GitHub enterprise audit events into a SIEM, querying
  there gives enterprise-wide visibility that bypasses every per-org SAML wall — far better than
  iterating `/orgs/<org>/audit-log`.

## Efficiency

- **Code search is heavily rate-limited (~10/min per token)** and unscoped by default (returns
  public-GitHub noise) — always `--owner=<org>`-scope it, and prefer the git-trees + contents
  API (`/repos/<o>/<r>/git/trees/<branch>?recursive=1`, 5000/hr) for exhaustive sweeps.
- Code search only indexes **default branches**; feature branches, PRs, and archived repos are
  not covered — note that as a residual gap when scope matters.
- `gh search code` substring matches yield benign lookalikes — confirm exact path/name.
- **The search API drops repos it cannot see — loudly when you name one, SILENTLY when you
  don't. This is the asymmetry that costs findings.** Scoped to a single repo it says so:

  ```
  gh api "search/issues?q=repo%3A<org>%2F<repo>+author%3A<user>+type%3Apr+state%3Aopen"
  HTTP 422 {"message":"Validation Failed","errors":[{"message":"The listed users and
  repositories cannot be searched either because the resources do not exist or you do not have
  permission to view them.","resource":"Search","field":"q","code":"invalid"}],"status":"422"}
  ```

  `gh` surfaces that as `gh: Validation Failed (HTTP 422)`. But in a broad
  `gh search prs --author=<user>` the same repo is dropped with **exit code 0, nothing on
  stderr, and a shorter array**. Measured once at **30 returned against 36 real**, hiding a PR
  that had sat for 493 days.
- **The SIZE of that gap is a per-token SSO-authorization artifact, not a standing property of
  the search API, and it has reversed on the same account** (search later answered for eight
  orgs it had not seen, with no change but per-org SSO authorization in between). The mechanism
  is permanent; the number is a property of your token today, so measure it at the start of a
  run instead of quoting a remembered figure. **The CROSS-CHECK side must come from outside the
  search index** — a GraphQL `search(type:ISSUE)` `issueCount` is the same index and measures it
  against itself. Compare like with like, one author and one state on both sides:

  ```sh
  gh search prs --author=<user> --state=open --limit 1000 --json id --jq 'length'
  ```

  against the `viewer{pullRequests(states:OPEN)}` call below, or a repo-by-repo `gh pr list`,
  then diff the id lists. The `--limit` default is 30, so it is not optional, and the search API
  hard-stops at 1,000 results, so an org-wide count saturates rather than counts.
  `--limit 100 | wc -l` is not a substitute either: it caps at 100 and counts table rows.
- **Cross-check with GraphQL, which does not use the search index.** One call replaces both the
  search and the per-PR fan-out, and diffing the two id lists is the proof:

  ```sh
  gh api graphql -f query='query{viewer{pullRequests(states:OPEN,first:100){totalCount
    nodes{number url repository{nameWithOwner} isDraft reviewDecision
    reviewRequests(first:20){totalCount nodes{requestedReviewer{
      ... on User{login} ... on Team{slug}}}}
    reviews(first:50){totalCount nodes{author{login} state}}
    commits(last:1){nodes{commit{statusCheckRollup{state}}}}}}}}'
  ```

  As written it returns `reviewDecision`, the CI rollup, and — via the `nodes{}` selections —
  requested reviewers (user *and* team) and per-review author + state. Drop those two `nodes{}`
  blocks if you only need counts. (`viewer` is self-only; for another user, diff
  `gh search prs --author=` against a repo-by-repo `gh pr list`.)
- **Issue search can be stale per-repo** — a dated `gh search issues` query can return empty for
  an issue that plainly matches. The verification path is plain
  `gh issue list --repo <r> --state all` + client-side filter; treat search emptiness as
  unverified, not as absence.
- Enumerate orgs with `gh api user/orgs --jq '.[].login'` — **but it does NOT list every
  accessible org.** An org reachable via `gh repo list <org>` can be absent from the list; when
  you suspect an org exists, probe it directly.

## Code-audit idioms (fast fan-out across many repos)

- **`gh search code --owner <org> '<pattern>'` audits many repos fast** (tens of repos across
  orgs in minutes). Returns ~30 results/call as **~3-line fragments**, not whole files — follow
  up on a hit with `gh api repos/<o>/<r>/contents/<path> --jq .content | base64 -d`.
- **Searching an infrastructure org for a raw opaque identifier is the highest-yield move for
  naming an unknown principal.** `gh search code --owner <org> "<literal id>"` — a cloud account
  number, a subscription GUID, a role ARN suffix — returns the friendly name, the locals-file
  aliases across repos, and any docs table naming it, in one query. That is what turns "unknown
  external account" into an identification.
- **Search fragments come back literal-escaped** (`\n` as two characters, not a newline). Add
  `| gsub("\n";" ")` in the `--jq` to flatten them into readable single lines.
- **`gh api …/contents/<path>` returns object-for-file vs array-for-dir.** Shape-check `type`
  before indexing — a blind `.content` access dies on a directory path.
- **Fetch a file by branch/SHA on a private repo via the contents API, not raw.**
  `raw.githubusercontent.com/<o>/<r>/<branch>/<path>` 404s when the branch name contains slashes
  (can't disambiguate branch from path) and again on private repos (curl carries no auth). Use
  `gh api repos/<o>/<r>/contents/<path>?ref=<sha-or-branch> --jq .content | base64 -d`.

## Per-user activity lookups

- **`gh search prs --review-requested=<user>` DOES include team-based requests** — verified,
  not assumed: a PR whose only `reviewRequests` were three *teams*, with no direct request on
  the user, still appeared. So a low review-request count is not a direct-request-only
  undercount; look elsewhere for the gap.
- **Merged PRs keep their pending team review requests.** PRs in state `MERGED` with
  `reviewDecision: APPROVED` still report a populated `reviewRequests` array. A reviewers-array
  check alone therefore marks them as still awaiting the user — **gate on `state` before reading
  `reviewRequests`**, or the inbox inflates with resolved work. This is what turned 7 in-window
  `review_requested` notifications into 0 real asks.
- **For a time-window lens, notifications beat search — and only notifications see the work that
  arrived and cleared inside the window.**
  `gh api --paginate "notifications?all=true&since=<iso>&per_page=100"` surfaced all 7 in-window
  review requests; **none** appeared in `gh search prs --review-requested=<user> --state=open`,
  correctly, because all 7 had already merged. **`all=true` is mandatory** — without it read
  notifications vanish and the window looks empty. `subject.url` is an **API** URL
  (`api.github.com/repos/<o>/<r>/pulls/<n>`), not a browser URL: derive owner/repo/number from
  it and take `html_url` from `gh pr view --json url` rather than hand-editing the string.
- **`contributionsCollection` lies for non-self queries.** Querying *another* user's
  contributions silently zeroes private-repo activity the requester can't see. Never report
  "user had 0 commits" from it without that caveat.
- **Search visibility ≠ contribution visibility.** Search results respect *repo* visibility from
  the requester's vantage; contribution counts respect the *target user's* privacy settings.
  Prefer search-derived counts and label contributions-derived numbers as such.
- **Treat a zero-activity result for a believed-active user as a resolution failure, not a true
  zero.** Login conventions vary wildly — org-suffixed (`jdoe-acme`), unrelated handles, or
  display-cased bare names — and a naive guess (e.g. stripping dots from `first.last`) silently
  returns zero for an active user. Cheapest exact resolution: `gh pr view <n> --repo <o>/<r>
  --json author` on a PR you know they authored; else match display names via
  `gh api orgs/<org>/members`. Record resolved mappings somewhere durable so you never re-derive.
- **One GraphQL request beats five REST calls** for activity rollups: search-by-author,
  by-commenter, by-reviewer, contributionsCollection, and rate-limit info fit in a single
  query.
- **Don't sum `commits.total` against per-repo numbers expecting agreement** — the API total is
  subject to privacy, per-repo numbers reflect what the requester can see; they legitimately
  differ.
- **Don't use `gh search prs --author=<x>` alone** for a person's footprint — it scopes to
  listable repos, misses cross-org results, skips review/comment surfaces, and silently drops
  every repo whose search index 422s (see the search-API asymmetry above).
- **Don't paginate beyond 100 per surface** — narrow the window and declare truncation instead.
- **External-org activity counts.** A PR in an unexpected org still belongs in a person's rollup
  if they authored or reviewed it. On a 404/permissions error, surface a missing-access item —
  never silently skip the org and report a false zero.
- **The org audit log bypasses user privacy settings** (events are org-scoped, not user-scoped) —
  a useful fallback when a user's activity is privacy-hidden but you hold org audit access.

## Workflow run history

- **Proving a workflow has NEVER succeeded is three cheap calls, and `gh run list` cannot do
  it.** A `--limit 100` listing shows recent failures and cannot distinguish "broken for days"
  from "broken forever". The definitive check is the status-filtered totals:
  `repos/<o>/<r>/actions/workflows/<id>/runs?per_page=1&status=success` → `total_count` 0, then
  `…&status=failure` → `total_count` N, with the unfiltered `total_count` also N. Then page to
  the last page (`ceil(N/100)`) and read `workflow_runs[-1]` for the first-ever run. That turns
  "it is failing" into "it has never once worked, since <date>".
- **`gh run list --workflow` needs the numeric id, and a name-substring lookup can return two.**
  Filtering the workflows list on a name substring matched both `<Name> — tests` and `<Name>`;
  assigning that two-line result to a shell variable put a literal newline inside the URL and
  `gh` failed with
  `net/url: invalid control character in URL`. Anchor the name match or take the exact id — and
  note that an em dash in a sibling workflow's name breaks naive quoting.
- **zsh does not word-split unquoted parameters**, so the common bash idiom
  `for p in "<repo> <num>"; do set -- $p; gh pr view $2 -R $1; done` passes **nothing**: every
  call dies with `argument required when using the --repo flag` plus a full help dump. Write the
  `gh` invocations out explicitly rather than looping over packed strings.

## What this skill does not cover

Modifying repos, runners, packages, or settings — read-only hunting only. It holds no org
inventory; pull live with `gh api`.

---
Wrong, stale, or missing edge? File it: https://github.com/ajilty/agentic/issues/new?template=edge-report.yml
