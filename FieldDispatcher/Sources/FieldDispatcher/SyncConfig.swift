import Foundation

/// Sync credentials for Capella App Services. These MUST match the iPhone
/// app's Secrets.xcconfig (same endpoint, same user) so both replicate
/// against the same App Services endpoint and see each other's documents.
///
/// Values are read from `capella-config.json` in the working directory (the
/// package root when you `swift run` from here), or from the file pointed at
/// by the CAPELLA_CONFIG env var. If neither is found, placeholder defaults
/// are used and sync will not connect until you fill them in.
enum SyncConfig {
    struct Values: Codable {
        var endpointURL: String
        var username: String
        var password: String
    }

    static let values: Values = {
        let fm = FileManager.default
        let candidates = [
            ProcessInfo.processInfo.environment["CAPELLA_CONFIG"],
            fm.currentDirectoryPath + "/capella-config.json",
        ].compactMap { $0 }.filter { !$0.isEmpty }

        for path in candidates {
            if let data = fm.contents(atPath: path),
               let v = try? JSONDecoder().decode(Values.self, from: data) {
                return v
            }
        }
        return Values(
            endpointURL: "wss://YOUR-ID.apps.cloud.couchbase.com:4984/fieldcopilot-endpoint",
            username: "tech1",
            password: "changeme"
        )
    }()

    static var endpointURL: String { values.endpointURL }
    static var username: String { values.username }
    static var password: String { values.password }

    /// True once the placeholder endpoint has been replaced with a real one.
    static var isConfigured: Bool {
        !endpointURL.contains("YOUR-ID") && URL(string: endpointURL) != nil
    }
}
