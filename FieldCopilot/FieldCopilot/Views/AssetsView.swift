import SwiftUI

/// Distinct navigation value for a work order. Asset navigation uses the
/// asset id (a String); reusing String for jobs too would collide with the
/// asset destination in the same stack (SwiftUI matches by type), so a WO
/// tap would silently resolve to "no asset found" and go nowhere.
struct JobLink: Hashable { let id: String }

/// Navigation value for opening an asset's full manual.
struct ManualLink: Hashable { let model: String; let title: String }

struct AssetsView: View {
    @Environment(DatabaseManager.self) private var dbManager
    @State private var assets: [Asset] = []
    @State private var jobs: [Job] = []

    private var subtitle: String {
        let attention = assets.filter { !$0.isOperational }.count
        let units = "\(assets.count) unit\(assets.count == 1 ? "" : "s")"
        return attention > 0 ? "\(units) · \(attention) needs attention" : units
    }

    private func openWOCount(_ asset: Asset) -> Int {
        jobs.filter { $0.assetTag == asset.assetTag && $0.status != "Completed" }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(assets) { asset in
                        NavigationLink(value: asset.id) {
                            AssetCard(asset: asset, openWOs: openWOCount(asset))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
            }
            .navigationTitle("Assets")
            .navigationSubtitle(subtitle)
            .navigationDestination(for: String.self) { assetId in
                if let asset = assets.first(where: { $0.id == assetId }) {
                    AssetDetailView(asset: asset)
                }
            }
            .onAppear {
                assets = (try? dbManager.allAssets()) ?? []
                jobs = (try? dbManager.allJobs()) ?? []
            }
            .onChange(of: dbManager.workOrdersRevision) {
                jobs = (try? dbManager.allJobs()) ?? []
            }
        }
    }
}

private struct AssetCard: View {
    let asset: Asset
    let openWOs: Int

    private var statusColor: Color { asset.isOperational ? .green : .orange }

