import SwiftUI

enum SearchMode: String, CaseIterable, Identifiable {
    case hybrid = "Hybrid"
    case fts = "FTS"
    case vector = "Pure Vector"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .hybrid: .green
        case .fts: .blue
        case .vector: .purple
        }
    }

    var shortLabel: String {
        switch self {
        case .hybrid: "HYB"
        case .fts: "FTS"
        case .vector: "VEC"
        }
    }

    func rank(of item: RankedSearchResult) -> Int? {
        switch self {
        case .hybrid: item.hybridRank
        case .fts: item.ftsRank
        case .vector: item.vectorRank
        }
    }
}

/// Expandable source citation card showing the chunk's position in all
/// three rankings. Tap to expand to the full chunk text. When
/// highlightTokens is non-empty, exact FTS match terms render bold.
struct SourceCard: View {
    let item: RankedSearchResult
    let activeMode: SearchMode
    var position: Int? = nil
    var highlightTokens: Set<String> = []
    var isCited: Bool = false
    @Binding var expandedId: String?

    private var isExpanded: Bool { expandedId == item.id }

    var body: some View {
        Button {
            withAnimation(.spring(duration: 0.3)) {
                expandedId = isExpanded ? nil : item.id
            }
        } label: {
            card
        }
        .buttonStyle(.plain)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                if let position {
                    Text("\(position)")
                        .font(.subheadline.bold())
                        .foregroundStyle(.black)
                        .frame(width: 28, height: 28)
                        .background(activeMode.color, in: RoundedRectangle(cornerRadius: 9))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.result.manualTitle)
                        .font(.headline)
                    Text("\(item.result.section) · Page \(item.result.page)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.bold())
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .padding(.top, 4)
            }

            HStack(spacing: 7) {
                if isCited {
                    Label("Used in answer", systemImage: "text.quote")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(activeMode.color.gradient, in: RoundedRectangle(cornerRadius: 8))
                }
                ForEach(SearchMode.allCases) { mode in
                    rankBadge(mode)
                }
            }

            Text(highlightedText)
                .font(.subheadline)
                .foregroundStyle(isExpanded ? .primary : .secondary)
                .lineLimit(isExpanded ? nil : 3)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            if isCited {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(activeMode.color, lineWidth: 1.5)
            } else if position != nil {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(activeMode.color.opacity(0.3), lineWidth: 0.5)
            }
        }
    }

    /// Splits the chunk text into word / separator runs and bolds words
    /// matching an FTS query token (exact, or prefix for stemmed forms
    /// like "bearing" matching "bearings").
    private var highlightedText: AttributedString {
        let text = item.result.text
        guard !highlightTokens.isEmpty else { return AttributedString(text) }

        var result = AttributedString()
        var wordRun = ""
        var separatorRun = ""

        func flushWord() {
            guard !wordRun.isEmpty else { return }
            var attr = AttributedString(wordRun)
            let lower = wordRun.lowercased()
            let matches = highlightTokens.contains(lower)
                || highlightTokens.contains { $0.count >= 3 && lower.hasPrefix($0) }
            if matches {
                attr.inlinePresentationIntent = .stronglyEmphasized
            }
            result += attr
            wordRun = ""
        }

        func flushSeparator() {
            guard !separatorRun.isEmpty else { return }
            result += AttributedString(separatorRun)
            separatorRun = ""
        }

        for ch in text {
            if ch.isLetter || ch.isNumber {
                flushSeparator()
                wordRun.append(ch)
            } else {
                flushWord()
                separatorRun.append(ch)
            }
        }
        flushWord()
        flushSeparator()
        return result
    }

    private func rankBadge(_ mode: SearchMode) -> some View {
        let rank = mode.rank(of: item)
        let isActive = mode == activeMode
        return Text("\(mode.shortLabel) \(rank.map { "#\($0)" } ?? "—")")
            .font(.caption.weight(isActive ? .bold : .semibold))
            .foregroundStyle(isActive ? AnyShapeStyle(.black) : AnyShapeStyle(mode.color))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                isActive ? AnyShapeStyle(mode.color) : AnyShapeStyle(mode.color.opacity(0.15)),
                in: RoundedRectangle(cornerRadius: 8)
            )
    }
}
