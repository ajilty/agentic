---
name: working-with-m365-connector
description: "Microsoft 365 / Outlook connector limits (mail, calendar, Teams, SharePoint): search results are a THINNER projection than a read_resource — no flag.flagStatus, no per-attendee responseStatus, hasAttachments wrong on inline parts; no binary downloads, unreadable .docx / nested .msg attachments (deep-link plus re-upload fallback); Type-3-font PDF mojibake; `order` silently scoping a search to the Inbox unless folderName is given, and the all-folder sweep returning moreResults with no totalResultCount; chat_message_search hitting a tenant-wide Graph 429 and reporting chatsFailed with no warning banner; events stamped timeZone UTC and carrying no onlineMeeting/joinUrl; no internetMessageHeaders (no SCL / SPF / DKIM / gateway verdict); no Exchange admin or audit-log surface; two ErrorAccessDenied 403s needing Mail.Read.Shared and admin-consented People.Read. Use when reading M365 content, sweeping mail by date, searching Teams chats, checking who accepted a meeting, or opening an attachment."
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
- **SEARCH results are a thinner projection than a full read.** Three fields are missing from
  search and present on `read_resource`, and each has produced a confidently wrong answer:
  - **`flag.flagStatus`** — absent from search, returned by a full message read. Use full-read
    as a per-message flag check on hot items; bulk "awaiting reply" judgments still come from
    thread-content inference, labeled as such.
  - **Per-attendee `responseStatus` on a calendar event** — absent from
    `outlook_calendar_search`, present on `read_resource` for the event, one entry per attendee
    with values like `accepted` / `none` (verified on three events). **This corrects an earlier
    note here that said accept/tentative status "is not a field": it is a field, just not a
    search field.** `showAs` (busy vs tentative) is only a proxy. **There is no cheap bulk
    form** — one read per event, so for a whole-calendar RSVP sweep fall back to the
    `Accepted:` / `Tentative:` / `Declined:` auto-receipts in Sent Items (see below) and label
    them as the proxy they are.
  - **`hasAttachments`** — search reported `false` for a message a full read returned as `true`
    with a populated `attachments` array; the search flag appears to ignore parts marked
    `isInline: true`. Never conclude "no attachment" from a search row.
  Budget for it: a full read of a long HTML thread can exceed the 25K-token cap and spill to a
  tool-results file (one measured at 83,396 characters), so these reads are affordable on hot
  items and not across a whole in-window inbox.
- **The all-folder sweep cannot tell you how much it is missing.** A date-only
  `outlook_email_search` with no `folderName` and no `order` searches every folder — the
  cheapest way to expose the auto-filing blind spot below — but it returns `moreResults: true`
  and **no `totalResultCount`**, so it can be paged forever without ever learning the
  denominator. The Inbox-scoped variant of the same window *does* return `totalResultCount`.
  Page the unscoped sweep until a page comes back short, and report its coverage as unbounded.
- **Inbox-folder listings miss auto-filed threads.** Sender-scoped searches return in-window mail
  that the Inbox listing does not (rules and auto-filing move it) — an inbox-only sweep
  undercounts. Cross-check hot threads by sender before claiming "no mail from X".
  **The mechanism: setting `order` (`newest`/`oldest`) on `outlook_email_search` silently scopes
  the search to the Inbox unless `folderName` is also given.** Measured: a date-bounded listing
  returned 11 results and omitted a message that an unscoped sender search found in the same
  window, because a mail rule had filed it elsewhere. Any "sorted by date" sweep is therefore an
  Inbox sweep by default. Pass `folderName` explicitly, or run unscoped and sort client-side.

## Teams chat search shares the tenant's Graph quota

- **`chat_message_search` can 429 on the first Teams call of a run**, before this session has
  made any other Graph call — verbatim: `Note: searched 0 of 47 chats before stopping due to
  Microsoft Graph rate limit (429). Results may be incomplete.` The quota is the tenant's, not
  the session's, so "run Teams first while the quota is fresh" is not a working strategy.
- **Recovery is slower than a minute and not monotonic.** Measured in one run: a 90s backoff
  still returned 0 of 47; 150s produced the only clean pass (37 of 47); a 100s backoff after
  that re-throttled to 0 of 47. Back off longer than feels necessary and re-check coverage.
- **No warning banner does not mean full coverage.** The clean pass returned a bare
  `searchInfo` with no banner and no `stoppedBy` field while still reporting `chatsFailed: 10`.
  `coverage.chatsScanned` against `coverage.chatsListed` is the only honest measure — read the
  ratio every time and report it rather than the absence of a warning.

## Calendar reading

- **Events come back stamped `timeZone: "UTC"` regardless of the mailbox time zone.** Convert
  every wall-clock value explicitly before showing it to anyone; the stamp is not evidence the
  mailbox runs on UTC.
- **A quoted "When:" line inside a mail body renders in the *forwarding* client's time zone.**
  One meeting read `10:00 AM - 11:00 AM` in a mobile-Outlook reference block quoted in a mail
  header and `1:00 PM-2:00 PM` in the calendar event body, with the event `start` at 17:00Z.
  Trust the event, never the quoted header.
- **A forwarded copy of an invite carries the forward's attendee list, not the meeting's.** One
  forwarded event listed 2 attendees while the cover mail's real distribution was 16 To plus 5
  Cc. Never take an attendee count off a forwarded event.
- **A reserved room can appear only in the invite body text**, while the event's `location`
  field carries just the online-meeting URL — a sweep that reads `location` misses the room.
- **Event body text truncates mid-string with no ellipsis**, so a join URL can silently lose its
  query string (cut at `…/j/<id>?`, dropping the `pwd` parameter). Report the URL as null rather
  than completing it from the pattern. (Events carry no `onlineMeeting`/`joinUrl` field at all —
  see "No headers, and no admin surface" below; every join link comes out of body or location
  text, and this is how that parse fails.)
- **Sent Items is ~a third RSVP auto-receipts, and they are noise and signal at once.** Of 80
  sent messages over 7 days, roughly 20 were `Accepted:` / `Tentative:` / `Canceled:` /
  `New Time Proposed:` receipts and ~6 were file-share/comment notifications, so a naive sent
  count overstates real correspondence by about a third — filter them out of any "who did I
  write to" measure. They are simultaneously **the only cheap bulk source of RSVP truth**, which
  is what the per-event `responseStatus` read above does not scale to.

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
