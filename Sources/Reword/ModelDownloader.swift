import Foundation

/// One-time download of the GGUF weights from Hugging Face. This is the only network access the
/// app ever makes, and only when the user asks for it; translation itself never leaves the Mac.
@MainActor
final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = ModelDownloader()

    @Published private(set) var isInstalled = ModelStore.isInstalled
    @Published private(set) var progress: Double?
    @Published private(set) var error: String?
    @Published private(set) var verifying = false

    private var task: URLSessionDownloadTask?
    private var verifyTask: Task<Void, Never>?
    private var downloadingQuant: ModelQuant?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    /// Re-checks the selected model file (after the quantization changes).
    func refresh() {
        cancel()
        verifyTask?.cancel()       // a verification for the previous quantization is no longer wanted
        verifyTask = nil
        verifying = false
        error = nil
        isInstalled = ModelStore.isInstalled
    }

    func start() {
        guard task == nil, !verifying, !ModelStore.isInstalled else { return }
        error = nil
        progress = 0
        downloadingQuant = ModelStore.quant
        task = session.downloadTask(with: ModelStore.remoteURL)
        task?.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
        progress = nil
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : ModelStore.expectedBytes
        let value = Double(totalBytesWritten) / Double(total)
        MainActor.assumeIsolated {
            guard downloadTask === self.task else { return }     // ignore a cancelled earlier download
            progress = value
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file disappears when this method returns, so move it to a staging name synchronously;
        // it only becomes the model after its SHA-256 matches the published one.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let isCurrent = MainActor.assumeIsolated { downloadTask === self.task }
        guard isCurrent else { return }                           // superseded download: drop its file
        let quant = MainActor.assumeIsolated { self.downloadingQuant } ?? ModelStore.quant
        let final = ModelStore.url(for: quant)
        let staging = final.appendingPathExtension("download")
        var failure: String?
        if status == 200 {
            do {
                try ModelStore.ensureDirectory()
                try? FileManager.default.removeItem(at: staging)
                try FileManager.default.moveItem(at: location, to: staging)
            } catch {
                failure = error.localizedDescription
            }
        } else {
            failure = "Download failed (HTTP \(status))."
        }
        MainActor.assumeIsolated {
            if let failure { self.error = failure; return }
            self.verifying = true
            self.verifyTask = Task {
                let hashing = Task.detached(priority: .utility) { ModelStore.matches(staging, sha256: quant.sha256) }
                let ok = await withTaskCancellationHandler { await hashing.value } onCancel: { hashing.cancel() }
                if Task.isCancelled {                              // quantization switched while verifying
                    try? FileManager.default.removeItem(at: staging)
                    return
                }
                if ok {
                    // Installed under its own quantization's name, even if the selection changed meanwhile.
                    try? FileManager.default.removeItem(at: final)
                    do {
                        try FileManager.default.moveItem(at: staging, to: final)
                        ModelStore.markVerified(quant)
                    } catch { self.error = error.localizedDescription }
                } else {
                    try? FileManager.default.removeItem(at: staging)
                    self.error = "The downloaded model failed its integrity check and was deleted. Please try again."
                }
                self.verifying = false
                self.verifyTask = nil
                self.isInstalled = ModelStore.isInstalled
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard task === self.task else { return }              // a cancelled earlier download finishing late
            self.task = nil
            self.progress = nil
            if let error, (error as? URLError)?.code != .cancelled { self.error = error.localizedDescription }
        }
    }
}
