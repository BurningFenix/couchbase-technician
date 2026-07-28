import SwiftUI

/// Van stock: parts inventory with warehouse availability and a
/// request flow persisted to the parts collection.
struct PartsView: View {
    @Environment(DatabaseManager.self) private var dbManager
    @State private var parts: [Part] = []

    private var requestedCount: Int { parts.filter { $0.requested == true }.count }
    private var lowOrOutCount: Int { parts.filter { $0.stockLevel != .ok }.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        StatTile(value: "\(parts.count)", label: "Van SKUs")
                        StatTile(value: "\(lowOrOutCount)", label: "Low / out",
                                 color: lowOrOutCount > 0 ? .orange : .primary)
                        StatTile(value: "\(requestedCount)", label: "Requested",
                                 color: requestedCount > 0 ? .blue : .primary)
                    }

                    HStack(alignment: .firstTextBaseline) {
                        Text("On the van")
                            .font(.title3.bold())
                        Spacer()
                        Text("\(parts.count) SKUs")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 4)

                    ForEach(parts) { part in
                        PartCard(part: part) {
                            toggleRequest(part)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 16)
            }
            .navigationTitle("Parts")
            .navigationSubtitle("Van stock · Truck 07")
            .onAppear(perform: refresh)
        }
    }

    private func refresh() {
        parts = (try? dbManager.allParts()) ?? []
    }

    private func toggleRequest(_ part: Part) {
        try? dbManager.setPartRequested(part.id, requested: !(part.requested ?? false))
        refresh()
    }
}

private struct PartCard: View {
    let part: Part
    let onRequest: () -> Void

    private var levelColor: Color {
        switch part.stockLevel {
        case .ok: .green
        case .low: .orange
        case .out, .backorder: .red
        }
    }

    private var canRequest: Bool {
        part.quantityOnHand == 0 || part.stockLevel == .low
    }

    private var isRequested: Bool { part.requested == true }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 13) {
                Image(systemName: "shippingbox")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(part.description)
                        .font(.subheadline.weight(.bold))
                        .lineLimit(2)
                    Text("SKU \(part.partNumber)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("On van \(part.quantityOnHand)")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(part.quantityOnHand > 0 ? AnyShapeStyle(.primary) : AnyShapeStyle(.red))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(
                        part.quantityOnHand > 0 ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.red.opacity(0.15)),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
            }

            Divider()

            HStack(spacing: 10) {
                Text(part.stockLevel.label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(levelColor)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(levelColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 7))
                Text("Warehouse: \(part.warehouseQty ?? 0) \(part.unit ?? "ea")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if canRequest {
                    Button(action: onRequest) {
                        Text(isRequested ? "Requested ✓" : ((part.warehouseQty ?? 0) > 0 ? "Request" : "Reorder"))
                            .font(.footnote.weight(.bold))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isRequested ? .green : .blue)
                    .background(
                        (isRequested ? Color.green : Color.blue).opacity(0.15),
                        in: RoundedRectangle(cornerRadius: 10)
                    )
                }
            }
        }
        .padding(15)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}
