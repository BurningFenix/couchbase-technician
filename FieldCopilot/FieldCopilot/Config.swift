import Foundation

enum SyncConfig {
    static var endpointURL: String {
        Bundle.main.infoDictionary?["SYNC_ENDPOINT_URL"] as? String
            ?? "wss://YOUR-ID.apps.cloud.couchbase.com:4984/fieldcopilot-endpoint"
    }

    static var username: String {
        Bundle.main.infoDictionary?["SYNC_USERNAME"] as? String ?? "tech1"
    }

    static var password: String {
        Bundle.main.infoDictionary?["SYNC_PASSWORD"] as? String ?? "changeme"
    }

    /// True once a real Capella endpoint has been configured (not the
    /// placeholder). Sync auto-starts only when this is true.
    static var isConfigured: Bool {
        !endpointURL.contains("YOUR-ID") && URL(string: endpointURL) != nil
    }
}

enum AIConfig {
    /// OpenAI API key from Secrets.xcconfig (via Info.plist). nil when
    /// not configured - the app then runs fully on-device.
    static var openAIKey: String? {
        guard let key = Bundle.main.infoDictionary?["OPENAI_API_KEY"] as? String,
              !key.trimmingCharacters(in: .whitespaces).isEmpty else {
            return nil
        }
        return key.trimmingCharacters(in: .whitespaces)
    }

    static var hasOpenAIKey: Bool { openAIKey != nil }
}
