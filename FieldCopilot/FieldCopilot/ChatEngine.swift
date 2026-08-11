import Foundation
import Observation

/// The two demo technicians. Switching users in Settings shows how a
/// field note saved by one tech surfaces for the next - the multi-user
/// sync story.
enum DemoUser: String, CaseIterable, Identifiable {
    case kyle, bj

    var id: String { rawValue }
    var displayName: String { self == .kyle ? "Kyle" : "BJ" }
    var role: String { self == .kyle ? "Senior technician" : "Technician" }
    var initials: String { self == .kyle ? "K" : "B" }
}

struct ChatMessage: Identifiable {
    enum Role { case user, bot }

    let id = UUID()
    var role: Role
    var text: String

    // Bot-message payload: the retrieval pool and per-mode answers so
    // the sources sheet can compare rankings and re-run the LLM.
    var question: String = ""
    var rankedPool: [RankedSearchResult] = []
    var queryTokens: Set<String> = []
    var answers: [SearchMode: AIService.Answer] = [:]
    /// A shared field note from ANOTHER tech that reached the sources.
    var tip: SearchResult?
    /// True when this exchange stored a new field note.
    var savedNote: Bool = false
    var backend: AIService.ModelBackend = .onDevice

    var isUser: Bool { role == .user }
}

/// Conversation state for the Ask tab: multi-turn RAG over the manuals
/// and shared field notes, kept per demo user.
@Observable
@MainActor
final class ChatEngine {
    private(set) var conversations: [DemoUser: [ChatMessage]] = [:]
    private(set) var isTyping = false
    private(set) var isRerunning = false
    /// Live progress line under the typing indicator (model download etc).
    private(set) var statusText: String?
    /// Qwen prewarm progress shown in the chat header (nil when idle).
    private(set) var qwenStatus: String?
    /// Determinate download fraction (0...1) while Qwen weights download;
    /// nil during the indeterminate load-into-memory phase and when idle.
    private(set) var qwenProgress: Double?
    /// True once the Qwen model has finished downloading and loading.
    private(set) var qwenReady = false
    /// Set when Qwen failed to load, so Settings can say so instead of
    /// showing a silent never-ready state.
    private(set) var qwenLoadError: String?
    var mode: SearchMode = .hybrid
    /// Asset context chip: (display label, asset model used as filter).
    var assetContext: (label: String, model: String)?
    /// The work order the chat is currently helping close, if the tech
    /// started the chat from a job screen. Drives the reported-issue
    /// grounding, the parts-stock check, the scripted prompts, and the
    /// Complete/Skip flow.
    private(set) var activeJob: Job?
    /// The bot message currently offering Complete/Skip buttons.
    private(set) var pendingJobCompletionMessageId: UUID?

