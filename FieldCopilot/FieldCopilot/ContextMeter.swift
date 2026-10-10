import Foundation
import FoundationModels

/// How full the model's context window will be for the NEXT question,
/// broken down the way the context popover shows it.
struct ContextUsage: Equatable, Sendable {
    enum Kind: Sendable { case instructions, workOrder, manuals, conversation, reserve }

    struct Segment: Equatable, Sendable, Identifiable {
        let kind: Kind
        let label: String
        let tokens: Int
        var id: String { label }
    }

    let limit: Int
    let modelName: String
    let segments: [Segment]
    /// True when every count came from the model's own tokenizer.
    let isExact: Bool

    var total: Int { segments.reduce(0) { $0 + $1.tokens } }
    var fraction: Double { limit > 0 ? min(1, Double(total) / Double(limit)) : 0 }
    var percent: Int { Int((fraction * 100).rounded()) }
    var conversationTokens: Int { segments.first { $0.kind == .conversation }?.tokens ?? 0 }
}

/// Measures the prompt AIService would build against the selected model's
/// window. Counts exactly where the model exposes a tokenizer (Apple's
/// Foundation model via `tokenCount(for:)`, Qwen once loaded), and falls
/// back to a character estimate otherwise.
enum ContextMeter {
    /// Compaction kicks in at this fraction of the window when auto-compact is on.
    static let autoCompactThreshold = 0.85
    static let autoCompactKey = "autoCompact"

    static var autoCompactEnabled: Bool {
        UserDefaults.standard.object(forKey: autoCompactKey) as? Bool ?? true
    }

    static func limit(for backend: AIService.ModelBackend) -> Int {
        switch backend {
        case .onDevice: SystemLanguageModel.default.contextSize      // 8,192 on iOS 27
        case .qwen: QwenLLMService.contextSize                          // 262,144, the model's maximum
        case .openAI: 400_000                                           // GPT-5.1 input + output window
        }
    }

    static func modelName(for backend: AIService.ModelBackend) -> String {
        switch backend {
        case .onDevice: "Apple on-device model"
        case .qwen: "\(QwenLLMService.displayName) (on-device)"
        case .openAI: "OpenAI \(AIService.openAIModel)"
        }
    }

    static func measure(
        backend: AIService.ModelBackend,
        workOrder: SearchResult?,
        sources: [SearchResult],
        conversation: [AIService.ConversationTurn],
        summaryTurns: Int,
        liveTurns: Int
    ) async -> ContextUsage {
        let counter = Counter(backend: backend)

        // Instructions plus whatever the backend adds for tools and schema.
        var instructions = await counter.count(AIService.answerInstructions)
        if backend == .onDevice, let extra = try? await foundationOverhead() {
            instructions += extra
        } else {
            instructions += await counter.count(String(describing: AgentTools.calculatorSchema))
        }

        var workOrderTokens = 0
        if let workOrder { workOrderTokens = await counter.count(AIService.contextBlock(for: [workOrder])) }
        let manualTokens = sources.isEmpty ? 0 : await counter.count(AIService.contextBlock(for: sources))
        let conversationTokens = conversation.isEmpty ? 0 : await counter.count(AIService.historyBlock(for: conversation))

        var conversationLabel: String
        switch (summaryTurns > 0, liveTurns) {
        case (true, 0): conversationLabel = "Conversation summary"
        case (true, let n): conversationLabel = "Summary + \(n) turn\(n == 1 ? "" : "s")"
        case (false, let n): conversationLabel = "Conversation (\(n) turn\(n == 1 ? "" : "s"))"
        }

        var segments = [ContextUsage.Segment(kind: .instructions, label: "Instructions & tools", tokens: instructions)]
        if workOrderTokens > 0 {
            segments.append(.init(kind: .workOrder, label: "Work order", tokens: workOrderTokens))
        }
        segments.append(.init(kind: .manuals, label: "Manual excerpts (\(sources.count))", tokens: manualTokens))
        segments.append(.init(kind: .conversation, label: conversationLabel, tokens: conversationTokens))
        segments.append(.init(kind: .reserve, label: "Reserved for answer", tokens: AIService.answerReserveTokens))

        return ContextUsage(
            limit: limit(for: backend),
            modelName: modelName(for: backend),
            segments: segments,
            isExact: await counter.isExact)
    }

    /// Tool definitions and the guided-answer schema are injected into the
    /// Foundation model's prompt too; count them for an honest total.
    private static func foundationOverhead() async throws -> Int {
        let model = SystemLanguageModel.default
        let tools = try await model.tokenCount(for: [AgentTools.RefrigerantCalculatorTool(log: ToolCallLog())] as [any Tool])
        let schema = try await model.tokenCount(for: AIService.CitedAnswer.generationSchema)
        return tools + schema
    }

    /// Picks the most accurate counter available for the backend.
    private actor Counter {
        let backend: AIService.ModelBackend
        private(set) var isExact = true

        init(backend: AIService.ModelBackend) { self.backend = backend }

        func count(_ text: String) async -> Int {
            guard !text.isEmpty else { return 0 }
            switch backend {
            case .onDevice:
                if let n = try? await SystemLanguageModel.default.tokenCount(for: text) { return n }
            case .qwen:
                if let n = await QwenLLMService.shared.tokenCount(text) { return n }
            case .openAI:
                break
            }
            isExact = false
            // ~3 chars/token, measured on this app's technician text with the
            // Foundation tokenizer; close enough for a meter.
            return Int((Double(text.count) / 3.0).rounded(.up))
        }
    }
}
