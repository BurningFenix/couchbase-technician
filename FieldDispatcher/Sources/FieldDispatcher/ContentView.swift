import SwiftUI

struct ContentView: View {
    @Environment(Store.self) private var store

    // Form state
    @State private var number = 5001
    @State private var title = ""
    @State private var priority = "High"
    @State private var assetModel = WorkOrder.assetModels[0]
    @State private var assetName = ""
    @State private var assetTag = ""
    @State private var site = ""
    @State private var reported = ""
    @State private var stepsText = ""
    @State private var didInit = false

    private var canCreate: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty &&
        !assetTag.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        HSplitView {
            formPane
                .frame(minWidth: 420, idealWidth: 460)
            listPane
                .frame(minWidth: 380)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) { syncPill }
        }
        .onAppear {
            if !didInit { number = store.nextWorkOrderNumber(); didInit = true }
        }
    }

    // MARK: - Form

    private var formPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("New work order").font(.title2.bold())
                    Spacer()
                    Button {
                        fillFromSample()
                    } label: {
                        Label("Generate sample", systemImage: "wand.and.stars")
                    }
                }

                field("Work order #") {
                    HStack(spacing: 6) {
                        Text("WO-").foregroundStyle(.secondary)
                        TextField("5001", value: $number, format: .number.grouping(.never))
                            .frame(width: 90)
                    }
                }
                field("Title") { TextField("Short summary", text: $title) }
                field("Priority") {
                    Picker("", selection: $priority) {
                        ForEach(WorkOrder.priorities, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden().pickerStyle(.segmented)
                }
                field("Asset model") {
                    Picker("", selection: $assetModel) {
                        ForEach(WorkOrder.assetModels, id: \.self) { Text($0).tag($0) }
                    }.labelsHidden()
                }
                HStack(spacing: 12) {
                    field("Asset name") { TextField("Rooftop Chiller", text: $assetName) }
                    field("Asset tag") { TextField("A-204", text: $assetTag) }
                }
                field("Site") { TextField("Building, roof, zone…", text: $site) }
                field("Reported issue") {
                    TextEditor(text: $reported)
                        .frame(height: 70)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                }
                field("Checklist (one step per line)") {
                    TextEditor(text: $stepsText)
                        .frame(height: 90)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                }

                Button {
                    createWorkOrder()
                } label: {
                    Label("Create & sync to Capella", systemImage: "arrow.up.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(!canCreate)

                if let msg = store.lastMessage {
                    Text(msg).font(.callout).foregroundStyle(.secondary)
                }
                if !store.isConfigured {
                    Text("⚠︎ Capella not configured — set capella-config.json (see README). Work orders save locally but won't sync yet.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(20)
        }
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - List

    private var listPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Work orders").font(.headline)
                Spacer()
                Text("\(store.workOrders.count)").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            Divider()
            if store.workOrders.isEmpty {
                ContentUnavailableView("No work orders yet",
                                       systemImage: "tray",
                                       description: Text("Create one, or wait for the phone's to sync down."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.workOrders) { wo in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(wo.priority)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(color(wo.priority).opacity(0.2), in: Capsule())
                                .foregroundStyle(color(wo.priority))
                            Text(wo.workOrderNumber).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Text(wo.status).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(wo.title).font(.body.weight(.semibold))
                        Text("\(wo.assetName) · \(wo.assetTag) · \(wo.assetModel)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Sync status

    private var syncPill: some View {
        HStack(spacing: 6) {
            Circle().fill(syncColor).frame(width: 8, height: 8)
            Text(store.syncActivity.capitalized).font(.callout)
            if let err = store.syncError {
                Text("· \(err)").font(.caption).foregroundStyle(.red).lineLimit(1)
            }
        }
        .help(store.endpointLabel)
    }

    private var syncColor: Color {
        switch store.syncActivity {
        case "connected": .green
        case "syncing": .blue
        case "connecting": .orange
        case "not configured", "offline", "stopped": .gray
        default: .red
        }
    }

    private func color(_ priority: String) -> Color {
        switch priority {
        case "Emergency": .red
        case "High": .orange
        case "Routine": .blue
        default: .gray
        }
    }

    // MARK: - Actions

    private func fillFromSample() {
        let s = SampleData.random()
        title = s.title
        priority = s.priority
        assetModel = s.assetModel
        assetName = s.assetName
        assetTag = s.assetTag
        site = s.site
        reported = s.reported
        stepsText = s.steps.joined(separator: "\n")
        number = store.nextWorkOrderNumber()
    }

    private func createWorkOrder() {
        let steps = stepsText.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Unique doc id (never reuse a number) — a fresh doc that reused an
        // id previously deleted would conflict with the remote tombstone and
        // silently fail to push. The "WO-####" number is display-only.
        let wo = WorkOrder(
            id: "job::wo-\(number)-\(UUID().uuidString.prefix(6).lowercased())",
            workOrderNumber: "WO-\(number)",
            priority: priority,
            status: "New",
            timeLabel: "Now",
            window: "Newly dispatched",
            title: title.trimmingCharacters(in: .whitespaces),
            assetName: assetName.isEmpty ? "Unassigned asset" : assetName,
            assetTag: assetTag.trimmingCharacters(in: .whitespaces),
            assetModel: assetModel,
            site: site,
            reported: reported,
            steps: steps.isEmpty ? ["Assess on site"] : steps,
            stepsDone: [],
            jobParts: [],
            clockSeconds: 0,
            routeOrder: 10 + store.workOrders.count
        )
        store.create(wo)
        // Reset for the next one; bump monotonically so rapid creates during
        // an in-flight sync don't reuse the same display number.
        title = ""; assetName = ""; assetTag = ""; site = ""; reported = ""; stepsText = ""
        number = max(number + 1, store.nextWorkOrderNumber())
    }
}
