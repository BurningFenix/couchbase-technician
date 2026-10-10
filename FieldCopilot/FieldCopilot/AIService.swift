import Foundation
import FoundationModels

enum AIService {
    /// OpenAI model used for the cloud answer mode.
    static let openAIModel = "gpt-5.1"

    enum ModelBackend: String, Sendable {
        case onDevice
        case qwen
        case openAI

        var displayName: String {
            switch self {
            case .onDevice: "On-Device Model"
            case .qwen: "\(QwenLLMService.displayName) (on-device)"
            case .openAI: "OpenAI \(AIService.openAIModel)"
            }
        }

        /// The user's Settings choice; the Foundation model is the default.
        static var preferred: ModelBackend {
            let stored = UserDefaults.standard.string(forKey: "modelBackend") ?? ModelBackend.onDevice.rawValue
            let backend = ModelBackend(rawValue: stored) ?? .onDevice
            if backend == .openAI && !AIConfig.hasOpenAIKey { return .onDevice }
            return backend
        }
    }

    struct Answer: Sendable {
        var text: String
        /// 1-based indices into the context array of the sources the
        /// model reports its answer is based on.
        var sourcesUsed: [Int]
        /// The backend that actually generated this answer (may differ
        /// from the requested one if the cloud call failed).
        var backend: ModelBackend
        /// Non-nil when the technician's message reported a fix the
        /// sources don't cover: a note worth saving for other techs.
        var novelFixNote: String?
        /// Tools the agent called while producing this answer.
        var toolCalls: [ToolActivity] = []
    }

    struct ConversationTurn: Sendable {
        var isUser: Bool
        var text: String
    }

    // On-device schemas stay SMALL: the beta guided-generation daemon is
    // reliable with the original two-field shape but can stall on larger
    // schemas, so answer and fix-detection run as two separate calls.
    @Generable(description: "An answer to a technician's question with the sources it is based on")
    struct CitedAnswer {
        @Guide(description: "The answer to the question, citing manual name, section, and page. Concise and practical.")
        var answer: String

        @Guide(description: "The 1-based numbers of the SOURCE blocks the answer is actually based on. Only include sources whose content directly supports the answer.")
        var sourcesUsed: [Int]
    }

    @Generable(description: "Classification of whether a technician message reports a newly discovered fix")
    struct FixCheck {
        @Guide(description: "true ONLY when the technician's message reports a fix or root cause they discovered themselves in the field that the listed sources do not cover. false for questions or symptom reports.")
        var reportsNovelFix: Bool

        @Guide(description: "When reportsNovelFix is true: a concise 1-3 sentence field note describing the symptom, root cause, and fix, written to help other technicians. Empty string otherwise.")
        var novelFixNote: String
    }

    // MARK: - Message routing

    enum MessageRoute: Sendable {
        /// Chat that needs no manual lookup (greeting, thanks, banter).
        case conversation
        /// Needs retrieval; query is the message rewritten to stand alone
        /// (follow-ups get the conversation topic folded in).
        case search(query: String)
    }

    @Generable(description: "Routing decision for one technician chat message")
    struct RouteDecision {
        @Guide(description: "conversation: a greeting, thanks, acknowledgment, or small talk that needs no manual lookup. search: a technical question or follow-up, OR the technician reporting a symptom, an observation, or a fix they made in the field - anything that should be checked against the manuals.", .anyOf(["conversation", "search"]))
        var kind: String

        @Guide(description: "For a search: the message rewritten as one self-contained search query, folding in the equipment model and topic from the conversation when it is a follow-up. Empty string for conversation.")
        var searchQuery: String
    }

