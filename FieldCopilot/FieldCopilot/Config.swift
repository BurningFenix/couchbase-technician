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

    // MARK: - Per-technician credentials

    // Each demo technician authenticates to App Services as their OWN App
    // User, so isolation is enforced by the server: Kyle's replicator is
    // only granted his channel, so BJ's work orders can never reach his
    // device. Switching users in Settings restarts the replicator with the
    // other set of credentials.
    //
    // Values come from Secrets.xcconfig (generated from .env by
    // scripts/setup.sh). If a per-user value is missing we fall back to the
    // single shared SYNC_USERNAME/SYNC_PASSWORD, so an older .env keeps
    // working - it just won't isolate the two techs.

    private static func value(_ key: String) -> String? {
        guard let v = Bundle.main.infoDictionary?[key] as? String else { return nil }
        let trimmed = v.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func username(for user: DemoUser) -> String {
        value(user == .kyle ? "SYNC_USERNAME_KYLE" : "SYNC_USERNAME_BJ") ?? username
    }

    static func password(for user: DemoUser) -> String {
        value(user == .kyle ? "SYNC_PASSWORD_KYLE" : "SYNC_PASSWORD_BJ") ?? password
    }

    /// True when both technicians have their own credentials, i.e. per-user
    /// isolation is actually in effect rather than a shared login.
    static var hasPerUserCredentials: Bool {
        value("SYNC_USERNAME_KYLE") != nil && value("SYNC_USERNAME_BJ") != nil
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
