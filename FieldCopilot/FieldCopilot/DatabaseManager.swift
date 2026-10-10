import Foundation
import Observation
import CouchbaseLiteSwift

@Observable
@MainActor
final class DatabaseManager {
    private(set) var isReady = false
    private(set) var statusMessage = "Initializing..."
    private(set) var embeddingDimension: UInt = 0
    /// 0...1 launch progress: model load, then per-chunk seeding.
    private(set) var launchProgress: Double = 0

    // App-lifetime continuous sync (auto-started once the DB is ready).
    private(set) var syncActivity = "stopped"
    private(set) var syncError: String?
    private(set) var lastSyncDate: Date?
    private(set) var isSyncing = false
    /// App Services account the replicator is currently authenticated as,
    /// shown in Settings so it's obvious which technician's channels are in
    /// play.
    private(set) var syncingAs: String?
    /// Bumped on every change to the workOrders collection — a local edit OR
    /// a document pulled from Capella — so list views can re-query and mirror
    /// the synced state live.
    private(set) var workOrdersRevision = 0

    private var database: Database?
    private var collections: [String: Collection] = [:]
    private var syncManager: SyncManager?
    private var workOrdersListener: ListenerToken?
    /// Set when a workOrders change arrives while the replicator is busy;
    /// flushed on idle. Keeps list-view queries off the DB during active
    /// pulls (concurrent reads race the replicator's Fleece encoder).
    private var pendingWorkOrdersBump = false

    private static let scopeName = "field"
    private static let collectionNames = ["assets", "manualChunks", "serviceHistory", "parts", "workOrders", "fieldNotes"]
    private static let embeddingVersionKey = "embeddingModelVersion"

    func initialize() async {
        do {
            try Extension.enableVectorSearch()

            let logsDir = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first!
                + "/cblogs"
            LogSinks.file = FileLogSink(level: .warning, directory: logsDir)

            statusMessage = "Opening database..."
            launchProgress = 0.02
            let db = try Database(name: "fieldcopilot")
            self.database = db

            for name in Self.collectionNames {
                let col = try db.createCollection(name: name, scope: Self.scopeName)
                collections[name] = col
            }

            // The 1.2 GB Qwen3 embedding model loads once, up front. An
            // AOT-compiled model specializes quickly; a raw .aimodel
            // compiles on-device the very first time (one-time cost).
            statusMessage = "Loading embedding model..."
            launchProgress = 0.05
            try await EmbeddingService.shared.load()
            let dim = await EmbeddingService.shared.dimension
            self.embeddingDimension = UInt(dim)
            launchProgress = 0.2

            let seededVersion = UserDefaults.standard.string(forKey: Self.embeddingVersionKey)
            let isEmpty = collections["assets"]!.count == 0

            if isEmpty {
                statusMessage = "Loading seed data..."
                try await loadSeedData()
            } else if seededVersion != EmbeddingService.modelVersion {
                // Embedding model changed: stored vectors live in a
                // different space and must all be regenerated.
                statusMessage = "New embedding model - re-indexing..."
                try deleteVectorIndex()
                try clearManualChunks()
                if let bundled = bundledSeedData() {
                    try await seedManualChunks(bundled.manualChunks)
                }
            } else if let bundled = bundledSeedData(),
                      collections["manualChunks"]!.count != UInt64(bundled.manualChunks.count) {
                // The bundled corpus changed since this device seeded:
                // rebuild the manualChunks collection.
                statusMessage = "Manual corpus changed - re-seeding..."
                try clearManualChunks()
                try await seedManualChunks(bundled.manualChunks)
            } else {
                statusMessage = "Creating vector index..."
                try createVectorIndex(dimension: UInt32(dim))
            }

            // Static demo data (assets, history, parts, jobs) upgrades in
            // place on every launch; jobs only seed when absent since the
            // user mutates them (checklist, clock).
            if let bundled = bundledSeedData() {
                for asset in bundled.assets where try collections["assets"]!.document(id: asset.id)?.string(forKey: "serial") == nil {
                    try saveCodable(asset, in: "assets")
                }
                for part in bundled.parts where try collections["parts"]!.document(id: part.id)?.value(forKey: "warehouseQty") == nil {
                    try saveCodable(part, in: "parts")
                }
                if collections["workOrders"]!.count == 0 {
                    for job in bundled.jobs ?? [] { try saveCodable(job, in: "workOrders") }
                }
            }

            UserDefaults.standard.set(EmbeddingService.modelVersion, forKey: Self.embeddingVersionKey)
            launchProgress = 1.0
            statusMessage = "Ready"
            isReady = true

            // Keep list views in step with the synced collection, and turn on
            // continuous sync automatically so every local change (create,
            // complete, reset) pushes and every remote change pulls.
            observeWorkOrders()
            startSync()
        } catch {
            statusMessage = "DB error: \(error.localizedDescription)"
        }
    }

