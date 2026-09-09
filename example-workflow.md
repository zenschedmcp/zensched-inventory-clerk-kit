# Example Workflow: What the AI Does Behind Each Request

This shows the exact tool calls the agent makes for a first week of operation, following `SKILL.md`. The owner only types the quoted lines; everything else is the agent's work. Assumes setup from `QUICKSTART.md` is complete (both MCP servers configured, `schema.sql` loaded, `SKILL.md` given as instructions).

The business is **Thames Inventory Co**, a solo inventory clerk (Priya Shah) in London, British Summer Time (`+01:00` in September). IDs and responses are illustrative. ZenSched IDs are integers. Watch what does **not** cross to ZenSched: the tenants' names and phone numbers, the key-safe codes. ZenSched sees `Check-out 12 Oak Lane`, a street address, and a photo Inventory Report.

## Session start (every session)

```
sqlite_execute: PRAGMA foreign_keys = ON;
sqlite_query:   SELECT key, value FROM settings;
  → business_name = My Inventory Clerk, timezone_offset = +00:00, country = UK,
    default_clerk_id = NULL, default_appointment_minutes = 90,
    default_travel_buffer_minutes = 30, invoice_due_days = 30, invoice_prefix = INV,
    report_form_id = NULL
sqlite_query:   SELECT * FROM reports_to_export;     → (none)
sqlite_query:   SELECT * FROM inventories_today;     → (none)
```

## "We're Thames Inventory Co in London, British Summer Time. It's just me, Priya Shah, priya@thamesinventory.example, 020 7946 0100. Set me up."

```
sqlite_execute: UPDATE settings SET value = 'Thames Inventory Co' WHERE key = 'business_name';
sqlite_execute: UPDATE settings SET value = '+01:00' WHERE key = 'timezone_offset';
sqlite_execute: UPDATE settings SET value = 'UK' WHERE key = 'country';
```

Agent (first metered call this session, rule 11):

> Saved. Since you're the clerk on the phone, I need to invite you to ZenSched as a worker so your appointments show up in the app; that's a one-time $0.25. If your account isn't funded yet you'll get a prompt for the $5 activation deposit. Go ahead?

Owner: *"yes"*

```
worker_invite:
  email: "priya@thamesinventory.example"
  first_name: "Priya"
  last_name: "Shah"
  idempotency_key: "worker-priya@thamesinventory.example"
  → worker_id: 701, status: "invited", invitation_sent: true
    billing: { meter: "worker_invite", units: 1, price: 0.25 }

sqlite_execute:
  INSERT INTO clerks (clerk_name, email, phone, zensched_worker_id, is_owner)
  VALUES ('Priya Shah', 'priya@thamesinventory.example', '020 7946 0100', 701, 1);
  → lastInsertRowid = 1

sqlite_execute: UPDATE settings SET value = '1' WHERE key = 'default_clerk_id';
```

> You're invited; install the app from the email. Your appointments will land on your own phone. Next, the Inventory Report: it's free to create and every visit comes back with rooms covered, cleanliness, up to eight room photos, meters, keys, a damage flag, and a note for the agent. No signature pad on it, on purpose. Want me to set it up now?

Owner: *"yes"*

```
form_create:
  title: "Inventory Report"
  idempotency_key: "form-inventory-report"
  fields_json: (the JSON below, passed as one string)
```