    var body: some View {
        VStack(spacing: 13) {
            HStack(spacing: 14) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.title3)
                    .foregroundStyle(statusColor)
                    .frame(width: 46, height: 46)
                    .background(statusColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .top) {
                        Text(asset.name)
                            .font(.headline)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 8)
                        Text(asset.assetTag)
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                    }
                    Text("\(asset.model) · \(asset.location)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 7) {
                        Circle().fill(statusColor).frame(width: 8, height: 8)
                        Text(asset.status.capitalized)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(statusColor)
                    }
                    .padding(.top, 4)
                }
            }

            Divider()

            HStack {
                metric(asset.runtimeHours.map { "\($0.formatted()) h" } ?? "—", "Runtime")
                metric(asset.lastService ?? "—", "Last service")
                metric("\(openWOs)", "Open WOs", color: openWOs > 0 ? .orange : .secondary)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private func metric(_ value: String, _ label: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.subheadline.bold()).foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AssetDetailView: View {
    @Environment(DatabaseManager.self) private var dbManager
    @Environment(AppRouter.self) private var router
    @Environment(ChatEngine.self) private var chatEngine

    let asset: Asset
    @State private var history: [ServiceRecord] = []
    @State private var openJobs: [Job] = []

    private var statusColor: Color { asset.isOperational ? .green : .orange }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 7) {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(asset.status.capitalized)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(statusColor)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(asset.name).font(.title.bold())
                    Text("\(asset.model) · \(asset.location)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Button {
                    chatEngine.assetContext = (
                        label: "\(asset.name.components(separatedBy: " — ").first ?? asset.name) · \(asset.assetTag)",
                        model: asset.model
                    )
                    router.selectedTab = .ask
                } label: {
                    Label("Ask AI about this asset", systemImage: "questionmark.bubble")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))

                HStack(spacing: 10) {
                    StatTile(value: asset.runtimeHours.map { "\($0.formatted()) h" } ?? "—", label: "Runtime")
                    StatTile(value: asset.cycles.map { $0.formatted() } ?? "—", label: "Cycles")
                    StatTile(value: asset.lastService ?? "—", label: "Serviced")
                }

                sectionHeader("Identification")
                VStack(spacing: 0) {
                    row("Serial", asset.serial ?? "—")
                    Divider().padding(.leading, 16)
                    row("Installed", asset.specs.installedDate ?? "—")
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))

                if !openJobs.isEmpty {
                    sectionHeader("Open work orders")
                    VStack(spacing: 10) {
                        ForEach(openJobs) { job in
                            NavigationLink(value: JobLink(id: job.id)) {
                                HStack(spacing: 12) {
                                    Circle().fill(job.statusColor).frame(width: 8, height: 8)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(job.title).font(.subheadline.weight(.bold))
                                        Text("\(job.workOrderNumber) · \(job.status)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption.bold())
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(14)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if !history.isEmpty {
                    sectionHeader("Service history")
                    VStack(spacing: 0) {
                        ForEach(Array(history.enumerated()), id: \.element.id) { index, record in
                            HStack(alignment: .top, spacing: 12) {
                                Text(record.date)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 76, alignment: .leading)
                                Text(record.summary)
                                    .font(.subheadline)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 12)
                            .padding(.horizontal, 16)
                            if index < history.count - 1 { Divider().padding(.leading, 16) }
                        }
                    }
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }

                sectionHeader("Documents")
                NavigationLink(value: ManualLink(model: asset.model, title: manualTitle)) {
                    HStack(spacing: 12) {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.blue)
                        Text(manualTitle)
                            .font(.subheadline)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .navigationTitle(asset.assetTag)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: JobLink.self) { link in
            JobDetailView(jobId: link.id)
        }
        .navigationDestination(for: ManualLink.self) { link in
            ManualView(assetModel: link.model, manualTitle: link.title)
        }
        .onAppear {
            history = (try? dbManager.serviceHistory(forAssetTag: asset.assetTag)) ?? []
            openJobs = ((try? dbManager.allJobs()) ?? [])
                .filter { $0.assetTag == asset.assetTag && $0.status != "Completed" }
        }
    }

    private var manualTitle: String {
        switch asset.model {
        case "AeroCool AC-5000": "AeroCool AC-5000 Service Manual"
        case "ThermaFlow RTU-20": "ThermaFlow RTU-20 Maintenance Guide"
        case "VentMax AHU-8": "VentMax AHU-8 Operation Manual"
        default: "\(asset.model) Manual"
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.medium)
        }
        .font(.subheadline)
        .padding(.vertical, 12)
        .padding(.horizontal, 16)
    }
}

/// The full manual reader: stitches the stored chunks back into a readable
/// document, in page order and grouped under their section headings. These
/// are the very same chunks the RAG pipeline retrieves — shown here as a
/// human-readable manual.
struct ManualView: View {
    @Environment(DatabaseManager.self) private var dbManager
    let assetModel: String
    let manualTitle: String
    @State private var chunks: [ManualChunk] = []

    /// Consecutive chunks that share a section become one section block,
    /// preserving the page order the chunks arrived in.
    private var sections: [(section: String, page: Int, paragraphs: [String])] {
        var result: [(section: String, page: Int, paragraphs: [String])] = []
        for chunk in chunks {
            if let last = result.last, last.section == chunk.section {
                result[result.count - 1].paragraphs.append(chunk.text)
            } else {
                result.append((section: chunk.section, page: chunk.page, paragraphs: [chunk.text]))
            }
        }
        return result
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if chunks.isEmpty {
                    ContentUnavailableView(
                        "Manual unavailable",
                        systemImage: "doc.text",
                        description: Text("No manual content is on this device yet.")
                    )
                    .padding(.top, 60)
                } else {
                    Text("\(chunks.count) sections · synced to this device")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(Array(sections.enumerated()), id: \.offset) { _, group in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(group.section)
                                    .font(.headline)
                                Spacer()
                                Text("p. \(group.page)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(Array(group.paragraphs.enumerated()), id: \.offset) { _, para in
                                Text(para)
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding()
            .padding(.bottom, 24)
        }
        .navigationTitle(manualTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            chunks = (try? dbManager.manualChunks(forModel: assetModel)) ?? []
        }
    }
}
