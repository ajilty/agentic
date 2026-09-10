---
name: working-with-wiz-mcp
description: "Wiz MCP hunting gotchas: NO console deep link on any posture issue, finding, resource or catalog record in any tenant (findings are id-only); tenant separation cannot be proved by comparing scoped queries, since two servers returned byte-identical {\"issues\":{\"nodes\":[],\"totalCount\":0}}, so use an unfiltered control probe; the deliberately-wrong-parameter schema probe (\"additionalProperties zzz_probe not allowed\") as the cheap way to test a tool exists and learn its required properties, and the corollary that a parameter which does NOT error is genuinely applied; graph_search taking a free-text STRING not an object (\"expected string, but got object\", \"Failed to convert free text to graph query\"); list_cloud_resources being richer than graph_search for one named resource (assumeRolePolicy as its own entity with an updatedAt that proves a trust policy did not change); Issue records pointing at SYNTHETIC entities that resolve nowhere; hasAccessToSensitiveData / hasHighPrivileges untrustworthy; list_issues paging 10 with no page param; list_subscriptions capped at 20; SBOM lookalikes; isAccessibleFromInternet null is not false; subscription UUID not cloud account ID; Issues lag. Use for cloud/K8s blast-radius or package hunts, IAM trust-policy questions, pivoting from an Issue to the real resource, when a deliverable needs clickable finding links, when a query returns totalCount 0, or when confirming which tenant a multi-tenant server is actually answering for."
---

# Working with the Wiz MCP — sharp edges (cloud/k8s blast radius)

How to drive the Wiz MCP tools for security hunts. If tools are deferred, load schemas first
(e.g. ToolSearch `select:mcp__wiz__list_sbom`). **Multi-tenant orgs:** separate MCP server
entries for each Wiz tenant share the same URL (`https://mcp.app.wiz.io`) — tenant selection is
scoped to the OAuth session. Run every hunt against each tenant, and read the control-probe
section below before asserting that the two are in fact separated. **Two tenants can also answer
each other's labelling questions:** a principal one tenant calls "outside our cloud
organizations" may be fully inventoried in the sibling tenant,
so querying the sibling for the same account id is the fastest way to tell an unknown third
party from an unregistered affiliate. Wiz cannot make that correlation itself.

## Package / SBOM presence (the "are we affected" question)

- `list_sbom` with a name filter, `list_package_dependencies` for exact names, and
  `graph_search` for library nodes. Search across cloud workloads **and** container images.
- **Substring search lumps languages and yields benign lookalikes** (a search for `vapi` matches
  `vmware.vapi` and `vapi-client-bindings`). Always confirm the **exact** package name *and*
  version before flagging — and exclude the known lookalikes.
- **Prove scanning is live before trusting a negative.** Run a control query for a package you
  know is present (e.g. `express`) and confirm it returns; only then is a `totalCount: 0` a true
  negative rather than a scanner blind spot. (SBOM reflects the last scan, so a transient
  in-build pull can still be missed — pair with endpoint/CI telemetry.)
- Wiz "Malicious Package" detections surface via `list_vulnerability_findings`
  (malicious-package / component-name filter); also check `list_malware_findings`.

## Amplification context

- `list_secret_findings` (exposed creds an executed payload could harvest),
  `list_network_exposure` (internet-facing?), and identity/entitlement tools for blast radius.
- **There is no console deep link anywhere in the MCP surface** — not on a posture issue, a
  finding, a resource, or a catalog record, in any tenant. A finding can be identified by **id
  only**: the full Issue field set observed is `createdAt`, `dueAt`, `entitySnapshot`, `id`,
  `resolvedAt`, `severity`, `sourceRules`, `status`, `statusChangedAt`, `type`, so there is
  nothing URL-shaped to render. Render items as "link not captured", and never construct an
  `app.wiz.io` console URL by pattern. Any workflow that needs a clickable link has to build one
  out of band from the id, or do without: settle that when you design the deliverable, not when
  you render it.
- Treat specific findings as **transactional** — re-pull at query time rather than caching them
  as durable facts.

## CVE exploitability / blast-radius hunts (presence AND exposure)

*(Captured from a single CVE investigation; verify against your tenant before relying on the
finer details.)*

- **Split a CVE into presence vs exposure, then join — never rank on presence alone.** Presence =
  *is the vulnerable artifact here at all* (Vulnerability Findings); exposure = *can it be
  reached* (Security Graph). Ranking on presence alone over-counts internal assets and is
  decisively wrong for an unauth-RCE — join the two and rank on the intersection.
- **A multi-product CVE spans four inventory surfaces — enumerate each.** One vulnerable
  component can land as (1) an **OS package**, (2) an **image SBOM** entry, (3) a **K8s
  workload**, and (4) an **external connector** asset. A single CVE filter misses the
  K8s-controller and appliance variants — query all four surfaces.
