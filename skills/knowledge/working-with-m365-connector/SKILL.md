---
name: working-with-m365-connector
description: "Microsoft 365 / Outlook connector limits (mail, calendar, SharePoint): no binary downloads, unreadable .docx and nested .msg attachments, the deep-link-plus-re-upload fallback, Type-3-font PDF mojibake, search/flag/RSVP blind spots, `order` silently scoping a search to the Inbox unless folderName is given, read_resource returning no internetMessageHeaders (so no SCL / SPF / DKIM / gateway-verdict analysis), no Exchange admin or audit-log surface at all, calendar events carrying no onlineMeeting/joinUrl, and the two ErrorAccessDenied 403s that need Mail.Read.Shared and admin-consented People.Read. Use when reading M365 content, sweeping mail by date, searching another mailbox, looking up a person, chasing a message header or mail-flow rule, or asked to open an attachment surfaced through the connector."
---

# Working with the Microsoft 365 connector — sharp edges

What the M365 connector can and, more importantly, **cannot** do — so a request to read a
document's contents resolves into a working fallback rather than a stall or a guess.

## What it can do

- **Reads METADATA across mail, calendar, and SharePoint** — message and event names, senders,
  recipients, dates, sizes, folder/path structure, and the **thread text** of email bodies and
  calendar event descriptions. Searching and listing work well.
- Right tool for "find the thread about X", "who was on this meeting", "what's the subject/size
  of the attachment", "what files are in this SharePoint folder".

## What it cannot do — and the fallback

The connector is **metadata-and-text only**, with **no binary download** path:

- **It cannot render `.doc` / `.docx` contents.** It surfaces that a Word attachment exists, its
  name and size — not the document text inside it.
- **It cannot open nested Outlook `.msg` items.** A message attached to another message
  (forward-as-attachment, a phishing-report package that nests the original, a `.msg` saved to a
  file) is opaque — you see it exists, not what it says.

**Fallback for unreadable content:** surface the **deep-link** to the item (the SharePoint or
Outlook URL the connector returns) and **ask the user to re-upload the file** directly into the
conversation, where it can be read as an attachment. Do not stall, and do not infer contents from
the filename — state plainly that the connector can't render it and hand back the link plus the
re-upload ask.

## It is read-only

**No mail-send, no calendar-write.** Drafting a reply, proposing a meeting, or composing a message
is fine as text for the user to act on — but the connector cannot transmit it. Any send or
schedule is the user's action after they review and approve the draft.

## PDF gotcha: Type-3-font PDFs extract as mojibake

A PDF built with **Type-3 fonts carrying no Unicode CMap** has no text-to-character mapping, so
text extraction returns garbled glyphs even though the PDF looks fine to a human. When extracted
text is garbage but the document clearly has real content, **rasterize the pages and read them
visually** instead of trusting the broken text layer.

## Search and status limits (mail + calendar)

- **Free-text `query` cannot combine with date filters inside a named folder** — either date-bound
  the folder listing (no query) and page by `offset`, or run the free-text search unscoped and
  filter client-side.
- **Flag status is absent from SEARCH results, but a full message read (`read_resource` on the
  message) DOES return `flag.flagStatus`.** Use full-read as a per-message flag check on hot
  items; bulk "awaiting reply" judgments still come from thread-content inference, labeled as such.
- **Event accept/tentative status is not a field.** Infer from `showAs` (busy vs tentative) plus
  explicit "Accepted:" items in Sent Items; label it as a proxy.
- **Inbox-folder listings miss auto-filed threads.** Sender-scoped searches return in-window mail
  that the Inbox listing does not (rules and auto-filing move it) — an inbox-only sweep
  undercounts. Cross-check hot threads by sender before claiming "no mail from X".
  **The mechanism: setting `order` (`newest`/`oldest`) on `outlook_email_search` silently scopes
  the search to the Inbox unless `folderName` is also given.** Measured: a date-bounded listing
  returned 11 results and omitted a message that an unscoped sender search found in the same
  window, because a mail rule had filed it elsewhere. Any "sorted by date" sweep is therefore an
  Inbox sweep by default. Pass `folderName` explicitly, or run unscoped and sort client-side.

## No headers, and no admin surface at all

- **`read_resource` on a message returns no `internetMessageHeaders` field.** The shape is body,
  sender, recipients, `flag`, `internetMessageId`, `webLink`, `parentFolderId` — and that is it.
  So spam-confidence scores, authentication results (SPF/DKIM/DMARC), and upstream mail-gateway
  verdicts are **unreachable on this plane**. Any "was this message's gateway verdict honoured"
  question cannot be answered here at all.
- **The connector exposes no Exchange admin surface whatsoever** — no transport-rule, inbound-
  connector, anti-spam-policy, unified-audit-log or mailbox-audit-log tool exists. There is
  nothing to call and be denied, which is why probing for one wastes a round-trip. **Route
  mail-flow, permission-change and audit questions to a SIEM that ingests the Exchange audit
  stream instead**; that pivot turns a dead end into a single query, and is usually the only way
  to establish who did what to which mailbox.
- **Calendar events return no `onlineMeeting` object and no `joinUrl` field.** Where a join link
  exists it sits inside the event's free-text body or location and must be parsed out. Do not
  report "no join link" from the absence of the field.

## Two 403s that look like outages and are not

`get_me` succeeding while another call 403s is the tell: the connector is live and the problem is
an unconsented scope, not connectivity. Both of these need an admin grant, so surface them as an
operator action rather than retrying.

- **Shared / other-mailbox reads need `Mail.Read.Shared`.** `outlook_email_search` with
  `mailboxOwnerEmail` set to any mailbox but your own returns HTTP 403, verbatim:
  `FORBIDDEN: Failed to search messages caused by: Access is denied. Check credentials and try
  again., Cannot find row based on condition.` with `graphErrorCode: ErrorAccessDenied` and
  `sharedMailbox: true`.
- **Directory lookup needs admin-consented `People.Read`.** `search_people` returns 403,
  verbatim: `FORBIDDEN: Graph denied access; this tool requires the 'People.Read' delegated
  permission. The hosted OBO path requests '.default', so 'People.Read' may not be
  admin-consented on the confidential client app registration`. With this dark there is no
  authoritative identity or group read at all — resist inferring membership from other surfaces
  without labelling it.

---
Wrong, stale, or missing edge? File it: https://github.com/ajilty/agentic/issues/new?template=edge-report.yml