```json
[
  {"type": "section", "label": "Rooms", "identifier": "rooms", "text": "Photograph each room you cover. Do not write the tenant's name, phone, or any access codes here. Capture location and time are stored with each photo when the phone can read them. They are not burned onto the image."},
  {"type": "multi_select", "label": "Rooms covered", "identifier": "rooms_covered", "required": true,
   "options": ["Hall", "Kitchen", "Living", "Bedroom 1", "Bedroom 2", "Bedroom 3", "Bathroom", "Garden", "Other"]},
  {"type": "select", "label": "Cleanliness", "identifier": "cleanliness", "required": true,
   "options": ["Excellent", "Good", "Fair", "Poor"]},
  {"type": "photo", "label": "Room photos", "identifier": "room_photos", "required": true, "max_images": 8},
  {"type": "select", "label": "Meters read", "identifier": "meters_read", "required": true,
   "options": ["Yes", "No", "Not applicable"]},
  {"type": "textarea", "label": "Meter readings", "identifier": "meter_readings",
   "show_if": {"field": "meters_read", "op": "equals", "value": "yes", "action": "show"}},
  {"type": "select", "label": "Keys checked", "identifier": "keys_checked", "required": true,
   "options": ["Yes", "No"]},
  {"type": "select", "label": "Damage found", "identifier": "damage_found", "required": true,
   "options": ["No", "Yes"]},
  {"type": "textarea", "label": "Damage notes", "identifier": "damage_notes",
   "show_if": {"field": "damage_found", "op": "equals", "value": "yes", "action": "show"}},
  {"type": "photo", "label": "Damage photos", "identifier": "damage_photos", "max_images": 3,
   "show_if": {"field": "damage_found", "op": "equals", "value": "yes", "action": "show"}},
  {"type": "textarea", "label": "Notes for agent", "identifier": "notes_for_agent"}
]
```

```
  → form_id: 501, fields: [ ...11 fields echoed with identifiers... ]

sqlite_execute: UPDATE settings SET value = '501' WHERE key = 'report_form_id';
```

> Inventory Report created. I'll attach it to every appointment automatically. One policy question: you'll usually arrive 10–15 minutes early and mansion-block pins often sit on the road; want me to allow early check-in and set the check-in radius to 150 m?

Owner: *"yes"*

```
policy_update:
  policy_id: 0
  settings_json: "{\"checkin_radius_m\": 150, \"checkin_slack_min\": 20, \"checkout_reminder_min_after\": 15}"
  → policy_id: 0, updated: [ "checkin_radius_m", "checkin_slack_min", "checkout_reminder_min_after" ]
```

## "Northcote Lettings just emailed. Book it."

> *Instruction NCL-8841 — CHECK-OUT — Property: 12 Oak Lane, Clapham, London SW4 1AA — Tenant: James Hale, 07700 900441 — Thu 10 Sep 2026 10:00 — Fee: £120.00 — Key safe 4411 on the right of the porch — Notes: outgoing tenant, deposit held with TDS.*

The agent parses: client Northcote Lettings (letting agent), instruction `NCL-8841`, type check-out, tenant James Hale + phone, address, Thu 10 Sep 10:00, fee 120, key safe. The TDS mention is **not** stored as a filing; this kit does not e-file.

```
sqlite_query: SELECT client_id, payment_terms_days FROM clients WHERE client_name LIKE 'Northcote%';   → (none)

sqlite_execute:
  INSERT INTO clients (client_name, client_type, billing_email, payment_terms_days,
                       default_check_in_fee, default_check_out_fee, default_mid_term_fee, default_travel_fee)
  VALUES ('Northcote Lettings', 'letting_agent', 'ap@northcote.example', 30, 95, 120, 75, 40);
  → lastInsertRowid = 1
```

> I don't have Northcote Lettings as a client yet. I've added them as a letting agent with £95 check-in / £120 check-out / £75 mid-term defaults; I've assumed net 30 and a £40 travel / wasted-journey fee, which is typical. Tell me if their terms differ.

