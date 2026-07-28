import Foundation
import Observation
import CouchbaseLiteSwift

/// Opens a local Couchbase Lite database, writes work orders to the
/// `field.workOrders` collection, and continuously replicates that one
/// collection to the same Capella App Services endpoint the iPhone uses.
@Observable
@MainActor
final class Store {
    private(set) var workOrders: [WorkOrder] = []
    private(set) var syncActivity = "stopped"
    private(set) var syncProgress = ""
    private(set) var syncError: String?
    private(set) var lastMessage: String?

    private var database: Database?
    private var collection: Collection?
    private var replicator: Replicator?
    private var listenerToken: ListenerToken?
    /// Set when a refresh is requested while the replicator is busy; flushed
    /// once it goes idle. Prevents querying concurrently with pulled inserts.
    private var pendingRefresh = false

    private let scopeName = "field"
    private let collectionName = "workOrders"

    var endpointLabel: String { SyncConfig.endpointURL }
    var isConfigured: Bool { SyncConfig.isConfigured }

    func start() {
        guard database == nil else { return }
        do {
            let db = try Database(name: "fielddispatcher")
            database = db
            collection = try db.createCollection(name: collectionName, scope: scopeName)
            refresh()
            startSync()
        } catch {
            lastMessage = "Database error: \(error.localizedDescription)"
        }
    }

    func refresh() {
        // Never read the DB while the replicator is actively inserting pulled
        // revisions — concurrent Fleece encoding corrupts shared state and
        // aborts the process. Defer until it goes idle.
        guard syncActivity != "syncing" else { pendingRefresh = true; return }
        pendingRefresh = false
        guard let db = database, let col = collection else { return }
        do {
            let q = try db.createQuery("SELECT META().id AS docid FROM \(scopeName).\(collectionName)")
            let decoder = JSONDecoder()
            var out: [WorkOrder] = []
            for row in try q.execute() {
                guard let id = row.string(forKey: "docid"),
                      let doc = try col.document(id: id) else { continue }
                if let wo = try? decoder.decode(WorkOrder.self, from: Data(doc.toJSON().utf8)) {
                    out.append(wo)
                }
            }
            workOrders = out.sorted { $0.routeOrder < $1.routeOrder }
        } catch {
            lastMessage = "Query error: \(error.localizedDescription)"
        }
    }

    /// Saves a work order locally; the continuous replicator pushes it to
    /// Capella, which fans it out to the phone.
    func create(_ wo: WorkOrder) {
        guard let col = collection else { return }
        do {
            let data = try JSONEncoder().encode(wo)
            let doc = try MutableDocument(id: wo.id, json: String(decoding: data, as: UTF8.self))
            try col.save(document: doc)
            refresh()
            lastMessage = "Created \(wo.workOrderNumber) — syncing to Capella…"
        } catch {
            lastMessage = "Save error: \(error.localizedDescription)"
        }
    }

    /// The next work-order number/id, avoiding the seeded 4xxx range.
    func nextWorkOrderNumber() -> Int {
        let used = workOrders.compactMap { Int($0.workOrderNumber.replacingOccurrences(of: "WO-", with: "")) }
        return max((used.max() ?? 5000) + 1, 5001)
    }

    private func startSync() {
        guard SyncConfig.isConfigured else {
            syncActivity = "not configured"
            return
        }
        guard let col = collection, let url = URL(string: SyncConfig.endpointURL) else {
            syncError = "Invalid endpoint URL"
            return
        }
        let target = URLEndpoint(url: url)
        let collConfigs = CollectionConfiguration.fromCollections([col])

        var config = ReplicatorConfiguration(collections: collConfigs, target: target)
        config.replicatorType = .pushAndPull
        config.continuous = true
        config.maxAttempts = 0
        config.authenticator = BasicAuthenticator(
            username: SyncConfig.username,
            password: SyncConfig.password
        )

        let replicator = Replicator(config: config)
        listenerToken = replicator.addChangeListener { [weak self] change in
            let status = change.status
            let activity: String
            switch status.activity {
            case .stopped: activity = "stopped"
            case .offline: activity = "offline"
            case .connecting: activity = "connecting"
            case .idle: activity = "connected"
            case .busy: activity = "syncing"
            @unknown default: activity = "unknown"
            }
            let progress = "\(status.progress.completed)/\(status.progress.total)"
            let error = status.error?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                self.syncActivity = activity
                self.syncProgress = progress
                self.syncError = error
                // Only touch the DB once the replicator is idle (caught up),
                // never mid-batch. This flushes any deferred refresh too.
                if activity == "connected" { self.refresh() }
            }
        }
        replicator.start()
        self.replicator = replicator
    }
}
