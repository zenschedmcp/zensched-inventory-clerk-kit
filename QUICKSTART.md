# Quickstart

Setup is about 15 minutes, once. After that everything is plain English to your AI. Each step below tells you what to do and, where relevant, exactly what to type to the AI.

You need: Claude Desktop, Cursor, or Muse Code, and [Node.js LTS](https://nodejs.org/) installed. Nothing else.

Before you start, read the "This is not a TDS/DPS e-file tool" section of `README.md`. Short version: this kit puts each inventory on your phone, GPS-verifies arrival at the property, and collects a photo report; it does not file with a deposit scheme, does not generate a branded PDF, and does not burn a GPS stamp onto the JPEG. Capture location and time are stored with each photo when the phone can read them. Tenant names and access codes stay on your computer; ZenSched only ever sees a type+street label (`Check-out 12 Oak Lane`), an address, and the Inventory Report.

## 1. Make a data folder

Create a folder such as `C:\Users\YourName\inventory-ops` (Windows) or `/Users/yourname/inventory-ops` (Mac). Note the full path. It will hold tenant names and key-safe codes, so keep it on an encrypted, backed-up disk.

## 2. Add the two tools to your AI's config

Open the config file:

- **Claude Desktop, Windows:** `%APPDATA%\Claude\claude_desktop_config.json`
- **Claude Desktop, Mac:** `~/Library/Application Support/Claude/claude_desktop_config.json`
- **Cursor:** Settings → MCP → Add new global MCP server

Paste this in and fix only the `SQLITE_PATH` line to match your folder from step 1:

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

- On Windows, double every backslash: `"C:\\Users\\YourName\\inventory-ops\\inventory-ops.db"`.
- Leave `zsc_your_key_here` as it is. You get the real key in the next step.

Save, then **fully quit and reopen** the AI app.

## 3. Create your ZenSched account

Type to the AI:

> Call zensched_guide, then account_create with org_name "My Inventory Clerk". Show me the zsc_ key.

Copy the key into the config file in place of `zsc_your_key_here`. Save. Quit and reopen the app once more. (You can also ask the AI to call `account_use_key` with the key to continue right away, but update the file anyway so it sticks.)

## 4. Create the database tables

Copy the full contents of `schema.sql` and paste it into the chat with this line above it:

> Create these tables in my inventory-ops database. Run each statement one at a time with the SQLite tool, then list the tables to confirm.

## 5. Give the AI its instructions

Paste `SKILL.md` into the AI as standing instructions (Claude Desktop: a Project's instructions; Cursor: a rule). Then:

> We're Thames Inventory Co in London, British Summer Time. It's just me, Priya Shah, priya@example.com. Set me up.

The AI saves your settings, invites **you** to ZenSched as a worker ($0.25, once; you are the clerk on the phone), and calls `form_create` once (free) to build the Inventory Report you fill in at each property: rooms covered, cleanliness, up to eight room photos, meters, keys, a damage flag with notes and photos, and a note for the agent. No signature pad. It stores the form id so every appointment gets it. Install the app from the invitation email ([Android](https://play.google.com/store/apps/details?id=com.zensched.app) / [iOS App Store](https://apps.apple.com/us/app/zensched/id6800081657)).

Optional but recommended: "Allow check-in 20 minutes early and set the radius to 150 m." Clerks arrive early and often park far from a mansion-block entrance. The radius is a **policy** setting, not per property.

Agency mode: "Add my sub Owen Blake, owen@example.com, I pay him £55 a job" for each clerk you dispatch.

## 6. Book your first inventory

Paste the instruction the agent emailed, then:

> Book it.

Behind the scenes the AI extracts the client, instruction number, type (check-in / check-out / mid-term), tenant, address, time, and fee; adds the client if new (asks for their payment terms); checks whether you have been to that property before, and if not calls `location_create` (geocode, $0.03, may trigger the $5 activation deposit the first time); saves the appointment as `INVY-2026-0001` with the tenant's name and the key-safe code kept local; creates a single-day `event_create` titled `Check-out 12 Oak Lane`, attaches the Inventory Report with `form_assign`, and creates the `shift_create` for the window. You get one line back with the inventory number, the fee, and the cost (~$0.38 at a new address).

## 7. The visit

Your phone shows the appointment. At the door, **Check in** (GPS-verified). Walk the property. Open the **Inventory Report** on the shift: rooms covered, cleanliness, room photos (required, up to 8), meters, keys, damage if any, note for the agent. Submit. **Check out**.

Photos are stored as you took them. Capture location and time travel **with** the upload when the phone can read them (EXIF GPS, or device GPS on a live camera shot). They are **not** burned onto the JPEG. The check-in punch is separate — that is the geofence proof, not the photo's capture point. Gallery picks without EXIF GPS, screenshots, and denied location permission can come back empty.

## 8. Close out and export

> Close out today.

The AI pulls your GPS-verified arrival and departure (free), reads the Inventory Report (metered, so it tells you the cost first, about $0.15 with photos), updates the appointment, and tells you what is now receivable.

> Export the check-out for 12 Oak Lane.

A plain-text dispute pack: GPS in/out, cleanliness, rooms, meters, keys, damage notes, and the photo links. You paste it into *your* report or email it to the agent. This is not a TDS/DPS filing and not a branded PDF.

## 9. Money

> Invoice Northcote Lettings.

A plain-text invoice under their terms with one line per inventory (your number, date, type, their instruction ref, fee breakdown). Nothing about tenants on it.

> Who owes me money?

Open invoices aged current / 30 / 60 / 90+ days past due.

> Northcote paid INV-2026-0001.

Marks it paid.

Agency: "What do I owe Owen?" lists his unpaid jobs and total; "paid Owen" marks them.

## What next

- `README.md` for the full explanation, the TDS / PDF / photo-stamp / privacy boundaries, troubleshooting table, and developer notes
- `example-workflow.md` to see the exact tool calls behind each step above
