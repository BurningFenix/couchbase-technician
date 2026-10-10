import Foundation

/// One suggested-prompt chip; tapping it sends `text`.
struct Suggestion: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case script, measure, howTo, fault, team, parts, history, closeOut, followUp, general }

    /// At most one chip per category is shown, so the row is a mix:
    /// diagnose / measure / parts / close-out (plus team and history).
    enum Category: Sendable { case script, diagnose, measure, parts, closeOut, team, history }

    let kind: Kind
    let text: String
    /// Higher shows first.
    var score = 0
    /// Lower-cased terms: if any earlier question contains one, the
    /// suggestion is treated as already asked and dropped.
    var askedIfContains: [String] = []

    var id: String { text }

    var category: Category {
        switch kind {
        case .script: .script
        case .measure: .measure
        case .parts: .parts
        case .closeOut: .closeOut
        case .team: .team
        case .history: .history
        case .howTo, .fault, .followUp, .general: .diagnose
        }
    }

    /// Whether the chip's answer depends on finding something in the
    /// manuals or field notes. The others are answered from data the app
    /// already holds (the calculator, parts stock, the work order's service
    /// history, or the conversation itself), so they can't dead-end.
    var needsRetrievalCheck: Bool {
        switch kind {
        case .howTo, .fault, .team, .followUp, .general: true
        case .script, .measure, .parts, .history, .closeOut: false
        }
    }
}

/// Everything the rules look at. Gathered by ChatEngine from the work
/// order, the synced database and the conversation.
struct SuggestionContext: Sendable {
    var job: Job?
    /// The equipment model in focus (from the job, or an asset chip).
    var assetModel: String?
    var part: Part?
    var serviceHistory: [ServiceRecord] = []
    /// Newest first; for the model in focus, or all models with no focus.
    var fieldNotes: [FieldNote] = []
    /// The tech using the app, so their own notes aren't suggested back.
    var viewer: String
    var askedQuestions: [String] = []
    var lastAnswer: String?
    /// The tech reported a fix in this chat (a field note was saved).
    var fixReported = false
    /// Model-written follow-ups for the last answer; only fill spare slots.
    var aiFollowUps: [String] = []
    /// The next scripted demo prompt, if this is a demo work order.
    var scriptedPrompt: String?
}

/// Rule-based suggestions: instant, offline, and grounded in the job's
/// data rather than a fixed list. Deterministic on purpose, so a demo plays
/// out the same way every time.
enum SuggestionEngine {
    static let maxShown = 3

    /// Cosine distance above which nothing in the manuals or notes is close
    /// enough to answer a question. Calibrated with the app's embedding
    /// model on its own corpus: every answerable question tested scored
    /// <= 0.47, every off-topic one (Bluetooth pairing, firmware over Wi-Fi,
    /// a non-existent fault code) >= 0.51.
    static let deadEndDistance = 0.50

    // MARK: Readings

    enum Measurement { case superheat, subcooling }

    /// Ready-to-send example readings (the WO-4821 story's numbers).
    static func readingQuestion(_ m: Measurement) -> Suggestion {
        switch m {
        case .superheat:
            Suggestion(kind: .measure, text: "Suction is 118 psig and the suction line is 43°F. What's my superheat?")
        case .subcooling:
            Suggestion(kind: .measure, text: "Head pressure is 365 psig and the liquid line is 98°F. What's my subcooling, is the charge right?")
        }
    }

    /// Which reading a piece of text calls for, if any.
    static func measurement(in text: String) -> Measurement? {
        let t = text.lowercased()
        if t.contains("superheat") { return .superheat }
        if t.contains("subcool") || t.contains("charge") { return .subcooling }
        return nil
    }

    /// A reading counts as taken once a question gave a pressure for it.
    private static func measured(_ m: Measurement, in questions: [String]) -> Bool {
        let key = m == .superheat ? "superheat" : "subcool"
        return questions.contains { q in
            let t = q.lowercased()
            return t.contains("psig") && (t.contains(key) || (m == .subcooling && t.contains("charge")))
        }
    }

    // MARK: Candidates