```
sqlite_query: SELECT property_id, zensched_location_id, street_name FROM properties
              WHERE normalized_address = '12 oak lane clapham london sw4 1aa';   → (none)

sqlite_execute:
  INSERT INTO properties (normalized_address, address, city, region, postcode, country,
                          street_name, property_label, access_notes, is_repeat_site)
  VALUES ('12 oak lane clapham london sw4 1aa', '12 Oak Lane', 'London', 'Lambeth', 'SW4 1AA', 'UK',
          '12 Oak Lane', '12 Oak Lane', 'Key safe 4411, right of porch.', 1);
  → lastInsertRowid = 1

sqlite_execute:
  INSERT INTO inventories (client_id, client_ref, inventory_type, tenant_name, tenant_phone, property_id,
                           scheduled_start, status, inventory_fee)
  VALUES (1, 'NCL-8841', 'check_out', 'James Hale', '07700 900441', 1,
          '2026-09-10T10:00', 'confirmed', 120);
  → lastInsertRowid = 1
  (triggers fill: inventory_no INVY-2026-0001, duration_minutes 90, clerk_id 1, travel_fee 40, other_fee 0)

sqlite_query:
  SELECT inventory_no, start_iso, end_iso, zensched_location_name, zensched_event_title, street_address,
         needs_location, zensched_location_id, zensched_worker_id,
         loc_idempotency_key, event_idempotency_key, shift_idempotency_key
  FROM inventories_upcoming WHERE inventory_id = 1;
  → INVY-2026-0001 | 2026-09-10T10:00:00+01:00 | 2026-09-10T11:30:00+01:00
    | Check-out 12 Oak Lane | Check-out 12 Oak Lane
    | 12 Oak Lane, London SW4 1AA | needs_location 1 | NULL | worker 701
    | loc-property-1 | event-invy-1 | shift-invy-1
```

> Putting this on ZenSched costs $0.03 to geocode the address; each inventory then costs about $0.35 in GPS check-in/out and reading the photo report (**~$0.38** total for a new address). OK to proceed for this and future inventories?

Owner: *"yes"*

```
location_create:
  name: "Check-out 12 Oak Lane"
  street_address: "12 Oak Lane, London SW4 1AA"
  checkin_radius_m: 100
  idempotency_key: "loc-property-1"
  → location_id: 9201, lat: 51.4618, lng: -0.1382, pin_quality: "street",
    radius_note: "Check-in radius is enforced by the talent policy ...",
    billing: { meter: "geocode", units: 1, price: 0.03 }

sqlite_execute: UPDATE properties SET zensched_location_id = 9201 WHERE property_id = 1;

event_create:
  location_id: 9201
  title: "Check-out 12 Oak Lane"
  start_date: "2026-09-10"
  end_date:   "2026-09-10"
  idempotency_key: "event-invy-1"
  → event_id: 7301

form_assign:
  form_id: 501
  event_id: 7301
  idempotency_key: "assign-report-7301"
  → status: "assigned", form_id: 501, event_id: 7301, policy_id: 0

shift_create:
  event_id: 7301
  worker_id: 701
  start: "2026-09-10T10:00:00+01:00"
  end:   "2026-09-10T11:30:00+01:00"
  idempotency_key: "shift-invy-1"
  → shift_id: 89101, status: "scheduled", forms_installed: [501]

sqlite_execute: UPDATE inventories SET zensched_event_id = 7301, zensched_shift_id = 89101 WHERE inventory_id = 1;
```

Nothing about James Hale, his phone, or the key-safe code is in `name`, `title`, or `notes`.

> Booked **INVY-2026-0001**: check-out, Northcote NCL-8841, Thu Sep 10 10:00–11:30 at 12 Oak Lane. £120, net 30. It's on your phone with the Inventory Report attached. James Hale's name and the key-safe code are only on your computer; ZenSched just sees "Check-out 12 Oak Lane".

## "Northcote again: check-in Friday 11 Sep 14:00 at 44 Merton Road, Wandsworth, SW18 5JT. Incoming tenant Aisha Rahman. Instruction NCL-8847. £95. Keys with the neighbour at 46, ring twice."

Same pattern. The agent does not re-ask about the $0.03 (owner already approved geocoding this session).

