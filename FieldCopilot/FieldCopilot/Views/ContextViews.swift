import SwiftUI

/// Ring colour by fill: blue, amber from 60%, red from the auto-compact
/// threshold (85%).
private func ringColor(_ fraction: Double) -> Color {
    if fraction >= ContextMeter.autoCompactThreshold { return .red }
    if fraction >= 0.6 { return .orange }
    return .blue
}

/// A thin progress ring, drawn from 12 o'clock.
struct ContextRing: View {
    let fraction: Double
    var lineWidth: CGFloat = 2.6

    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.25), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(ringColor(fraction), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.easeInOut(duration: 0.6), value: fraction)
    }
}

/// The ring in the message field. Tapping opens the context popover.
struct ContextRingButton: View {
    @Environment(ChatEngine.self) private var engine
    @State private var showing = false

    var body: some View {
        let fraction = engine.contextUsage?.fraction ?? 0
        Button {
            showing = true
        } label: {
            ContextRing(fraction: fraction)
                .frame(width: 20, height: 20)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Context window \(engine.contextUsage?.percent ?? 0)% full")
        .accessibilityHint("Shows what fills the model's context and lets you compact the conversation")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ContextPopover()
                .presentationCompactAdaptation(.popover)
        }
    }
}

/// Breakdown of the next prompt against the model's window, with the
/// auto-compact switch and a manual Compact button.
struct ContextPopover: View {
    @Environment(ChatEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ContextMeter.autoCompactKey) private var autoCompact = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let usage = engine.contextUsage {
                summary(usage)
                SegmentBar(usage: usage)
                legend(usage)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }

            Text("Compacting summarizes older turns into one note. Manuals and field notes are searched again for every question, so nothing is lost.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Auto-compact at \(Int(ContextMeter.autoCompactThreshold * 100))%", isOn: $autoCompact)
                .font(.subheadline)

            compactControl
        }
        .padding(16)
        .frame(width: 330)
    }

    private var header: some View {
        HStack(spacing: 10) {
            ContextRing(fraction: engine.contextUsage?.fraction ?? 0, lineWidth: 3.5)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Context window").font(.headline)
                if let usage = engine.contextUsage {
                    Text("\(usage.modelName) · \(usage.limit.formatted()) tokens")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    private func summary(_ usage: ContextUsage) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(usage.percent)%")
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(ringColor(usage.fraction))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text("\(usage.isExact ? "" : "≈")\(usage.total.formatted()) of \(usage.limit.formatted()) tokens used")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .animation(.default, value: usage.percent)
    }

    private func legend(_ usage: ContextUsage) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(usage.segments) { segment in
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(SegmentBar.color(segment.kind))
                        .frame(width: 9, height: 9)
                    Text(segment.label)
                    Spacer()
                    Text(segment.tokens.formatted())
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .font(.footnote)
            }
        }
    }

    @ViewBuilder
    private var compactControl: some View {
        if engine.isCompacting {
            HStack(spacing: 9) {
                ProgressView()
                Text("Summarizing earlier turns…")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.blue)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
        } else if let freed = engine.lastCompactionFreed {
            Label("Freed \(freed.formatted()) tokens", systemImage: "checkmark")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        } else {
            Button {
                Task { await engine.compact() }
            } label: {
                Label("Compact conversation", systemImage: "arrow.down.right.and.arrow.up.left")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!engine.canCompact)
        }
    }
}

/// Stacked bar of the segments, scaled to the whole window, so free space
/// shows as empty track.
private struct SegmentBar: View {
    let usage: ContextUsage

    static func color(_ kind: ContextUsage.Kind) -> Color {
        switch kind {
        case .instructions: Color(red: 0.12, green: 0.23, blue: 0.48)
        case .workOrder: Color(red: 0.25, green: 0.45, blue: 0.85)
        case .manuals: Color(red: 0.58, green: 0.71, blue: 0.95)
        case .conversation: .orange
        case .reserve: Color.secondary.opacity(0.45)
        }
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(usage.segments) { segment in
                    Rectangle()
                        .fill(Self.color(segment.kind))
                        .frame(width: max(2, geo.size.width * Double(segment.tokens) / Double(max(1, usage.limit))))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 10)
        .background(Color.secondary.opacity(0.15))
        .clipShape(Capsule())
        .animation(.easeInOut(duration: 0.6), value: usage)
        .accessibilityHidden(true)
    }
}

/// Stands in for the turns a compaction replaced: a divider plus the
/// summary the model now remembers.
struct CompactionCard: View {
    let message: ChatMessage

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Rectangle().fill(.quaternary).frame(height: 1)
                Text("EARLIER CONVERSATION COMPACTED")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                Rectangle().fill(.quaternary).frame(height: 1)
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "text.alignleft")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Summary of \(message.compactedTurns) earlier turn\(message.compactedTurns == 1 ? "" : "s")")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange)
                    Text(message.text)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.orange.opacity(0.35), lineWidth: 0.5))
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
    }
}
