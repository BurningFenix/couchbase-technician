import Foundation

struct Asset: Identifiable, Codable, Sendable {
    var id: String
    var assetTag: String
    var name: String
    var model: String
    var location: String
    var status: String
    var specs: AssetSpecs
    var serial: String?
    var runtimeHours: Int?
    var cycles: Int?
    var lastService: String?

    var isOperational: Bool { status.lowercased() == "operational" }
}

struct AssetSpecs: Codable, Sendable {
    var type: String?
    var capacityTons: Int?
    var cfm: Int?
    var refrigerant: String?
    var voltage: String?
    var installedDate: String?
}

struct ManualChunk: Identifiable, Codable, Sendable {
    var id: String
    var manualTitle: String
    var section: String
    var page: Int
    var assetModel: String
    var text: String
    var embedding: [Float]?
}

struct ServiceRecord: Identifiable, Codable, Sendable {
    var id: String
    var assetTag: String
    var date: String
    var summary: String
    var technician: String
}

struct Part: Identifiable, Codable, Sendable {
    var id: String
    var partNumber: String
    var description: String
    var quantityOnHand: Int
    var binLocation: String
    var warehouseQty: Int?
    var unit: String?
    var requested: Bool?

    enum StockLevel {
        case ok, low, out, backorder

        var label: String {
            switch self {
            case .ok: "In stock"
            case .low: "Low"
            case .out: "Out on van"
            case .backorder: "Backorder"
            }
        }
    }

    var stockLevel: StockLevel {
        if quantityOnHand == 0 {
            return (warehouseQty ?? 0) == 0 ? .backorder : .out
        }
        return quantityOnHand == 1 ? .low : .ok
    }
}

struct JobPart: Codable, Sendable, Hashable {
    var name: String
    var note: String
}

/// A field-service work order (the design's "job").
struct Job: Identifiable, Codable, Sendable {
    var id: String
    var workOrderNumber: String
    var priority: String
    var status: String
    var timeLabel: String
    var window: String
    var title: String
    var assetName: String
    var assetTag: String
    var assetModel: String
    var site: String
    var reported: String
    var steps: [String]
    var stepsDone: [Int]
    var jobParts: [JobPart]
    var clockSeconds: Int
    var routeOrder: Int
    /// Display name of the technician this work order belongs to ("Kyle" /
    /// "BJ"). Drives the per-user job list locally, and the per-user channel
    /// on App Services so a tech can only ever pull their own work orders.
    /// nil means unassigned - visible to everyone (e.g. dispatcher-created).
    var assignedTo: String?
    /// Inventory part number this job needs, if any. Drives the chat's
    /// agentic parts-stock check when the tech asks about this job.
    var requiredPart: String?
    /// Scripted questions [first, follow-up] for the guided demo flow when
    /// the tech starts a chat from this work order. nil for ordinary jobs.
    var demoPrompts: [String]?
}

/// A tech-authored fix that isn't in the manuals. Stored in its own
/// collection, embedded for retrieval, and synced so other techs see it.
struct FieldNote: Identifiable, Codable, Sendable {
    var id: String
    var text: String
    var author: String
    var assetModel: String
    var createdAt: String
}

struct SeedData: Codable {
    var assets: [Asset]
    var manualChunks: [ManualChunk]
    var serviceHistory: [ServiceRecord]
    var parts: [Part]
    var jobs: [Job]?
}

struct SearchResult: Sendable {
    var chunkId: String
    var manualTitle: String
    var section: String
    var page: Int
    var text: String
    var distance: Double?
    /// Set when the hit came from the shared fieldNotes collection
    /// rather than the manuals.
    var fieldNoteAuthor: String?

    var isFieldNote: Bool { fieldNoteAuthor != nil }
}

/// A search hit annotated with its position in each of the three
/// rankings. nil means the chunk did not appear in that ranking's pool.
struct RankedSearchResult: Identifiable, Sendable {
    var result: SearchResult
    var ftsRank: Int?
    var vectorRank: Int?
    var hybridRank: Int

    var id: String { result.chunkId }
}

/// Shared query tokenization for FTS: the same tokens drive the MATCH
/// query and the match-term highlighting in the source cards.
enum SearchTokenizer {
    /// Superset of the Snowball English stopword list that CBL's FTS
    /// tokenizer uses. Any term we emit that the engine then erases as a
    /// stopword leaves "OR <nothing>" - a malformed MATCH expression -
    /// so our filter must cover everything the engine's filter covers.
    static let stopwords: Set<String> = [
        "i", "me", "my", "myself", "we", "our", "ours", "ourselves",
        "you", "your", "yours", "yourself", "yourselves",
        "he", "him", "his", "himself", "she", "her", "hers", "herself",
        "it", "its", "itself", "they", "them", "their", "theirs", "themselves",
        "what", "which", "who", "whom", "this", "that", "these", "those",
        "am", "is", "are", "was", "were", "be", "been", "being",
        "have", "has", "had", "having", "do", "does", "did", "doing",
        "a", "an", "the", "and", "but", "if", "or", "because", "as",
        "until", "while", "of", "at", "by", "for", "with", "about",
        "against", "between", "into", "through", "during", "before",
        "after", "above", "below", "to", "from", "up", "down", "in",
        "out", "on", "off", "over", "under", "again", "further", "then",
        "once", "here", "there", "when", "where", "why", "how",
        "all", "any", "both", "each", "few", "more", "most", "other",
        "some", "such", "no", "nor", "not", "only", "own", "same",
        "so", "than", "too", "very", "can", "will", "just", "don",
        "should", "now",
        // Extras beyond Snowball that carry no search signal
        "could", "would", "mean", "means", "keep", "keeps"
    ]

    static func tokens(from text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stopwords.contains($0) }
    }
}