```
sqlite_query:   SELECT property_id, zensched_location_id FROM properties
                WHERE normalized_address = '44 merton road wandsworth london sw18 5jt';   → (none)
sqlite_execute: INSERT INTO properties (normalized_address, address, city, region, postcode, country,
                                        street_name, property_label, access_notes, is_repeat_site)
                VALUES ('44 merton road wandsworth london sw18 5jt', '44 Merton Road', 'London', 'Wandsworth',
                        'SW18 5JT', 'UK', '44 Merton Road', '44 Merton Road',
                        'Keys with neighbour at 46. Ring twice.', 1);   → 2
sqlite_execute: INSERT INTO inventories (client_id, client_ref, inventory_type, tenant_name, property_id,
                                         scheduled_start, status, inventory_fee)
                VALUES (1, 'NCL-8847', 'check_in', 'Aisha Rahman', 2,
                        '2026-09-11T14:00', 'confirmed', 95);   → 2
                (trigger: INVY-2026-0002, 90 min, clerk 1, travel_fee 40)

location_create: name "Check-in 44 Merton Road", street_address "44 Merton Road, London SW18 5JT",
                 checkin_radius_m 100, idempotency_key "loc-property-2"
  → location_id 9202, pin_quality "street"
sqlite_execute:  UPDATE properties SET zensched_location_id = 9202 WHERE property_id = 2;
event_create:    location_id 9202, title "Check-in 44 Merton Road", start_date "2026-09-11",
                 end_date "2026-09-11", idempotency_key "event-invy-2"  → event_id 7302
form_assign:     form_id 501, event_id 7302, idempotency_key "assign-report-7302"
shift_create:    event_id 7302, worker_id 701, start "2026-09-11T14:00:00+01:00",
                 end "2026-09-11T15:30:00+01:00", idempotency_key "shift-invy-2"  → shift_id 89102
sqlite_execute:  UPDATE inventories SET zensched_event_id = 7302, zensched_shift_id = 89102 WHERE inventory_id = 2;
```

> Booked **INVY-2026-0002**: check-in for Northcote, NCL-8847, Fri Sep 11 14:00–15:30 at 44 Merton Road. £95, net 30. Added the property as a repeat site, so the check-out there later will reuse the pin. Aisha's name and "keys with neighbour" stay on your computer.

## Thursday: the check-out, with damage

09:52, outside 12 Oak Lane, in the ZenSched app: Priya taps **Check in** (GPS: 12 m from the pin, verified, $0.10). Walks hall, kitchen, living, two bedrooms, bathroom, garden. Hall wall is scuffed behind the door, plaster through the paint. Opens **Inventory Report**: Rooms covered = Hall, Kitchen, Living, Bedroom 1, Bedroom 2, Bathroom, Garden; Cleanliness = Fair; eight room photos; Meters read = Yes; Meter readings = "Elec 44211, Gas 1098, Water 3321"; Keys checked = Yes; Damage found = Yes; Damage notes = "Scuffed plaster on hall wall behind front door, approx 20 cm, down to plaster"; two damage photos; Notes for agent = "Outgoing tenant present. Garden furniture left, photographed." Submits. **Check out** 11:18 ($0.10).

## "Oak Lane is done. Close it out."

```
shift_list:
  date_from: "2026-09-10"
  date_to:   "2026-09-10"
  status:    "checked_out"
  → shifts: [ { shift_id: 89101, event_id: 7301, worker_id: 701, status: "checked_out" } ]
(free)

shift_status: shift_id 89101
  → status "checked_out", actual_in "2026-09-10T09:52:08+01:00", actual_out "2026-09-10T11:18:22+01:00",
    punches: [ { type: "in", gps_verified: true, distance_from_site_m: 12 },
               { type: "out", gps_verified: true, distance_from_site_m: 9 } ]
(free)
```

> Reading the Inventory Report for INVY-2026-0001 costs $0.15 because it has photos. It bills once; after this I answer from the local record. OK?

Owner: *"go"*