    // MARK: - Sync (app-lifetime, continuous)

    private func observeWorkOrders() {
        guard workOrdersListener == nil, let col = collections["workOrders"] else { return }
        workOrdersListener = col.addChangeListener { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Defer the UI refresh while a pull is in flight; a list-view
                // query during active inserts races the replicator and can
                // abort the process. Flush it once sync goes idle.
                if self.syncActivity == "busy" {
                    self.pendingWorkOrdersBump = true
                } else {
                    self.workOrdersRevision &+= 1
                }
            }
        }
    }

    func startSync() {
        guard SyncConfig.isConfigured, !isSyncing, let db = database else { return }
        let cols = getCollections()
        guard !cols.isEmpty else { return }
        let manager = SyncManager()
        let user = DemoUser(rawValue: UserDefaults.standard.string(forKey: "activeUser") ?? "kyle") ?? .kyle
        syncingAs = SyncConfig.username(for: user)
        do {
            try manager.start(
                database: db,
                collections: cols,
                username: SyncConfig.username(for: user),
                password: SyncConfig.password(for: user)
            ) { [weak self] activity, _, error in
                Task { @MainActor in
                    guard let self else { return }
                    self.syncActivity = activity
                    self.syncError = error
                    if activity == "idle" {
                        self.lastSyncDate = Date()
                        // Batch caught up — safe to let views re-query now.
                        if self.pendingWorkOrdersBump {
                            self.pendingWorkOrdersBump = false
                            self.workOrdersRevision &+= 1
                        }
                    }
                }
            }
            syncManager = manager
            isSyncing = true
        } catch {
            syncError = error.localizedDescription
        }
    }

    func stopSync() {
        syncManager?.stop()
        syncManager = nil
        isSyncing = false
        syncingAs = nil
        syncActivity = "stopped"
    }

    /// Called when the technician switches in Settings: tear the replicator
    /// down and bring it back up as the other App Services user, so the new
    /// technician's channels take effect immediately. Also refreshes the job
    /// list, which is filtered per technician.
    func switchUser() {
        let wasSyncing = isSyncing
        stopSync()
        if wasSyncing || SyncConfig.isConfigured { startSync() }
        workOrdersRevision &+= 1
    }

    private func deleteVectorIndex() throws {
        guard let col = collections["manualChunks"] else { return }
        if try col.indexes().contains("embedding_index") {
            try col.deleteIndex(forName: "embedding_index")
        }
    }

    private func bundledSeedData() -> SeedData? {
        guard let url = Bundle.main.url(forResource: "seed-data", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(SeedData.self, from: data)
    }

    private func clearManualChunks() throws {
        try clearCollection("manualChunks")
    }

    /// Deletes every document in a collection.
    private func clearCollection(_ name: String) throws {
        guard let db = database, let col = collections[name] else { return }
        let q = try db.createQuery("SELECT META().id AS docid FROM field.\(name)")
        for row in try q.execute() {
            if let id = row.string(forKey: "docid"), let doc = try col.document(id: id) {
                try col.delete(document: doc)
            }
        }
    }

    /// Restores the mutable demo data to the bundled defaults: assets,
    /// service history, parts, and work orders are wiped and re-seeded, and
    /// all shared field notes are cleared. The expensive manualChunks
    /// collection (and its embeddings) is left intact — it never changes
    /// per user, so there's no need to re-embed 200+ chunks on a reset.
    func resetToSeed() throws {
        guard let bundled = bundledSeedData() else { return }
        try clearCollection("assets")
        try clearCollection("serviceHistory")
        try clearCollection("parts")
        try clearCollection("workOrders")
        try deleteAllFieldNotes()
        for asset in bundled.assets { try saveCodable(asset, in: "assets") }
        for svc in bundled.serviceHistory { try saveCodable(svc, in: "serviceHistory") }
        for part in bundled.parts { try saveCodable(part, in: "parts") }
        for job in bundled.jobs ?? [] { try saveCodable(job, in: "workOrders") }
    }

    private func saveCodable<T: Identifiable & Encodable>(_ value: T, in collectionName: String) throws where T.ID == String {
        guard let col = collections[collectionName] else { return }
        let data = try JSONEncoder().encode(value)
        let doc = try MutableDocument(id: value.id, json: String(decoding: data, as: UTF8.self))
        try col.save(document: doc)
    }

    private func loadSeedData() async throws {
        guard let seed = bundledSeedData() else {
            statusMessage = "seed-data.json not found in bundle"
            return
        }

        for asset in seed.assets { try saveCodable(asset, in: "assets") }
        for svc in seed.serviceHistory { try saveCodable(svc, in: "serviceHistory") }
        for part in seed.parts { try saveCodable(part, in: "parts") }
        for job in seed.jobs ?? [] { try saveCodable(job, in: "workOrders") }

        statusMessage = "Generating embeddings for manual chunks..."
        try await seedManualChunks(seed.manualChunks)
    }

    private func seedManualChunks(_ chunks: [ManualChunk]) async throws {
        try await EmbeddingService.shared.load()
        let dim = await EmbeddingService.shared.dimension
        self.embeddingDimension = UInt(dim)

        for (index, chunk) in chunks.enumerated() {
            let doc = MutableDocument(id: chunk.id)
            doc.setString(chunk.manualTitle, forKey: "manualTitle")
            doc.setString(chunk.section, forKey: "section")
            doc.setInt(chunk.page, forKey: "page")
            doc.setString(chunk.assetModel, forKey: "assetModel")
            doc.setString(chunk.text, forKey: "text")

            let vector = try await EmbeddingService.shared.embedDocument(chunk.text)
            let arr = MutableArrayObject()
            for v in vector { arr.addFloat(v) }
            doc.setArray(arr, forKey: "embedding")

            try collections["manualChunks"]!.save(document: doc)

            statusMessage = "Embedding manuals (\(index + 1)/\(chunks.count))..."
            launchProgress = 0.2 + 0.78 * Double(index + 1) / Double(chunks.count)
        }

        try createVectorIndex(dimension: UInt32(dim))
    }

    private func createVectorIndex(dimension: UInt32) throws {
        guard let col = collections["manualChunks"] else { return }

        // centroids ~= sqrt(number of vectors); 223 chunks -> 15
        var config = VectorIndexConfiguration(
            expression: "embedding",
            dimensions: dimension,
            centroids: 15
        )
        config.metric = .cosine
        config.minTrainingSize = 100
        config.maxTrainingSize = 250

        // ENGINE QUIRK (verified on CBL 4.0.4 + vector search 2.x): index
        // names are effectively database-wide. Creating an index with the
        // same name on a second collection SILENTLY DELETES the first
        // collection's index - no error anywhere. Index names must
        // therefore be unique across collections.

        // One-time cleanup for databases touched by the earlier build
        // that used identical names on fieldNotes: drop the stale
        // fieldNotes indexes BEFORE creating the manuals ones, or the
        // manuals indexes could get clobbered again.
        if let notes = collections["fieldNotes"] {
            let stale = try notes.indexes()
            if stale.contains("embedding_index") { try notes.deleteIndex(forName: "embedding_index") }
            if stale.contains("textIndex") { try notes.deleteIndex(forName: "textIndex") }
        }

        try col.createIndex(withName: "embedding_index", config: config)

        try col.createIndex(withName: "textIndex", config: FullTextIndexConfiguration(["text"]))

        // Field notes are searched alongside the manuals. Tiny collection:
        // the index stays untrained and scans flat, which is fine.
        if let notes = collections["fieldNotes"] {
            var noteConfig = VectorIndexConfiguration(
                expression: "embedding",
                dimensions: dimension,
                centroids: 2
            )
            noteConfig.metric = .cosine
            noteConfig.minTrainingSize = 0
            noteConfig.maxTrainingSize = 64
            try notes.createIndex(withName: "notes_embedding_index", config: noteConfig)
            try notes.createIndex(withName: "notes_textIndex", config: FullTextIndexConfiguration(["text"]))
        }
    }

    // MARK: - Queries

    func allAssets() throws -> [Asset] {
        try allCodable(Asset.self, in: "assets").sorted { $0.assetTag < $1.assetTag }
    }

    private func allCodable<T: Decodable>(_ type: T.Type, in collectionName: String) throws -> [T] {
        guard let db = database, let col = collections[collectionName] else { return [] }
        let q = try db.createQuery("SELECT META().id AS docid FROM field.\(collectionName)")
        var results: [T] = []
        let decoder = JSONDecoder()
        for row in try q.execute() {
            guard let id = row.string(forKey: "docid"),
                  let doc = try col.document(id: id) else { continue }
            let json = Data(doc.toJSON().utf8)
            if let value = try? decoder.decode(T.self, from: json) {
                results.append(value)
            }
        }
        return results
    }

    // MARK: - Manual

    /// All manual chunks for one asset model, in reading order (by page,
    /// then section). Used to stitch the full manual back together for the
    /// Documents reader. Embeddings are not fetched (not needed for display).
    func manualChunks(forModel model: String) throws -> [ManualChunk] {
        guard let db = database else { return [] }
        let q = try db.createQuery("""
            SELECT META().id AS id, manualTitle, section, page, text, assetModel
            FROM field.manualChunks WHERE assetModel = $model
            """)
        let params = Parameters()
        params.setString(model, forName: "model")
        q.parameters = params

        var out: [ManualChunk] = []
        for row in try q.execute() {
            out.append(ManualChunk(
                id: row.string(forKey: "id") ?? "",
                manualTitle: row.string(forKey: "manualTitle") ?? "",
                section: row.string(forKey: "section") ?? "",
                page: row.int(forKey: "page"),
                assetModel: row.string(forKey: "assetModel") ?? "",
                text: row.string(forKey: "text") ?? "",
                embedding: nil
            ))
        }
        return out.sorted { $0.page != $1.page ? $0.page < $1.page : $0.section < $1.section }
    }

    // MARK: - Jobs

    /// The technician currently signed in, read from the same UserDefaults
    /// key ChatEngine writes.
    private var activeUserName: String {
        (UserDefaults.standard.string(forKey: "activeUser") == "bj") ? "BJ" : "Kyle"
    }

    /// Work orders belonging to the signed-in technician. Unassigned orders
    /// (e.g. created by the Mac dispatcher) are visible to everyone.
    ///
    /// This is the local half of the isolation story - App Services enforces
    /// the real one by channel, so another tech's orders never reach the
    /// device. Both matter: the filter keeps the UI honest even when one
    /// device has synced as both technicians.
    func allJobs() throws -> [Job] {
        let me = activeUserName
        return try allCodable(Job.self, in: "workOrders")
            .filter { $0.assignedTo == nil || $0.assignedTo == me }
            .sorted { $0.routeOrder < $1.routeOrder }
    }

    /// Every work order regardless of assignee - used only where the tech
    /// is opening a specific order by id.
    func allJobsUnfiltered() throws -> [Job] {
        try allCodable(Job.self, in: "workOrders").sorted { $0.routeOrder < $1.routeOrder }
    }

    func job(id: String) throws -> Job? {
        try allJobsUnfiltered().first { $0.id == id }
    }

    func saveJob(_ job: Job) throws {
        try saveCodable(job, in: "workOrders")
    }

    // MARK: - Parts

    func allParts() throws -> [Part] {
        try allCodable(Part.self, in: "parts").sorted { $0.partNumber < $1.partNumber }
    }

    func part(withNumber number: String) throws -> Part? {
        try allParts().first { $0.partNumber == number }
    }

    func setPartRequested(_ partId: String, requested: Bool) throws {
        guard let col = collections["parts"],
              let doc = try col.document(id: partId)?.toMutable() else { return }
        doc.setBoolean(requested, forKey: "requested")
        try col.save(document: doc)
    }

    // MARK: - Service history

    func serviceHistory(forAssetTag tag: String) throws -> [ServiceRecord] {
        try allCodable(ServiceRecord.self, in: "serviceHistory")
            .filter { $0.assetTag == tag }
            .sorted { $0.date > $1.date }
    }

    // MARK: - Field notes

    func fieldNoteCount() -> Int {
        Int(collections["fieldNotes"]?.count ?? 0)
    }

    /// Newest field notes, for one equipment model or (nil) all of them.
    /// Built field-by-field: the stored documents carry no "id" key, so the
    /// generic Codable reader can't decode them.
    func recentFieldNotes(forAssetModel model: String?, limit: Int = 3) throws -> [FieldNote] {
        guard let db = database else { return [] }
        let filter = model == nil ? "" : "WHERE assetModel = $model "
        let q = try db.createQuery(
            "SELECT META().id AS docid, text, author, assetModel, createdAt FROM field.fieldNotes \(filter)ORDER BY createdAt DESC LIMIT \(limit)")
        if let model {
            let params = Parameters()
            params.setString(model, forName: "model")
            q.parameters = params
        }
        return try q.execute().compactMap { row in
            guard let id = row.string(forKey: "docid"), let text = row.string(forKey: "text") else { return nil }
            return FieldNote(id: id, text: text,
                             author: row.string(forKey: "author") ?? "a tech",
                             assetModel: row.string(forKey: "assetModel") ?? "General",
                             createdAt: row.string(forKey: "createdAt") ?? "")
        }
    }

    func deleteAllFieldNotes() throws {
        guard let db = database, let col = collections["fieldNotes"] else { return }
        let q = try db.createQuery("SELECT META().id AS docid FROM field.fieldNotes")
        for row in try q.execute() {
            if let id = row.string(forKey: "docid"), let doc = try col.document(id: id) {
                try col.delete(document: doc)
            }
        }
    }

    func saveFieldNote(_ note: FieldNote, embedding: [Float]) throws {
        guard let col = collections["fieldNotes"] else { return }
        let doc = MutableDocument(id: note.id)
        doc.setString(note.text, forKey: "text")
        doc.setString(note.author, forKey: "author")
        doc.setString(note.assetModel, forKey: "assetModel")
        doc.setString(note.createdAt, forKey: "createdAt")
        let arr = MutableArrayObject()
        for v in embedding { arr.addFloat(v) }
        doc.setArray(arr, forKey: "embedding")
        try col.save(document: doc)
        print("[DatabaseManager] Saved field note by \(note.author): \(note.text.prefix(60))...")
    }

    func vectorSearch(queryVector: [Float], assetModel: String?, limit: Int = 5) throws -> [SearchResult] {
        guard let db = database else { return [] }

        let vectorArr = MutableArrayObject()
        for v in queryVector { vectorArr.addFloat(v) }

        // A WHERE clause combined with APPROX_VECTOR_DISTANCE makes the
        // planner reject the vector index on this engine build, so the
        // asset filter is applied in memory over an over-fetched pool.
        let fetchLimit = (assetModel?.isEmpty ?? true) ? limit : max(limit * 6, 30)
        let sql = """
            SELECT META().id, manualTitle, section, page, text, assetModel,
                   APPROX_VECTOR_DISTANCE(embedding, $queryVec, "cosine") AS distance
            FROM field.manualChunks
            ORDER BY APPROX_VECTOR_DISTANCE(embedding, $queryVec, "cosine")
            LIMIT \(fetchLimit)
        """

        let q = try db.createQuery(sql)
        let params = Parameters()
        _ = params.setArray(vectorArr, forName: "queryVec")
        q.parameters = params

        var results: [SearchResult] = []
        for row in try q.execute() {
            if let model = assetModel, !model.isEmpty,
               row.string(forKey: "assetModel") != model {
                continue
            }
            results.append(SearchResult(
                chunkId: row.string(forKey: "id") ?? "",
                manualTitle: row.string(forKey: "manualTitle") ?? "",
                section: row.string(forKey: "section") ?? "",
                page: row.int(forKey: "page"),
                text: row.string(forKey: "text") ?? "",
                distance: row.double(forKey: "distance")
            ))
            if results.count == limit { break }
        }
        return results
    }

    /// Full-text keyword search over chunk text. Catches exact tokens
    /// (fault codes, part numbers) that mean-pooled vectors dilute.
    func keywordSearch(_ queryText: String, assetModel: String?, limit: Int = 10) throws -> [SearchResult] {
        guard let db = database else { return [] }

        let tokens = SearchTokenizer.tokens(from: queryText)
        guard !tokens.isEmpty else { return [] }

        // Tokens are alphanumeric-only at this point, safe to inline.
        let match = tokens.joined(separator: " OR ")

        // Asset filter applied in memory (see vectorSearch).
        let fetchLimit = (assetModel?.isEmpty ?? true) ? limit : max(limit * 6, 30)
        let sql = """
            SELECT META(mc).id, mc.manualTitle, mc.section, mc.page, mc.text, mc.assetModel
            FROM field.manualChunks AS mc
            WHERE MATCH(mc.textIndex, '\(match)')
            ORDER BY RANK(mc.textIndex) DESC LIMIT \(fetchLimit)
        """

        // Fail soft: an FTS parse error (e.g. the engine's tokenizer
        // erasing a term we emitted) must degrade to vector-only
        // retrieval, not fail the whole question.
        do {
            let q = try db.createQuery(sql)

            var results: [SearchResult] = []
            for row in try q.execute() {
                if let model = assetModel, !model.isEmpty,
                   row.string(forKey: "assetModel") != model {
                    continue
                }
                results.append(SearchResult(
                    chunkId: row.string(forKey: "id") ?? "",
                    manualTitle: row.string(forKey: "manualTitle") ?? "",
                    section: row.string(forKey: "section") ?? "",
                    page: row.int(forKey: "page"),
                    text: row.string(forKey: "text") ?? "",
                    distance: nil
                ))
                if results.count == limit { break }
            }
            return results
        } catch {
            print("[DatabaseManager] FTS query failed (\(error)) - continuing with vector results only")
            return []
        }
    }

    /// Hybrid search: runs vector and keyword search, merges with
    /// reciprocal rank fusion so a top hit in either list surfaces.
    func hybridSearch(queryVector: [Float], queryText: String, assetModel: String?, limit: Int = 5) throws -> [SearchResult] {
        Array(try rankedSearch(queryVector: queryVector, queryText: queryText, assetModel: assetModel)
            .prefix(limit)
            .map(\.result))
    }

    /// Vector search over the shared field-notes collection. The
    /// embedding must be referenced unqualified (no collection alias):
    /// CBL matches the query expression against the index expression
    /// literally, and the index was created on "embedding".
    private func vectorSearchFieldNotes(queryVector: [Float], limit: Int = 3) throws -> [SearchResult] {
        guard let db = database, fieldNoteCount() > 0 else { return [] }
        let vectorArr = MutableArrayObject()
        for v in queryVector { vectorArr.addFloat(v) }
        let sql = """
            SELECT META().id, text, author,
                   APPROX_VECTOR_DISTANCE(embedding, $queryVec, "cosine") AS distance
            FROM field.fieldNotes
            ORDER BY APPROX_VECTOR_DISTANCE(embedding, $queryVec, "cosine")
            LIMIT \(limit)
        """
        do {
            let q = try db.createQuery(sql)
            let params = Parameters()
            _ = params.setArray(vectorArr, forName: "queryVec")
            q.parameters = params
            var results: [SearchResult] = []
            for row in try q.execute() {
                let author = row.string(forKey: "author") ?? "another tech"
                results.append(SearchResult(
                    chunkId: row.string(forKey: "id") ?? "",
                    manualTitle: "Shared field note",
                    section: "Saved by \(author)",
                    page: 0,
                    text: row.string(forKey: "text") ?? "",
                    distance: row.double(forKey: "distance"),
                    fieldNoteAuthor: author
                ))
            }
            return results
        } catch {
            // Fail soft: a notes-search problem must not kill the question.
            print("[DatabaseManager] Field-note vector search failed (\(error)) - continuing with manuals only")
            return []
        }
    }

    /// FTS over field notes; fail-soft like the manuals FTS.
    private func keywordSearchFieldNotes(_ queryText: String, limit: Int = 3) throws -> [SearchResult] {
        guard let db = database, fieldNoteCount() > 0 else { return [] }
        let tokens = SearchTokenizer.tokens(from: queryText)
        guard !tokens.isEmpty else { return [] }
        let match = tokens.joined(separator: " OR ")
        let sql = """
            SELECT META(fn).id, fn.text, fn.author
            FROM field.fieldNotes AS fn
            WHERE MATCH(fn.notes_textIndex, '\(match)')
            ORDER BY RANK(fn.notes_textIndex) DESC LIMIT \(limit)
        """
        do {
            let q = try db.createQuery(sql)
            var results: [SearchResult] = []
            for row in try q.execute() {
                let author = row.string(forKey: "author") ?? "another tech"
                results.append(SearchResult(
                    chunkId: row.string(forKey: "id") ?? "",
                    manualTitle: "Shared field note",
                    section: "Saved by \(author)",
                    page: 0,
                    text: row.string(forKey: "text") ?? "",
                    distance: nil,
                    fieldNoteAuthor: author
                ))
            }
            return results
        } catch {
            print("[DatabaseManager] Field-note FTS failed (\(error))")
            return []
        }
    }

    /// Runs vector and keyword search once, returns the union with each
    /// chunk's position in all three rankings (vector, FTS, hybrid RRF)
    /// so the UI can re-sort by mode without re-searching. Field notes
    /// are searched alongside the manuals and merged into both pools.
    func rankedSearch(queryVector: [Float], queryText: String, assetModel: String?, poolSize: Int = 10) throws -> [RankedSearchResult] {
        var vectorResults = try vectorSearch(queryVector: queryVector, assetModel: assetModel, limit: poolSize)
        let noteVectorResults = try vectorSearchFieldNotes(queryVector: queryVector)
        if !noteVectorResults.isEmpty {
            // Cosine distances are comparable across collections: merge
            // and re-sort so a close note outranks distant chunks.
            vectorResults = Array((vectorResults + noteVectorResults)
                .sorted { ($0.distance ?? 1) < ($1.distance ?? 1) }
                .prefix(poolSize))
        }

        var keywordResults = try keywordSearch(queryText, assetModel: assetModel, limit: poolSize)
        let noteKeywordResults = try keywordSearchFieldNotes(queryText)
        if !noteKeywordResults.isEmpty {
            // FTS ranks are not comparable across collections; personal
            // notes are few and high-signal, so they lead the list.
            keywordResults = Array((noteKeywordResults + keywordResults).prefix(poolSize))
        }

        var byId: [String: SearchResult] = [:]
        var vectorRanks: [String: Int] = [:]
        var ftsRanks: [String: Int] = [:]
        var scores: [String: Double] = [:]
        // Small k makes fusion top-heavy: a #1 in either list (1/2 = 0.5)
        // outscores a chunk at mid-rank in both (e.g. #5+#5 = 0.33). The
        // textbook k=60 is tuned for large corpora; with 10-item pools it
        // buried exact-match winners at hybrid #4-6, where the small
        // on-device model attends to them unreliably.
        let k = 1.0

        for (i, r) in vectorResults.enumerated() {
            vectorRanks[r.chunkId] = i + 1
            scores[r.chunkId, default: 0] += 1.0 / (k + Double(i + 1))
            byId[r.chunkId] = r
        }
        for (i, r) in keywordResults.enumerated() {
            ftsRanks[r.chunkId] = i + 1
            scores[r.chunkId, default: 0] += 1.0 / (k + Double(i + 1))
            if byId[r.chunkId] == nil { byId[r.chunkId] = r }
        }

        var finalOrder = scores.sorted { $0.value > $1.value }.map(\.key)

        // RRF favors chunks present in BOTH lists: two mid-rank scores sum
        // higher than a single #1 score. For exact-identifier queries
        // (fault codes, part numbers) the right chunk is often #1 in FTS
        // only, and dual-listed near-misses crowd it out of the top 5
        // that reach the LLM. Guarantee each mode's #1 a top-5 seat.
        // Field notes get a guaranteed seat too. They are few, deliberately
        // written by a technician, and the whole point of the sharing story -
        // but RRF favors manual chunks that appear in BOTH lists, so a
        // matching note could land at hybrid #6+ and never reach the model at
        // all (it would show in the sources sheet and nowhere else).
        let bestNoteId = finalOrder.first { byId[$0]?.isFieldNote == true }

        var guaranteed: [String] = []
        for id in [keywordResults.first?.chunkId, vectorResults.first?.chunkId, bestNoteId].compactMap(\.self)
        where !guaranteed.contains(id) {
            guaranteed.append(id)
        }

        var promoted: [String] = []
        for id in guaranteed {
            if let idx = finalOrder.firstIndex(of: id), idx >= 5 {
                finalOrder.remove(at: idx)
                promoted.append(id)
            }
        }
        // Insert at ascending positions ending at 4, so every promoted item
        // lands inside the top 5 and later inserts cannot push earlier ones
        // back out (2 promotions -> 3,4; 3 promotions -> 2,3,4).
        let start = max(0, 5 - promoted.count)
        for (i, id) in promoted.enumerated() {
            finalOrder.insert(id, at: min(start + i, finalOrder.count))
        }

        return finalOrder.enumerated().compactMap { i, id in
            guard let result = byId[id] else { return nil }
            return RankedSearchResult(
                result: result,
                ftsRank: ftsRanks[id],
                vectorRank: vectorRanks[id],
                hybridRank: i + 1
            )
        }
    }

    // MARK: - Stats

    func totalDocumentCount() -> Int {
        collections.values.reduce(0) { $0 + Int($1.count) }
    }

    func databaseSizeInMB() -> Double {
        guard let path = database?.path else { return 0 }
        let url = URL(fileURLWithPath: path)
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total = 0
        for case let file as URL in enumerator {
            total += (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return Double(total) / 1_048_576
    }

    func getCollections() -> [Collection] {
        Self.collectionNames.compactMap { collections[$0] }
    }

    func getDatabase() -> Database? {
        database
    }
}
