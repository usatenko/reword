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
    private var folderWatch: DispatchSourceFileSystemObject?
    private var verifyTask: Task<Void, Never>?
    private var downloadingQuant: ModelQuant?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    override init() {
        super.init()
        watchModelsFolder()
    }

    /// Notices the model file being added or removed outside the app (e.g. deleted in Finder).
    private func watchModelsFolder() {
        try? ModelStore.ensureDirectory()
        let fd = open(ModelStore.directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.task == nil, !self.verifying else { return }
                self.isInstalled = ModelStore.isInstalled
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        folderWatch = source
    }

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
        let quant = ModelStore.quant
        downloadingQuant = quant
        // Continue a download that was interrupted by quitting (e.g. "Restart Reword" for Screen Recording).
        let resumeURL = Self.resumeURL(for: quant)
        if let data = try? Data(contentsOf: resumeURL) {
            try? FileManager.default.removeItem(at: resumeURL)
            resuming = true
            task = session.downloadTask(withResumeData: data)
        } else {
            resuming = false
            task = session.downloadTask(with: ModelStore.remoteURL)
        }
        task?.resume()
    }

    /// Whether the current task continues an earlier download; if that fails, it starts over once by itself.
    private var resuming = false

    private static func resumeURL(for quant: ModelQuant) -> URL {
        ModelStore.url(for: quant).appendingPathExtension("resume")
    }

    /// Called when Reword quits: keeps what was downloaded so far, so the next launch continues from there. The
    /// returned wait doesn't need the main thread (it may be blocked while quitting) and gives up after 2 s.
    func saveForQuit() -> @Sendable () -> Void {
        guard let task, let quant = downloadingQuant else { return {} }
        self.task = nil
        let url = Self.resumeURL(for: quant)
        let saved = DispatchSemaphore(value: 0)
        task.cancel(byProducingResumeData: { data in
            if let data { try? data.write(to: url, options: .atomic) }
            saved.signal()
        })
        return { _ = saved.wait(timeout: .now() + 2) }
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
                if self.isInstalled { Task.detached(priority: .utility) { await HyMTEngine.shared.compileShadersIfNeeded() } }
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard task === self.task else { return }              // a cancelled earlier download finishing late
            self.task = nil
            self.progress = nil
            guard let error, (error as? URLError)?.code != .cancelled else { return }
            if self.resuming {                                    // the saved partial download is unusable
                self.resuming = false
                self.start()
                return
            }
            self.error = error.localizedDescription
        }
    }
}