```
form_submissions:
  form_id: 501
  event_id: 7301
  limit: 5
  → submissions: [
      { submission_id: 3601, worker_id: 701, event_id: 7301, submitted_at: "2026-09-10 11:16:40",
        data: { rooms_covered: ["hall", "kitchen", "living", "bedroom_1", "bedroom_2", "bathroom", "garden"],
                cleanliness: "fair", meters_read: "yes",
                meter_readings: "Elec 44211, Gas 1098, Water 3321", keys_checked: "yes",
                damage_found: "yes",
                damage_notes: "Scuffed plaster on hall wall behind front door, approx 20 cm, down to plaster",
                notes_for_agent: "Outgoing tenant present. Garden furniture left, photographed." },
        media: [ { field: "room_photos", cdn_url: "https://cdn.zensched.com/m/.../r1.jpg" },
                 ... 8 room photos ...,
                 { field: "damage_photos", cdn_url: "https://cdn.zensched.com/m/.../d1.jpg" },
                 { field: "damage_photos", cdn_url: "https://cdn.zensched.com/m/.../d2.jpg" } ] }
    ], count: 1, billing: { meter: "form_media", units: 1, price: 0.15 }

sqlite_execute:
  UPDATE inventories
  SET status = 'completed',
      rooms_covered = '["hall","kitchen","living","bedroom_1","bedroom_2","bathroom","garden"]',
      cleanliness = 'fair', meters_read = 'yes',
      meter_readings = 'Elec 44211, Gas 1098, Water 3321', keys_checked = 'yes',
      damage_found = 1,
      damage_notes = 'Scuffed plaster on hall wall behind front door, approx 20 cm, down to plaster',
      photo_count = 10, report_dc_id = 3601,
      checked_in_at = '2026-09-10T09:52:08+01:00', checked_out_at = '2026-09-10T11:18:22+01:00',
      gps_verified = 1, checkin_distance_m = 12,
      notes = 'Outgoing tenant present. Garden furniture left, photographed.'
  WHERE inventory_id = 1;
```

> INVY-2026-0001 closed. Check-out at 12 Oak Lane, GPS-verified 09:52–11:18 (12 m from the pin), cleanliness Fair, **damage flagged** — scuffed plaster on the hall wall, two photos. Meters read, keys checked. £120 is now receivable from Northcote, net 30. It is on the export list until you ask for the dispute pack.

## "Export the check-out for 12 Oak Lane."

```
sqlite_query:
  SELECT i.inventory_id, i.inventory_no, i.zensched_event_id, i.zensched_shift_id, i.report_dc_id,
         i.checked_in_at, i.checked_out_at, i.gps_verified, i.checkin_distance_m,
         i.rooms_covered, i.cleanliness, i.meter_readings, i.keys_checked,
         i.damage_found, i.damage_notes, i.photo_count, i.client_ref,
         p.street_name, p.address || ', ' || p.city || ' ' || p.postcode AS street_address
  FROM inventories i JOIN properties p ON p.property_id = i.property_id
  WHERE p.street_name LIKE '%Oak Lane%' AND i.inventory_type = 'check_out';
  → INVY-2026-0001 | event 7301 | shift 89101 | dc 3601 | in 09:52 | out 11:18 | gps 1 | 12 m
    | damage 1 | NCL-8841 | 12 Oak Lane, London SW4 1AA
```

The submission was already billed this session; a replay is free.

```
form_export:
  form_id:  501
  event_id: 7301
  format:   "json"
  → submissions: [ { submission_id: 3601, data: { ...same as above... },
                     media: [ ...8 room_photos..., ...2 damage_photos... ] } ]
    billing: { meter: "form_media", units: 1, price: 0.00, note: "already billed" }

shift_status: shift_id 89101
  → actual_in "2026-09-10T09:52:08+01:00", actual_out "2026-09-10T11:18:22+01:00",
    punches: [ { type: "in", gps_verified: true, distance_from_site_m: 12 },
               { type: "out", gps_verified: true, distance_from_site_m: 9 } ]
(free)

sqlite_execute: UPDATE inventories SET exported_at = datetime('now', 'localtime') WHERE inventory_id = 1;
```

> Dispute pack for **INVY-2026-0001** (Northcote NCL-8841) — paste this into your own report or email it to the agent. This is not a TDS filing and not a branded PDF. Pixels are **unmarked**. Punch GPS is the geofence. Each photo's `capture_*` is where that picture was taken, when the phone had it.
>
> ```
> Thames Inventory Co — Inventory dispute pack
> INVY-2026-0001   Check-out   12 Oak Lane, London SW4 1AA
> Client ref: NCL-8841    Date: Thu 10 Sep 2026
> Scheduled: 10:00–11:30 BST (+01:00)
> GPS in:  09:52:08 +01:00   verified   12 m from pin
> GPS out: 11:18:22 +01:00   verified    9 m from pin
>
> Rooms: Hall, Kitchen, Living, Bedroom 1, Bedroom 2, Bathroom, Garden
> Cleanliness: Fair
> Meters: Elec 44211, Gas 1098, Water 3321
> Keys checked: Yes
> Damage: Yes — Scuffed plaster on hall wall behind front door, approx 20 cm, down to plaster
>
> Room photos:
>   https://cdn.zensched.com/m/.../r1.jpg
>   ... (8)
> Damage photos:
>   https://cdn.zensched.com/m/.../d1.jpg
>   https://cdn.zensched.com/m/.../d2.jpg
>
> Notes for agent: Outgoing tenant present. Garden furniture left, photographed.
> ```

