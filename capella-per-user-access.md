# Per-technician data isolation (Kyle / BJ)

Each technician signs in to App Services as **their own App User**, and work
orders are routed to a **per-technician channel**. Kyle's replicator is only
granted Kyle's channel, so BJ's work orders are never sent to Kyle's device —
the isolation is enforced by the server, not by hiding rows in the UI.

Reference data (manuals, assets, parts, service history) and **field notes**
stay in one `shared` channel: field notes are the whole point of the sharing
demo — a fix Kyle discovers must reach BJ.

| Collection | Channel | Who reads it |
|---|---|---|
| `workOrders` | `tech-kyle` / `tech-bj` (from `assignedTo`) | only that technician |
| `workOrders` (unassigned) | `shared` | everyone — e.g. dispatcher-created |
| `fieldNotes` | `shared` | everyone (the knowledge-sharing story) |
| `assets`, `manualChunks`, `serviceHistory`, `parts` | `shared` | everyone |

---

## 1. Access control functions

In **App Services → your endpoint → Access and Data Validation**, set the
function **per collection**.

### `workOrders`

```javascript
function (doc, oldDoc, meta) {
  // On a delete the body is gone, so fall back to the previous revision —
  // otherwise the tombstone lands in no channel and the technician's device
  // never learns the work order went away.
  var tech = doc._deleted
    ? (oldDoc && oldDoc.assignedTo)
    : doc.assignedTo;

  // Unassigned work orders (created by the Mac dispatcher) go to everyone.
  channel(tech ? "tech-" + tech.toLowerCase() : "shared");
}
```

### Every other collection — `assets`, `manualChunks`, `serviceHistory`, `parts`, `fieldNotes`

```javascript
function (doc, oldDoc, meta) {
  channel("shared");
}
```

> Optional hardening, if you want writes locked down too — add to `workOrders`
> before the `channel()` call. Skip it for a demo; it makes reassignment fail
> loudly.
> ```javascript
> if (!doc._deleted && oldDoc && oldDoc.assignedTo && oldDoc.assignedTo !== doc.assignedTo) {
>   throw({forbidden: "work orders cannot be reassigned from the device"});
> }
> ```

## 2. Create the two App Users

**App Services → your endpoint → Security → App Users → Add User.**

| User | `workOrders` channels | All other collections |
|---|---|---|
| `kyle` | `tech-kyle`, `shared` | `shared` |
| `bj` | `tech-bj`, `shared` | `shared` |

Use the same password for both in a demo, and put them in `.env` as
`SYNC_PASSWORD_KYLE` / `SYNC_PASSWORD_BJ`.

> **The gotcha that will cost you an hour.** For a *named scope* like `field`,
> App Services **ignores flat `admin_channels`** — channels must be granted
> per collection under `collection_access`. In the UI, set channels on each
> collection row rather than in the top-level box. Via the Admin API:
>
> ```json
> {
>   "password": "your-password",
>   "collection_access": {
>     "field": {
>       "workOrders":     { "admin_channels": ["tech-kyle", "shared"] },
>       "assets":         { "admin_channels": ["shared"] },
>       "manualChunks":   { "admin_channels": ["shared"] },
>       "serviceHistory": { "admin_channels": ["shared"] },
>       "parts":          { "admin_channels": ["shared"] },
>       "fieldNotes":     { "admin_channels": ["shared"] }
>     }
>   }
> }
> ```

## 3. Resync existing documents — do not skip this

An access function only runs on **write**. Documents already in the bucket keep
whatever channel they had when they were last written — so if you set this up
after syncing, everything is still sitting in the old `demo` channel and
neither technician will see anything.

**App Services → your endpoint → Resync.** You may need to take the endpoint
offline first, then bring it back online when it finishes.

Alternatively, skip Resync by forcing a rewrite: **Settings → Reset demo to
defaults** in the app republishes all eight work orders, which re-runs the
access function on each.

## 4. Leave the old shared user alone (or delete it)

The existing `tech1` user has admin channels `*`, which reads **everything**
and bypasses this entirely. That is correct for the **Mac dispatcher**, which
should see all work orders. Just don't sign the phone in as `tech1` — with
per-user credentials in `.env`, it no longer does.

---

## Verifying it actually works

Check what each technician can pull, without launching the app:

```bash
HOST=YOUR-ID.apps.cloud.couchbase.com

# Kyle should see only his 5 work orders
curl -sk -u kyle:PASSWORD \
  "https://$HOST:4984/fieldcopilot-endpoint.field.workOrders/_changes?limit=100" \
  | python3 -c "import sys,json; print([r['id'] for r in json.load(sys.stdin)['results'] if not r['id'].startswith('_user')])"

# BJ should see only his 3
curl -sk -u bj:PASSWORD \
  "https://$HOST:4984/fieldcopilot-endpoint.field.workOrders/_changes?limit=100" \
  | python3 -c "import sys,json; print([r['id'] for r in json.load(sys.stdin)['results'] if not r['id'].startswith('_user')])"
```

Expected: Kyle gets `wo-4821, 4822, 4809, 4790, 4830`; BJ gets `wo-4901, 4902,
4903`. If both return everything, the access function didn't run on the
existing docs — go back to step 3 and Resync.

Field notes should return the **same** documents for both users — that's the
sharing story working.

## What the app does with this

- Credentials for both technicians live in `Secrets.xcconfig` (generated from
  `.env`), so switching users in Settings needs no typing.
- Switching technician tears down the replicator and restarts it authenticated
  as the other App User. Settings shows `as kyle` / `as bj` next to the sync
  status.
- Locally, the Work tab filters by `assignedTo` as well. Both layers matter:
  channels stop the data reaching the device, and the filter keeps the UI
  honest on a device that has synced as both technicians.
