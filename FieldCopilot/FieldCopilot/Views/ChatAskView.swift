import SwiftUI

/// Chat-style Ask: multi-turn RAG with per-answer sources, field-note
/// tips from other techs, and suggestion chips.
struct ChatAskView: View {
    @Environment(ChatEngine.self) private var engine
    @State private var draft = ""
    @State private var sourcesFor: ChatMessage?
    /// Messages before the latest compaction are collapsed unless expanded.
    @State private var showEarlier = false
    @FocusState private var inputFocused: Bool
    @AppStorage("modelBackend") private var modelBackendRaw = AIService.ModelBackend.onDevice.rawValue

    private var modelLabel: String {
        // Read the stored choice so the header updates when Settings changes
        // it, but show the backend actually in use: .preferred downgrades
        // OpenAI to the Foundation model when no key is configured.
        _ = modelBackendRaw
        switch AIService.ModelBackend.preferred {
        case .onDevice: return "Foundation model"
        case .qwen: return QwenLLMService.displayName
        case .openAI: return "OpenAI"
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                messagesList
                Divider()
                inputArea
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $sourcesFor) { message in
                SourcesSheet(messageId: message.id)
            }
            // Checklist ticks on the job screen change what's suggested.
            .onAppear { engine.refreshSuggestions() }
        }
    }

    private var header: some View {
        VStack(spacing: 5) {
            CouchbaseLogo()
                .frame(width: 38, height: 38)
            Text("Agent · Couchbase")
                .font(.subheadline)
            HStack(spacing: 6) {
                Circle().fill(engine.qwenStatus == nil ? .green : .orange)
                    .frame(width: 6, height: 6)
                Text(engine.qwenStatus ?? "\(modelLabel) · \(engine.activeUser.displayName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(.default, value: engine.qwenStatus)
            }
            // First-run model download/load: a slim bar under the status line.
            if engine.qwenStatus != nil {
                Group {
                    if let fraction = engine.qwenProgress {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .tint(.blue)
                    } else {
                        IndeterminateBar()
                    }
                }
                .frame(maxWidth: 220)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 14) {
                    if let context = engine.assetContext {
                        assetChip(context.label)
                    }

                    if engine.messages.isEmpty && !engine.isTyping {
                        Text("Ask about a fault code, procedure, or part. Answers are grounded in your synced manuals and shared field notes.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 260)
                            .padding(.top, 80)
                    }

                    if hiddenCount > 0 {
                        Button {
                            withAnimation { showEarlier = true }
                        } label: {
                            Label("Show \(hiddenCount) earlier message\(hiddenCount == 1 ? "" : "s")", systemImage: "chevron.up")
                                .font(.caption.weight(.semibold))
                                .frame(minHeight: 44)
                        }
                    }

                    ForEach(visibleMessages) { message in
                        if message.isCompaction {
                            CompactionCard(message: message)
                                .id(message.id)
                        } else {
                            MessageRow(
                                message: message,
                                viewer: engine.activeUser.displayName,
                                showJobActions: message.id == engine.pendingJobCompletionMessageId,
                                openSources: { sourcesFor = message },
                                onComplete: { engine.completeActiveJob() },
                                onSkip: { engine.dismissJobActions() }
                            )
                            .id(message.id)
                        }
                    }

                    if engine.isTyping {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(engine.liveToolCalls) { ToolCallCard(activity: $0) }
                            TypingIndicator()
                            if let status = engine.statusText {
                                Text(status)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .contentTransition(.numericText())
                                    .animation(.default, value: status)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("typing")
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: latestCompactionIndex) { showEarlier = false }
            .onChange(of: engine.messages.count) {
                withAnimation {
                    proxy.scrollTo(engine.messages.last?.id, anchor: .bottom)
                }
            }
            .onChange(of: engine.messages.last?.text) {
                // Follow the streaming answer as it grows.
                proxy.scrollTo(engine.messages.last?.id, anchor: .bottom)
            }
            .onChange(of: engine.isTyping) {
                if engine.isTyping {
                    withAnimation { proxy.scrollTo("typing", anchor: .bottom) }
                }
            }
        }
    }

    private func assetChip(_ label: String) -> some View {
        Button {
            engine.clearContext()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.caption)
                Text(label)
                    .font(.caption.weight(.semibold))
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.blue.opacity(0.13), in: Capsule())
            .overlay(Capsule().strokeBorder(.blue.opacity(0.3), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.blue)
    }

    private var inputArea: some View {
        VStack(alignment: .leading, spacing: 9) {
            if !engine.isTyping && draft.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                        .foregroundStyle(.indigo)
                    Text("SUGGESTED PROMPTS")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 4)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(engine.suggestions) { suggestion in
                            Button {
                                engine.send(suggestion.text)
                            } label: {
                                SuggestionChip(suggestion: suggestion)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.primary)
                            .accessibilityHint("Sends this question")
                        }
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
                HStack(alignment: .bottom, spacing: 0) {
                    TextField(engine.isTyping ? "Field Assist is typing…" : "Message Field Assist…",
                              text: $draft, axis: .vertical)
                        .lineLimit(1...5)
                        .padding(.leading, 14)
                        .padding(.vertical, 10)
                        .focused($inputFocused)
                        // Return inserts a newline (its native behavior);
                        // only the blue button submits.
                    // How full the model's context window is; tap for
                    // the breakdown and Compact.
                    ContextRingButton()
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22))

                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(canSend ? AnyShapeStyle(.blue) : AnyShapeStyle(.gray.opacity(0.5)), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var latestCompactionIndex: Int? {
        engine.messages.lastIndex(where: \.isCompaction)
    }

    /// Messages hidden behind "Show earlier": everything before the latest
    /// compaction marker (the marker's summary card stands in for them).
    private var hiddenCount: Int {
        showEarlier ? 0 : (latestCompactionIndex ?? 0)
    }

    private var visibleMessages: [ChatMessage] {
        Array(engine.messages.dropFirst(hiddenCount))
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespaces).isEmpty && !engine.isTyping
    }

    private func send() {
        guard canSend else { return }
        let text = draft
        draft = ""
        inputFocused = false
        engine.send(text)
    }
}

/// The Couchbase mark: red disc with the white "cup" glyph.
///
/// Drawn as a vector so it stays crisp at any size and needs no bundled
/// asset. If an image named "CouchbaseLogo" is added to Assets.xcassets it
/// is used instead automatically — drop the official artwork in to get
/// pixel-exact branding without touching this code.
struct CouchbaseLogo: View {
    var body: some View {
        if UIImage(named: "CouchbaseLogo") != nil {
            Image("CouchbaseLogo")
                .resizable()
                .scaledToFit()
        } else {
            ZStack {
                Circle().fill(Color(red: 0.918, green: 0.137, blue: 0.157)) // Couchbase red #EA2328
                CouchbaseCup()
                    .fill(.white, style: FillStyle(eoFill: true))
                    .padding(.horizontal, 0.22 * 38)
                    .padding(.vertical, 0.30 * 38)
            }
        }
    }
}

/// A wide, heavy "U" — a rounded rectangle with a rounded notch punched out
/// of the top centre (filled even-odd so the notch reads as a hole).
private struct CouchbaseCup: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: rect, cornerRadius: rect.height * 0.32)
        // The notch is open at the top: square corners flush with the top
        // edge (so the opening has clean vertical sides) and rounded corners
        // at the bottom. A plain rounded rect would either leave a sliver
        // across the opening or, if overshot, add a tab above the shape.
        let width = rect.width * 0.34
        let radius = width * 0.34
        let left = rect.midX - width / 2
        let right = rect.midX + width / 2
        let bottom = rect.minY + rect.height * 0.62

        path.move(to: CGPoint(x: left, y: rect.minY))
        path.addLine(to: CGPoint(x: left, y: bottom - radius))
        path.addQuadCurve(to: CGPoint(x: left + radius, y: bottom),
                          control: CGPoint(x: left, y: bottom))
        path.addLine(to: CGPoint(x: right - radius, y: bottom))
        path.addQuadCurve(to: CGPoint(x: right, y: bottom - radius),
                          control: CGPoint(x: right, y: bottom))
        path.addLine(to: CGPoint(x: right, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private struct MessageRow: View {
    let message: ChatMessage
    /// Display name of the tech reading the chat, for author-aware labelling
    /// of field-note cards.
    var viewer: String = ""
    var showJobActions: Bool = false
    let openSources: () -> Void
    var onComplete: () -> Void = {}
    var onSkip: () -> Void = {}

    /// Inline markdown (bold, italics, code) rendered rather than shown as
    /// literal asterisks - Qwen in particular bolds key numbers.
    private var renderedText: AttributedString {
        (try? AttributedString(
            markdown: message.text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(message.text)
    }

    var body: some View {
        VStack(alignment: message.isUser ? .trailing : .leading, spacing: 7) {
            ForEach(message.toolCalls) { ToolCallCard(activity: $0) }

            Text(renderedText)
                .font(.subheadline)
                .padding(.horizontal, 15)
                .padding(.vertical, 11)
                .foregroundStyle(message.isUser ? .white : .primary)
                .background(
                    message.isUser ? AnyShapeStyle(.blue) : AnyShapeStyle(.regularMaterial),
                    in: UnevenRoundedRectangle(
                        topLeadingRadius: 21,
                        bottomLeadingRadius: message.isUser ? 21 : 7,
                        bottomTrailingRadius: message.isUser ? 7 : 21,
                        topTrailingRadius: 21
                    )
                )
                .frame(maxWidth: 320, alignment: message.isUser ? .trailing : .leading)

            if let tip = message.tip {
                FieldNoteTipCard(tip: tip, viewer: viewer)
            }

            if !message.isUser && !message.rankedPool.isEmpty {
                Button(action: openSources) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                            .font(.caption)
                        Text("Sources · \(min(5, message.rankedPool.count))")
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(.blue.opacity(0.13), in: Capsule())
                    .overlay(Capsule().strokeBorder(.blue.opacity(0.3), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }

            if showJobActions {
                HStack(spacing: 10) {
                    Button(action: onComplete) {
                        Label("Complete work", systemImage: "checkmark.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 15)
                            .padding(.vertical, 10)
                            .background(.green, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    Button(action: onSkip) {
                        Text("Not yet")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 15)
                            .padding(.vertical, 10)
                            .background(.gray.opacity(0.18), in: Capsule())
                            .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 3)
            }
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
    }
}

private struct FieldNoteTipCard: View {
    let tip: SearchResult
    /// The tech reading the chat, so the card can distinguish their own
    /// saved note from knowledge shared by someone else.
    let viewer: String

    private var isOwn: Bool { tip.fieldNoteAuthor == viewer }

    private var heading: String {
        isOwn
            ? "YOUR FIELD NOTE"
            : "FIELD-NOTE TIP · FROM \(tip.fieldNoteAuthor?.uppercased() ?? "A TECH")"
    }

    private var footnote: String {
        isOwn
            ? "You saved this · synced to the other techs"
            : "Saved by another tech · not in the manuals"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle")
                    .font(.footnote.weight(.semibold))
                Text(heading)
                    .font(.caption2.weight(.bold))
            }
            .foregroundStyle(.green)
            Text(tip.text)
                .font(.subheadline)
            Text(footnote)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .padding(13)
        .frame(maxWidth: 320, alignment: .leading)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.green.opacity(0.4), lineWidth: 0.5))
    }
}

private struct TypingIndicator: View {
    @State private var phase = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(.secondary)
                    .frame(width: 7, height: 7)
                    .offset(y: phase ? -3 : 0)
                    .animation(
                        .easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(Double(i) * 0.18),
                        value: phase
                    )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 21))
        .onAppear { phase = true }
    }
}

/// Bottom sheet: ranked sources for one answer with the three-mode
/// comparison. Switching modes re-runs the LLM with that mode's top-5.
struct SourcesSheet: View {
    @Environment(ChatEngine.self) private var engine
    let messageId: UUID

    @State private var expandedId: String?

    private var message: ChatMessage? {
        engine.messages.first { $0.id == messageId }
    }

    private var sortedTop: [RankedSearchResult] {
        guard let message else { return [] }
        return Array(message.rankedPool
            .sorted {
                let a = engine.mode.rank(of: $0) ?? Int.max
                let b = engine.mode.rank(of: $1) ?? Int.max
                if a != b { return a < b }
                return $0.hybridRank < $1.hybridRank
            }
            .prefix(5))
    }

    private var modelShort: String {
        switch AIService.ModelBackend.preferred {
        case .onDevice: "local LLM"
        case .qwen: QwenLLMService.displayName
        case .openAI: "OpenAI"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    modeSelector

                    HStack(spacing: 7) {
                        if engine.isRerunning {
                            ProgressView().controlSize(.small)
                            Text("Re-running sources → feeding \(modelShort)…")
                                .font(.caption)
                        } else {
                            Text(caption)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(minHeight: 18)
                    .padding(.horizontal, 4)

                    ForEach(Array(sortedTop.enumerated()), id: \.element.id) { index, item in
                        SourceCard(
                            item: item,
                            activeMode: engine.mode,
                            position: index + 1,
                            highlightTokens: engine.mode == .vector ? [] : (message?.queryTokens ?? []),
                            isCited: (message?.answers[engine.mode]?.sourcesUsed ?? []).contains(index + 1),
                            expandedId: $expandedId
                        )
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .navigationTitle("Sources")
            .navigationBarTitleDisplayMode(.inline)
            .navigationSubtitle("Ranked by \(engine.mode.rawValue)")
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private var caption: String {
        switch engine.mode {
        case .hybrid: "Hybrid ranking · exact matches in bold"
        case .fts: "Keyword ranking · exact matches in bold"
        case .vector: "Semantic ranking · no exact-term match"
        }
    }

    private var modeSelector: some View {
        HStack(spacing: 6) {
            ForEach(SearchMode.allCases) { m in
                Button {
                    withAnimation(.snappy(duration: 0.25)) {
                        expandedId = nil
                        engine.setMode(m, for: messageId)
                    }
                } label: {
                    Text(m.rawValue)
                        .font(.subheadline.weight(engine.mode == m ? .semibold : .medium))
                        .foregroundStyle(engine.mode == m ? AnyShapeStyle(.black) : AnyShapeStyle(.primary))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(
                            engine.mode == m ? AnyShapeStyle(m.color) : AnyShapeStyle(.clear),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(engine.isRerunning)
            }
        }
        .padding(5)
        .background(.regularMaterial, in: Capsule())
        .padding(.top, 8)
    }
}

/// "The agent ran a tool" card: shows the deterministic computation the
/// model delegated, so the audience sees the number didn't come from the LLM.
struct ToolCallCard: View {
    let activity: ToolActivity

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "function")
                .font(.footnote.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(.indigo, in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text("TOOL CALL")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.indigo)
                    Text("· \(activity.title)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(activity.result)
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                Text(activity.inputs)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: 320, alignment: .leading)
        .background(.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.indigo.opacity(0.3), lineWidth: 0.5))
        .transition(.scale(scale: 0.95).combined(with: .opacity))
    }
}

/// A suggested-prompt chip, with an icon saying where the idea came from.
private struct SuggestionChip: View {
    let suggestion: Suggestion

    private var icon: String? {
        switch suggestion.kind {
        case .measure: "gauge.with.dots.needle.33percent"
        case .howTo: "list.bullet.clipboard"
        case .fault: "exclamationmark.triangle"
        case .team: "person.2"
        case .parts: "shippingbox"
        case .history: "clock.arrow.circlepath"
        case .closeOut: "checkmark.seal"
        case .followUp: "sparkles"
        case .script, .general: nil
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(.indigo)
            }
            Text(suggestion.text)
                .font(.footnote)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: 250, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .background(.indigo.opacity(0.13), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.indigo.opacity(0.35), lineWidth: 0.5))
    }
}