## Friday: the check-in, no damage

Priya checks in at 44 Merton Road at 13:55 (GPS-verified, 18 m), walks the empty flat, Inventory Report: rooms Hall / Kitchen / Living / Bedroom 1 / Bathroom; Cleanliness = Good; six room photos; Meters read = Yes ("Elec 1204, Gas 88, Water 441"); Keys checked = Yes; Damage found = No; Notes = "Clean incoming. Stopcock labelled under kitchen sink." Checks out 15:12.

## "Close out Merton Road."

```
shift_list: date_from "2026-09-11", date_to "2026-09-11", status "checked_out"
  → [ { shift_id: 89102, event_id: 7302 } ]
shift_status: 89102 → in 13:55:10+01:00, out 15:12:04+01:00, gps in 18 m verified
form_submissions: form_id 501, event_id 7302, limit 5   ($0.15)
  → [ { submission_id: 3602, data: { rooms_covered: ["hall","kitchen","living","bedroom_1","bathroom"],
        cleanliness: "good", meters_read: "yes", meter_readings: "Elec 1204, Gas 88, Water 441",
        keys_checked: "yes", damage_found: "no",
        notes_for_agent: "Clean incoming. Stopcock labelled under kitchen sink." },
        media: [ ...6 room_photos... ] } ]

sqlite_execute:
  UPDATE inventories
  SET status = 'completed',
      rooms_covered = '["hall","kitchen","living","bedroom_1","bathroom"]',
      cleanliness = 'good', meters_read = 'yes',
      meter_readings = 'Elec 1204, Gas 88, Water 441', keys_checked = 'yes',
      damage_found = 0, photo_count = 6, report_dc_id = 3602,
      checked_in_at = '2026-09-11T13:55:10+01:00', checked_out_at = '2026-09-11T15:12:04+01:00',
      gps_verified = 1, checkin_distance_m = 18,
      notes = 'Clean incoming. Stopcock labelled under kitchen sink.'
  WHERE inventory_id = 2;
```

> INVY-2026-0002 closed. Check-in at 44 Merton Road, GPS-verified 13:55–15:12, cleanliness Good, no damage. £95 receivable from Northcote. Say the word if you want that report exported too.

## "Invoice Northcote."

```
sqlite_query: SELECT * FROM receivables_by_client;
  → Northcote Lettings | letting_agent | ap@northcote.example | net 30
    | 2 inventories (2 completed) | 215.00 | 2026-09-10 .. 2026-09-11

sqlite_execute:
  INSERT INTO invoices (client_id, invoice_date, due_date, total_amount, line_items)
  SELECT b.client_id, date('now', 'localtime'),
         date('now', 'localtime', '+' || (SELECT payment_terms_days FROM clients WHERE client_id = 1) || ' days'),
         SUM(b.billable_total),
         json_group_array(json_object('inventory_no', b.inventory_no, 'date', b.inventory_date,
                                      'type', b.inventory_type, 'status', b.status,
                                      'client_ref', b.client_ref, 'inventory_fee', b.inventory_fee,
                                      'travel_fee', b.travel_fee, 'other_fee', b.other_fee,
                                      'billable', b.billable_total, 'shift_id', b.zensched_shift_id))
  FROM billable_inventories b WHERE b.invoiced = 0 AND b.client_id = 1 AND b.billable_total > 0
  GROUP BY b.client_id;
sqlite_execute: UPDATE inventories SET invoiced = 1 WHERE invoiced = 0 AND client_id = 1
                AND status IN ('completed', 'no_show', 'cancelled');
sqlite_query:   SELECT invoice_number, invoice_date, due_date, total_amount FROM invoices
                WHERE invoice_id = last_insert_rowid();
  → INV-2026-0001 | 2026-09-11 | 2026-10-11 | 215.00
```

