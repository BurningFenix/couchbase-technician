// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FieldDispatcher",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "FieldDispatcher",
            dependencies: ["CouchbaseLiteSwift"]
        ),
        // The same Couchbase Lite enterprise xcframework the iPhone app uses
        // (its macOS slice). Basic replication only — no vector search here.
        .binaryTarget(
            name: "CouchbaseLiteSwift",
            path: "../FieldCopilot/couchbase-lite-swift_xc_enterprise_4/CouchbaseLiteSwift.xcframework"
        ),
    ]
)
