# Nekius Dispatch — Specification

## What this is
A dispatcher web app for a volunteer laundry organization ("Nekius") that
washes clothes for people who are unable to do it themselves. It is modeled
on an existing hospital-volunteer dispatch app ("Reisman Dispatch") whose
screenshots drove the visual design (blue header bar, rounded white cards,
pill-shaped status badges, big blue primary buttons, numbered-step forms,
bottom app footer). See `/design-reference/` for the original screenshots.

The owner has **no computer** — only a phone and a tablet — and is on a
**free, non-subscribed personal claude.ai account**. That constraint is why
this is a real, independently-hosted web app (Supabase + GitHub Pages)
rather than a claude.ai artifact: a free individual account cannot grant
real multi-user shared write access with access control.

## Entities

### Clients (people getting laundry washed)
- Name, phone number
- Address + Note (free text)
- **Mashilach** toggle (Israeli charity-visitor flag). When on, auto-fills
  the address/note from a shared preset stored in Settings — but the
  filled-in values remain fully editable per client.
- Status: Active / Inactive. Default filter everywhere = Active.

### Volunteers (washers)
- Name, phone, address + note
- Status: **Active / Inactive / Temporary Inactive** (Temporary Inactive
  takes a from/till date range and auto-reverts to Active once the till
  date passes)
- Bag-capacity label: 1 / 2 / 3 / **4 bags plus**
- Wash Frequency: once a month / twice a month — drives a readiness
  indicator shown throughout the app:
  - **Green** = on track given their frequency and last **completed**
    request
  - **Amber** = due / falling behind
  - **Gray** = no completed requests yet (frequency not yet established)
  Readiness is computed strictly from **completed** requests, never from
  in-progress ones.
- Default filter everywhere = Active.
- Tapping a volunteer's name anywhere in the app (dispatch cards, request
  history, etc.) navigates to their profile.

### Drivers
- A fully separate top-level section — **never** nested under Volunteers.
- Name, phone, email, address
- Contact-method labels: SMS / WhatsApp (used to decide how the
  copy-pasted Driver Message should be sent)
- Status: Active / Inactive only (no Temporary Inactive — that's a
  volunteer-only concept). Default filter = Active.

### Requests
- Client (one), number of bags, requested-for date/time, assigned
  Volunteer, and **two** driver assignments — a pickup-leg driver and a
  return-leg driver — each assigned at its own Posted stage (see status
  flow below).
- Bag count is only meaningful on the pickup-from-client leg. On the
  return leg the washer packages however she wants, so bag count is
  omitted from return-leg messaging.
- Notes field.

## Status lifecycle

```
Open → Assigned → Posted (pickup) → Delivered → Finished → Posted (return) → Completed
```
Plus two reachable end-states from anywhere: **Not Covered**, **Cancelled**.

- **Open**: new request, no volunteer yet.
- **Assigned**: a volunteer has been assigned.
- **Posted** (pickup leg): a driver is assigned to bring the bags from the
  client to the volunteer. Driver assignment happens *within* this status,
  not as its own separate status.
- **Delivered**: bags are with the volunteer.
- **Finished**: washing is done, ready to go back to the client.
- **Posted** (return leg): a driver (can be the same or different) is
  assigned to bring the clean bags back to the client. Same status name as
  the pickup Posted stage, reused for the return leg.
- **Completed**: fully done. This is what readiness indicators count.
- **Not Covered** / **Cancelled**: end states, reachable manually at any
  point. Cancelled is tracked as its own real, visible status — not merged
  into Not Covered — and shows up in individual and aggregate request
  history.

### Manual override
Every request's status badge is tappable and opens a full override menu
that can jump to **any** status regardless of current data completeness
(e.g. force a request straight to Completed even with no driver recorded).
This is a deliberate escape hatch for dispatcher judgment calls.

### Full edit, always available
Every request — in any status — has a complete "Edit Request" action
reachable next to Cancel/Delete, letting the dispatcher change: client,
bag count, requested-for date, assigned volunteer, pickup driver, return
driver, and notes. Editing a client/volunteer/driver's core info (name,
phone, address) propagates everywhere that record is referenced, including
already-open requests.

## Messaging (copy-to-clipboard, not auto-sent)

Two distinct, dispatcher-customizable templates, generated per request and
copied to the clipboard for the dispatcher to paste into SMS/WhatsApp:

1. **Post Message** — short, street-only (no house number/full address),
   available at the Assigned and Posted stages. Example shape: "Acer to
   Blavelt" (pickup leg: client street → volunteer street) reversed for the
   return leg (volunteer street → client street). Wording (before/between/
   after the two street names) is customizable in Settings.
