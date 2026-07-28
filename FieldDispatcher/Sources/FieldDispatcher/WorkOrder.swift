import Foundation

/// A work order, encoded to the SAME JSON shape as the iPhone app's `Job`
/// (stored in the `field.workOrders` collection). Keeping the field names
/// identical is what lets a work order created here decode and display on
/// the phone after it syncs through Capella.
struct WorkOrder: Identifiable, Codable, Sendable {
    var id: String
    var workOrderNumber: String
    var priority: String
    var status: String
    var timeLabel: String
    var window: String
    var title: String
    var assetName: String
    var assetTag: String
    var assetModel: String
    var site: String
    var reported: String
    var steps: [String]
    var stepsDone: [Int]
    var jobParts: [JobPart]
    var clockSeconds: Int
    var routeOrder: Int
    // Optional fields the phone also understands; left nil for dispatched WOs.
    var requiredPart: String?
    var demoPrompts: [String]?

    static let priorities = ["Emergency", "High", "Routine", "Low"]
    static let assetModels = ["AeroCool AC-5000", "ThermaFlow RTU-20", "VentMax AHU-8"]
    static let statuses = ["New", "Scheduled", "In Progress"]
}

struct JobPart: Codable, Sendable, Hashable {
    var name: String
    var note: String
}
