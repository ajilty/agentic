---
name: working-with-aws-cli
description: "aws CLI (any aws command: SSO profiles, SSM, CloudTrail, IAM, load balancers). Load before the first aws call in a session; covers identity and expired-SSO traps, SSM RunCommand quoting, CloudTrail lookups, load-balancer exposure joins. Also when asked which account or role a command really runs as."
---

# Working with the AWS CLI — sharp edges (read-only investigation)

Operating knowledge for `aws` CLI investigation. Account maps, session names, and fleet coverage
are your environment's facts — confirm them live, don't assume.

## Auth

- One `aws sso login --sso-session <session>` authenticates every account sharing that start URL.
  Add `--use-device-code` if the browser flow doesn't open. The login is interactive — the user
  completes it.
- Know which config is active: `AWS_CONFIG_FILE` may point somewhere other than `~/.aws/config`,
  and a stale default file can shadow the real one. Confirm the target account with
  `aws sts get-caller-identity --profile <p>` before acting.

## Profile / identity discipline

- **Profile names lie — always confirm identity before trusting one.** A profile's *name* is not
  its account: `aws sts get-caller-identity --profile <name>` is mandatory before acting on a
  profile, every time. A friendly-looking name can resolve to an entirely different (e.g.
  personal) account.
- **A `ForbiddenException` / `No access` can mean an expired SSO session, not a permission gap.**
  Re-auth with `aws sso login` before concluding the profile lacks the permission.
- **Read-only self-restriction is the norm for audits.** Even with admin SSO, restrict to
  `describe-*` / `list-*` / `get-*` for an audit; offer this proactively.

## Internet-exposure check (the LB→TG→ProtocolVersion join)

Fixed idiom for "is this CVE reachable over the internet here": **list load balancers → list
their target groups → check each target group's `ProtocolVersion` — not just the listener port.**
Port alone misleads: a gRPC target group on `:50051` (`ProtocolVersion: GRPC`) is unaffected by
an HTTP-only CVE even though the port looks open. Don't stop at the open port.

## SSM RunCommand on live hosts (read-only IOC sweeps)

The way to inspect hosts that are not in EDR (commonly CI/build agents).

- **Inline `--parameters commands=...` breaks on any script with quotes/commas**
  (`ParamValidation: Expected ','`). Working pattern: write the script to a file, then
  ```
  jq -Rs '{commands:[.], executionTimeout:["300"]}' script.sh > params.json
  aws ssm send-command --profile <p> --document-name AWS-RunShellScript \
    --instance-ids <ids...> --parameters file://params.json --query Command.CommandId --output text
  ```
- Confirm reachability first: `aws ssm describe-instance-information` (only SSM-managed, online
  hosts can receive commands; EC2-running ≠ SSM-managed). Internal-only hosts with no SSM and no
  EC2 Instance Connect Endpoint have **no read-only path** — document the gap, don't make a
  change to reach them without approval.
- Poll `aws ssm list-commands --command-id <id>` for `Status`/`CompletedCount`, then fetch per
  host with `aws ssm get-command-invocation --command-id <id> --instance-id <iid>`.
- **Keep commands strictly read-only** (find/ls/ps/grep/cat) — this is for hunting, not
  remediation. On-host changes are a separate, approval-gated action.

## CloudTrail

- `aws cloudtrail lookup-events --lookup-attributes AttributeKey=EventName,AttributeValue=<ev>`
  takes **one** attribute filter; loop over event names rather than combining. High-signal,
  low-noise IAM-persistence checks: `CreateAccessKey`, `CreateUser`, `CreateRole`,
  `CreateLoginProfile`, `AttachUserPolicy`.
- Externally-owned access keys (`isExternalAccount`) won't appear in your CloudTrail — their use
  must be checked at the owning account.

## IAM field validation

- **IAM description fields reject em dashes: keep generated text ASCII.** The `CreateRole`
  Description pattern is `[\u0009\u000A\u000D\u0020-\u007E\u00A1-\u00FF]*` (printable ASCII plus
  Latin-1 supplement); an em dash (U+2014) is outside it and fails with `InvalidInput`. The same
  character class applies to other IAM free-text fields, so write descriptions with plain hyphens
  or commas.

## What this skill does not cover

Making changes (rotation, containment, infra/IAM edits) — read-only only. It also holds no
account map or coverage facts; pull those live.

---
Wrong, stale, or missing edge? File it: https://github.com/ajilty/agentic/issues/new?template=edge-report.yml