2. **Driver Message** — the full message sent to whichever driver is
   specifically assigned to that leg. Built from an editable Settings
   template with placeholders (client name/address, volunteer name/address,
   bag count, date/time, etc.). Bag count is omitted on the return-leg
   template since the washer packages freely.

Street-only extraction is a heuristic: strip a leading house number and
common street-type suffixes from a full address.

## Navigation & roles

Main sections: Dashboard, Dispatch, Clients, Volunteers, Drivers, Request
History, and (Editor-only) Settings + user management.

- **Dispatch** search box is explicitly restricted to **request ID only**
  — it must never search by client/volunteer/driver name. Searching by
  name happens on the Clients/Volunteers/Drivers pages themselves.
- Tapping any person's name anywhere (dispatch card, history row, etc.)
  navigates to that person's profile.
- Default filter = Active, applied consistently across Clients,
  Volunteers, Drivers lists.
- The Dispatch status tab bar must stay scrolled to whichever tab the
  dispatcher just moved a request into (it must not snap back to the
  first tab after a status change).

### Roles
Two roles, enforced server-side (Postgres RLS), not just hidden in the UI:
- **Editor**: full access, plus Settings and dispatcher user management
  (invite new dispatchers, change roles, remove users).
- **Dispatcher**: everything except Settings/user management.

Login is real Supabase Auth (email + password), gated by an **invite
list**: only emails an Editor has pre-added to the invite list can sign up.
The very first person to ever sign up automatically becomes the Editor
(bootstrap case, since there's no Editor yet to invite one). All
dispatchers see and edit the same live shared data — no per-user silos.

"I don't want anyone with the link to see everything" was the owner's
explicit requirement that ruled out any link-only / no-login access model.

## Settings (Editor-only)
Collapsible accordion sections (collapsed by default — a small bold-label
box with an icon that expands on tap), covering:
- Mashilach preset address/note
- Default bag-count options
- Post Message wording template (before/between/after street names)
- Driver Message templates (pickup-leg and return-leg, with placeholders)
- Dispatcher/user management (invite emails, change roles, remove users)

## Hosting / infrastructure (already set up and live)
- **Supabase** project (Postgres + Auth + RLS) — see
  `supabase_credentials.md` for the project URL and publishable key only;
  the secret/service-role key and DB password are deliberately **not**
  stored in this project.
- **GitHub Pages** static hosting, deployed from the `main` branch root,
  no build step — the whole app is one `index.html` plus the Supabase JS
  client loaded from a CDN.
- Schema already executed successfully against the live project: see
  `database_schema.sql` (7 tables, RLS policies, the invite/first-user
  trigger).

## Implementation state as of handoff
`index.html` is a from-scratch rebuild of the earlier claude.ai prototype,
reusing its CSS/visual language but wired to real Supabase tables
(snake_case columns) with async CRUD wrappers and role-gated UI. It was
syntax-checked (`node --check`) but **had not yet been interactively
tested end-to-end against the live Supabase project with the owner**
before this handoff — sign-up, login, and CRUD against the real database
from the deployed GitHub Pages site still need to be verified live.

## Explicitly deferred / not yet built
- Address autocomplete (would need a server-proxied Places API key)
- Real SMS/WhatsApp sending (would need a provider like Twilio) — for now
  messages are copy-to-clipboard only, sent manually by the dispatcher
- "Forgot password?" flow (Supabase supports `resetPasswordForEmail`,
  not yet wired into the UI)
- Change-own-password UI
- True Supabase Auth account deletion for "remove dispatcher" (currently
  only removes the `profiles` row, which blocks access via RLS but leaves
  the underlying auth account intact)

## Architecture note for whoever continues this
Built as a single-file vanilla JS/HTML/CSS app (no build step), using an
event-delegation pattern: `data-action` / `data-nav` / `data-live`
attributes read by one set of listeners bound once at init (never rebound
inside `render()` — that caused a duplicate-listener freeze bug earlier).
Whether to keep this architecture or migrate to a framework (React/Vite)
is an open question — do not assume a migration is wanted without asking.

Known bug fixes already baked into the design, worth preserving when
continuing:
- Modal close must check `e.target.closest('.modal-overlay')` and that the
  click target is *not* inside `.modal` itself — an earlier `closest`
  check was wrong and caused any click inside a modal to close it.
- Event binding happens exactly once at script init, never inside
  `render()`.
- Default datetime inputs use a `toLocalInputValue(d)` helper to avoid a
  UTC/local timezone bug.
- Toggle chips (bags, SMS/WhatsApp labels) are wired through a single
  generic `data-action="toggle-chip"` so they participate in the normal
  event-delegation system instead of being a special case that silently
  doesn't fire.