    var activeUser: DemoUser {
        get {
            DemoUser(rawValue: UserDefaults.standard.string(forKey: "activeUser") ?? "kyle") ?? .kyle
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "activeUser")
        }
    }

    /// Appended to the visible bubble (never to the cached per-mode answer)
    /// when an exchange stored a new field note, so switching search modes
    /// preserves the confirmation instead of re-generating or dropping it.
    static let savedNoteConfirmation = "\n\nI've saved your fix to the shared field-notes knowledge base and synced it - it'll surface for the next tech who hits this."

    private var preferredBackend: AIService.ModelBackend { .preferred }

    /// The bot message currently being streamed into, if any. Set when the
    /// first token arrives, cleared once the answer is finalized.
    private var streamingBotId: UUID?

    private weak var dbManager: DatabaseManager?

    func attach(_ dbManager: DatabaseManager) {
        self.dbManager = dbManager
    }

    var messages: [ChatMessage] { conversations[activeUser] ?? [] }

    var suggestions: [String] {
        // In a job chat, walk the tech through the scripted questions one at
        // a time (first question, then the follow-up), then hand off to the
        // Complete/Skip buttons.
        if let job = activeJob, let prompts = job.demoPrompts {
            let asked = (conversations[activeUser] ?? []).filter(\.isUser).count
            return asked < prompts.count ? [prompts[asked]] : []
        }
        if messages.isEmpty {
            return [
                "The AC-5000 is showing fault code E11 — what does that mean?",
                "There's a damp, musty smell when the AC first starts cooling. Any idea why?",
                "What should I keep an eye on around 380 psig?",
            ]
        }
        return [
            "Found the culprit — the liquid line was kinked where it runs behind the condenser mounting bracket. I straightened it out and the E11 cleared right up.",
            "And what about fault code F04?",
            "Which unit takes 24x24x2 filters?",
        ]
    }

    /// Begins a fresh, job-focused chat from a work-order screen: clears the
    /// current conversation, pins the reported issue as context, and drives
    /// the scripted prompts / parts-check / completion flow.
    func startJobChat(_ job: Job) {
        let user = activeUser
        conversations[user] = []
        pendingJobCompletionMessageId = nil
        activeJob = job
        assetContext = (label: "\(job.workOrderNumber) · \(job.title)", model: job.assetModel)
    }

    /// Clears the asset/job context chip and any pending completion buttons.
    func clearContext() {
        assetContext = nil
        activeJob = nil
        pendingJobCompletionMessageId = nil
    }

    /// Marks the active work order complete and confirms in the chat.
    func completeActiveJob() {
        guard let job = activeJob, let dbManager else { return }
        if var latest = try? dbManager.job(id: job.id) {
            latest.status = "Completed"
            try? dbManager.saveJob(latest)
        }
        let wo = job.workOrderNumber
        pendingJobCompletionMessageId = nil
        activeJob = nil
        assetContext = nil
        conversations[activeUser, default: []].append(
            ChatMessage(role: .bot, text: "✅ Done — I've marked \(wo) complete and signed you off. It'll show under Completed on your Work tab.")
        )
    }

    /// Dismisses the Complete/Skip buttons without completing (the tech can
    /// keep asking; the buttons return after the next answer).
    func dismissJobActions() {
        pendingJobCompletionMessageId = nil
    }

    /// A one-line parts-stock check for the job's required part, or nil.
    private func jobPartLine(_ job: Job) -> String? {
        guard let partNo = job.requiredPart, let dbManager,
              let part = try? dbManager.part(withNumber: partNo) else { return nil }
        let van = part.quantityOnHand
        let wh = part.warehouseQty ?? 0
        let status: String
        if van > 0 {
            status = "you've got \(van) on the van" + (wh > 0 ? " and \(wh) in the warehouse" : "") + " — you're set."
        } else if wh > 0 {
            status = "none on the van, but \(wh) in the warehouse — grab one before you roll out."
        } else {
            status = "none on the van or in the warehouse — this one needs a backorder."
        }
        return "\n\n🔧 Parts check — \(part.description) (\(part.partNumber)): \(status)"
    }

    /// Grounding context built from the work order itself: the reported
    /// problem plus recent service history for the asset.
    private func jobBriefing(_ job: Job) -> SearchResult {
        var history = ""
        if let recs = try? dbManager?.serviceHistory(forAssetTag: job.assetTag), !recs.isEmpty {
            history = " Recent service on this unit: " + recs.prefix(2)
                .map { "\($0.date), \($0.summary)" }.joined(separator: "; ") + "."
        }
        let text = "\(job.workOrderNumber) (\(job.priority) priority). Asset: \(job.assetName) \(job.assetTag), a \(job.assetModel). Reported problem: \(job.reported)\(history)"
        return SearchResult(
            chunkId: "wo::\(job.id)",
            manualTitle: "Work order \(job.workOrderNumber)",
            section: "Reported issue & history",
            page: 0,
            text: text,
            distance: nil
        )
    }

    private func top5(_ pool: [RankedSearchResult], mode: SearchMode) -> [RankedSearchResult] {
        Array(pool
            .sorted {
                let a = mode.rank(of: $0) ?? Int.max
                let b = mode.rank(of: $1) ?? Int.max
                if a != b { return a < b }
                return $0.hybridRank < $1.hybridRank
            }
            .prefix(5))
    }

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isTyping, let dbManager else { return }
        let user = activeUser

        conversations[user, default: []].append(ChatMessage(role: .user, text: trimmed))
        isTyping = true

        Task {
            do {
                let history = Array((conversations[user] ?? []).dropLast().map {
                    AIService.ConversationTurn(isUser: $0.isUser, text: $0.text)
                })

                // Route before retrieving: greetings and chit-chat get a
                // direct reply; follow-ups get rewritten into standalone
                // search queries so retrieval sees the full topic. The router
                // is itself a model call, so skip it for a first-turn message
                // that is clearly a substantive question — there's no prior
                // topic to fold in, so the raw message already stands alone,
                // and skipping removes a serial round-trip from the opener.
                let route: AIService.MessageRoute
                if history.isEmpty && (trimmed.count > 24 || trimmed.contains(where: \.isNumber)) {
                    route = .search(query: trimmed)
                } else {
                    statusText = "Understanding your question…"
                    route = await AIService.route(trimmed, conversation: history)
                }

                if case .conversation = route {
                    statusText = "Writing a reply…"
                    let answer = try await AIService.converse(
                        trimmed,
                        conversation: history,
                        preferredBackend: preferredBackend
                    )
                    var bot = ChatMessage(role: .bot, text: answer.text)
                    bot.backend = answer.backend
                    conversations[user, default: []].append(bot)
                    isTyping = false
                    statusText = nil
                    return
                }

                guard case .search(let searchQuery) = route else { return }

                statusText = "Searching your manuals…"
                let queryVector = try await EmbeddingService.shared.embedQuery(searchQuery)
                let pool = try dbManager.rankedSearch(
                    queryVector: queryVector,
                    queryText: searchQuery,
                    assetModel: assetContext?.model
                )
                let tokens = Set(SearchTokenizer.tokens(from: searchQuery))
                let top = top5(pool, mode: mode)

                statusText = "Reading sources & writing your answer…"
                streamingBotId = nil
                // In a job chat, lead the context with the work-order briefing
                // (reported issue + recent service) so the answer is grounded
                // in this specific job, not just the manuals.
                var contextResults = top.map(\.result)
                if let job = activeJob { contextResults.insert(jobBriefing(job), at: 0) }
                // detectFixes:false — the field-note check is a second serial
                // model call, so we defer it (below) and show the answer first.
                // onPartial streams the answer token by token into the bubble.
                let answer = try await AIService.answerQuestion(
                    trimmed,
                    context: contextResults,
                    conversation: history,
                    preferredBackend: preferredBackend,
                    detectFixes: false,
                    onStatus: { [weak self] status in
                        Task { @MainActor in
                            // Status only shows before the first token lands.
                            guard let self, self.streamingBotId == nil else { return }
                            self.statusText = status
                        }
                    },
                    onPartial: { [weak self] partial in
                        Task { @MainActor in self?.streamPartial(partial, user: user, question: trimmed) }
                    }
                )

                // Surface any field note that reached the sources — including
                // one this tech saved themselves. (It used to require a
                // different author, which meant your own note never showed up
                // after you saved it.) The card labels the author, so a note
                // from another tech still reads as shared knowledge.
                let tip = top.first(where: { $0.result.isFieldNote })?.result

                // Job chat: append the agentic parts-stock check, and once the
                // scripted questions are done, invite the tech to close it out.
                var finalText = answer.text
                var offerCompletion = false
                if let job = activeJob {
                    if let partLine = jobPartLine(job) { finalText += partLine }
                    let asked = (conversations[user] ?? []).filter(\.isUser).count
                    if asked >= (job.demoPrompts?.count ?? 0) {
                        finalText += "\n\nDoes that give you what you need to close out \(job.workOrderNumber)?"
                        offerCompletion = true
                    }
                }

                // Finalize: fill in the retrieval payload on the streamed
                // bubble (or create it now if nothing streamed, e.g. OpenAI).
                // The raw per-mode answer is cached; any field-note
                // confirmation is appended later by detectAndSaveFix.
                let botId: UUID
                if let id = streamingBotId,
                   let idx = conversations[user]?.firstIndex(where: { $0.id == id }) {
                    conversations[user]?[idx].text = finalText
                    conversations[user]?[idx].rankedPool = pool
                    conversations[user]?[idx].queryTokens = tokens
                    conversations[user]?[idx].answers[mode] = answer
                    conversations[user]?[idx].tip = tip
                    conversations[user]?[idx].backend = answer.backend
                    botId = id
                } else {
                    var bot = ChatMessage(role: .bot, text: finalText)
                    bot.question = trimmed
                    bot.rankedPool = pool
                    bot.queryTokens = tokens
                    bot.answers[mode] = answer
                    bot.tip = tip
                    bot.backend = answer.backend
                    botId = bot.id
                    conversations[user, default: []].append(bot)
                }
                streamingBotId = nil
                isTyping = false
                statusText = nil
                if offerCompletion { pendingJobCompletionMessageId = botId }

                // Answer is on screen; now run the deferred novel-fix check,
                // comparing the tech's message against the answer we just gave.
                await detectAndSaveFix(question: trimmed, answer: answer.text, sources: top.map(\.result), user: user, botId: botId)
                return
            } catch {
                print("[ChatEngine] Error: \(error)")
                conversations[user, default: []].append(
                    ChatMessage(role: .bot, text: "Something went wrong: \(error.localizedDescription)")
                )
            }
            isTyping = false
            statusText = nil
        }
    }

    /// Streams a partial (cumulative) answer into the chat: creates the bot
    /// bubble on the first token — replacing the typing indicator — then
    /// grows its text. Guards against out-of-order updates by only ever
    /// lengthening the text.
    private func streamPartial(_ text: String, user: DemoUser, question: String) {
        guard !text.isEmpty else { return }
        if let id = streamingBotId,
           let idx = conversations[user]?.firstIndex(where: { $0.id == id }) {
            if text.count > (conversations[user]?[idx].text.count ?? 0) {
                conversations[user]?[idx].text = text
            }
        } else {
            var bot = ChatMessage(role: .bot, text: text)
            bot.question = question
            streamingBotId = bot.id
            conversations[user, default: []].append(bot)
            isTyping = false
            statusText = nil
        }
    }

    /// Runs after the answer is displayed: a second, deferred model call that
    /// checks whether the tech reported a novel fix. On a hit it embeds and
    /// saves the note, then appends the sync confirmation to the already-
    /// visible bubble — so the answer never waits on this extra call.
    private func detectAndSaveFix(question: String, answer: String, sources: [SearchResult], user: DemoUser, botId: UUID) async {
        guard let dbManager,
              let noteText = await AIService.detectNovelFix(latestMessage: question, assistantAnswer: answer, sources: sources)
        else { return }
        do {
            let noteVector = try await EmbeddingService.shared.embedDocument(noteText)
            let note = FieldNote(
                id: "note::\(UUID().uuidString)",
                text: noteText,
                author: user.displayName,
                assetModel: assetContext?.model ?? "General",
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
            try dbManager.saveFieldNote(note, embedding: noteVector)
            if let idx = conversations[user]?.firstIndex(where: { $0.id == botId }) {
                conversations[user]?[idx].savedNote = true
                conversations[user]?[idx].text += Self.savedNoteConfirmation
            }
        } catch {
            print("[ChatEngine] Field-note save failed: \(error)")
        }
    }

    /// Sources-sheet mode switch: re-sorts that message's pool and
    /// re-runs the LLM with the new top-5 unless already cached. The
    /// chat bubble updates to the new mode's answer.
    func setMode(_ newMode: SearchMode, for messageId: UUID) {
        mode = newMode
        let user = activeUser
        guard let idx = conversations[user]?.firstIndex(where: { $0.id == messageId }),
              let msg = conversations[user]?[idx], !msg.isUser, !msg.rankedPool.isEmpty else { return }

        let suffix = msg.savedNote ? Self.savedNoteConfirmation : ""

        if let cached = msg.answers[newMode] {
            conversations[user]?[idx].text = cached.text + suffix
            conversations[user]?[idx].backend = cached.backend
            return
        }

        isRerunning = true
        Task {
            do {
                let history = (conversations[user] ?? []).prefix(upTo: max(0, idx - 1)).map {
                    AIService.ConversationTurn(isUser: $0.isUser, text: $0.text)
                }
                let top = top5(msg.rankedPool, mode: newMode)
                // A mode switch only re-ranks and re-answers; the field note
                // was already detected and saved on the original send, so skip
                // fix detection here and re-attach the same confirmation.
                let answer = try await AIService.answerQuestion(
                    msg.question,
                    context: top.map(\.result),
                    conversation: Array(history),
                    preferredBackend: preferredBackend,
                    detectFixes: false
                )
                conversations[user]?[idx].answers[newMode] = answer
                conversations[user]?[idx].text = answer.text + suffix
                conversations[user]?[idx].backend = answer.backend
            } catch {
                print("[ChatEngine] Mode re-run error: \(error)")
            }
            isRerunning = false
        }
    }

    /// Warms the Qwen CoreAI model at launch (and on switching to it in Settings) so
    /// the first question pays no download/load cost.
    func prewarmQwenIfNeeded() {
        guard AIService.ModelBackend.preferred == .qwen, !qwenReady else { return }
        qwenLoadError = nil
        Task {
            do {
                try await QwenLLMService.shared.load { [weak self] update in
                    Task { @MainActor in
                        guard let self else { return }
                        // Callback fires ~10×/s; only publish real changes.
                        if self.qwenStatus != update.message { self.qwenStatus = update.message }
                        if self.qwenProgress != update.fraction { self.qwenProgress = update.fraction }
                    }
                }
                qwenReady = true
            } catch {
                // Leave qwenReady false so a retry re-attempts the load;
                // answers meanwhile fall back to the Foundation model.
                print("[ChatEngine] Qwen prewarm failed: \(error)")
                qwenLoadError = "Qwen3 4B couldn't load — answers will use the Foundation model."
            }
            qwenStatus = nil
            qwenProgress = nil
        }
    }

    func resetDemo() {
        conversations = [:]
        assetContext = nil
        activeJob = nil
        pendingJobCompletionMessageId = nil
        try? dbManager?.deleteAllFieldNotes()
    }
}
