import SwiftUI

/// Job detail: checklist, clock, parts, complete - all persisted to the
/// workOrders collection so progress syncs.
struct JobDetailView: View {
    @Environment(DatabaseManager.self) private var dbManager
    @Environment(AppRouter.self) private var router
    @Environment(ChatEngine.self) private var chatEngine
    @Environment(\.dismiss) private var dismiss

    let jobId: String
    var onJobChanged: () -> Void = {}

    @State private var job: Job?
    @State private var loadFailed = false
    @State private var clockedIn = false
    @State private var tick = 0

    var body: some View {
        ScrollView {
            if let job {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 8) {
                        Text(job.priority)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(job.priorityColor, in: RoundedRectangle(cornerRadius: 8))
                        Text(job.status)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(job.statusColor)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(job.statusColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.title)
                            .font(.title.bold())
                        Text("\(job.timeLabel) · \(job.site)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    assetCard(job)
                    section("Reported issue") {
                        Text(job.reported)
                            .font(.subheadline)
                            .padding(15)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }
                    clockCard(job)
                    checklist(job)
                    partsCard(job)
                    completeButton(job)
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            } else if loadFailed {
                ContentUnavailableView(
                    "Work order not found",
                    systemImage: "questionmark.folder",
                    description: Text("This job may have been removed or hasn't synced to this device yet.")
                )
                .padding(40)
            } else {
                ProgressView().padding(40)
            }
        }
        .navigationTitle(job?.workOrderNumber ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard job == nil else { return }
            job = try? dbManager.allJobs().first { $0.id == jobId }
            loadFailed = (job == nil)
        }
        .task(id: clockedIn) {
            // Ticks only while clocked in; cancelled automatically when
            // clocking out or leaving the screen.
            guard clockedIn else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard clockedIn, !Task.isCancelled else { break }
                job?.clockSeconds += 1
                tick += 1
                if tick % 15 == 0 { persist() }
            }
        }
        .onDisappear { if clockedIn { persist() } }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            content()
        }
    }

    private func assetCard(_ job: Job) -> some View {
        VStack(spacing: 14) {
            HStack(spacing: 13) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(job.assetName) · \(job.assetTag)")
                        .font(.headline)
                    Text(job.assetModel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Button {
                chatEngine.startJobChat(job)
                router.selectedTab = .ask
            } label: {
                Label("Ask AI about this issue", systemImage: "questionmark.bubble")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
            .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(15)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private func clockCard(_ job: Job) -> some View {
        section("Time on site") {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(formatted(job.clockSeconds))
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(clockedIn ? "Clocked in · timer running" : "Paused · tap to resume")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    clockedIn.toggle()
                    if !clockedIn { persist() }
                } label: {
                    Text(clockedIn ? "Clock out" : "Clock in")
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(clockedIn ? .red : .black)
                .background(
                    clockedIn ? AnyShapeStyle(.red.opacity(0.15)) : AnyShapeStyle(.green),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            }
            .padding(16)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func checklist(_ job: Job) -> some View {
        let done = job.stepsDone.count
        return section("Procedure · \(done) of \(job.steps.count) done") {
            VStack(spacing: 0) {
                ProgressView(value: Double(done), total: Double(job.steps.count))
                    .tint(done == job.steps.count ? .green : .blue)
                    .padding(.bottom, 10)
                VStack(spacing: 0) {
                    ForEach(Array(job.steps.enumerated()), id: \.offset) { index, step in
                        let isDone = job.stepsDone.contains(index)
                        Button {
                            toggleStep(index)
                        } label: {
                            HStack(spacing: 13) {
                                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(isDone ? .green : .secondary)
                                Text(step)
                                    .font(.subheadline)
                                    .strikethrough(isDone)
                                    .foregroundStyle(isDone ? .secondary : .primary)
                                    .multilineTextAlignment(.leading)
                                Spacer()
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 14)
                        }
                        .buttonStyle(.plain)
                        if index < job.steps.count - 1 { Divider().padding(.leading, 44) }
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private func partsCard(_ job: Job) -> some View {
        section("Parts & materials") {
            VStack(spacing: 0) {
                ForEach(job.jobParts, id: \.self) { part in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(part.name).font(.subheadline.weight(.semibold))
                        Text(part.note).font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 11)
                    .padding(.horizontal, 14)
                    if part != job.jobParts.last { Divider().padding(.leading, 14) }
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func completeButton(_ job: Job) -> some View {
        Button {
            self.job?.status = "Completed"
            clockedIn = false
            persist()
            dismiss()
        } label: {
            Text(job.status == "Completed" ? "Completed" : "Complete & sign off")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.glassProminent)
        .tint(job.status == "Completed" ? .green : .blue)
        .disabled(job.status == "Completed")
        .padding(.top, 8)
    }

    private func toggleStep(_ index: Int) {
        guard var j = job else { return }
        if let pos = j.stepsDone.firstIndex(of: index) {
            j.stepsDone.remove(at: pos)
        } else {
            j.stepsDone.append(index)
        }
        if j.status == "New" || j.status == "Scheduled" { j.status = "In Progress" }
        job = j
        persist()
    }

    private func persist() {
        guard let job else { return }
        try? dbManager.saveJob(job)
        onJobChanged()
    }

    private func formatted(_ seconds: Int) -> String {
        String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }
}