- **Wiz does NOT parse application config.** Config-dependent reachability (e.g. an `nginx.conf`
  rewrite pattern that gates whether the CVE is actually hit) cannot be answered by Wiz —
  confirm it out-of-band, then re-import the result as a **custom asset tag** so the graph can
  use it.
- **`isAccessibleFromInternet: null` ≠ `false` — the single biggest lesson.** Wiz returns `null`
  when it can't fully chain a public path, *not* a confirmed "internal." Treat `null` as unknown
  and cross-check raw cloud load-balancer inventory before concluding an asset is not
  internet-facing.
- **Finding-level `executionControllers: []` underreports cross-account deploys.** An empty
  controller list at the finding level does not mean the image is undeployed — for
  centralized-registry patterns the deploy lives in another account. Use
  `list_container_image_execution_context` for the real execution context.
- **`list_kubernetes_clusters` rejects cloud account IDs.** It wants the internal Wiz
  **subscription UUID**, and the error on an AWS account ID is unhelpful. Translate account ID →
  subscription UUID via `list_subscriptions` first.
- **Pagination is not cleanly disjoint** (`first:20` max; a DESC then ASC pass only partially
  overlaps). For exhaustive enumeration use the **grouped endpoints** with
  `group_by=["VULNERABLE_ASSET"]` and accept multiple ordering passes rather than trusting one
  page.
- **Param naming is inconsistent across sibling tools** — fetch the exact schema first before
  composing a call; don't reuse a sibling's param name.
- **`list_issues` returns no assignee fields** — "unassigned" cannot be verified from a list
  call; carry a prior observation as unconfirmed, or fetch the single issue.
- **Wiz "Issues" lag — don't read "0 Issues" as low risk.** Fresh Vulnerability Findings may not
  yet have rolled up into Issues; a `0 Issues` count on a new CVE is a lag artifact, not an
  all-clear.

## Issues, resources, and entitlement flags

- **`list_cloud_resources` is far richer than `graph_search` for one named resource.** It takes
  a `search` param and returns the cloud object, its **`assumeRolePolicy` as a separate
  `RAW_ACCESS_POLICY` entity with its own `updatedAt`**, the attached customer-managed policies,
  and the IaC declarations with repo, branch and path. That `updatedAt` is **the cheapest way to
  prove a trust policy did NOT change inside a window**.
- **Issue records point at SYNTHETIC entities that resolve nowhere.** An issue titled for a
  finding class carries an entity id that is **not** the underlying resource's, and resolves
  through neither `list_cloud_resources` nor `graph_search`; searching the synthetic name
  returns `totalCount: 0`. **There is no API path from an Issue to the specific resource** when
  several share a name — pivot on name plus account, or say the issue could not be pinned.
- **`hasAccessToSensitiveData` / `hasHighPrivileges` are not trustworthy where reach is
  indirect.** A role able to read a database private key and dozens of counterparty transfer
  secrets reported **false** in one tenant while the other end of the same pipeline reported
  **true** in another: reach via secrets-manager *contents* or a tag-gated resource wildcard is
  invisible to these booleans. **Read the attached policy documents; never rank on the flags.**
- **`list_issues` pages 10 with a `totalCount` and no pagination parameter.** Slice with
  `created_after` / `created_before`; records sharing a timestamp cannot be separated, so
  exhaustive enumeration is not always reachable — report the shortfall.
- **`list_subscriptions` accepts no parameters at all** and returns only the first 20 of its own
  `totalCount`. The cloud-account inventory cannot be exhaustively enumerated from this tool.

## Tenant separation cannot be verified by comparing scoped queries

**Two differently-configured servers returning the same empty body proves nothing in either
direction.** Observed: byte-identical `{"issues":{"nodes":[],"totalCount":0}}` from both. That
result is equally consistent with two properly isolated tenants that both happen to have no
matching issue, with one tenant answering twice, and with a filter that matches nothing anywhere.
Matching emptiness is not evidence; it is the absence of evidence, and reporting it as
confirmation of separation is a wrong operator-facing claim.

- **Probe unfiltered, per server.** List issues with **no filters**, ordered by creation. Only a
  server that returns rows is demonstrably answering for *some* tenant — a scoped query cannot
  establish that much.
- **Then check the two result sets are disjoint** — issue ids, resources, and totals should not
  coincide. Overlap is the positive evidence of crossing; identical zeros are not the positive
  evidence of isolation.
- **Control-test the severity filter separately before believing any zero.** An unsupported or
  mis-cased filter value returns an empty set rather than an error, so "no critical issues" is
  only reportable alongside a filter known to return rows in that same tenant.

## What this skill does not cover

Creating findings, suppressions, or ignore rules — read-only hunting only.

---
Wrong, stale, or missing edge? File it: https://github.com/ajilty/agentic/issues/new?template=edge-report.yml
