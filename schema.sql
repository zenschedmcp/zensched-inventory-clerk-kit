-- ZenSched Tenant-Inventory Clerk Local Database Schema
-- SQLite database for clients (letting agents, landlords, inventory firms),
-- a cache of properties, the clerk roster, one-off check-in / check-out /
-- mid-term inventory appointments, client invoices / receivables, and
-- subcontractor payouts.
-- DO NOT duplicate live schedule data from ZenSched (shifts, punches, timesheets).
--
-- HOW TO LOAD THIS FILE
--   Normal path: paste this whole file into your AI chat and say
--   "Create these tables in my inventory-ops database. Run each statement one at a time."
--   The AI runs each statement through the SQLite MCP tool (sqlite_execute).
--   Most SQLite MCP tools accept ONE statement per call, so every statement
--   below ends with a semicolon and stands alone.
--
--   Alternative (if you have the sqlite3 command-line tool):
--     sqlite3 inventory-ops.db < schema.sql
--
-- Every statement is idempotent (IF NOT EXISTS / INSERT OR IGNORE), so it is
-- safe to run this file again on an existing database.
--
-- THIS IS NOT A TDS / DPS / MYDEPOSITS E-FILE TOOL, AND IT IS NOT A BRANDED
-- PDF INVENTORY REPORT GENERATOR. The kit puts each appointment on the clerk's
-- phone, GPS-verifies arrival at the property, and collects a photo Inventory
-- Report. reports_to_export plus form_export give you the photos and GPS times
-- for a dispute pack you paste into YOUR report or email to the agent. Nothing
-- here files with a tenancy-deposit scheme, and nothing renders a branded PDF.
--
-- PRIVACY: tenant names, tenant phone numbers, and access notes (key-safe
-- codes, alarm codes, "keys with neighbour") live ONLY in this file on your
-- computer: inventories.tenant_name, inventories.tenant_phone,
-- inventories.access_notes, properties.access_notes. ZenSched receives, per
-- inventory, a location label made of the visit type and the street
-- ("Check-out 12 Oak Lane"), the street address for the GPS pin, a matching
-- event title, and the Inventory Report the clerk fills in on the phone.
-- SKILL.md forbids the agent from putting any local-only column into a
-- ZenSched field.
--
-- PHOTOS: ZenSched stores the upload and the GPS punch separately. It does
-- NOT burn a date, time, or GPS stamp onto the image pixels.

-- Foreign keys are OFF by default in SQLite. This must be run once per
-- connection for ON DELETE CASCADE to work. SKILL.md tells the agent to run it
-- at the start of each session.
PRAGMA foreign_keys = ON;

-- Settings: small key/value store so the agent does not have to be re-told the
-- basics every session (timezone, defaults, business name, form id).
CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value TEXT
);

INSERT OR IGNORE INTO settings (key, value) VALUES ('business_name', 'My Inventory Clerk');
INSERT OR IGNORE INTO settings (key, value) VALUES ('timezone_offset', '+00:00');
INSERT OR IGNORE INTO settings (key, value) VALUES ('country', 'UK');
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_clerk_id', NULL);
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_appointment_minutes', '90');
INSERT OR IGNORE INTO settings (key, value) VALUES ('default_travel_buffer_minutes', '30');
INSERT OR IGNORE INTO settings (key, value) VALUES ('invoice_due_days', '30');
INSERT OR IGNORE INTO settings (key, value) VALUES ('invoice_prefix', 'INV');
INSERT OR IGNORE INTO settings (key, value) VALUES ('report_form_id', NULL);

