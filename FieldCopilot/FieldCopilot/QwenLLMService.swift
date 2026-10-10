import Foundation
import MLX
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
    /// The model's full native window (`max_position_embeddings`). Only 8 of
    /// its 32 layers are full attention, so the KV cache grows on those
    /// alone - long chats are far cheaper than on a classic transformer.
    static let contextSize = 262_144

    private var container: ModelContainer?
    private var loadTask: Task<Void, Error>?

    private init() {}

    var isLoaded: Bool { container != nil }

    /// Exact token count with Qwen's own tokenizer; nil until loaded.
    func tokenCount(_ text: String) async -> Int? {
        guard let container else { return nil }
        return await container.encode(text).count
    }

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

    /// MLX keeps freed GPU buffers in a reuse cache that by default may grow
    /// to its whole memory limit (1.5x the device's recommended working set).
    /// On iPhone, every answer's KV cache and activations piled up there turn
    /// after turn until iOS killed the app under CriticalMemoryPressure. A
    /// small cap costs no measurable speed (MLX's own docs suggest ~MBs).
    static let gpuCacheLimit = 32 * 1024 * 1024

    /// Releases cached GPU buffers. Called after every generation and on
    /// iOS memory warnings.
    nonisolated static func releaseCachedMemory() {
        Memory.clearCache()
    }

    private func performLoad(onProgress: (@Sendable (LoadProgress) -> Void)?) async throws {
        Memory.cacheLimit = Self.gpuCacheLimit
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
        // Prompt is processed in chunks of this many tokens. 128 instead of
        // the default 512 cut peak memory per answer from ~1.2 GB to ~0.5 GB
        // above the weights, at no measurable speed cost (measured on M-series
        // with a growing 6-turn chat).
        parameters.prefillStepSize = 128

        let start = Date()
        // Each round's session (KV cache + activations) is dropped when the
        // round ends; hand that memory back instead of letting it pile up.
        defer { Self.releaseCachedMemory() }

        // Our own tool loop instead of ChatSession's `toolDispatch`. After a
        // tool call, ChatSession continues by templating ONLY the tool-result
        // message (leaning on its KV cache for the rest), and Qwen3.5's chat
        // template rejects any message list without a user turn ("No user
        // query found in messages") - so every Qwen tool call failed and the
        // answer fell back to the Foundation model. Here each round is a
        // fresh session given the WHOLE exchange: question, the assistant's
        // tool call, and the tool's result.
        var messages: [Chat.Message] = [.user(prompt)]
        var text = ""
        for round in 1...Self.maxToolRounds {
            // Qwen3.5 dropped the "/no_think" soft switch; thinking is turned
            // off through the chat template instead (it then emits an empty
            // <think></think>, which stripThinking removes).
            let session = ChatSession(
                container, instructions: instructions, generateParameters: parameters,
                additionalContext: ["enable_thinking": false],
                tools: tools)

            var raw = ""
            var calls: [ToolCall] = []
            for try await item in session.streamDetails(to: messages) {
                switch item {
                case .chunk(let chunk):
                    raw += chunk
                    let display = Self.stripThinking(raw)
                    if !display.isEmpty { onPartial?(display) }
                case .toolCall(let call):
                    calls.append(call)
                case .info:
                    break
                }
            }
            text = Self.stripThinking(raw)

            // No tool call (or nowhere to dispatch it): this is the answer.
            guard !calls.isEmpty, let toolDispatch, round < Self.maxToolRounds else { break }
            messages.append(.assistant(text, toolCalls: calls))
            for call in calls {
                let result = toolDispatch(call.function.name, call.function.arguments.mapValues(\.anyValue))
                messages.append(.tool(result, id: call.id))
            }
            print("[QwenLLMService] Round \(round): \(calls.count) tool call(s), continuing")
            Self.releaseCachedMemory()
        }
        print("[QwenLLMService] Generated \(text.count) chars in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        return text
    }

    /// Generation passes per answer: tool calls then a final reply. A cap so
    /// a model that keeps calling tools can't loop forever.
    private static let maxToolRounds = 4

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
