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
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    /// Re-checks the selected model file (after the quantization changes).
    func refresh() {
        cancel()
        error = nil
        isInstalled = ModelStore.isInstalled
    }

    func start() {
        guard task == nil, !verifying, !ModelStore.isInstalled else { return }
        error = nil
        progress = 0
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
        MainActor.assumeIsolated { progress = value }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file disappears when this method returns, so move it to a staging name synchronously;
        // it only becomes the model after its SHA-256 matches the published one.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let quant = ModelStore.quant
        let final = ModelStore.localURL
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
            Task {
                let ok = await Task.detached(priority: .utility) { ModelStore.matchesPublishedHash(staging) }.value
                if ok, quant == ModelStore.quant {
                    try? FileManager.default.removeItem(at: final)
                    do {
                        try FileManager.default.moveItem(at: staging, to: final)
                        ModelStore.markVerified()
                    } catch { self.error = error.localizedDescription }
                } else {
                    try? FileManager.default.removeItem(at: staging)
                    self.error = "The downloaded model failed its integrity check and was deleted. Please try again."
                }
                self.verifying = false
                self.isInstalled = ModelStore.isInstalled
                if self.isInstalled { await HyMTEngine.shared.warmUp() }
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            self.task = nil
            self.progress = nil
            if let error, (error as? URLError)?.code != .cancelled { self.error = error.localizedDescription }
        }
    }
}
