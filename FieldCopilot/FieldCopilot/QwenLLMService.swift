import Foundation
import HuggingFace
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import Tokenizers

/// Qwen3-4B (4-bit) running locally via MLX. NOT bundled: the ~2.2 GB
/// weights download from the Hugging Face Hub on demand the first time
/// the user selects this model, then cache. Requires the
/// increased-memory-limit entitlement.
///
/// Note on model choice: Qwen3.5-4B was tried twice and removed. It is a
/// vision-language model, so it needs MLX's VLM factory (the text-only
/// `LLMModelFactory` hangs forever building it). Loaded that way it *does*
/// run and answer, but it crashed on the second question on-device: its
/// weights carry a vision tower this app never uses, and the app already
/// keeps the 1.1 GB Core AI embedding model resident. Not worth the memory.
actor QwenLLMService {
    static let shared = QwenLLMService()
    static let modelId = "mlx-community/Qwen3-4B-4bit"
    static let displayName = "Qwen3 4B"

    private var container: ModelContainer?
    private var loadTask: Task<Void, Error>?

    private init() {}

    var isLoaded: Bool { container != nil }

    /// One progress update from `load`. `fraction` is non-nil only during
    /// the byte-download phase; it is nil for the "loading weights into
    /// memory / compiling kernels" phase, which reports no byte progress
    /// and can take 20-40s — the UI should show an indeterminate spinner
    /// there so a frozen MB count is never mistaken for a hang.
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
        let configuration = ModelConfiguration(id: Self.modelId)
        let name = Self.displayName
        onProgress?(LoadProgress(message: "Preparing \(name)…", fraction: nil))
        // The HuggingFace downloader's NSProgress reports 0 bytes until the
        // large weight file finishes on-device (verified: the callback fires
        // ~10×/s but completedUnitCount stays 0 the whole download), so a
        // determinate bar would just sit at 0%. Instead we show a moving
        // elapsed-time indicator — honest and clearly alive — and only fall
        // back to a real % bar if the platform ever does report bytes.
        let downloadStart = Date()
        // Heartbeat: every progress callback stamps this; the watchdog below
        // fails the load if it goes quiet for too long.
        let heartbeat = Heartbeat()

        container = try await withThrowingTaskGroup(of: ModelContainer?.self) { group in
            group.addTask {
                try await LLMModelFactory.shared.loadContainer(
                    from: #hubDownloader(),
                    using: #huggingFaceTokenizerLoader(),
                    configuration: configuration
                ) { progress in
                    Task { await heartbeat.beat() }
                    let done = progress.completedUnitCount
                    let total = progress.totalUnitCount
                    let fraction = progress.fractionCompleted
                    if progress.isFinished || fraction >= 0.999 {
                        onProgress?(LoadProgress(message: "Loading \(name) into memory… (20-40s)", fraction: nil))
                    } else if done > 5_000_000, total > 10_000_000, fraction > 0.01 {
                        // Real byte progress is available → determinate bar.
                        onProgress?(LoadProgress(
                            message: "Downloading \(name) — \(Int(fraction * 100))% (\(done / 1_048_576) of \(total / 1_048_576) MB)",
                            fraction: fraction))
                    } else {
                        let secs = Int(Date().timeIntervalSince(downloadStart))
                        onProgress?(LoadProgress(message: "Downloading \(name)… \(secs)s elapsed (~2.2 GB)", fraction: nil))
                    }
                }
            }
            group.addTask {
                while true {
                    try await Task.sleep(for: .seconds(5))
                    if await heartbeat.silence > Self.stallTimeout {
                        throw QwenError.loadStalled(name)
                    }
                }
            }
            defer { group.cancelAll() }
            // The loader finishes first on success; the watchdog only wins if
            // the load goes quiet past the timeout.
            while let result = try await group.next() {
                if let container = result { return container }
            }
            throw QwenError.loadStalled(name)
        }
        print("[QwenLLMService] Model loaded")
    }

    func generate(instructions: String, prompt: String, maxTokens: Int = 700,
                  onStatus: (@Sendable (String) -> Void)? = nil,
                  onPartial: (@Sendable (String) -> Void)? = nil) async throws -> String {
        try await load { onStatus?($0.message) }
        guard let container else { throw QwenError.notLoaded }

        var parameters = GenerateParameters()
        parameters.maxTokens = maxTokens
        parameters.temperature = 0.0
        parameters.kvBits = 4

        let start = Date()
        let session = ChatSession(container, instructions: instructions, generateParameters: parameters)
        let fullPrompt = prompt + " /no_think"  // template honors this on Qwen3

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
            case .notLoaded: "Qwen3 4B is not loaded."
            case .loadStalled(let name):
                "\(name) stopped responding while loading. Try again, or switch to the Foundation model."
            }
        }
    }
}

/// Tracks how long it's been since the last progress callback.
private actor Heartbeat {
    private var last = Date()
    func beat() { last = Date() }
    var silence: TimeInterval { Date().timeIntervalSince(last) }
}