    /// Classifies a message before any retrieval runs. Fail-soft: on any
    /// error the message is treated as a search (today's behavior).
    static func route(_ message: String, conversation: [ConversationTurn]) async -> MessageRoute {
        guard SystemLanguageModel.default.availability == .available else {
            return .search(query: message)
        }

        var historyBlock = ""
        if !conversation.isEmpty {
            historyBlock = "Recent conversation:\n"
            for turn in conversation.suffix(4) {
                historyBlock += "\(turn.isUser ? "Technician" : "Assistant"): \(turn.text.prefix(200))\n"
            }
            historyBlock += "\n"
        }

        let instructions = """
        You route one technician chat message for a field-service assistant that can search equipment manuals. \
        Classify the message and, when a manual lookup is needed, produce one self-contained search query.
        """
        let prompt = "\(historyBlock)Technician's message: \(message)"

        do {
            let decision = try await withThrowingTaskGroup(of: (String, String).self) { group in
                group.addTask {
                    let session = LanguageModelSession(instructions: instructions)
                    let response = try await session.respond(
                        to: prompt,
                        generating: RouteDecision.self,
                        options: GenerationOptions(samplingMode: .greedy)
                    )
                    return (response.content.kind, response.content.searchQuery)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(20))
                    throw AIError.generationTimedOut
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else { throw AIError.generationTimedOut }
                return first
            }
            print("[AIService] Route: \(decision.0), query: \(decision.1)")
            if decision.0 == "conversation" { return .conversation }
            let query = decision.1.trimmingCharacters(in: .whitespacesAndNewlines)
            return .search(query: query.isEmpty ? message : query)
        } catch {
            print("[AIService] Router skipped (\(error))")
            return .search(query: message)
        }
    }

