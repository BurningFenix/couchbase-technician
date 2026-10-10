import Foundation

/// Downloads a Hugging Face model repo (pinned to one commit) into
/// Application Support with REAL byte-level progress.
///
/// Why not the MLX `#hubDownloader()`: its NSProgress reports 0 bytes until
/// the multi-GB weight file finishes on-device, so the UI could only ever
/// show an indeterminate spinner. Here the file sizes come from the Hub
/// tree API up front and every chunk written is reported, so the first-run
/// download gets an honest determinate bar.
///
/// Resumable at file granularity: files already on disk with the expected
/// size are skipped, and a `.complete` marker short-circuits the whole step
/// once everything has landed.
enum ModelDownloader {
    struct Progress: Sendable {
        let completedBytes: Int64
        let totalBytes: Int64
        var fraction: Double { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0 }
    }

    /// Only the files MLX needs to build a text model; skips README etc.
    private static let wantedExtensions: Set<String> = ["json", "safetensors", "jinja", "txt", "model"]

    static func localDirectory(repo: String, revision: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(repo.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
            .appendingPathComponent(revision, isDirectory: true)
    }

    static func isDownloaded(repo: String, revision: String) -> Bool {
        FileManager.default.fileExists(
            atPath: localDirectory(repo: repo, revision: revision).appendingPathComponent(".complete").path)
    }

    /// Ensures every model file is on disk and returns the local directory.
    static func ensureDownloaded(
        repo: String,
        revision: String,
        onProgress: @escaping @Sendable (Progress) -> Void
    ) async throws -> URL {
        let dir = localDirectory(repo: repo, revision: revision)
        let marker = dir.appendingPathComponent(".complete")
        if FileManager.default.fileExists(atPath: marker.path) { return dir }

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Weights are re-downloadable; keep them out of iCloud/iTunes backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDir = dir
        try? mutableDir.setResourceValues(values)

        let files = try await listFiles(repo: repo, revision: revision)
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        var done: Int64 = 0

        for file in files {
            let dest = dir.appendingPathComponent(file.path)
            if let size = (try? FileManager.default.attributesOfItem(atPath: dest.path))?[.size] as? Int64,
               size == file.size {
                done += file.size
                onProgress(Progress(completedBytes: done, totalBytes: total))
                continue
            }
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let url = URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file.path)")!
            let base = done
            try await FileDownload.run(from: url, to: dest) { written in
                onProgress(Progress(completedBytes: base + written, totalBytes: total))
            }
            done += file.size
        }

        FileManager.default.createFile(atPath: marker.path, contents: nil)
        return dir
    }

    private struct HubFile: Decodable {
        let type: String
        let path: String
        let size: Int64
    }

    private static func listFiles(repo: String, revision: String) async throws -> [HubFile] {
        let url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/\(revision)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw DownloadError.listingFailed
        }
        return try JSONDecoder().decode([HubFile].self, from: data).filter {
            $0.type == "file" && wantedExtensions.contains(($0.path as NSString).pathExtension)
        }
    }

    enum DownloadError: LocalizedError {
        case listingFailed
        case badStatus(Int)

        var errorDescription: String? {
            switch self {
            case .listingFailed: "Couldn't reach Hugging Face to list the model files. Check your connection."
            case .badStatus(let code): "Model download failed (HTTP \(code))."
            }
        }
    }
}

/// One file download via a delegate-backed URLSession, which (unlike the
/// async `download(from:)` convenience) reports bytes as they are written.
private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onBytes: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var moveError: Error?
    private var lastReport = Date.distantPast

    private init(destination: URL, onBytes: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.onBytes = onBytes
    }

    static func run(from url: URL, to destination: URL, onBytes: @escaping @Sendable (Int64) -> Void) async throws {
        let download = FileDownload(destination: destination, onBytes: onBytes)
        let session = URLSession(configuration: .default, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                download.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // Fires per network chunk; ~10 updates/s is plenty for a progress bar.
        let now = Date()
        guard now.timeIntervalSince(lastReport) > 0.1 else { return }
        lastReport = now
        onBytes(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this returns, so move it now.
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            moveError = ModelDownloader.DownloadError.badStatus(http.statusCode)
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error ?? moveError {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
        continuation = nil
    }
}