> Here's the Northcote invoice, ready to paste into an email. No tenant names on it; their instruction refs identify the files. VAT is for your own accounts if you are registered.
>
> ```
> Thames Inventory Co
> Invoice INV-2026-0001
> To: Northcote Lettings (ap@northcote.example)
> Date: 11 Sep 2026    Due: 11 Oct 2026 (net 30)
>
>   INVY-2026-0001  Thu 10 Sep  Check-out  NCL-8841  12 Oak Lane     £120.00
>   INVY-2026-0002  Fri 11 Sep  Check-in   NCL-8847  44 Merton Road  £ 95.00
>
> Total due: £215.00
> ```
>
> Both visits were GPS-verified; photo reports available on request (Oak Lane already exported with a damage flag). Say "sent" when you've emailed it.

```
sqlite_query: SELECT * FROM invoices_outstanding;
  → INV-2026-0001 | Northcote Lettings | due 2026-10-11 | 215.00 | days_past_due -30 | current
```

> Outstanding: £215, current. I'll flag it after 11 October if they haven't paid.

## Summary of who stored what

| Thing | Where | Why |
|---|---|---|
| Tenants' names and phone numbers (James Hale, Aisha Rahman) | SQLite **only** (`inventories.tenant_name`, `tenant_phone`) | Tenant PII never reaches ZenSched |
| Key-safe 4411; "keys with neighbour at 46" | SQLite **only** (`properties.access_notes`) | Access codes never leave the computer |
| TDS / deposit-scheme details | **Nowhere in this kit** | Not an e-file tool; the agent holds the scheme file |
| Branded PDF inventory report | **Nowhere in this kit** | Not a report generator; export is plain text + photo links |
| Northcote Lettings: terms, billing email, default fees | SQLite (`clients`) | Billing; ZenSched does not model clients or fees |
| Each address, normalized, with its ZenSched location id | SQLite (`properties`) | De-dup cache; check-out of a known flat skips the $0.03 geocode and keeps the pin |
| `Check-out 12 Oak Lane`, `Check-in 44 Merton Road` and their street addresses and GPS pins | ZenSched (ID in `properties`) | Needed for geofenced check-in; labels carry no tenant identity |
| One single-day event per inventory | ZenSched (ID in `inventories`) | Shifts hang off events; title is type + street only |
| One shift per inventory (the 90-minute window) | ZenSched (ID in `inventories`) | Live schedule and push notification; never copied |
| Priya as a ZenSched worker | ZenSched (ID in `clerks`, `is_owner = 1`) | Solo mode: the owner is the clerk on the phone |
| GPS punches, arrival time, distance from pin | ZenSched (originals); stamps copied once to `inventories.checked_in_at` / `checked_out_at` / `gps_verified` / `checkin_distance_m` | Proof of arrival and the dispute-pack times, answered from SQLite afterwards |
| The Inventory Report form | ZenSched (ID in `settings`) | Installed on the phone per shift; no signature field |
| Two Inventory Report submissions and their photos | ZenSched (originals); summary, damage flag, photo count, `report_dc_id` in `inventories` | Read once (metered $0.15); `form_export` replay free for the Oak Lane pack |
| Photo pixels (no burned-in date/time/GPS stamp) | ZenSched CDN | JPEG is unmarked; `capture_lat` / `capture_lng` / `capture_ts` sit on the image record when the phone had them |
| Check-in policy (150 m radius, 20 min early check-in, 15 min check-out reminder) | ZenSched (policy 0) | Radius is enforced by the policy, not per location |
| Fees per inventory, billable totals, INV-2026-0001, aging | SQLite (`inventories`, `billable_inventories`, `invoices`, `invoices_outstanding`) | Receivables from the letting agent |
| Sub payouts | SQLite (`payouts`) | Not used this week (solo); agency mode only |