    /// Direct conversational reply - no retrieval, no citations.
    static func converse(
        _ message: String,
        conversation: [ConversationTurn],
        preferredBackend: ModelBackend = .onDevice
    ) async throws -> Answer {
        var historyBlock = ""
        if !conversation.isEmpty {
            historyBlock = "Conversation so far:\n"
            for turn in conversation.suffix(8) {
                historyBlock += "\(turn.isUser ? "Technician" : "Assistant"): \(turn.text)\n"
            }
            historyBlock += "\n"
        }

        let instructions = """
        You are Field Assist, a friendly assistant built into the FieldCopilot app for HVAC field technicians. \
        Reply briefly and naturally. When the technician asks a technical question you can search their synced \
        equipment manuals and shared field notes, so you may mention that ability when it helps.
        """
        let prompt = "\(historyBlock)Technician's message: \(message)"

        if preferredBackend == .qwen,
           let text = try? await QwenLLMService.shared.generate(
               instructions: instructions, prompt: prompt, maxTokens: 200) {
            return Answer(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                          sourcesUsed: [], backend: .qwen, novelFixNote: nil)
        }

        if preferredBackend == .openAI,
           let cloud = try? await openAIConverse(instructions: instructions, prompt: prompt) {
            return cloud
        }

        guard SystemLanguageModel.default.availability == .available else {
            throw AIError.modelUnavailable
        }

        let text = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let session = LanguageModelSession(instructions: instructions)
                let response = try await session.respond(to: prompt, options: GenerationOptions(samplingMode: .greedy))
                return response.content
            }
            group.addTask {
                try await Task.sleep(for: .seconds(45))
                throw AIError.generationTimedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw AIError.generationTimedOut }
            return first
        }
        return Answer(text: text, sourcesUsed: [], backend: .onDevice, novelFixNote: nil)
    }

    private static func openAIConverse(instructions: String, prompt: String) async throws -> Answer {
        guard let apiKey = AIConfig.openAIKey else { throw AIError.openAIKeyMissing }
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": openAIModel,
            "messages": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": prompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIError.openAIRequestFailed(String(data: data, encoding: .utf8) ?? "no body")
        }
        let decoded = try JSONDecoder().decode(OpenAIChatResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            throw AIError.openAIRequestFailed("unexpected response shape")
        }
        return Answer(text: content, sourcesUsed: [], backend: .openAI, novelFixNote: nil)
    }

    static func answerQuestion(
        _ question: String,
        context: [SearchResult],
        conversation: [ConversationTurn] = [],
        preferredBackend: ModelBackend = .onDevice,
        detectFixes: Bool = true,
        onStatus: (@Sendable (String) -> Void)? = nil,
        onPartial: (@Sendable (String) -> Void)? = nil,
        onToolCall: (@Sendable (ToolActivity) -> Void)? = nil
    ) async throws -> Answer {
        let sources = Array(context.prefix(5))
        // Every backend gets the same tools and reports calls into this log,
        // so the chat can show what the agent ran, whichever model answered.
        let toolLog = ToolCallLog { activity in
            onStatus?("\(activity.title): \(activity.result) — writing answer…")
            onToolCall?(activity)
        }
        var contextBlock = ""
        for (i, chunk) in sources.enumerated() {
            if chunk.page == 0 && !chunk.isFieldNote {
                // The job briefing (reported issue + history), not a manual.
                contextBlock += """
                --- SOURCE \(i + 1) (\(chunk.manualTitle.uppercased()) - the job you are on, not a manual) ---
                Content: \(chunk.text)

                """
            } else if chunk.isFieldNote {
                contextBlock += """
                --- SOURCE \(i + 1) (SHARED FIELD NOTE from technician \(chunk.fieldNoteAuthor ?? "unknown"), not from a manual) ---
                Content: \(chunk.text)

                """
            } else {
                contextBlock += """
                --- SOURCE \(i + 1) ---
                Manual: \(chunk.manualTitle)
                Section: \(chunk.section)
                Page: \(chunk.page)
                Content: \(chunk.text)

                """
            }
        }

        var historyBlock = ""
        if !conversation.isEmpty {
            historyBlock = "Conversation so far:\n"
            for turn in conversation.suffix(8) {
                historyBlock += "\(turn.isUser ? "Technician" : "Assistant"): \(turn.text)\n"
            }
            historyBlock += "\n"
        }

        let baseInstructions = """
        You are a helpful field technician assistant. Answer the technician's latest message based on the provided source material and the conversation. \
        Read every source carefully before answering - the most relevant source may appear at any position in the list. \
        Technicians describe symptoms in everyday words; if a source describes a likely cause or fix for the symptom, \
        explain it even when the source uses different wording than the question. \
        Only say the information is not available when no source is plausibly related. \
        Cite the manual name, section, and page number; cite shared field notes as field notes. Be concise and practical. \
        Report which numbered sources you based the answer on. \
        If the technician reports a fix they discovered that no source covers, acknowledge it. \
        You have a refrigerantCalculator tool. Whenever the technician gives a pressure reading and asks about \
        superheat, subcooling, saturation temperature, or whether the charge or readings are OK, call the tool \
        first and use its numbers - never work out saturation temperatures yourself. When the technician gives a \
        pressure AND a line temperature, always pass both: suction pressure + suction line temperature is superheat, \
        head pressure + liquid line temperature is subcooling (which is how charge is verified). Use the unit's refrigerant \
        from the work order (R-410A if not stated). Then compare the result to the target range in the sources \
        and say plainly what it means and what to do next.
        """
        // The cloud model handles the combined 4-field schema in one call.
        let instructions = baseInstructions
            + " If the technician reports a fix they discovered that no source covers, also produce a field note for it."

        let prompt = """
        Here is reference material from equipment service manuals and shared field notes:

        \(contextBlock)
        \(historyBlock)Based on the reference material\(conversation.isEmpty ? "" : " and the conversation"), answer the technician's latest message: \(question)
        """

        if preferredBackend == .qwen {
            do {
                // Qwen (MLX, no guided generation) is asked for a PLAIN
                // prose answer only - forcing a multi-field JSON contract
                // on a 4B model makes it emit a long "Thinking Process"
                // preamble that buries the answer. Field-note detection is
                // delegated to the Foundation model's guided call, which is
                // reliable at that structured task.
                let text = try await QwenLLMService.shared.generate(
                    instructions: baseInstructions, prompt: prompt,
                    tools: [AgentTools.calculatorSchema],
                    toolDispatch: { name, args in AgentTools.dispatch(name: name, arguments: args, log: toolLog) },
                    onStatus: onStatus, onPartial: onPartial)
                let answerText = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !answerText.isEmpty else { throw AIError.generationTimedOut }
                var novelFix: String?
                if detectFixes {
                    onStatus?("Checking for new field knowledge…")
                    novelFix = await detectNovelFix(latestMessage: question, assistantAnswer: answerText, sources: sources)
                }
                return Answer(text: answerText, sourcesUsed: [], backend: .qwen, novelFixNote: novelFix,
                              toolCalls: toolLog.all)
            } catch {
                // Local-first resilience: Qwen model trouble (still loading,
                // memory pressure, or a stalled load) falls back to the
                // Foundation model so the demo never dead-ends.
                print("[AIService] Qwen failed (\(error)), falling back to Foundation model")
                onStatus?("Qwen unavailable — using Foundation model…")
            }
        }

        if preferredBackend == .openAI {
            do {
                return try await askOpenAI(instructions: instructions, prompt: prompt, sourceCount: sources.count, toolLog: toolLog)
            } catch {
                // Offline-first: any cloud failure falls back to on-device.
                print("[AIService] OpenAI failed (\(error)), falling back to on-device")
            }
        }

        guard SystemLanguageModel.default.availability == .available else {
            throw AIError.modelUnavailable
        }

        print("[AIService] Sending prompt via on-device model with \(sources.count) sources (~\(prompt.count) chars)")
        let start = Date()
        do {
            let raw = try await respondWithRetry(instructions: baseInstructions, prompt: prompt, toolLog: toolLog,
                                                 offerTools: AgentTools.hasPressureReading(question),
                                                 onStatus: onStatus, onPartial: onPartial)
            let valid = raw.sourcesUsed.filter { (1...sources.count).contains($0) }
            print("[AIService] Generated in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
            print("[AIService] Response: \(raw.answer)")
            var novelFix: String?
            if detectFixes {
                onStatus?("Checking for new field knowledge…")
                novelFix = await detectNovelFix(latestMessage: question, assistantAnswer: raw.answer, sources: sources)
            }
            print("[AIService] Sources used: \(valid), novelFix: \(novelFix != nil)")
            return Answer(text: raw.answer, sourcesUsed: valid, backend: .onDevice, novelFixNote: novelFix,
                          toolCalls: toolLog.all)
        } catch {
            // Last resort: if the on-device model is stuck or broken and
            // a cloud key exists, rescue the answer via OpenAI.
            if !(error is CancellationError), AIConfig.hasOpenAIKey {
                print("[AIService] On-device generation failed (\(error)) — attempting OpenAI rescue")
                onStatus?("On-device model stuck — trying cloud…")
                if let rescued = try? await askOpenAI(instructions: instructions, prompt: prompt, sourceCount: sources.count, toolLog: toolLog) {
                    return rescued
                }
            }
            throw error
        }
    }

    private struct RawAnswer: Sendable {
        let answer: String
        let sourcesUsed: [Int]
    }

    /// One generation attempt with a hard watchdog timeout. The beta
    /// inference daemon can hang indefinitely on some inputs; without
    /// this the UI spins forever.
    private static func respondOnce(
        instructions: String,
        prompt: String,
        timeout: Double,
        toolLog: ToolCallLog,
        offerTools: Bool,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) async throws -> RawAnswer {
        try await withThrowingTaskGroup(of: RawAnswer.self) { group in
            group.addTask {
                // The framework runs any tool calls the model makes before
                // the guided answer starts streaming.
                let session = LanguageModelSession(
                    tools: offerTools ? [AgentTools.RefrigerantCalculatorTool(log: toolLog)] : [],
                    instructions: instructions)
                // Stream the guided generation: the `answer` field fills in
                // token by token (sourcesUsed lands at the end), so we emit
                // the growing answer for a live typewriter effect.
                let stream = session.streamResponse(
                    to: prompt,
                    generating: CitedAnswer.self,
                    options: GenerationOptions(samplingMode: .greedy)
                )
                var answer = ""
                var sources: [Int] = []
                for try await snapshot in stream {
                    if let partial = snapshot.content.answer, partial.count > answer.count {
                        answer = partial
                        onPartial?(partial)
                    }
                    if let used = snapshot.content.sourcesUsed { sources = used }
                }
                return RawAnswer(answer: answer, sourcesUsed: sources)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw AIError.generationTimedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else {
                throw AIError.generationTimedOut
            }
            return first
        }
    }

    /// Second, deliberately tiny guided call: does the technician's
    /// message report a fix the sources don't cover? Short prompt, short
    /// schema - the shape the on-device daemon handles reliably. Fail-soft:
    /// detection is an enhancement, never worth failing the answer over.
    /// Callable on its own so the chat can show the answer first and run
    /// this in the background (it is a second serial model call).
    static func detectNovelFix(latestMessage: String, assistantAnswer: String, sources: [SearchResult]) async -> String? {
        let sourceList = sources.prefix(4).map { s in
            let head = s.isFieldNote
                ? "Shared field note by \(s.fieldNoteAuthor ?? "a tech")"
                : "\(s.manualTitle), \(s.section)"
            return "- \(head): \(s.text.prefix(140))"
        }.joined(separator: "\n")

        // Give the classifier both the manual material AND the answer we just
        // gave, so it decides novelty by COMPARING the tech's report against
        // what was already known - not by looking for an explicit "not in the
        // manual" phrase.
        let instructions = """
        Compare a technician's latest message against the manual material and the answer that was just given to them. Decide whether the technician is reporting a NEW fix or root cause they found in the field - a specific cause or repair that the material and the answer do not already describe. If the cause or repair they describe is not present in that material, it is new and worth saving for other techs. A plain question, a symptom with no fix, or something already covered in the material is NOT new.
        """
        let prompt = """
        Manual material used:
        \(sourceList)

        The answer already given to the technician: \(assistantAnswer.prefix(500))

        The technician's latest message: \(latestMessage)
        """

        do {
            let result = try await withThrowingTaskGroup(of: (Bool, String).self) { group in
                group.addTask {
                    let session = LanguageModelSession(instructions: instructions)
                    let response = try await session.respond(
                        to: prompt,
                        generating: FixCheck.self,
                        options: GenerationOptions(samplingMode: .greedy)
                    )
                    return (response.content.reportsNovelFix, response.content.novelFixNote)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(30))
                    throw AIError.generationTimedOut
                }
                defer { group.cancelAll() }
                guard let first = try await group.next() else {
                    throw AIError.generationTimedOut
                }
                return first
            }
            return result.0 && !result.1.isEmpty ? result.1 : nil
        } catch {
            print("[AIService] Fix-check skipped (\(error))")
            return nil
        }
    }

    /// On-device generation fails transiently in two ways: the system
    /// rate-limits rapid successive requests, and the beta inference
    /// daemon occasionally dies underneath the framework (opaque
    /// ModelManagerError). Both get retries with a FRESH session each
    /// attempt (a new session reconnects to the daemon). Deterministic
    /// errors (guardrails, context size, refusal) fail immediately.
    private static func respondWithRetry(
        instructions: String,
        prompt: String,
        toolLog: ToolCallLog,
        offerTools: Bool,
        maxRetries: Int = 3,
        onStatus: (@Sendable (String) -> Void)? = nil,
        onPartial: (@Sendable (String) -> Void)? = nil
    ) async throws -> RawAnswer {
        var attempt = 0
        var timeoutRetries = 0
        while true {
            do {
                return try await respondOnce(instructions: instructions, prompt: prompt, timeout: 60,
                                             toolLog: toolLog, offerTools: offerTools, onPartial: onPartial)
            } catch {
                if error is CancellationError { throw error }

                // A hung generation rarely recovers on retry: allow one,
                // then bail (the caller may rescue via cloud).
                if case AIError.generationTimedOut = error {
                    guard timeoutRetries < 1 else { throw error }
                    timeoutRetries += 1
                    print("[AIService] Generation timed out after 60s, retrying once")
                    onStatus?("Taking too long — retrying…")
                    continue
                }

                var isRateLimit = false
                if let lmError = error as? LanguageModelError {
                    switch lmError {
                    case .guardrailViolation, .refusal, .contextSizeExceeded,
                         .unsupportedGenerationGuide, .unsupportedLanguageOrLocale,
                         .unsupportedCapability, .unsupportedTranscriptContent:
                        throw error
                    case .rateLimited:
                        isRateLimit = true
                    default:
                        break
                    }
                }

                guard attempt < maxRetries else { throw error }
                attempt += 1
                let delay = isRateLimit ? Double(attempt) * 2.0 : Double(attempt)
                print("[AIService] \(isRateLimit ? "Rate limited" : "Transient failure (\(error))"), retrying in \(delay)s (\(attempt)/\(maxRetries))")
                onStatus?(isRateLimit
                    ? "System busy — retrying (\(attempt)/\(maxRetries))…"
                    : "Model hiccup — retrying (\(attempt)/\(maxRetries))…")
                try await Task.sleep(for: .seconds(delay))
                onStatus?("Generating…")
            }
        }
    }

    // MARK: - OpenAI backend

    private struct OpenAIChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    private static func askOpenAI(instructions: String, prompt: String, sourceCount: Int,
                                  toolLog: ToolCallLog) async throws -> Answer {
        guard let apiKey = AIConfig.openAIKey else {
            throw AIError.openAIKeyMissing
        }

        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "answer": [
                    "type": "string",
                    "description": "The answer, citing manual name, section, and page."
                ],
                "sourcesUsed": [
                    "type": "array",
                    "items": ["type": "integer"],
                    "description": "1-based numbers of the SOURCE blocks the answer is based on."
                ],
                "reportsNovelFix": [
                    "type": "boolean",
                    "description": "true ONLY when the technician's latest message reports a fix or root cause they discovered in the field that no provided source covers."
                ],
                "novelFixNote": [
                    "type": "string",
                    "description": "When reportsNovelFix is true: a concise 1-3 sentence field note describing symptom, root cause, and fix. Empty string otherwise."
                ]
            ],
            "required": ["answer", "sourcesUsed", "reportsNovelFix", "novelFixNote"],
            "additionalProperties": false
        ]
        var messages: [[String: Any]] = [
            ["role": "system", "content": instructions],
            ["role": "user", "content": prompt]
        ]

        // Function-calling loop: the model may call the calculator before
        // producing the final structured answer. Capped so a confused model
        // can't loop forever.
        var content: String?
        for round in 0..<4 {
            let body: [String: Any] = [
                "model": openAIModel,
                "messages": messages,
                "tools": [AgentTools.calculatorSchema],
                "response_format": [
                    "type": "json_schema",
                    "json_schema": ["name": "cited_answer", "strict": true, "schema": schema]
                ]
            ]
            print("[AIService] Sending prompt via OpenAI (\(openAIModel)), round \(round + 1)")
            let message = try await openAIChatMessage(apiKey: apiKey, body: body)
            guard let toolCalls = message["tool_calls"] as? [[String: Any]], !toolCalls.isEmpty else {
                content = message["content"] as? String
                break
            }
            messages.append(message)
            for call in toolCalls {
                let function = call["function"] as? [String: Any] ?? [:]
                let argsJSON = (function["arguments"] as? String ?? "{}").data(using: .utf8) ?? Data()
                let args = (try? JSONSerialization.jsonObject(with: argsJSON)) as? [String: Any] ?? [:]
                let output = AgentTools.dispatch(name: function["name"] as? String ?? "", arguments: args, log: toolLog)
                messages.append(["role": "tool", "tool_call_id": call["id"] as? String ?? "", "content": output])
            }
        }

        guard let content,
              let contentData = content.data(using: .utf8),
              let parsed = try JSONSerialization.jsonObject(with: contentData) as? [String: Any],
              let answerText = parsed["answer"] as? String else {
            throw AIError.openAIRequestFailed("unexpected response shape")
        }

        let used = (parsed["sourcesUsed"] as? [Int] ?? []).filter { (1...sourceCount).contains($0) }
        let novelFix = (parsed["reportsNovelFix"] as? Bool ?? false)
            ? (parsed["novelFixNote"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            : nil
        print("[AIService] OpenAI response: \(answerText)")
        print("[AIService] Sources used: \(used), novelFix: \(novelFix != nil)")
        return Answer(text: answerText, sourcesUsed: used, backend: .openAI, novelFixNote: novelFix,
                      toolCalls: toolLog.all)
    }

    /// One chat-completions round trip, returning the raw assistant message
    /// (kept as a dictionary so tool_calls can be echoed back verbatim).
    private static func openAIChatMessage(apiKey: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AIError.openAIRequestFailed(String(data: data, encoding: .utf8) ?? "no body")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw AIError.openAIRequestFailed("unexpected response shape")
        }
        return message
    }

    enum AIError: LocalizedError {
        case modelUnavailable
        case openAIKeyMissing
        case openAIRequestFailed(String)
        case generationTimedOut

        var errorDescription: String? {
            switch self {
            case .modelUnavailable:
                "Apple Intelligence is not available on this device. Please use an Apple Intelligence-eligible device with the models downloaded."
            case .openAIKeyMissing:
                "No OpenAI API key configured. Add OPENAI_API_KEY to Secrets.xcconfig."
            case .openAIRequestFailed(let detail):
                "OpenAI request failed: \(detail)"
            case .generationTimedOut:
                "The on-device model did not respond in time. Try again, or restart the device if this persists."
            }
        }
    }
}
