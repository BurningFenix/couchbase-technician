# Capella App Services — FieldCopilot Sync Setup

This is the cloud side of the demo. The app works fully offline against local Couchbase Lite; this just lets work orders (and any updated manuals/assets) sync to Capella when the tablet is online.

## 1. Create the backend

1. In Capella, create (or reuse) a **free-tier Operational cluster**.
2. Create a **bucket** named `fieldcopilot`.
3. Inside the bucket, create a **scope** named `field` and these **collections** (they must match the Couchbase Lite collection names in the app exactly):
   - `assets`
   - `manualChunks`
   - `serviceHistory`
   - `parts`
   - `workOrders`
4. Go to **App Services → Create App Service**, associate it with the `fieldcopilot` cluster.
5. Create an **App Endpoint** named `fieldcopilot-endpoint`, backed by the `fieldcopilot` bucket. The endpoint starts in **offline** mode — leave it offline until security is configured (steps 2–3 below), then activate it.
6. Under the endpoint, **link** the five collections in the `field` scope.

## 2. Access Control & Data Validation function

This JavaScript runs on every document write to a linked collection. For a single-tech demo, keep it simple: put every document in one `technicians` channel and validate the obvious fields. Set this **per linked collection** (the console lets you customize each one; the function below is collection-agnostic so you can paste the same one everywhere, or just use it on `workOrders` where writes originate and use the default `function(doc, oldDoc, meta){ channel("technicians"); }` on the read-only collections).

```javascript
function (doc, oldDoc, meta) {
  // Reject tombstones quickly (deletes are allowed through).
  if (doc._deleted) {
    channel("technicians");
    return;
  }

  // Everything in this demo is readable/writable by any authenticated technician.
  channel("technicians");

  // Light validation for work orders written from the device.
  if (meta.collection === "workOrders") {
    if (!doc.assetTag) {
      throw({forbidden: "workOrder requires assetTag"});
    }
    if (!doc.title) {
      throw({forbidden: "workOrder requires title"});
    }
    // Don't let a client silently change which asset an existing order belongs to.
    if (oldDoc && oldDoc.assetTag && oldDoc.assetTag !== doc.assetTag) {
      throw({forbidden: "assetTag is immutable"});
    }
  }
}
```

Notes:
- The seed JSON intentionally has **no `channels` field** — this function assigns the channel, so you don't have to tag documents.
- For a real deployment you'd scope channels per site/team and grant users only their channels. This demo grants everyone `technicians`.

## 3. Authentication — create an App User

1. Under the endpoint, go to **App User → Create**.
2. Name: `tech1` (or `tech1@example.com`), set a password.
3. **Admin channels:** add `technicians` (this is what grants read/write access to all the demo data).
4. Save, then **activate the App Endpoint**.

> For the demo, basic auth with a hardcoded user is fine. For anything real, use OIDC/OAuth and per-user channels instead of a shared account.

## 4. Get the connection URL

Endpoint → **Connect → Connect via Couchbase Lite → Swift**. Copy the **Public Connection URL**. It looks like:

```
wss://abcd1234.apps.cloud.couchbase.com:4984/fieldcopilot-endpoint
```

The `wss://` scheme and the `:4984` port matter — replication uses WebSockets, not plain HTTPS.

## 5. App side — Replicator config (drop into Config.swift)

Fill in the three placeholders. **Do not commit real credentials** — for the demo, load them from a local untracked file or xcconfig, not source.

```swift
import CouchbaseLiteSwift

enum SyncConfig {
    // From Capella: Endpoint → Connect → Connect via Couchbase Lite
    static let endpointURL = "wss://<YOUR-ID>.apps.cloud.couchbase.com:4984/fieldcopilot-endpoint"
    static let username = "<APP_USER>"      // e.g. "tech1"
    static let password = "<APP_PASSWORD>"  // load from xcconfig / Keychain, not hardcoded
}

final class SyncManager {
    private var replicator: Replicator?

    func start(database: Database,
               collections: [Collection]) throws {
        guard let url = URL(string: SyncConfig.endpointURL) else { return }
        let target = URLEndpoint(url: url)

        var config = ReplicatorConfiguration(target: target)
        config.replicatorType = .pushAndPull
        config.continuous = true
        // Best-effort: keep retrying across network drops instead of giving up.
        config.maxAttempts = 0              // 0 = retry forever (good for field use)
        config.authenticator = BasicAuthenticator(
            username: SyncConfig.username,
            password: SyncConfig.password
        )

        // Sync all five collections. manualChunks/assets are effectively
        // read-only pulls; workOrders pushes up.
        let collConfig = CollectionConfiguration()
        config.addCollections(collections, config: collConfig)

        let replicator = Replicator(config: config)

        // Surface status to the UI (online/offline, syncing, error, last synced).
        replicator.addChangeListener { change in
            let s = change.status
            // Map s.activity (.stopped/.offline/.connecting/.idle/.busy)
            // and s.progress / s.error into your @Published sync-status state.
            print("Sync: \(s.activity), completed=\(s.progress.completed)/\(s.progress.total), err=\(String(describing: s.error))")
        }

        replicator.start()
        self.replicator = replicator
    }

    func stop() {
        replicator?.stop()
    }
}
```

Behavior you get for free: when the tablet goes offline the replicator drops to `.offline` and the app keeps writing work orders locally; when connectivity returns it reconnects and pushes everything that queued up. That's the whole point of the offline-first demo, so show `status.activity` somewhere visible.

## 6. Quick verification

1. Run the app, create a work order from a voice note while online → confirm the doc appears in the `workOrders` collection in the Capella UI.
2. Turn on Airplane Mode, create another work order → it saves locally, sync status shows offline.
3. Turn networking back on → the queued work order pushes up automatically.
4. Edit a `manualChunks` doc in Capella → it pulls down to the device on next sync.

## Gotchas

- **Collection names must match exactly** on both sides (`field` scope + the five collection names). A mismatch fails silently with nothing syncing.
- **`wss://` + port 4984.** Using `https://` won't connect.
- **`embedding` field syncs as a normal array of floats.** If you ever generate manual embeddings in the cloud instead of on-device, make sure the cloud model's dimension matches whatever the app's `NLContextualEmbedding` produces, or local vector search breaks.
- Couchbase Lite **3.1+** and Sync Gateway **3.1+** are required for custom scopes/collections — current Capella App Services is well past that, so you're fine.
