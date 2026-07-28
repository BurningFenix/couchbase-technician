import Foundation

/// On-device text embeddings via Qwen3-Embedding-0.6B running on Core AI.
/// The model is ~1.2 GB and loads once; always use the shared instance.
actor EmbeddingService {
    static let shared = EmbeddingService()

    /// Bump when the embedding model changes: stored chunk vectors are
    /// only comparable to queries embedded by the same model.
    static let modelVersion = "qwen3-embedding-0.6b-f16-s512"

    private var embedder: QwenTextEmbedder?
    private(set) var dimension: Int = 0

    private init() {}

    func load() async throws {
        guard embedder == nil else { return }

        guard let modelURL = Self.bundledModelURL() else {
            throw EmbeddingError.modelNotBundled
        }
        guard let tokenizerURL = Bundle.main.url(forResource: "Qwen3Tokenizer", withExtension: nil) else {
            throw EmbeddingError.tokenizerNotBundled
        }

        print("[EmbeddingService] Loading \(modelURL.lastPathComponent)...")
        let start = Date()
        let embedder = try await QwenTextEmbedder(
            modelAt: modelURL,
            tokenizerAt: tokenizerURL,
            computeUnits: .neuralEngine,
            prompts: .qwen3Embedding
        )
        print("[EmbeddingService] Loaded in \(String(format: "%.1f", Date().timeIntervalSince(start)))s, dim=\(embedder.dimension), seqLen=\(embedder.sequenceLength)")
        self.dimension = embedder.dimension
        self.embedder = embedder
    }

    /// Finds the bundled model: the AOT-compiled .aimodelc that Xcode
    /// produces from the .aimodel resource, or the raw .aimodel.
    private static func bundledModelURL() -> URL? {
        let name = "qwen3-embedding-0.6b_float16_s512_static"
        return Bundle.main.url(forResource: name, withExtension: "aimodelc")
            ?? Bundle.main.url(forResource: name, withExtension: "aimodel")
    }

    func embedQuery(_ text: String) async throws -> [Float] {
        guard let embedder else { throw EmbeddingError.modelNotLoaded }
        return try await embedder.embed(query: text)
    }

    func embedDocument(_ text: String) async throws -> [Float] {
        guard let embedder else { throw EmbeddingError.modelNotLoaded }
        return try await embedder.embed(document: text)
    }

    enum EmbeddingError: LocalizedError {
        case modelNotBundled
        case tokenizerNotBundled
        case modelNotLoaded

        var errorDescription: String? {
            switch self {
            case .modelNotBundled:
                "Qwen3 embedding model not found in the app bundle."
            case .tokenizerNotBundled:
                "Qwen3 tokenizer folder not found in the app bundle."
            case .modelNotLoaded:
                "Embedding model is not loaded. Call load() first."
            }
        }
    }
}
