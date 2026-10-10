import Foundation
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Qwen3.5-4B (4-bit, text-only) running locally via MLX. NOT bundled: the
/// ~2.4 GB weights download on demand the first time the user selects this
/// model (with real byte progress, see `ModelDownloader`), then cache in
/// Application Support. Requires the increased-memory-limit entitlement.
///
/// Note on model choice: the stock Qwen3.5-4B checkpoints are vision-language
/// models. Earlier attempts loaded them via MLX's VLM factory, which kept the
/// unused vision tower resident next to the 1.1 GB Core AI embedding model
/// and crashed on-device. This repo has the vision tower stripped (language
/// weights bit-identical), so it loads through the text-only
/// `LLMModelFactory` (`qwen3_5`, supported since mlx-swift-lm 3.31) at
/// roughly the same footprint as Qwen3-4B. To roll back, set `modelId` to
/// "mlx-community/Qwen3-4B-4bit" with its own pinned revision.
actor QwenLLMService {
    static let shared = QwenLLMService()
    static let modelId = "droyster/Qwen3.5-4B-Text-MLX-4bit"
    /// Pinned commit: a third-party repo must never change under us.
    static let modelRevision = "c229db37d5e00db8bbbe9a5a61f95964637fc226"
    static let displayName = "Qwen3.5 4B"
    static let downloadSizeLabel = "~2.4 GB"

    private var container: ModelContainer?
    private var loadTask: Task<Void, Error>?

    private init() {}

    var isLoaded: Bool { container != nil }

    /// True once the weights are fully on disk (only the load remains).
    static var isDownloaded: Bool {
        ModelDownloader.isDownloaded(repo: modelId, revision: modelRevision)
    }

    /// One progress update from `load`. `fraction` is non-nil during the
    /// byte-download phase; it is nil for the "loading weights into memory /
    /// compiling kernels" phase, which reports no progress and can take
    /// 20-40s — the UI shows an indeterminate bar there.
    struct LoadProgress: Sendable {
        let message: String
        let fraction: Double?
    }

    /// Wall-clock allowance for the quiet "loading weights into memory"
    /// phase, which emits no progress callbacks. A model the factory cannot
    /// build hangs there forever, so a stall this long is treated as a failed
    /// load rather than letting it wedge the app.
    private static let stallTimeout: TimeInterval = 150

    /// Idempotent and concurrency-safe: a Settings-switch prewarm and a
    /// first question arriving mid-download share one load.
    func load(onProgress: (@Sendable (LoadProgress) -> Void)? = nil) async throws {
        guard container == nil else { return }
        if let loadTask { return try await loadTask.value }
        let task = Task { try await self.performLoad(onProgress: onProgress) }
        loadTask = task
        defer { loadTask = nil }
        do {
            try await task.value
        } catch {
            container = nil
            throw error
        }
    }

    private func performLoad(onProgress: (@Sendable (LoadProgress) -> Void)?) async throws {
        let name = Self.displayName
        onProgress?(LoadProgress(message: "Preparing \(name)…", fraction: Self.isDownloaded ? nil : 0))

        let directory = try await ModelDownloader.ensureDownloaded(
            repo: Self.modelId, revision: Self.modelRevision
        ) { p in
            let mb = { (b: Int64) in b / 1_048_576 }
            onProgress?(LoadProgress(
                message: "Downloading \(name) — \(Int(p.fraction * 100))% (\(mb(p.completedBytes)) of \(mb(p.totalBytes)) MB)",
                fraction: p.fraction))
        }

        onProgress?(LoadProgress(message: "Loading \(name) into memory… (20-40s)", fraction: nil))
        container = try await withThrowingTaskGroup(of: ModelContainer?.self) { group in
            group.addTask {
                try await LLMModelFactory.shared.loadContainer(
                    from: directory,
                    using: #huggingFaceTokenizerLoader()
                )
            }
            group.addTask {
                try await Task.sleep(for: .seconds(Self.stallTimeout))
                throw QwenError.loadStalled(name)
            }
            defer { group.cancelAll() }
            // The loader finishes first on success; the watchdog only wins if
            // building the model hangs past the timeout.
            while let result = try await group.next() {
                if let container = result { return container }
            }
            throw QwenError.loadStalled(name)
        }
        print("[QwenLLMService] Model loaded")
    }

    /// `tools` are OpenAI-style function schemas; when the model emits a tool
    /// call, `toolDispatch(name, arguments)` runs it and ChatSession feeds the
    /// result back before generation continues.
    func generate(instructions: String, prompt: String, maxTokens: Int = 700,
                  tools: [ToolSpec]? = nil,
                  toolDispatch: (@Sendable (String, [String: Any]) -> String)? = nil,
                  onStatus: (@Sendable (String) -> Void)? = nil,
                  onPartial: (@Sendable (String) -> Void)? = nil) async throws -> String {
        try await load { onStatus?($0.message) }
        guard let container else { throw QwenError.notLoaded }

        var parameters = GenerateParameters()
        parameters.maxTokens = maxTokens
        // Qwen's recommended non-thinking sampling. Pure greedy (temp 0) is
        // explicitly discouraged for Qwen3.5: it degrades quality and can
        // loop on repeated phrases.
        parameters.temperature = 0.7
        parameters.topP = 0.8
        parameters.topK = 20
        parameters.presencePenalty = 1.5
        parameters.kvBits = 4

        let start = Date()
        // Qwen3.5 dropped the "/no_think" soft switch; thinking is turned off
        // through the chat template instead (it then emits an empty
        // <think></think>, which stripThinking removes).
        let session = ChatSession(
            container, instructions: instructions, generateParameters: parameters,
            additionalContext: ["enable_thinking": false],
            tools: tools,
            toolDispatch: toolDispatch.map { dispatch in
                { @Sendable call in
                    dispatch(call.function.name, call.function.arguments.mapValues(\.anyValue))
                }
            })
        let fullPrompt = prompt

        // Without a partial-callback, one-shot; otherwise stream the chunks
        // and emit the running text (with the <think> block stripped) for a
        // live typewriter effect.
        guard let onPartial else {
            let raw = try await session.respond(to: fullPrompt)
            let text = Self.stripThinking(raw)
            print("[QwenLLMService] Generated \(text.count) chars in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
            return text
        }

        var raw = ""
        for try await chunk in session.streamResponse(to: fullPrompt) {
            raw += chunk
            let display = Self.stripThinking(raw)
            if !display.isEmpty { onPartial(display) }
        }
        let text = Self.stripThinking(raw)
        print("[QwenLLMService] Streamed \(text.count) chars in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        return text
    }

    /// Removes a leading <think>…</think> block if the model emits one.
    /// While streaming, an unterminated block is withheld entirely so the
    /// reasoning never flashes on screen before the answer starts.
    private static func stripThinking(_ s: String) -> String {
        if let close = s.range(of: "</think>") {
            return String(s[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if s.contains("<think>") { return "" }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum QwenError: LocalizedError {
        case notLoaded
        case loadStalled(String)
        var errorDescription: String? {
            switch self {
            case .notLoaded: "\(QwenLLMService.displayName) is not loaded."
            case .loadStalled(let name):
                "\(name) stopped responding while loading. Try again, or switch to the Foundation model."
            }
        }
    }
}
