import Foundation
import CouchbaseLiteSwift

final class SyncManager: @unchecked Sendable {
    private var replicator: Replicator?
    private var listenerToken: ListenerToken?

    func start(
        database: Database,
        collections: [Collection],
        onChange: @escaping @Sendable (String, String, String?) -> Void
    ) throws {
        guard let url = URL(string: SyncConfig.endpointURL) else { return }
        let target = URLEndpoint(url: url)

        let collConfigs = CollectionConfiguration.fromCollections(collections)

        var config = ReplicatorConfiguration(collections: collConfigs, target: target)
        config.replicatorType = .pushAndPull
        config.continuous = true
        config.maxAttempts = 0

        config.authenticator = BasicAuthenticator(
            username: SyncConfig.username,
            password: SyncConfig.password
        )

        let replicator = Replicator(config: config)

        listenerToken = replicator.addChangeListener { change in
            let s = change.status
            let activity: String
            switch s.activity {
            case .stopped: activity = "stopped"
            case .offline: activity = "offline"
            case .connecting: activity = "connecting"
            case .idle: activity = "idle"
            case .busy: activity = "busy"
            @unknown default: activity = "unknown"
            }
            let progress = "\(s.progress.completed)/\(s.progress.total)"
            let error = s.error?.localizedDescription
            onChange(activity, progress, error)
        }

        replicator.start()
        self.replicator = replicator
    }

    func stop() {
        listenerToken?.remove()
        listenerToken = nil
        replicator?.stop()
        replicator = nil
    }
}
