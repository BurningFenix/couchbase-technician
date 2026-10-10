import SwiftUI

/// Settings: demo user switcher (the field-notes sync story), AI model
/// choice, sync status, and demo reset.
struct SettingsView: View {
    @Environment(DatabaseManager.self) private var dbManager
    @Environment(ChatEngine.self) private var chatEngine
    @AppStorage("modelBackend") private var modelBackendRaw = AIService.ModelBackend.onDevice.rawValue
    @AppStorage("activeUser") private var activeUserRaw = DemoUser.kyle.rawValue

    @State private var documentCount = 0
    @State private var fieldNoteCount = 0
    @State private var showResetConfirm = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(DemoUser.allCases) { user in
                        Button {
                            activeUserRaw = user.rawValue
                            chatEngine.activeUser = user
                            // Re-authenticate to App Services as this tech so
                            // their channels (and only theirs) apply, and
                            // refresh the per-tech job list.
                            dbManager.switchUser()
                            refreshStats()
                        } label: {
                            HStack(spacing: 13) {
                                ZStack {
                                    Circle()
                                        .fill(activeUserRaw == user.rawValue
                                              ? AnyShapeStyle(LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                                              : AnyShapeStyle(.quaternary))
                                        .frame(width: 38, height: 38)
                                    Text(user.initials)
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(.white)
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(user.displayName)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text(user.role)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if activeUserRaw == user.rawValue {
                                    Image(systemName: "checkmark")
                                        .font(.body.weight(.bold))
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Signed in as")
                } footer: {
                    Text(userFooter)
                }

                Section {
                    Picker("AI Model", selection: $modelBackendRaw) {
                        Text("Foundation").tag(AIService.ModelBackend.onDevice.rawValue)
                        Text(QwenLLMService.displayName).tag(AIService.ModelBackend.qwen.rawValue)
                        Text("OpenAI").tag(AIService.ModelBackend.openAI.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: modelBackendRaw) {
                        chatEngine.prewarmQwenIfNeeded()
                    }

                    if let status = chatEngine.qwenStatus {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(status)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                                .animation(.default, value: status)
                            // Download phase → determinate byte-progress bar;
                            // load-into-memory phase (no measurable progress)
                            // → indeterminate animated bar, never a frozen one.
                            if let fraction = chatEngine.qwenProgress {
                                ProgressView(value: fraction)
                                    .tint(.blue)
                            } else {
                                IndeterminateBar()
                            }
                        }
                    } else if let error = chatEngine.qwenLoadError,
                              modelBackendRaw == AIService.ModelBackend.qwen.rawValue {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                    } else if modelBackendRaw == AIService.ModelBackend.qwen.rawValue
                                && chatEngine.qwenReady {
                        Label("\(QwenLLMService.displayName) ready", systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    }
                } header: {
                    Text("AI model")
                } footer: {
                    Text(modelFooter)
                }

                Section {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 11, height: 11)
                        Text(activityLabel)
                            .font(.headline)
                        Spacer()
                        Text(dbManager.syncingAs.map { "as \($0)" } ?? SyncConfig.endpointURL)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 150)
                    }
                    .padding(.vertical, 2)

                    HStack {
                        statCell(value: "\(documentCount)", label: "Documents")
                        Divider()
                        statCell(value: "\(fieldNoteCount)", label: "Field notes")
                        Divider()
                        statCell(value: lastSyncLabel, label: "Last sync")
                    }
                    .padding(.vertical, 6)

                    if let syncError = dbManager.syncError {
                        Text(syncError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Button(dbManager.isSyncing ? "Stop Sync" : "Start Sync") {
                        dbManager.isSyncing ? dbManager.stopSync() : dbManager.startSync()
                    }
                    .foregroundStyle(dbManager.isSyncing ? .red : .blue)
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Sync runs automatically while the app is open. Work orders, completions, and resets sync through Capella to the Mac dispatcher and back.")
                }

                Section {
                    Button("Reset demo to defaults", role: .destructive) {
                        showResetConfirm = true
                    }
                } footer: {
                    Text("Restores all work orders, assets, and parts to their starting state, and clears both techs' chats and shared field notes.")
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Reset the demo?", isPresented: $showResetConfirm, titleVisibility: .visible) {
                Button("Reset everything to defaults", role: .destructive) {
                    chatEngine.resetDemo()
                    try? dbManager.resetToSeed()
                    refreshStats()
                }
            } message: {
                Text("Completed work orders return to assigned, timers and checklists reset, requested parts clear, and all conversations and shared field notes are deleted.")
            }
            .onAppear(perform: refreshStats)
        }
    }

    private var userFooter: String {
        let base = "Switch techs to see how a field-note discovery made by one user surfaces for the next."
        return SyncConfig.hasPerUserCredentials
            ? base + " Each tech signs in to App Services as themselves, so they only sync their own work orders."
            : base
    }

    private var modelFooter: String {
        switch AIService.ModelBackend(rawValue: modelBackendRaw) ?? .onDevice {
        case .onDevice:
            "Apple's on-device foundation model. Fastest replies, fully offline - no data leaves the device."
        case .qwen:
            "\(QwenLLMService.displayName) running locally via MLX. Larger, more capable on-device answers; fully offline. Downloads \(QwenLLMService.downloadSizeLabel) on demand the first time you select it."
        case .openAI:
            AIConfig.hasOpenAIKey
                ? "OpenAI \(AIService.openAIModel) in the cloud. Highest quality; requires a connection and sends prompts off-device."
                : "OpenAI requires an API key in Secrets.xcconfig - without one the app uses the Foundation model."
        }
    }

    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.title3.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var activityLabel: String {
        switch dbManager.syncActivity {
        case "idle": "Connected"
        case "busy": "Syncing"
        case "connecting": "Connecting"
        case "offline": "Offline"
        case "stopped": "Not Connected"
        default: dbManager.syncActivity.capitalized
        }
    }

    private var statusColor: Color {
        switch dbManager.syncActivity {
        case "idle": .green
        case "busy": .blue
        case "connecting": .orange
        case "offline", "stopped": .gray
        default: .red
        }
    }

    private var lastSyncLabel: String {
        guard let date = dbManager.lastSyncDate else { return "—" }
        return date.formatted(.relative(presentation: .numeric))
    }

    private func refreshStats() {
        documentCount = dbManager.totalDocumentCount()
        fieldNoteCount = dbManager.fieldNoteCount()
    }
}

/// An indeterminate linear progress bar: a highlight segment sweeps across a
/// track on a loop. Used when there's activity but no measurable fraction
/// (the Qwen load-into-memory phase reports no progress), so the
/// bar always moves instead of sitting frozen at 0%.
struct IndeterminateBar: View {
    @State private var animating = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let segment = w * 0.35
            Capsule()
                .fill(.blue.opacity(0.15))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(.blue)
                        .frame(width: segment)
                        .offset(x: animating ? w - segment : 0)
                }
                .clipShape(Capsule())
        }
        .frame(height: 5)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                animating = true
            }
        }
    }
}
