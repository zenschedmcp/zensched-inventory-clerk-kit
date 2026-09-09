# ZenSched Tenant-Inventory Clerk Reference Kit

A copy-pasteable setup for a solo UK / Ireland inventory clerk, or a 2–6 clerk firm that dispatches subcontracted clerks, that wants an AI assistant to run appointment intake, GPS-verified arrival at each property, a photo Inventory Report (rooms, cleanliness, meters, keys, damage), a dispute pack you can paste into your own report or email to the agent, receivables from letting agents and landlords, and sub payouts. ZenSched handles the phone app, the GPS check-in at each property, the one-off event and shift per appointment, and the Inventory Report. A small local database on your computer holds your clients, the properties you have been to, your inventories (with the tenants' names and the key-safe codes), invoices, and payouts.

**You do not need to know how to program or write SQL to use this.** You paste an agent's instruction into your AI assistant ("Northcote just sent this, book it"), ask "what's today", "close out today", "export the check-out for 12 Oak Lane", "invoice Northcote", "who owes me money", and the AI does the work using two tools you set up once. Setup takes about 15 minutes and is the only technical part.

If you *are* a developer, skip to [For developers](#for-developers).

## This is not a TDS/DPS e-file tool, and it is not a branded PDF report generator — read this first

**What this kit is:** a way for an inventory clerk to get every check-in, check-out, and mid-term onto their phone from a pasted agent email, prove GPS-verified arrival at the property, record a photo Inventory Report (rooms covered, cleanliness, meters, keys, damage), and turn those records into a dispute pack, invoices, receivables follow-up, and sub payouts, with an AI assistant doing the clerical work.

**What it is not:**

- **It is not a TDS, DPS, or mydeposits e-file tool.** It does not submit to a tenancy-deposit scheme, does not produce a statutory inventory in a scheme's format, and does not decide whether a deduction is justified. `reports_to_export` plus a `form_export` give you the photos and the GPS-verified times; you (or the agent) paste that into *your* report or email and file however you file today.
- **It is not a branded PDF inventory report generator.** Tools such as InventoryBase, iInventory, and similar products render a formatted report for the agent and the tenant. This kit does not. The Inventory Report on the phone is an operational photo form; the "export" is plain text plus photo links.
- **It does not watermark photos.** Each room / damage photo stores capture location and time **as metadata** when the phone can read them (`capture_lat`, `capture_lng`, `capture_ts`, `capture_source` — EXIF GPS first; a live camera shot can fall back to device GPS). Gallery picks without EXIF coords, screenshots, and denied location permission come back empty. Compression strips EXIF from the JPEG on S3, so those fields travel next to the file, not inside it. That is where the picture was taken. The GPS **punch** is separate: it is whether the clerk was inside the geofence. The exported image is **not** stamped with date, time, or coordinates. If a solicitor or a scheme later wants a *readable* stamp on the image itself, shoot with your phone camera's timestamp / GPS overlay turned on (or a GPS-stamp camera app) and upload *that* image.
- **It does not store tenancy agreements, deposit amounts, or scheme membership numbers.** Those belong in the agent's file. The local database stores the agent's instruction reference so invoices match their works order.

If any of that is a deal-breaker, this kit is not for you. If you want a phone schedule with GPS proof of arrival, a photo report per visit, and receivables you can actually chase, read on.

## What lives where

**ZenSched (source of truth for where you were and when):**

- Locations (one per property, cached locally so the check-out reuses the check-in pin; the check-in radius is a policy setting)
- Workers (you, in solo mode; you plus your subs in agency mode, each with the mobile app)
- Events (one single-day event per inventory)
- Shifts (one per inventory: the appointment window, 90 minutes by default, with a push notification to the clerk)
- GPS punches (check-in / check-out with distance-from-the-pin verification)
- The Inventory Report form (rooms, cleanliness, room photos, meters, keys, damage, notes) and every submission with its photos

**Local SQLite database (`inventory-ops.db`, on your computer):**

- Clients: letting agents, landlords, other inventory firms, with payment terms and default fees by visit type
- Properties: every address you have been sent to, normalized, with its ZenSched location id and access notes (key safe, alarm, "keys with neighbour") — **access notes never leave your computer**
- Clerks: you (and your subs); payout split per sub
- Inventories: instruction ref, type, tenant name and phone (**never leave your computer**), property, time, fees, the ZenSched event/shift/submission ids, GPS arrival stamps copied once, a summary of the report
- Invoices per client with aging; payouts per sub per inventory
- Your settings (timezone, country, default clerk, default appointment length, invoice terms and prefix, Inventory Report form id)

**Never duplicated:** the live schedule, punches, and photos stay in ZenSched. The local database stores *references* to them plus the few facts you need to answer "was I on time", "export Oak Lane", and "who owes me" without paying to re-read records.

### Privacy note

Everything that identifies a tenant lives only in the local database: `inventories.tenant_name`, `tenant_phone`, `access_notes`, and `properties.access_notes`. `SKILL.md` forbids the AI from putting any of them into any ZenSched field, including location names, event titles, notes, and cancellation reasons (subs see those). Location name and event title are the visit type plus the street — `Check-out 12 Oak Lane` — never the tenant. The Inventory Report form itself tells the clerk not to write names or codes in it. You are still responsible for your own privacy obligations (the local database, your email, your phone); this kit narrows what a third party sees, it does not make you compliant by itself.

## How it works day to day

Your AI assistant has two sets of tools:

1. **ZenSched tools** (`location_create`, `event_create`, `shift_create`, `shift_status`, `form_submissions`, `form_export`, ...) that talk to ZenSched over the internet.
2. **A SQLite tool** (`sqlite_query`, `sqlite_execute`) that reads and writes `inventory-ops.db` on your computer.

When you paste an agent's email, the AI extracts the client, instruction number, type, tenant, address, time, and fee; adds the client if new; looks the address up in your `properties` cache (a flat you checked in last year is reused, a new address is geocoded once); saves the inventory with a number like `INVY-2026-0001`; creates a single-day event and a shift on ZenSched with the Inventory Report attached; and confirms in one line. You see the appointment on your phone, check in at the door (GPS-verified), walk the property, fill in the Inventory Report with photos, and check out. In the evening you say "close out today" and the AI pulls your verified times and the reports, updates each inventory, and tells you what is now receivable. "Export the check-out for 12 Oak Lane" writes the dispute pack (GPS times + photo links). "Invoice Northcote" produces a plain-text invoice under their terms; "who owes me money" ages what is open. In agency mode, "what do I owe Owen" lists his split per job. You never run SQL yourself. `SKILL.md` in this repo is the instruction sheet that teaches the AI how to do all of this; you paste it into your AI tool once.

## Setup

### 0. What you need

- **An AI tool that supports MCP.** These instructions use Claude Desktop (Windows or Mac). Cursor and Muse Code work too.
- **Node.js 20 or newer.** The SQLite tool runs on it. Download the LTS installer from [nodejs.org](https://nodejs.org/) and run it with the defaults. This is the only software install.
- You do **not** need the `sqlite3` command-line program, Python, or Git.

### 1. Make a folder for your data

Create a folder where the database will live and write down its full path. Examples:

- Windows: `C:\Users\YourName\inventory-ops`
- Mac: `/Users/yourname/inventory-ops`

The database file will be created automatically inside this folder the first time the AI uses it. This folder will contain tenant names and access codes; keep it on an encrypted, backed-up disk, not in a shared folder.

### 2. Add both tools to your AI's config file

Open the MCP configuration file for your AI tool:

- **Claude Desktop, Windows:** `%APPDATA%\Claude\claude_desktop_config.json` (paste that into the File Explorer address bar)
- **Claude Desktop, Mac:** `~/Library/Application Support/Claude/claude_desktop_config.json` (in Claude Desktop: Settings → Developer → Edit Config)
- **Cursor:** Settings → MCP → Add new global MCP server

Paste in the contents of `mcp.json.example` from this repo, then change one line, the `SQLITE_PATH`, to point at your folder from step 1 plus `\inventory-ops.db` (Windows) or `/inventory-ops.db` (Mac):

```json
{
  "mcpServers": {
    "zensched": {
      "url": "https://mcp.zensched.com/mcp",
      "headers": { "Authorization": "Bearer zsc_your_key_here" }
    },
    "inventory-ops-db": {
      "command": "npx",
      "args": ["-y", "easy-sqlite-mcp"],
      "env": { "SQLITE_PATH": "/Users/yourname/inventory-ops/inventory-ops.db" }
    }
  }
}
```

**Windows path gotcha:** inside a JSON file every backslash must be doubled. Write `"C:\\Users\\YourName\\inventory-ops\\inventory-ops.db"`, not `"C:\Users\..."`. A single backslash will silently break the config.

**Leave `zsc_your_key_here` exactly as it is for now.** You do not have a key yet. The ZenSched tools that create your account work without one, and you will fill this in during step 3.

Save the file and **fully quit and reopen** your AI tool (on Mac, Cmd-Q; on Windows, right-click the tray icon → Quit). It only reads this file on startup.

### 3. Create your ZenSched account

In a new chat, type:

> Call `zensched_guide`, then call `account_create` with org_name "My Inventory Clerk" (use my real business name if I told you one). Show me the `zsc_` key it returns.

Copy the `zsc_` key. Go back to the config file from step 2, replace `zsc_your_key_here` with your real key, save, and fully quit and reopen the AI tool again.

Some clients can adopt the key mid-session with `account_use_key`; you can ask the AI to try that to keep going immediately, but still update the config file so the key survives restarts. Keep the key private; it is the password to your account.

### 4. Create the database tables

Open `schema.sql` from this repo in any text editor, copy the whole thing, and paste it into the chat with this message in front of it:

> Create these tables in my inventory-ops database. Run each statement one at a time using the SQLite tool, then list the tables to confirm.

The AI will run 45 statements and confirm the tables exist. The `inventory-ops.db` file now exists in your folder with default settings (90-minute appointments, net 30, GMT `+00:00`) you can change.

If you happen to have the `sqlite3` command-line tool, `sqlite3 inventory-ops.db < schema.sql` does the same thing, but it is not required.

### 5. Teach the AI the workflow

Paste the contents of `SKILL.md` into your AI tool as standing instructions. In Claude Desktop, create a Project and put it in the project instructions; in Cursor, save it as a rule. Then tell it your basics once:

> We're Thames Inventory Co in London, British Summer Time. It's just me, Priya Shah, priya@example.com. Set me up.

It writes those to the `settings` table, **invites you to ZenSched as a worker** (you are the clerk on the phone; $0.25, one time), creates the Inventory Report form on ZenSched (free), and saves the form id so every appointment gets it automatically. In agency mode you then say "add my sub Owen Blake, owen@example.com, I pay him £55 a job" for each clerk you dispatch.

**Check-in radius.** ZenSched enforces the radius through the account's policy, not per property, and with geofencing on it raises anything under 100 m to about 91 m (300 ft), so a house and its front garden are covered as is. For mansion blocks, gated developments, and new-build courtyards where you park a long way from the entrance, ask the AI to "set the check-in radius to 150 m" or 300 m (`policy_update`), or to move the pin onto the entrance for a repeat site (`location_update`, free; the `properties` cache keeps it). Never ask it to "widen the radius on that location" — that field is informational only. Clerks arrive early: ask for "allow check-in 20 minutes before the shift" (`checkin_slack_min`). `remote_checkin` turns GPS verification off for every appointment and should be a last resort, because it also turns off the proof.

**Forgotten check-outs.** Ask the AI to "remind me to check out 15 minutes after the shift ends" (`checkout_reminder_min_after`).

### 6. Funding (only when asked)

The first 200 ZenSched tool calls per day are free. Some things are metered: creating a location (geocoding, $0.03; skipped for a cached repeat property), inviting a worker ($0.25, including yourself), each GPS-verified check-in or check-out ($0.10), and reading an Inventory Report ($0.05, or $0.15 when it has photos; each record is billed once, ever; replays are free). When a metered call happens without funds, the AI will get a `payment_required` response and tell you how to add the $5 activation deposit, which is credited to your balance. You will not be charged without seeing this first.

An inventory at a new address costs $0.03 + $0.20 + $0.15 = **~$0.38**; an inventory at a property you have already pinned costs **~$0.35**. Twenty inventories a month is about $7.50. The AI states the cost before it spends.

## Using it

Everything after setup is plain English. Examples:

- (paste a letting-agent instruction) "Book it."
- "What's today?" / "What's this week?"
- "Close out today."
- "Export the check-out for 12 Oak Lane."
- "The 10 o'clock moved to 1." / "Northcote moved Oak Lane to Monday."
- "Cancel Merton Road; they owe a £40 wasted-journey fee."
- "Invoice Northcote." / "Invoice everyone."
- "Who owes me money?"
- "Northcote paid INV-2026-0001."
- Agency: "Add my sub Owen Blake, owen@example.com, £55 a job." / "Give Friday's check-in to Owen." / "What do I owe Owen?"

See `QUICKSTART.md` for the first-week walkthrough and `example-workflow.md` for exactly which tools the AI calls behind each of these.

### What "invoice" means here

"Invoice Northcote" records the invoice in your database (number, date, due date under that client's terms, total, which inventories with their fee breakdown) and the AI writes out a plain-text invoice you can paste into an email or the agent's payables portal, with a line per inventory (your inventory number, date, type, their instruction ref, street, fees) and, for a no-show, the GPS-verified arrival. It does **not** generate a PDF, submit it for you, or collect payment, and it does not add VAT — you do that in your own accounts if you are VAT-registered. Invoices never carry a tenant's name; the instruction ref and the street identify the file to them. When the client pays, tell the AI ("Northcote paid INV-2026-0001") and it marks it paid. "Who owes me money" ages what is open into current / 30 / 60 / 90+ days past due.

### What "payouts" means here (agency mode)

Subs are paid per inventory, not by the hour. Each sub has a split (`£55 flat` or `70%` of what the client is billed for that appointment). When a sub's inventory is closed out, a payout row is created with the amount; "what do I owe Owen" lists his unpaid jobs and the total, and "paid Owen" marks them. Your own inventories never generate payouts. The kit does not calculate taxes or pay anyone. If you also want an hours record for your own books, ZenSched's `timesheet_export(mode="hours")` is free; the kit does not use timesheets for pay.

## Mobile app for clerks

- **Android:** [Google Play](https://play.google.com/store/apps/details?id=com.zensched.app)
- **iOS:** [App Store](https://apps.apple.com/us/app/zensched/id6800081657)

In solo mode you invite yourself; the email arrives at your own address, you install the app, and your appointments appear as they are booked. Each one shows the address and time; you check in on arrival (GPS-verified), walk the property, fill in the Inventory Report with photos, and check out. Subs get the same email when you add them. There is no signature step; you submit the report yourself.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| AI says it has no ZenSched tools | Config file not saved, or the app was not fully restarted | Check the JSON is valid (paste it into [jsonlint.com](https://jsonlint.com)), then quit and reopen the app |
| AI says it has no SQLite / `inventory-ops-db` tools | Node.js not installed, or bad `SQLITE_PATH` | Install Node.js LTS; on Windows check every backslash is doubled |
| `SQLITE_PATH` points nowhere / "unable to open database" | Folder from step 1 does not exist | Create the folder; the file is created automatically but the folder is not |
| ZenSched tools return an auth error | Key still says `zsc_your_key_here`, or was pasted with a space | Re-paste the key, restart |
| `payment_required` | Metered call with no balance | Follow the instructions in the response; $5 deposit |
| AI creates shifts at the wrong hour | Timezone not set, or daylight saving changed | "Set my timezone offset to +01:00 in settings" (BST) or `+00:00` (GMT / winter). Ireland uses the same offsets. |
| Appointment not on my phone | Booked locally but the ZenSched shift was never created (`needs_shift = 1`) | "Put today's inventories on my phone"; the AI finishes the intake steps |
| Check-in not GPS-verified at a mansion block / gated development | You parked outside the policy radius, or the pin is on the road | "Set the check-in radius to 200 m" (`policy_update`), or "move the pin to the main entrance" (`location_update`, free; the cached property keeps it), or `location_refine` ($0.10). Do not ask to widen the radius "on that location". |
| App would not let me check in 15 minutes early | Early check-in window too small | "Allow check-in 20 minutes before the shift" (`checkin_slack_min`) |
| Forgot to check out | Shift still `checked_in` | Tell the AI the real time; ask for a 15-minute check-out reminder |
| Inventory Report not on the phone | Form not assigned to that appointment's event before the shift was created | "Attach the Inventory Report to INVY-2026-0004" (`form_assign`), then cancel and recreate the shift |
| "Meter readings" / "Damage notes" show even when the answer is No | Conditionals follow the prior answer on the phone; a leftover draft can still show them | Leave them blank if they do not apply |
| Photos have no date/GPS printed on them | Working as intended | Pixels are unmarked. Capture lat/lng/time sit on the image record when the phone could read them. Punch GPS is separate (were you at the pin). Use a camera overlay if you need pixels stamped. |
| AI refuses to put the tenant's name or the key-safe code on ZenSched | Working as intended | Tenant PII and access codes stay on your computer |
| Same property geocoded twice | Address typed differently ("Lane" vs "Ln", postcode on a new line) | Tell the AI it is the same place; it merges the `properties` rows and keeps one location |
| Appointment moved to another day fails on `shift_update` | Events are single-day | The AI cancels the shift and creates a new inventory (`rescheduled_from`) with its own event; ask it to |
| Inventory numbers look like invoices | You numbered an inventory `INV-` | Inventories are `INVY-YYYY-0001`; invoices are `INV-YYYY-0001`. Leave `inventory_no` NULL and the trigger assigns `INVY-`. |
| AI asks you to run SQL yourself | It does not have `SKILL.md` loaded | Re-paste `SKILL.md` as project instructions |

If something is confusing or broken in ZenSched itself, ask the AI to call `feedback_submit` with a description. It is free, needs no account, and a human reads every submission.

## For developers

**Architecture.** Two MCP servers, no application code. The agent is the integration layer; `SKILL.md` is the spec it follows. ZenSched is authoritative for operations (schedule, punches, form submissions); SQLite is authoritative for clients, properties, roster, inventories (including all tenant PII and access codes), billing, and payouts; each side stores only the other's IDs, plus a per-inventory summary and the GPS stamps cached locally because submission reads are metered. The PII boundary is enforced by data placement (tenant columns exist only locally, and the views compute the ZenSched-safe `zensched_location_name` / `zensched_event_title` strings) and by `SKILL.md` rules 2–3; there is no technical control stopping a misbehaving agent, so review the rules if you swap models.

**Data model decisions.**

- **One-off appointments, not recurring routes.** Lawn / pet / home-care kits expand a weekly template onto a per-site event rolled every 60 days. Inventory work is a dated appointment at a property, so there is no recurrence table and no event roll. `inventories` is the driving table; each row maps to exactly one `event_create(location_id, title, start_date=<date>, end_date=<date>, idempotency_key="event-invy-{inventory_id}")` and one `shift_create(event_id, worker_id, start, end, idempotency_key="shift-invy-{inventory_id}")`, with `form_assign(form_id, event_id=...)` in between so the shift installs the form on the phone. The 60-day event cap is irrelevant because every event is one day.
- **`properties` is an address de-dup cache.** `properties.normalized_address` is `UNIQUE`; the agent normalizes (lowercase, strip `,` `.` `#`, collapse whitespace, include city and postcode) and looks it up before any `location_create`. A hit reuses `zensched_location_id`, which saves the $0.03 geocode and, more importantly, preserves any hand-tuned pin (`location_update`) for a mansion block the clerk returns to for check-out. Normalization is done by the agent rather than a trigger because SQLite cannot collapse whitespace cleanly. One ZenSched location per property; the first visit's type+street label (`Check-in 12 Oak Lane`) is what `location_create` sends, and later visits reuse the pin. Event titles are always computed for the *current* visit (`Check-out 12 Oak Lane`).
- **Solo mode is the default; agency mode is additive.** The owner is invited as a ZenSched worker (`worker_invite` with their own email, $0.25) and stored on `clerks` with `is_owner = 1`; `settings.default_clerk_id` points at that row and the `fill_inventory_defaults` trigger assigns it when `clerk_id` is left NULL. Subs are further `clerks` rows with `payout_type` `CHECK IN ('flat', 'percent')` and `payout_value`. `payouts_due` and `payouts_missing` exclude `is_owner = 1`.
- **Receivables and payouts, not timesheets.** Clerks are paid per inventory by the agent, often net 30, so the money model is per-inventory fees → `billable_inventories` → `invoices` with the client's `payment_terms_days` → `invoices_outstanding` aging. Subs are paid per inventory (split), so `payouts` is per inventory, not hourly. `timesheet_export` appears in `SKILL.md` only as an optional free hours record. VAT is out of scope.
- **`billable_total` is computed in a view, not stored.** The fee columns on `inventories` (`inventory_fee`, `travel_fee`, `other_fee`) are snapshots filled by trigger from the client's defaults when left NULL (`inventory_fee` follows `inventory_type`). Which of them are owed depends on `status`, and that rule lives once, in `billable_inventories`: `completed` → inventory + travel + other; `no_show` → travel only (wasted journey); `cancelled` → `other_fee` only; everything else → 0. `receivables_by_client`, the invoice `INSERT ... SELECT`, `payouts_due`, and the `fill_payout_amount` trigger all read from that view.
- **`inventory_no`** is assigned by trigger as `INVY-{YYYY of scheduled_start}-{inventory_id:04d}` when left NULL; an explicit value is kept. **Do not use `INV-`** — that prefix is `invoices.invoice_number` (`{prefix}-{YYYY}-{invoice_id:04d}`).
- **`scheduled_start` is local wall-clock time without an offset** (`2026-09-10T10:00`, `CHECK`-constrained to reject a trailing offset or `Z`). `inventories_today` / `inventories_upcoming` emit `start_iso` and `end_iso` by appending `settings.timezone_offset`, with `end_iso` via `datetime(..., '+N minutes')`. Day-based views use `date('now', 'localtime')` because the SQLite MCP server runs on the owner's computer, whose clock is in the business's time zone; `date('now')` would be UTC and would roll "today" over at midnight UTC (evening in the UK is fine; do not rely on that).
- **No signature field on the form.** ZenSched replaces the Submit button with the signature pad when a form has a `signature` field. The clerk is alone in an empty (or nearly empty) property and submits with a normal button. `room_photos` is a required `photo` field (`max_images: 8`); a submission with photos bills $0.15 instead of $0.05.
- **GPS stamps are copied once.** `checked_in_at`, `checked_out_at`, `gps_verified`, `checkin_distance_m` are filled from `shift_status` at close-out so "was I on time" and the dispute pack are answered locally. ZenSched remains the original.
- **`exported_at`** gates `reports_to_export`. The agent sets it after writing the dispute pack so the same check-out does not keep appearing at session start.
- **Reschedules.** Same day → `shift_update` and update `scheduled_start`. Different day → the single-day event cannot move, so `shift_cancel`, mark the row `rescheduled`, insert a new row with `rescheduled_from` (self-referencing FK, `ON DELETE SET NULL`), and create a new event/shift. Only the new row bills.
- `inventories.zensched_shift_id`, `clerks.zensched_worker_id`, `payouts.inventory_id`, and `properties.normalized_address` are `UNIQUE`. `PRAGMA foreign_keys = ON` is in `schema.sql` and `SKILL.md` tells the agent to run it per session. Deleting a client cascades to inventories, invoices, and payouts; deleting a clerk sets `inventories.clerk_id` NULL and removes their payouts; `properties` is `ON DELETE RESTRICT` while inventories reference it.

**Inventory Report form.** Created once with `form_create(title, fields_json, idempotency_key="form-inventory-report")`; the exact `fields_json` is in `SKILL.md` and `example-workflow.md` (byte-identical) and was validated against ZenSched's form validator (`_validate_fields`; 11 fields, well under the 80-field cap). Every field, including the `rooms` section, carries an explicit `identifier` so submission `data` keys are stable (`rooms_covered`, `cleanliness`, `room_photos`, `meters_read`, `meter_readings`, `keys_checked`, `damage_found`, `damage_notes`, `damage_photos`, `notes_for_agent`). Option keys are derived by ZenSched from the labels (lowercase, non-alphanumerics → `_`, truncated at 30 characters); every label in this form produces a key shorter than 30 characters (`not_applicable` is 14). One `show_if` references `meters_read` with value `yes` and two reference `damage_found` with value `yes`. Those follow-ups work on the phone. Each photo object can carry `capture_lat` / `capture_lng` / `capture_ts` / `capture_source` (and `capture_accuracy_m` when coords came from device GPS). Attaching is `form_assign(form_id, event_id=...)` per inventory, which resolves event → brand → policy and installs the form on the phone for the subsequent `shift_create`.

**Idempotency keys.** Deterministic, derived from local IDs so a retried or re-run agent turn cannot duplicate:

- location: `loc-property-{property_id}`
- event: `event-invy-{inventory_id}`
- shift: `shift-invy-{inventory_id}` (a clerk swap on the same inventory appends `-2`)
- assignment: `assign-report-{event_id}`
- cancel: `cancel-shift-{shift_id}`
- worker: `worker-{email}`
- form: `form-inventory-report`

ZenSched caches idempotent responses for 24 hours. The views emit `loc_idempotency_key`, `event_idempotency_key`, and `shift_idempotency_key` per row.

**Timestamps.** `shift_create` / `shift_update` take `start` and `end` in ISO 8601 with an explicit offset. Always use the business's local offset from `settings.timezone_offset` (e.g. `2026-09-10T10:00:00+01:00`), never `Z`. The views build these strings so the agent does not have to. `checked_in_at` / `checked_out_at` keep the offset ZenSched returns.

**Metered reads.** `form_submissions(form_id, event_id=...)` is the natural per-inventory read because every inventory has its own event; `form_export` covers a week or a single event in one call and is what "export the check-out for 12 Oak Lane" uses. Both bill $0.05 per submission ($0.15 with a photo), once per submission ever. `shift_list`, `shift_status`, `event_get`, and `timesheet_export(mode="hours"|"raw")` are free.

**Check-in policy.** The radius is enforced by `policy_update(0, '{"checkin_radius_m": N}')`, not by `location_create(checkin_radius_m=...)`, which is informational; with geofencing on, values under 100 m are raised to about 91 m. `checkin_slack_min` matters for clerks who arrive early. The kit's example sets 150 m / 20 min / 15 min check-out reminder.

**SQLite MCP server.** `mcp.json.example` uses [`easy-sqlite-mcp`](https://github.com/chenkumi/easy-sqlite-mcp) (Node, `better-sqlite3`, `SQLITE_PATH` env var). Its `sqlite_execute` calls `prepare()`, so it accepts **one statement per call**; `schema.sql` is written so every statement stands alone and is idempotent. `payouts_due` uses a window function (`SUM() OVER`), which needs SQLite ≥ 3.25 (2018); `better-sqlite3` bundles a current SQLite. Any SQLite MCP server with read and write tools will work; adjust the tool names in `SKILL.md`.

**Schema test.** The schema was verified by splitting the file into its 45 statements with `sqlite3.complete_statement` and executing each individually (as the MCP server does) twice for idempotency (seed rows not duplicated), then exercising: all 7 tables, 9 views, and 8 triggers present; every view on an empty database; `properties.normalized_address`, `clerks.zensched_worker_id`, `inventories.zensched_shift_id`, and `payouts.inventory_id` `UNIQUE`; the `number_inventory` trigger (`INVY-YYYY-0001`, explicit number kept); `fill_inventory_defaults` (duration from settings, clerk from `default_clerk_id`, check-in / check-out / mid-term fees from the matching client default, travel from `default_travel_fee`, else 0, explicit fee kept); `inventories_today` / `inventories_upcoming` (`start_iso` / `end_iso` with offset for `HH:MM` and `HH:MM:SS` inputs and 90/60-minute durations, `needs_location` when the property has no location id, `needs_shift`, the three idempotency keys, `zensched_event_title` / `zensched_location_name` equal to type + street with no tenant name, worker id from the default clerk, 7-day window bounds, cancelled excluded); `updated_at` triggers on inventories and clients; `needs_location` (includes unpinned properties with open work, drops a property after `zensched_location_id` is set); `reports_to_export` (empty without `report_dc_id`, includes a completed check-out with damage, empty after `exported_at`); `billable_inventories` for completed (170 = inventory + travel + other), no-show (travel only), cancelled (`other_fee` only), and confirmed (0); `receivables_by_client` totals, counts, and the drop-off after invoicing; invoice numbering, total, `invoices_outstanding` aging buckets `90+` / `60` / `30` / `current` with `days_past_due` and paid excluded; `payouts_missing`; `payouts_due` math for flat (55) and percent (70% of 95 = 66.50), `needs_amount` for a clerk without a split, owner exclusion, paid rows dropping out; `rescheduled_from`; every `CHECK` (client type, inventory type, status, `scheduled_start` format with offset and `Z` rejected, duration range, payout type, country); foreign keys rejecting an unknown client or property, `RESTRICT` on properties, `SET NULL` on clerk delete, and the full cascade on client delete. 100 checks, all passing.

## Support

- ZenSched docs: <https://www.zensched.com/docs/>
- Tool reference: <https://www.zensched.com/docs/tools/>
- Feedback: ask your AI to call `feedback_submit` (categories: `bug`, `friction`, `missing_capability`, `docs`, `billing`, `feature`, `other`)

## License

MIT. See `LICENSE`.
