import SwiftUI

/// Which slice of the day's jobs the Work list is showing. The three
/// stat tiles double as the filter control.
enum JobFilter { case assigned, emergency, completed }

/// "Today" - the day's jobs, filterable by the three stat tiles.
struct WorkView: View {
    @Environment(DatabaseManager.self) private var dbManager
    @Environment(AppRouter.self) private var router
    @State private var jobs: [Job] = []
    @State private var filter: JobFilter = .assigned

    private var dateLine: String {
        Date().formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " · North region"
    }

    // Assigned = everything not yet completed. Emergency = every emergency,
    // completed or not (a critical unit stays visible). Completed = done.
    private var assignedJobs: [Job] { jobs.filter { $0.status != "Completed" } }
    private var emergencyJobs: [Job] { jobs.filter { $0.priority == "Emergency" } }
    private var completedJobs: [Job] { jobs.filter { $0.status == "Completed" } }

    private var visibleJobs: [Job] {
        switch filter {
        case .assigned: assignedJobs
        case .emergency: emergencyJobs
        case .completed: completedJobs
        }
    }

    private var listHeader: String {
        switch filter {
        case .assigned: "Assigned jobs"
        case .emergency: "Emergency jobs"
        case .completed: "Completed jobs"
        }
    }

    private var emptyTitle: String {
        switch filter {
        case .assigned: "All caught up"
        case .emergency: "No emergencies"
        case .completed: "Nothing completed yet"
        }
    }

    private var emptyIcon: String {
        switch filter {
        case .assigned: "checkmark.circle"
        case .emergency: "checkmark.shield"
        case .completed: "tray"
        }
    }

    private var emptyMessage: String {
        switch filter {
        case .assigned: "You've cleared every open job for today. Nice work."
        case .emergency: "No emergency work orders right now."
        case .completed: "Finish a job and it'll show up here."
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        StatTile(value: "\(assignedJobs.count)", label: "Assigned",
                                 isSelected: filter == .assigned) { filter = .assigned }
                        StatTile(value: "\(emergencyJobs.count)", label: "Emergency",
                                 color: emergencyJobs.isEmpty ? .primary : .red,
                                 isSelected: filter == .emergency) { filter = .emergency }
                        StatTile(value: "\(completedJobs.count)", label: "Completed",
                                 color: .green,
                                 isSelected: filter == .completed) { filter = .completed }
                    }

                    HStack(alignment: .firstTextBaseline) {
                        Text(listHeader)
                            .font(.title3.bold())
                        Spacer()
                        Text(filter == .assigned ? "Route order" : "\(visibleJobs.count) shown")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)

                    if visibleJobs.isEmpty {
                        ContentUnavailableView(emptyTitle, systemImage: emptyIcon, description: Text(emptyMessage))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else {
                        ForEach(visibleJobs) { job in
                            NavigationLink(value: job.id) {
                                JobCard(job: job)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
            }
            .animation(.snappy(duration: 0.25), value: filter)
            .navigationTitle("Today")
            .navigationSubtitle(dateLine)
            .navigationDestination(for: String.self) { jobId in
                JobDetailView(jobId: jobId, onJobChanged: refresh)
            }
            .onAppear(perform: refresh)
            // Mirror synced changes live (dispatched WOs, resets, completions
            // from the Mac or another device) without needing to re-navigate.
            .onChange(of: dbManager.workOrdersRevision) { refresh() }
        }
    }

    private func refresh() {
        jobs = (try? dbManager.allJobs()) ?? []
    }
}

struct StatTile: View {
    let value: String
    let label: String
    var color: Color = .primary
    /// When an `action` is supplied the tile becomes a selectable filter
    /// button; otherwise it renders as a plain read-only stat.
    var isSelected: Bool = false
    var action: (() -> Void)? = nil

    var body: some View {
        let tile = VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.title2.bold())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(isSelected ? AnyShapeStyle(.blue) : AnyShapeStyle(.secondary))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            isSelected ? AnyShapeStyle(.blue.opacity(0.14)) : AnyShapeStyle(.regularMaterial),
            in: RoundedRectangle(cornerRadius: 16)
        )
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 16).strokeBorder(.blue, lineWidth: 1.5)
            }
        }

        if let action {
            Button(action: action) { tile }
                .buttonStyle(.plain)
        } else {
            tile
        }
    }
}

extension Job {
    var priorityColor: Color {
        switch priority {
        case "Emergency": .red
        case "High": .orange
        case "Routine": .blue
        default: .gray
        }
    }

    var statusColor: Color {
        switch status {
        case "In Progress": .blue
        case "New": .red
        case "Completed": .green
        default: .gray
        }
    }
}

private struct JobCard: View {
    let job: Job

    var body: some View {
        HStack(spacing: 13) {
            RoundedRectangle(cornerRadius: 3)
                .fill(job.priorityColor)
                .frame(width: 4)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(job.priority)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(job.priorityColor, in: RoundedRectangle(cornerRadius: 7))
                    Text(job.workOrderNumber)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(job.timeLabel)
                        .font(.caption.weight(.semibold))
                }
                Text(job.title)
                    .font(.headline)
                Text("\(job.assetName) · \(job.assetTag) · \(job.site)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: 7) {
                    Circle()
                        .fill(job.statusColor)
                        .frame(width: 8, height: 8)
                    Text(job.status)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(job.statusColor)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }
                .padding(.top, 5)
            }
        }
        .padding(15)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            if job.priority == "Emergency" {
                RoundedRectangle(cornerRadius: 20)
                    .strokeBorder(.red.opacity(0.4), lineWidth: 0.5)
            }
        }
    }
}