-- Clients: who hires you and who pays you. A high-street or corporate letting
-- agent, a private landlord, or another inventory firm passing overflow.
-- payment_terms_days drives invoice due dates; the default_* fees are what the
-- agent uses when an instruction does not state a fee (a trigger copies the
-- matching fee onto the inventory by type).
CREATE TABLE IF NOT EXISTS clients (
  client_id INTEGER PRIMARY KEY AUTOINCREMENT,
  client_name TEXT NOT NULL,
  client_type TEXT NOT NULL DEFAULT 'letting_agent'
    CHECK (client_type IN ('letting_agent', 'landlord', 'inventory_firm', 'other')),
  contact_name TEXT,                                -- LOCAL ONLY: agent's inventory booker
  contact_phone TEXT,
  billing_email TEXT,
  payment_terms_days INTEGER NOT NULL DEFAULT 30,   -- net 30; landlord / cash = 0
  default_check_in_fee REAL,                        -- £ per completed check-in
  default_check_out_fee REAL,                       -- £ per completed check-out
  default_mid_term_fee REAL,                        -- £ per completed mid-term
  default_travel_fee REAL,                          -- £ wasted-journey / travel
  notes TEXT,
  is_active INTEGER DEFAULT 1,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

-- Properties: a cache of inventory addresses -> ZenSched location ids.
-- The same flat is visited at check-in, mid-term, and check-out, so the pin
-- must survive. normalized_address is the de-dup key: the agent builds it as
-- lowercase(address + city + postcode) with commas, periods, and '#' removed
-- and whitespace collapsed to single spaces (SQLite cannot collapse whitespace,
-- so the agent does it). The agent looks here FIRST and only calls
-- location_create (geocode, $0.03) on a miss. Hand-tuned pins (location_update)
-- therefore survive for mansion blocks and gated developments. street_name
-- (house number + street, no tenant) feeds location and event titles.
-- access_notes is LOCAL ONLY.
CREATE TABLE IF NOT EXISTS properties (
  property_id INTEGER PRIMARY KEY AUTOINCREMENT,
  normalized_address TEXT NOT NULL UNIQUE,
  address TEXT NOT NULL,
  city TEXT,
  region TEXT,                                      -- borough / county
  postcode TEXT,                                    -- UK postcode or IE Eircode
  country TEXT NOT NULL DEFAULT 'UK'
    CHECK (country IN ('UK', 'IE')),
  street_name TEXT,                                 -- '12 Oak Lane' (number + street); used in titles
  property_label TEXT,                              -- street only, e.g. '12 Oak Lane'
  zensched_location_id INTEGER,                     -- from location_create (permanent; one per property)
  access_notes TEXT,                                -- LOCAL ONLY: key safe, alarm, 'keys with neighbour'
  is_repeat_site INTEGER DEFAULT 1,                 -- 1 = expect check-in AND check-out at this address
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

-- Clerks: in solo mode this is one row (you, is_owner = 1) whose
-- zensched_worker_id came from inviting yourself. In agency mode add a row per
-- subcontracted clerk with payout_type/payout_value ('flat' = £ per inventory,
-- 'percent' = % of the billable total).
CREATE TABLE IF NOT EXISTS clerks (
  clerk_id INTEGER PRIMARY KEY AUTOINCREMENT,
  clerk_name TEXT NOT NULL,
  email TEXT,
  phone TEXT,
  zensched_worker_id INTEGER UNIQUE,                -- from worker_invite
  is_owner INTEGER DEFAULT 0,                       -- 1 = the business owner (no payouts)
  payout_type TEXT
    CHECK (payout_type IS NULL OR payout_type IN ('flat', 'percent')),
  payout_value REAL,                                -- £ (flat) or % (percent)
  is_active INTEGER DEFAULT 1,
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now'))
);

-- Inventories: THE driving table. One row per check-in, check-out, or mid-term
-- appointment. Each row maps to exactly one ZenSched event (start_date =
-- end_date = the appointment date) and one shift (the appointment window).
-- There is no recurrence and no 60-day event roll — every event is one day.
--
-- inventory_no is INVY-YYYY-0001 (INV- is reserved for invoices).
--
-- scheduled_start is LOCAL wall-clock time as 'YYYY-MM-DDTHH:MM' or
-- 'YYYY-MM-DDTHH:MM:SS' with NO offset and no 'Z'; the views append
-- settings.timezone_offset to produce start_iso / end_iso for shift_create.
--
-- Fees are per-appointment snapshots. Leave them NULL on insert and the
-- fill_inventory_defaults trigger copies the client's default fee for this
-- inventory_type (else 0). Which fees are billable depends on status; see
-- the billable_inventories view.
--
-- tenant_name, tenant_phone, access_notes are LOCAL ONLY and never reach
-- ZenSched. Report summary columns and GPS stamps are copied from
-- form_submissions / shift_status once, so "export the check-out for 12 Oak
-- Lane" is answered from SQLite after the first metered read.
CREATE TABLE IF NOT EXISTS inventories (
  inventory_id INTEGER PRIMARY KEY AUTOINCREMENT,
  inventory_no TEXT UNIQUE,                         -- 'INVY-2026-0001', filled by trigger if NULL
  client_id INTEGER NOT NULL,
  client_ref TEXT,                                  -- agent's instruction / tenancy / works order
  inventory_type TEXT NOT NULL
    CHECK (inventory_type IN ('check_in', 'check_out', 'mid_term')),
  tenant_name TEXT,                                 -- LOCAL ONLY
  tenant_phone TEXT,                                -- LOCAL ONLY
  property_id INTEGER NOT NULL,
  scheduled_start TEXT NOT NULL                     -- local 'YYYY-MM-DDTHH:MM[:SS]', no offset
    CHECK (scheduled_start GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-2][0-9]:[0-5][0-9]*'
           AND scheduled_start NOT GLOB '*T*[+-]*'
           AND scheduled_start NOT GLOB '*Z'),
  duration_minutes INTEGER                          -- NULL -> settings.default_appointment_minutes
    CHECK (duration_minutes IS NULL OR duration_minutes BETWEEN 15 AND 480),
  clerk_id INTEGER,                                 -- NULL -> settings.default_clerk_id (trigger)
  status TEXT NOT NULL DEFAULT 'confirmed'
    CHECK (status IN ('requested', 'confirmed', 'completed', 'no_show', 'cancelled', 'rescheduled')),
  inventory_fee REAL,                               -- NULL -> client default for this type (trigger)
  travel_fee REAL,                                  -- NULL -> client default_travel_fee (trigger)
  other_fee REAL,                                   -- late-cancel, extra rooms, wait fee, ...
  access_notes TEXT,                                -- LOCAL ONLY: key-safe for this visit
  zensched_event_id INTEGER,                        -- one same-day event per inventory
  zensched_shift_id INTEGER UNIQUE,                 -- one shift per inventory
  report_dc_id INTEGER,                             -- Inventory Report submission_id
  checked_in_at TEXT,                               -- from shift_status (ISO with offset)
  checked_out_at TEXT,
  gps_verified INTEGER,                             -- 1 if the check-in punch was on site
  checkin_distance_m INTEGER,
  rooms_covered TEXT,                               -- JSON array of form option keys
  cleanliness TEXT,                                 -- form option key: excellent / good / fair / poor
  meters_read TEXT,                                 -- yes / no / not_applicable
  meter_readings TEXT,
  keys_checked TEXT,                                -- yes / no
  damage_found INTEGER,                             -- 1 if form damage_found = yes
  damage_notes TEXT,
  photo_count INTEGER,
  notes TEXT,
  invoiced INTEGER DEFAULT 0,
  paid_out INTEGER DEFAULT 0,                       -- 1 = sub payout done (agency mode)
  exported_at TEXT,                                 -- when the dispute / agent pack was produced
  rescheduled_from INTEGER,                         -- previous inventory_id when this row is the reschedule
  created_at TEXT DEFAULT (datetime('now')),
  updated_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (client_id) REFERENCES clients(client_id) ON DELETE CASCADE,
  FOREIGN KEY (property_id) REFERENCES properties(property_id) ON DELETE RESTRICT,
  FOREIGN KEY (clerk_id) REFERENCES clerks(clerk_id) ON DELETE SET NULL,
  FOREIGN KEY (rescheduled_from) REFERENCES inventories(inventory_id) ON DELETE SET NULL
);

-- Invoices: one per client per billing run. invoice_number is filled by trigger
-- if left NULL (INV-YYYY-0001 — different prefix from inventory_no). due_date
-- is invoice_date + the client's payment_terms_days. line_items is a JSON
-- array with one object per inventory so the invoice can be regenerated.
CREATE TABLE IF NOT EXISTS invoices (
  invoice_id INTEGER PRIMARY KEY AUTOINCREMENT,
  client_id INTEGER NOT NULL,
  invoice_number TEXT UNIQUE,                       -- 'INV-2026-0001'
  invoice_date TEXT NOT NULL,
  due_date TEXT,
  total_amount REAL NOT NULL,
  paid INTEGER DEFAULT 0,
  paid_date TEXT,
  sent_date TEXT,
  line_items TEXT,                                  -- JSON array
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (client_id) REFERENCES clients(client_id) ON DELETE CASCADE
);

-- Payouts: what you owe a subcontracted clerk for one inventory (agency
-- mode). One row per inventory. amount is filled by trigger when left NULL:
-- flat -> clerks.payout_value; percent -> billable_total * payout_value / 100.
-- Never insert a payout for the owner row.
CREATE TABLE IF NOT EXISTS payouts (
  payout_id INTEGER PRIMARY KEY AUTOINCREMENT,
  clerk_id INTEGER NOT NULL,
  inventory_id INTEGER NOT NULL UNIQUE,
  amount REAL,                                      -- trigger fills if NULL
  paid INTEGER DEFAULT 0,
  paid_date TEXT,
  notes TEXT,
  created_at TEXT DEFAULT (datetime('now')),
  FOREIGN KEY (clerk_id) REFERENCES clerks(clerk_id) ON DELETE CASCADE,
  FOREIGN KEY (inventory_id) REFERENCES inventories(inventory_id) ON DELETE CASCADE
);

-- Indexes for common queries
CREATE INDEX IF NOT EXISTS idx_properties_location ON properties(zensched_location_id);
CREATE INDEX IF NOT EXISTS idx_inventories_start ON inventories(scheduled_start);
CREATE INDEX IF NOT EXISTS idx_inventories_status_start ON inventories(status, scheduled_start);
CREATE INDEX IF NOT EXISTS idx_inventories_client ON inventories(client_id, invoiced);
CREATE INDEX IF NOT EXISTS idx_inventories_property ON inventories(property_id);
CREATE INDEX IF NOT EXISTS idx_inventories_clerk ON inventories(clerk_id, paid_out);
CREATE INDEX IF NOT EXISTS idx_inventories_event ON inventories(zensched_event_id);
CREATE INDEX IF NOT EXISTS idx_inventories_export ON inventories(status, report_dc_id, exported_at);
CREATE INDEX IF NOT EXISTS idx_invoices_client ON invoices(client_id);
CREATE INDEX IF NOT EXISTS idx_invoices_paid ON invoices(paid, due_date);
CREATE INDEX IF NOT EXISTS idx_payouts_clerk ON payouts(clerk_id, paid);

-- Which fees are billable depends on what happened. This is the single place
-- that rule lives; receivables, invoicing, and payouts all read billable_total
-- from here rather than re-deriving it.
--   completed  -> inventory + travel + other
--   no_show    -> travel_fee only                  (wasted journey)
--   cancelled  -> other_fee only                   (a late-cancel fee the agent puts in other_fee)
--   requested / confirmed / rescheduled -> 0
CREATE VIEW IF NOT EXISTS billable_inventories AS
SELECT
  i.inventory_id,
  i.inventory_no,
  i.client_id,
  i.client_ref,
  i.inventory_type,
  i.status,
  date(i.scheduled_start)                          AS inventory_date,
  i.scheduled_start,
  i.clerk_id,
  i.inventory_fee,
  i.travel_fee,
  i.other_fee,
  CASE i.status
    WHEN 'completed' THEN round(COALESCE(i.inventory_fee, 0) + COALESCE(i.travel_fee, 0) + COALESCE(i.other_fee, 0), 2)
    WHEN 'no_show'   THEN round(COALESCE(i.travel_fee, 0), 2)
    WHEN 'cancelled' THEN round(COALESCE(i.other_fee, 0), 2)
    ELSE 0
  END                                              AS billable_total,
  i.invoiced,
  i.paid_out,
  i.zensched_shift_id,
  i.report_dc_id,
  i.property_id
FROM inventories i;

-- Keep updated_at current
CREATE TRIGGER IF NOT EXISTS update_client_timestamp
AFTER UPDATE ON clients
BEGIN
  UPDATE clients SET updated_at = datetime('now') WHERE client_id = NEW.client_id;
END;

CREATE TRIGGER IF NOT EXISTS update_property_timestamp
AFTER UPDATE ON properties
BEGIN
  UPDATE properties SET updated_at = datetime('now') WHERE property_id = NEW.property_id;
END;

CREATE TRIGGER IF NOT EXISTS update_clerk_timestamp
AFTER UPDATE ON clerks
BEGIN
  UPDATE clerks SET updated_at = datetime('now') WHERE clerk_id = NEW.clerk_id;
END;

CREATE TRIGGER IF NOT EXISTS update_inventory_timestamp
AFTER UPDATE OF client_id, client_ref, inventory_type, tenant_name, tenant_phone,
                property_id, scheduled_start, duration_minutes, clerk_id, status,
                inventory_fee, travel_fee, other_fee, access_notes, zensched_event_id,
                zensched_shift_id, report_dc_id, checked_in_at, checked_out_at,
                gps_verified, checkin_distance_m, rooms_covered, cleanliness,
                meters_read, meter_readings, keys_checked, damage_found, damage_notes,
                photo_count, notes, invoiced, paid_out, exported_at, rescheduled_from
ON inventories
BEGIN
  UPDATE inventories SET updated_at = datetime('now') WHERE inventory_id = NEW.inventory_id;
END;

-- Auto-number inventories: INVY-2026-0001, INVY-2026-0002, ... (year of the
-- appointment, sequence = inventory_id). Do NOT use INV- — that is invoices.
CREATE TRIGGER IF NOT EXISTS number_inventory
AFTER INSERT ON inventories
WHEN NEW.inventory_no IS NULL
BEGIN
  UPDATE inventories
  SET inventory_no = 'INVY-' || strftime('%Y', NEW.scheduled_start) || '-' || printf('%04d', NEW.inventory_id)
  WHERE inventory_id = NEW.inventory_id;
END;

-- Fill defaults the agent left NULL:
--   duration_minutes <- settings.default_appointment_minutes (else 90)
--   clerk_id         <- settings.default_clerk_id (solo mode: you)
--   inventory_fee    <- client's default fee for this inventory_type, else 0
--   travel_fee       <- client's default_travel_fee, else 0
--   other_fee        <- 0
-- Fees are snapshots: changing a client's defaults later never rewrites history.
CREATE TRIGGER IF NOT EXISTS fill_inventory_defaults
AFTER INSERT ON inventories
BEGIN
  UPDATE inventories
  SET duration_minutes = COALESCE(NEW.duration_minutes,
                                  (SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'default_appointment_minutes'),
                                  90),
      clerk_id = COALESCE(NEW.clerk_id,
                          (SELECT CAST(value AS INTEGER) FROM settings WHERE key = 'default_clerk_id' AND value IS NOT NULL)),
      inventory_fee = COALESCE(NEW.inventory_fee,
                               CASE NEW.inventory_type
                                 WHEN 'check_in'  THEN (SELECT default_check_in_fee  FROM clients WHERE client_id = NEW.client_id)
                                 WHEN 'check_out' THEN (SELECT default_check_out_fee FROM clients WHERE client_id = NEW.client_id)
                                 WHEN 'mid_term'  THEN (SELECT default_mid_term_fee  FROM clients WHERE client_id = NEW.client_id)
                               END,
                               0),
      travel_fee = COALESCE(NEW.travel_fee, (SELECT default_travel_fee FROM clients WHERE client_id = NEW.client_id), 0),
      other_fee  = COALESCE(NEW.other_fee, 0)
  WHERE inventory_id = NEW.inventory_id;
END;

-- Auto-number invoices: INV-2026-0001, INV-2026-0002, ...
CREATE TRIGGER IF NOT EXISTS number_invoice
AFTER INSERT ON invoices
WHEN NEW.invoice_number IS NULL
BEGIN
  UPDATE invoices
  SET invoice_number = (SELECT COALESCE(value, 'INV') FROM settings WHERE key = 'invoice_prefix')
                       || '-' || strftime('%Y', NEW.invoice_date)
                       || '-' || printf('%04d', NEW.invoice_id)
  WHERE invoice_id = NEW.invoice_id;
END;

-- Payout amount from the clerk's split when the agent leaves it NULL.
-- flat    -> payout_value
-- percent -> billable_total * payout_value / 100, rounded to pence
-- If the clerk has no payout_type the amount stays NULL and payouts_due flags it.
CREATE TRIGGER IF NOT EXISTS fill_payout_amount
AFTER INSERT ON payouts
WHEN NEW.amount IS NULL
BEGIN
  UPDATE payouts
  SET amount = (SELECT CASE c.payout_type
                         WHEN 'flat'    THEN c.payout_value
                         WHEN 'percent' THEN round(b.billable_total * c.payout_value / 100.0, 2)
                       END
                FROM clerks c
                JOIN billable_inventories b ON b.inventory_id = NEW.inventory_id
                WHERE c.clerk_id = NEW.clerk_id)
  WHERE payout_id = NEW.payout_id;
END;

-- Today's inventories (local date of the computer running the database),
-- open statuses only. One row = one appointment to work. start_iso / end_iso
-- carry settings.timezone_offset and are ready for shift_create. The three
-- idempotency keys and the ZenSched names are ready too.
--   needs_location = 1 -> the property has no ZenSched location yet
--   needs_shift    = 1 -> the inventory has no ZenSched shift yet
-- zensched_location_name / zensched_event_title are type + street
-- ("Check-out 12 Oak Lane") with no tenant name.
CREATE VIEW IF NOT EXISTS inventories_today AS
SELECT
  i.inventory_id,
  i.inventory_no,
  i.status,
  i.inventory_type,
  i.scheduled_start,
  i.duration_minutes,
  strftime('%Y-%m-%dT%H:%M:%S', i.scheduled_start)
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                 AS start_iso,
  strftime('%Y-%m-%dT%H:%M:%S', datetime(i.scheduled_start, '+' || i.duration_minutes || ' minutes'))
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                 AS end_iso,
  c.client_id,
  c.client_name,
  c.client_type,
  i.client_ref,
  i.tenant_name,
  i.tenant_phone,
  p.property_id,
  p.address,
  p.city,
  p.region,
  p.postcode,
  p.country,
  p.address || COALESCE(', ' || p.city, '') || COALESCE(' ' || p.postcode, '')     AS street_address,
  CASE i.inventory_type
    WHEN 'check_in'  THEN 'Check-in '
    WHEN 'check_out' THEN 'Check-out '
    WHEN 'mid_term'  THEN 'Mid-term '
    ELSE 'Inventory '
  END || COALESCE(p.street_name, p.property_label, p.address)                      AS zensched_location_name,
  CASE i.inventory_type
    WHEN 'check_in'  THEN 'Check-in '
    WHEN 'check_out' THEN 'Check-out '
    WHEN 'mid_term'  THEN 'Mid-term '
    ELSE 'Inventory '
  END || COALESCE(p.street_name, p.property_label, p.address)                      AS zensched_event_title,
  p.access_notes                                                                  AS property_access_notes,
  i.access_notes,
  p.is_repeat_site,
  p.zensched_location_id,
  CASE WHEN p.zensched_location_id IS NULL THEN 1 ELSE 0 END                      AS needs_location,
  i.zensched_event_id,
  i.zensched_shift_id,
  CASE WHEN i.zensched_shift_id IS NULL THEN 1 ELSE 0 END                         AS needs_shift,
  i.clerk_id,
  k.clerk_name,
  k.zensched_worker_id,
  i.inventory_fee,
  i.travel_fee,
  i.notes,
  'loc-property-' || p.property_id                                                AS loc_idempotency_key,
  'event-invy-' || i.inventory_id                                                 AS event_idempotency_key,
  'shift-invy-' || i.inventory_id                                                 AS shift_idempotency_key
FROM inventories i
JOIN clients c ON c.client_id = i.client_id
JOIN properties p ON p.property_id = i.property_id
LEFT JOIN clerks k ON k.clerk_id = i.clerk_id
WHERE i.status IN ('requested', 'confirmed')
  AND date(i.scheduled_start) = date('now', 'localtime')
ORDER BY i.scheduled_start;

-- Same columns, next 7 days (today through today + 6).
CREATE VIEW IF NOT EXISTS inventories_upcoming AS
SELECT
  i.inventory_id,
  i.inventory_no,
  i.status,
  i.inventory_type,
  i.scheduled_start,
  i.duration_minutes,
  strftime('%Y-%m-%dT%H:%M:%S', i.scheduled_start)
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                 AS start_iso,
  strftime('%Y-%m-%dT%H:%M:%S', datetime(i.scheduled_start, '+' || i.duration_minutes || ' minutes'))
    || (SELECT value FROM settings WHERE key = 'timezone_offset')                 AS end_iso,
  c.client_id,
  c.client_name,
  c.client_type,
  i.client_ref,
  i.tenant_name,
  i.tenant_phone,
  p.property_id,
  p.address,
  p.city,
  p.region,
  p.postcode,
  p.country,
  p.address || COALESCE(', ' || p.city, '') || COALESCE(' ' || p.postcode, '')     AS street_address,
  CASE i.inventory_type
    WHEN 'check_in'  THEN 'Check-in '
    WHEN 'check_out' THEN 'Check-out '
    WHEN 'mid_term'  THEN 'Mid-term '
    ELSE 'Inventory '
  END || COALESCE(p.street_name, p.property_label, p.address)                      AS zensched_location_name,
  CASE i.inventory_type
    WHEN 'check_in'  THEN 'Check-in '
    WHEN 'check_out' THEN 'Check-out '
    WHEN 'mid_term'  THEN 'Mid-term '
    ELSE 'Inventory '
  END || COALESCE(p.street_name, p.property_label, p.address)                      AS zensched_event_title,
  p.access_notes                                                                  AS property_access_notes,
  i.access_notes,
  p.is_repeat_site,
  p.zensched_location_id,
  CASE WHEN p.zensched_location_id IS NULL THEN 1 ELSE 0 END                      AS needs_location,
  i.zensched_event_id,
  i.zensched_shift_id,
  CASE WHEN i.zensched_shift_id IS NULL THEN 1 ELSE 0 END                         AS needs_shift,
  i.clerk_id,
  k.clerk_name,
  k.zensched_worker_id,
  i.inventory_fee,
  i.travel_fee,
  i.notes,
  'loc-property-' || p.property_id                                                AS loc_idempotency_key,
  'event-invy-' || i.inventory_id                                                 AS event_idempotency_key,
  'shift-invy-' || i.inventory_id                                                 AS shift_idempotency_key
FROM inventories i
JOIN clients c ON c.client_id = i.client_id
JOIN properties p ON p.property_id = i.property_id
LEFT JOIN clerks k ON k.clerk_id = i.clerk_id
WHERE i.status IN ('requested', 'confirmed')
  AND date(i.scheduled_start) BETWEEN date('now', 'localtime') AND date('now', 'localtime', '+6 days')
ORDER BY i.scheduled_start;

-- Properties that still need a ZenSched pin, limited to ones with an open
-- inventory so a leftover empty row does not clutter the list.
CREATE VIEW IF NOT EXISTS needs_location AS
SELECT
  p.property_id,
  p.address,
  p.city,
  p.postcode,
  p.country,
  p.street_name,
  p.property_label,
  p.address || COALESCE(', ' || p.city, '') || COALESCE(' ' || p.postcode, '')     AS street_address,
  p.access_notes,
  p.zensched_location_id,
  'loc-property-' || p.property_id                                                AS loc_idempotency_key,
  COUNT(i.inventory_id)                                                           AS open_inventory_count,
  MIN(i.scheduled_start)                                                          AS first_scheduled_start,
  MIN(i.inventory_type)                                                           AS first_inventory_type
FROM properties p
JOIN inventories i ON i.property_id = p.property_id
                  AND i.status IN ('requested', 'confirmed')
WHERE p.zensched_location_id IS NULL
GROUP BY p.property_id
ORDER BY first_scheduled_start;

-- Completed inventories whose photo report is on file but has not yet been
-- turned into an agent / dispute pack. "Export the check-out for 12 Oak Lane"
-- reads this, calls form_export + shift_status, then sets exported_at.
CREATE VIEW IF NOT EXISTS reports_to_export AS
SELECT
  i.inventory_id,
  i.inventory_no,
  i.inventory_type,
  i.status,
  date(i.scheduled_start)                          AS inventory_date,
  i.scheduled_start,
  c.client_id,
  c.client_name,
  c.billing_email,
  i.client_ref,
  p.property_id,
  p.street_name,
  p.address || COALESCE(', ' || p.city, '') || COALESCE(' ' || p.postcode, '')     AS street_address,
  i.zensched_event_id,
  i.zensched_shift_id,
  i.report_dc_id,
  i.checked_in_at,
  i.checked_out_at,
  i.gps_verified,
  i.checkin_distance_m,
  i.rooms_covered,
  i.cleanliness,
  i.meters_read,
  i.meter_readings,
  i.keys_checked,
  i.damage_found,
  i.damage_notes,
  i.photo_count,
  i.exported_at,
  k.clerk_name
FROM inventories i
JOIN clients c ON c.client_id = i.client_id
JOIN properties p ON p.property_id = i.property_id
LEFT JOIN clerks k ON k.clerk_id = i.clerk_id
WHERE i.status = 'completed'
  AND i.report_dc_id IS NOT NULL
  AND i.exported_at IS NULL
ORDER BY i.scheduled_start;

-- Uninvoiced billable work grouped by client, with the billing contact and
-- terms. Completed inventories bill their full fees; no-shows bill travel
-- only; cancellations bill other_fee only (see billable_inventories).
CREATE VIEW IF NOT EXISTS receivables_by_client AS
SELECT
  c.client_id,
  c.client_name,
  c.client_type,
  c.contact_name,
  c.billing_email,
  c.payment_terms_days,
  COUNT(b.inventory_id)                            AS inventory_count,
  SUM(CASE WHEN b.status = 'completed' THEN 1 ELSE 0 END) AS completed_count,
  SUM(CASE WHEN b.status = 'no_show' THEN 1 ELSE 0 END)   AS no_show_count,
  SUM(b.billable_total)                            AS total_billable,
  MIN(b.inventory_date)                            AS first_date,
  MAX(b.inventory_date)                            AS last_date
FROM billable_inventories b
JOIN clients c ON c.client_id = b.client_id
WHERE b.invoiced = 0
  AND b.status IN ('completed', 'no_show', 'cancelled')
  AND b.billable_total > 0
GROUP BY c.client_id
ORDER BY total_billable DESC;

-- Unpaid invoices with aging. days_past_due is negative while not yet due.
--   current : not yet due
--   30      : 1-30 days past due
--   60      : 31-60 days past due
--   90+     : more than 60 days past due (chase now)
CREATE VIEW IF NOT EXISTS invoices_outstanding AS
SELECT
  inv.invoice_id,
  inv.invoice_number,
  c.client_id,
  c.client_name,
  c.client_type,
  c.contact_name,
  c.billing_email,
  c.payment_terms_days,
  inv.invoice_date,
  inv.due_date,
  inv.sent_date,
  inv.total_amount,
  CAST(julianday(date('now', 'localtime')) - julianday(inv.due_date) AS INTEGER) AS days_past_due,
  CASE
    WHEN julianday(date('now', 'localtime')) - julianday(inv.due_date) <= 0  THEN 'current'
    WHEN julianday(date('now', 'localtime')) - julianday(inv.due_date) <= 30 THEN '30'
    WHEN julianday(date('now', 'localtime')) - julianday(inv.due_date) <= 60 THEN '60'
    ELSE '90+'
  END                                              AS aging_bucket,
  CASE WHEN inv.due_date < date('now', 'localtime') THEN 1 ELSE 0 END AS overdue
FROM invoices inv
JOIN clients c ON c.client_id = inv.client_id
WHERE inv.paid = 0
ORDER BY inv.due_date;

-- Agency mode: unpaid sub payouts, one row per inventory, with a running
-- total per clerk (clerk_total_due). Owner rows never appear.
-- needs_amount = 1 means the clerk has no payout_type; ask the owner.
CREATE VIEW IF NOT EXISTS payouts_due AS
SELECT
  p.payout_id,
  k.clerk_id,
  k.clerk_name,
  k.email,
  k.payout_type,
  k.payout_value,
  i.inventory_id,
  i.inventory_no,
  date(i.scheduled_start)                          AS inventory_date,
  i.inventory_type,
  i.status,
  b.billable_total,
  p.amount,
  CASE WHEN p.amount IS NULL THEN 1 ELSE 0 END     AS needs_amount,
  SUM(p.amount) OVER (PARTITION BY k.clerk_id)     AS clerk_total_due,
  i.invoiced                                       AS client_invoiced
FROM payouts p
JOIN clerks k ON k.clerk_id = p.clerk_id
JOIN inventories i ON i.inventory_id = p.inventory_id
JOIN billable_inventories b ON b.inventory_id = i.inventory_id
WHERE p.paid = 0
  AND k.is_owner = 0
ORDER BY k.clerk_name, i.scheduled_start;

-- Agency mode: completed / no-show inventories worked by a sub that have no
-- payouts row yet. The agent inserts one per row when recording completion.
CREATE VIEW IF NOT EXISTS payouts_missing AS
SELECT
  i.inventory_id,
  i.inventory_no,
  i.status,
  date(i.scheduled_start)                          AS inventory_date,
  i.inventory_type,
  k.clerk_id,
  k.clerk_name,
  k.payout_type,
  k.payout_value,
  b.billable_total
FROM inventories i
JOIN clerks k ON k.clerk_id = i.clerk_id AND k.is_owner = 0
JOIN billable_inventories b ON b.inventory_id = i.inventory_id
WHERE i.status IN ('completed', 'no_show')
  AND NOT EXISTS (SELECT 1 FROM payouts p WHERE p.inventory_id = i.inventory_id)
ORDER BY i.scheduled_start;
