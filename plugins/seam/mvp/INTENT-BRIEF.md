# Seam — intent brief

*Read this before the artifacts. It is the high-level intent; the UI, docs, and
site are one attempt at expressing it. Judge the execution against the intent,
not in a vacuum.*

## The one-sentence version

Seam is a personal overlay that reads the surfaces where your work actually
happens — mail and calendar today — works out what genuinely needs you, and puts
it on one page where **every claim links to its source and nothing acts in the
world without your say-so.**

## The problem

Real work runs in through-lines that cross surfaces: a decision half-made in an
email chain, an ask you delegated in chat, a deadline mentioned once in a meeting
invite. No single app sees the through-line, so the user carries it in their head
and things fall through the seams — the ask nobody answered, the plan that
drifted, the buried decision. The failure mode for the target user is not
forgetting a task; it is forgetting a *person* they owe.

## Who it is for

One user (n=1), and specifically a **security-conscious leader** — someone whose
day is other people's asks, who owes answers up a chain, and who will hold this
tool to the same standard they hold vendors to. This person wants two things at
once, and will not accept trading one for the other:

- **Use:** a genuinely useful morning triage that surfaces what needs them, ranked.
- **Trust:** the ability to audit exactly what the tool saw, decided, and did —
  and the guarantee that it cannot act on their behalf without explicit approval.

Trust and use are not a fork. The whole point is that this user gets both.

## The stance (settled decisions)

1. **Overlay, never system of record.** Seam holds only the *delta* between
   reality-in-communications and the formal systems. In perfect sync it holds
   nothing. It points at Jira/wiki/mail; it never replaces them.
2. **Bottom-up inference.** Messages → threads → workstreams. Alignment to formal
   systems is the last step, never the first.
3. **You approve every write.** The system drafts and proposes; the user confirms
   and disposes. Sending, posting, and notifying anyone else is out of scope for
   the foreseeable future. Narrow, self-scoped auto-write rules (e.g. a mail
   filter that affects only the user) may be *earned later*, per-item confirmed —
   never by default, never touching another person.
4. **Ingested content is untrusted input.** External senders' text is
   adversarial-capable. It is data, never instructions. External-sourced facts
   never auto-promote; sender-claimed urgency never reaches the top tier alone.
5. **Local files are the spine.** Plain JSONL + markdown the user owns. No server,
   no account. Inference runs through a model provider — that call is disclosed,
   not hidden.
6. **Everything is actor-attributed.** Every state change is logged as user or
   agent, so "what did this do while I was away" is answerable completely.

## The priority model

Three urgency tiers — **Critical Now** (soft cap 5, auto-demote with visible
reasons) · **Opportunity Now** · **Over the Horizon**. Action *type* — reply,
nudge (a delegation gone quiet), review, approve, reconcile, filter — is a
**lens** you filter by, **not** a section. "Waiting on someone" is one such action
type, and its items carry their own urgency like anything else; it is not a
separate bucket.

Cards are compiled stories under hard word budgets: an outcome-oriented title, a
WHY NOW, a CONTEXT — each claim tappable to the exact source message. AI-assigned
tiers render *provisional* (visually distinct) until the user confirms; you can
always tell at a glance which judgments are yours and which are the machine's.

## First run

A ~10-minute seeding conversation is the install path, not a buried option: name
3–5 workstreams, point at their channels, name the people you cannot keep
waiting. Day one is confident, not apologetic.

## Honest scope right now

- **In:** email + calendar ingest, thread/workstream inference, urgency tiering,
  the compiled board, the actor-attributed ledger.
- **Not yet:** chat, tracker/drift detection, weekly rollups, any write at all
  (drafts included — writes arrive later, always user-confirmed).
- **Commercial posture:** personal-first. Dogfooded on the builder's real mail
  before anything ships publicly; likely open-sourced, not sold. There is no
  business model and n=1 is a deliberate non-goal, not an oversight.

## What we want from your review

Given the intent above: does this execution serve it? Where does the MVP's UI,
documentation, or positioning **misrepresent, undersell, or contradict** the
intent — and what is the single highest-leverage change to close that gap?
