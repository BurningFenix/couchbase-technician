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
    /// Technician this work order is dispatched to ("Kyle" / "BJ"). On the
    /// phone this drives the per-tech job list, and on App Services it routes
    /// the document to that technician's private channel — so assigning here
    /// is what decides whose device the work order reaches.
    var assignedTo: String?
    // Optional fields the phone also understands; left nil for dispatched WOs.
    var requiredPart: String?
    var demoPrompts: [String]?

    /// Field technicians a work order can be dispatched to. These must match
    /// the display names the phone uses, since the channel name is derived
    /// from them ("Kyle" -> tech-kyle).
    static let technicians = ["Kyle", "BJ"]
    static let priorities = ["Emergency", "High", "Routine", "Low"]
    static let assetModels = ["AeroCool AC-5000", "ThermaFlow RTU-20", "VentMax AHU-8"]
    static let statuses = ["New", "Scheduled", "In Progress"]
}

struct JobPart: Codable, Sendable, Hashable {
    var name: String
    var note: String
}
