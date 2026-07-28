# Field Dispatcher (macOS)

A small macOS companion to the FieldCopilot iPhone app. Dispatchers create
work orders here; they sync up to **Couchbase Capella App Services** and back
down to the technician's iPhone — all through the same endpoint and user the
phone uses.

- **Custom form** — fill in a work order by hand.
- **Generate sample** — drops one of a handful of hardcoded work orders into
  the form (no AI, just canned data you can tweak before sending).
- **Create & sync** — saves to the local Couchbase Lite DB; a continuous
  replicator pushes it to Capella, which fans it out to the phone.

It writes to the same `field.workOrders` collection, in the exact JSON shape
the phone's `Job` model expects, so a work order created here shows up on the
phone's **Work** tab after it syncs.

---

## 1. One-time Capella setup

You need a Capella **Operational** cluster plus an **App Services** endpoint.
Everything below is deliberately wide-open — **single channel, no real
security** — because it's a demo.

### a. Cluster + bucket + collections
1. In Capella, create (or reuse) an Operational cluster.
2. Create a bucket, e.g. **`fieldcopilot`**.
3. Under that bucket create a **scope** named **`field`** and these
   **collections** (the phone replicates all of them, so create all six):
   - `assets`, `manualChunks`, `serviceHistory`, `parts`, `workOrders`, `fieldNotes`

   > For *this* Mac↔phone work-order demo, `workOrders` is the one that
   > matters, but the phone's replicator lists all six — if a collection is
   > missing on the endpoint, that collection's sync errors. Create all six.

### b. App Services endpoint
4. Create an **App Service** and link it to the cluster.
5. Add an **App Endpoint** named **`fieldcopilot-endpoint`** (this becomes the
   last path segment of the connection URL — keep it consistent with the URL
   you put in the apps).
6. Point the endpoint at the **`fieldcopilot`** bucket and map the **`field`**
   scope with all six collections (**Import / link** them).

### c. Single channel + access (no security)
7. For **each** collection, set the **Access Control & Data Validation**
   function to route everything into one channel:

   ```javascript
   function (doc, oldDoc, meta) {
     channel("demo");
   }
   ```

8. Under the endpoint's **App Users**, create one user:
   - **Username:** `tech1`  **Password:** `changeme`
   - **Admin channels:** set to **`*`** (all channels) for **every collection**
     in the `field` scope. `*` reads every document regardless of routing —
     the simplest thing that works for a demo. (`demo` also works, but only if
     the access function above actually routed the docs there.)

   > **This is the #1 gotcha.** Pushing to Capella only needs *write* access,
   > so a device can upload docs even with no channel grant — but it will
   > **pull nothing**. If the phone connects but never receives the Mac's work
   > orders, `tech1` is missing read access. Fix it here.

9. **If you created/synced any documents *before* setting the access function**
   (routing docs to `demo`), those existing docs were already assigned to
   their old channel. Either give `tech1` the `*` channel (reads them
   regardless), **or** run **Resync** on the App Endpoint so existing docs are
   re-evaluated against the new function. New docs written afterward route
   correctly on their own.

### d. Connectivity + URL
9. Make sure the endpoint has **public connectivity** enabled (allow all IPs
   for the demo).
10. Copy the endpoint's **public connection string**. It looks like:

    ```
    wss://<your-id>.apps.cloud.couchbase.com:4984/fieldcopilot-endpoint
    ```

---

## 2. Point both apps at the same endpoint

Use the **same** URL / username / password in both places.

### iPhone app
Edit `FieldCopilot/FieldCopilot/Secrets.xcconfig`:

```
SYNC_ENDPOINT_URL = wss:/$()/<your-id>.apps.cloud.couchbase.com:4984/fieldcopilot-endpoint
SYNC_USERNAME = tech1
SYNC_PASSWORD = changeme
```

> The `$()` is an empty substitution that stops xcconfig from treating `//`
> as a comment — leave it exactly as shown.

### Mac dispatcher
Create `FieldDispatcher/capella-config.json` (copy the example and fill it in —
this file is gitignored):

```bash
cd FieldDispatcher
cp capella-config.example.json capella-config.json
```

```json
{
  "endpointURL": "wss://<your-id>.apps.cloud.couchbase.com:4984/fieldcopilot-endpoint",
  "username": "tech1",
  "password": "changeme"
}
```

(No `$()` trick here — it's plain JSON.)

---

## 3. Run

**Mac dispatcher** (from this folder):

```bash
cd FieldDispatcher
swift run
```

The sync pill in the toolbar should go **Connecting → Connected**. If it says
*not configured*, you haven't created `capella-config.json` yet.

**iPhone app:** build & run in Xcode, then **Settings → Start Sync**.

---

## 4. Demo flow

1. On the Mac, click **Generate sample** (or fill the form), then
   **Create & sync to Capella**.
2. Watch the toolbar pill sync; the work order appears in the Mac list.
3. On the phone (with sync on), it lands in **Work** within a few seconds.
4. Complete it on the phone → the status change syncs back and shows in the
   Mac list too (the dispatcher pulls as well as pushes).

---

## Notes / troubleshooting

- **Same user, same channel:** both apps log in as `tech1` and everything
  lives in the `demo` channel. That's the whole security model — fine for a
  demo, not for production.
- **Nothing syncs:** check the endpoint URL (scheme must be `wss://`, port
  `:4984`, path = your endpoint name), that `tech1` exists with `demo`/`*`
  channel access, and that public connectivity allows your IP.
- **`swift run` builds but no window appears:** the app promotes itself to a
  foreground app on launch; if it's hidden, look for **Field Dispatcher** via
  ⌘-Tab.
- **Rebuild clean:** `swift package clean && swift run`.
- This app uses only the Couchbase Lite **macOS** slice of the same
  `CouchbaseLiteSwift.xcframework` the iPhone app bundles (no vector search /
  no embedding model — it just reads and writes work orders).
