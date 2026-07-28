import Foundation

/// A hardcoded work-order template for the "generate" button. No AI — just a
/// handful of canned rows we pick from at random and drop into the form.
struct SampleWorkOrder {
    let title: String
    let priority: String
    let assetModel: String
    let assetName: String
    let assetTag: String
    let site: String
    let reported: String
    let steps: [String]
}

enum SampleData {
    /// A few dumb, fully hardcoded work orders spanning the three units.
    static let all: [SampleWorkOrder] = [
        SampleWorkOrder(
            title: "Compressor short-cycling",
            priority: "High",
            assetModel: "AeroCool AC-5000",
            assetName: "Rooftop Chiller",
            assetTag: "A-204",
            site: "North Plant · Bldg 3, Roof, Zone N",
            reported: "Chiller keeps starting and stopping every couple of minutes. Head pressure looks high on the gauge. Cooling to Zone N is weak.",
            steps: ["Check refrigerant charge and subcooling",
                    "Inspect condenser coil for blockage",
                    "Test high-pressure switch",
                    "Verify condenser fan staging"]
        ),
        SampleWorkOrder(
            title: "No cooling — condenser fan not spinning",
            priority: "Emergency",
            assetModel: "ThermaFlow RTU-20",
            assetName: "Rooftop AC Unit",
            assetTag: "B-110",
            site: "Warehouse · Bldg 1, Roof, Bay 4",
            reported: "Warehouse office has no cooling, space is at 84°F and climbing. The condenser fan isn't turning. Occupied space, please prioritize.",
            steps: ["Confirm thermostat is calling for cooling",
                    "Check disconnect and breakers",
                    "Inspect contactor and run capacitor",
                    "Verify condenser fan motor"]
        ),
        SampleWorkOrder(
            title: "Musty smell from supply vents",
            priority: "High",
            assetModel: "VentMax AHU-8",
            assetName: "Air Handler",
            assetTag: "C-302",
            site: "Office Wing · Bldg 2, Mech 2B",
            reported: "Occupants report a musty, mildew-like smell from the vents at morning startup. Airflow feels a little weak too.",
            steps: ["Inspect chilled-water coil and drain pan for biofilm",
                    "Prime and flush the condensate trap",
                    "Replace the final filters",
                    "Verify airflow after service"]
        ),
        SampleWorkOrder(
            title: "Quarterly preventive maintenance",
            priority: "Routine",
            assetModel: "VentMax AHU-8",
            assetName: "Air Handler",
            assetTag: "C-302",
            site: "Office Wing · Bldg 2, Mech 2B",
            reported: "Scheduled quarterly PM. Run the standard air-handler service checklist and note belt and filter condition.",
            steps: ["Inspect and tension belts",
                    "Replace filters",
                    "Check bearings and lubricate",
                    "Verify damper operation"]
        ),
        SampleWorkOrder(
            title: "E11 low-superheat alarm",
            priority: "High",
            assetModel: "AeroCool AC-5000",
            assetName: "Rooftop Chiller",
            assetTag: "A-204",
            site: "North Plant · Bldg 3, Roof, Zone N",
            reported: "Unit is latching an E11 alarm on the display and dropping cooling. Suction line looks frosted near the compressor.",
            steps: ["Read superheat at the compressor",
                    "Inspect the electronic expansion valve",
                    "Check the suction temperature sensor strap",
                    "Confirm refrigerant charge"]
        ),
        SampleWorkOrder(
            title: "Economizer stuck — F11 fault",
            priority: "Routine",
            assetModel: "ThermaFlow RTU-20",
            assetName: "Rooftop AC Unit",
            assetTag: "B-110",
            site: "Warehouse · Bldg 1, Roof, Bay 4",
            reported: "Controller is throwing an F11 economizer fault. Free cooling isn't kicking in on mild mornings.",
            steps: ["Check damper linkage set screws",
                    "Test the actuator drive time",
                    "Verify the enthalpy sensor",
                    "Cycle the damper open to closed"]
        ),
    ]

    static func random() -> SampleWorkOrder {
        all.randomElement()!
    }
}
