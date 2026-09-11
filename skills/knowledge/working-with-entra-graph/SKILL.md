---
name: working-with-entra-graph
description: "Microsoft Graph via az rest for Entra ID (app registrations, service principals, app roles, permissions). Load before the first Graph call in a session; covers permission-to-app-role mapping, pagination, null guards, ConsistencyLevel headers. Also when asked who holds an application permission."
---

# Working with Entra / Microsoft Graph via `az` — sharp edges

How to drive `az rest` against Microsoft Graph for security auditing — the exercised use case is
**auditing which service principals hold a given application permission**. Tenant IDs, SP object
IDs, and role GUIDs are your environment's facts: pull them live, don't memorize.

## The core mental model — app permissions are app roles on a *resource* SP

An application permission is an **app role published by the resource service principal**, not by
the consuming app. So "who holds permission X" is answered against the **resource** SP that
publishes the role, not the app that uses it. Procedure:

1. Identify the resource SP that publishes the role, and the role's GUID (`appRoleId`). Treat
   this as a **lookup**, not something to memorize — pull it live. Sharp edge: **don't infer the
   resource from the permission name.** `ExchangeMessageTrace.Read.All` is a **Microsoft Graph**
   app role (the modern Message Trace API), *not* the Office 365 Exchange Online API the name
   suggests.
2. Enumerate every grant of that role:
   ```
   az rest --method get \
     --url 'https://graph.microsoft.com/v1.0/servicePrincipals/{resourceSpId}/appRoleAssignedTo?$top=999'
   ```
   Page through `@odata.nextLink` until it is absent. Result sets run to hundreds of assignments
   on a busy tenant — always paginate; don't trust a single page.

## Sharp edges

- **Guard against `appRoles: null`.** When sweeping SPs' published `appRoles` to *find* the role
  that backs a permission name, many SPs return `appRoles: null` — iterating without a null
  guard crashes the sweep.
- **`$search` / `$filter` on `displayName` needs `ConsistencyLevel=eventual`.** Add the header
  (`--headers ConsistencyLevel=eventual`) or these advanced queries return 400.
- **Auth / scope / tenant.** `az rest` reuses the `az login` session and mints a token for
  `--url`'s resource (Graph) automatically — no separate token handling. Confirm the active
  context with `az account show` (that's the **tenant** the queries run against). Auditing
  app-role assignments needs only directory **read** (e.g. `Directory.Read.All` /
  `Application.Read.All`); a 403 means a missing read scope or wrong tenant, not a query bug.

## Read-only discipline

- This skill **audits** — read-only Graph `get` calls only. It does not grant, modify, or
  consent to permissions. If your org manages grants as infrastructure-as-code, changes land as
  an IaC PR (not a UI click, not `az rest --method post`), and admin consent is a separate human
  step.
- **No secrets in artifacts.** Access tokens are minted transiently by `az`; never echo or
  persist them.

## What this skill does not cover

Granting or consenting to permissions, and holding tenant/SP/role identifiers — pull live and
verify.

---
Wrong, stale, or missing edge? File it: https://github.com/ajilty/agentic/issues/new?template=edge-report.yml