    /// Every applicable suggestion, already-asked ones removed, best first.
    static func candidates(for ctx: SuggestionContext) -> [Suggestion] {
        // The scripted prompt counts as "about to be asked" for de-duping.
        let asked = ctx.askedQuestions + (ctx.scriptedPrompt.map { [$0] } ?? [])
        let fresh = ctx.askedQuestions.isEmpty
        var out: [Suggestion] = []

        if let script = ctx.scriptedPrompt {
            out.append(Suggestion(kind: .script, text: script, score: 1_000))
        }

        let model = ctx.assetModel
        if let job = ctx.job {
            // Next checklist step not ticked AND not already covered in chat.
            // Skipped once the tech has reported their fix: the job is solved,
            // so remaining diagnostic steps would just be noise.
            if !ctx.fixReported, let step = nextStep(job, asked: asked) {
                if let m = measurement(in: step) {
                    var reading = readingQuestion(m)
                    reading.score = 95
                    out.append(reading)
                } else {
                    out.append(Suggestion(kind: .howTo, text: "How do I \(lowercasedFirst(step))?", score: 80))
                }
            }
            // Fault codes in the reported problem, e.g. "E11".
            if let code = faultCodes(in: job.title + " " + job.reported).first {
                out.append(Suggestion(kind: .fault, text: "What does \(code) mean on the \(job.assetModel)?",
                                      score: fresh ? 100 : 30, askedIfContains: [code.lowercased()]))
            }
            if let part = ctx.part {
                out.append(Suggestion(kind: .parts,
                                      text: "Do I have a \(shortName(part.description)) (\(part.partNumber)) on the van?",
                                      score: 60, askedIfContains: [part.partNumber.lowercased(), " van"]))
            }
            if !ctx.serviceHistory.isEmpty {
                out.append(Suggestion(kind: .history, text: "Has \(job.assetTag) had this problem before?", score: 50,
                                      askedIfContains: ["had this before", "happened before", "history", "last time", "previous"]))
            }
        }

        // Wrap-up once the tech has reported their fix.
        if ctx.fixReported {
            let text = ctx.job.map { "Summarise what I found and fixed on \($0.workOrderNumber) for the completion notes" }
                ?? "Summarise this fix for my service report"
            out.append(Suggestion(kind: .closeOut, text: text, score: 88,
                                  askedIfContains: ["summarise", "summarize", "completion notes", "service report"]))
        }

        // Phrased from the note's own content (its fault code, else its
        // opening words) so the question actually retrieves that note - the
        // note text names neither its author nor the model.
        if let note = ctx.fieldNotes.first(where: { $0.author != ctx.viewer }) {
            let unit = note.assetModel == "General" ? (model ?? "unit") : note.assetModel
            let text: String
            if let code = faultCodes(in: note.text).first {
                text = "What fix did \(note.author) find for \(code) on the \(unit)?"
            } else {
                let topic = note.text.split(separator: " ").prefix(3).joined(separator: " ")
                text = "What did \(note.author) find about the \(topic) on the \(unit)?"
            }
            out.append(Suggestion(kind: .team, text: text, score: 75, askedIfContains: [note.author.lowercased()]))
        }

        // The last answer asked for a reading: offer that reading.
        if let answer = ctx.lastAnswer, let m = measurement(in: answer), !measured(m, in: asked) {
            var reading = readingQuestion(m)
            reading.score = 85
            out.append(reading)
        }

        // General starters when there's no job.
        if ctx.job == nil {
            if fresh {
                // Demo beat: asked as the OTHER tech, this surfaces the field
                // note saved during the WO-4821 story.
                out.append(Suggestion(kind: .general, text: "The AC-5000 is latching E11 again — anything I should know?",
                                      score: 90, askedIfContains: ["e11"]))
                out.append(Suggestion(kind: .general, text: "There's a damp, musty smell when the AC first starts cooling. Any idea why?",
                                      score: 40, askedIfContains: ["musty"]))
                var reading = readingQuestion(.superheat)
                reading.score = 70
                out.append(reading)
            } else {
                var reading = readingQuestion(.subcooling)
                reading.score = 45
                out.append(reading)
                out.append(Suggestion(kind: .general, text: "What should I keep an eye on around 380 psig?",
                                      score: 30, askedIfContains: ["380"]))
            }
        }

        // Model-written follow-ups rank below every rule.
        for (i, q) in ctx.aiFollowUps.enumerated() {
            out.append(Suggestion(kind: .followUp, text: q, score: 10 - i))
        }

        let askedLower = asked.map { $0.lowercased() }
        var seen = Set<String>()
        return out.sorted { $0.score > $1.score }.filter { c in
            guard seen.insert(c.text.lowercased()).inserted else { return false }
            if c.kind == .script { return true }
            if c.askedIfContains.contains(where: { key in askedLower.contains { $0.contains(key) } }) { return false }
            if c.kind == .measure, let m = measurement(in: c.text), measured(m, in: asked) { return false }
            return !askedLower.contains(c.text.lowercased())
        }
    }

    // MARK: Selection

    /// Walks the candidates best-first, at most one per category, checking
    /// each retrieval-dependent one with `isAnswerable` before it can take a
    /// slot. Checks run lazily, so only chips that would actually show cost
    /// an embedding.
    static func select(_ candidates: [Suggestion],
                       isAnswerable: @Sendable (Suggestion) async -> Bool) async -> [Suggestion] {
        var chosen: [Suggestion] = []
        var categories = Set<Suggestion.Category>()
        for c in candidates where !categories.contains(c.category) {
            if c.needsRetrievalCheck, !(await isAnswerable(c)) { continue }
            chosen.append(c)
            categories.insert(c.category)
            if chosen.count == maxShown { break }
        }
        return chosen
    }

    // MARK: Helpers

    /// First checklist step neither ticked on the job nor covered in chat.
    static func nextStep(_ job: Job, asked: [String]) -> String? {
        for (i, step) in job.steps.enumerated() where !job.stepsDone.contains(i) {
            if let m = measurement(in: step) {
                if measured(m, in: asked) { continue }
            } else {
                // Covered when one question shares 2+ meaningful words with it.
                let stepTokens = Set(SearchTokenizer.tokens(from: step))
                let covered = asked.contains { q in
                    stepTokens.intersection(SearchTokenizer.tokens(from: q)).count >= 2
                }
                if covered { continue }
            }
            return step
        }
        return nil
    }

    /// Codes like E11, F08, A01: one capital letter then two digits.
    static func faultCodes(in text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).compactMap { word in
            let w = String(word)
            guard w.count == 3, let first = w.first, first.isUppercase, first.isLetter,
                  w.dropFirst().allSatisfy(\.isNumber), seen.insert(w).inserted else { return nil }
            return w
        }
    }

    /// "Run capacitor, 7.5 microfarad, 440V (condenser fan)" → "run capacitor"
    private static func shortName(_ description: String) -> String {
        let head = description.split(separator: ",").first.map(String.init) ?? description
        return lowercasedFirst(head.trimmingCharacters(in: .whitespaces))
    }

    private static func lowercasedFirst(_ s: String) -> String {
        guard let first = s.first else { return s }
        // Keep acronyms ("EEV", "AHU") as they are.
        if s.count > 1, s.dropFirst().first?.isUppercase == true { return s }
        return first.lowercased() + s.dropFirst()
    }
}
