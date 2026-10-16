import CryptoKit
import Foundation
import OSLog
import Synchronization
import llama

/// A translator that runs entirely on this Mac.
protocol TranslationEngine: Sendable {
    var id: String { get }
    var name: String { get }
    var detail: String { get }
    func translate(_ text: String, from source: String, to target: String,
                   onPartial: @escaping @Sendable (String) -> Void) async throws -> String
}

enum EngineError: LocalizedError {
    case modelMissing(URL)
    case modelLoadFailed(String)
    case tooLong
    case modelCorrupted
    case decodeFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .modelMissing:
            return "The translation model isn't downloaded yet. Download it from the popup or Settings."
        case let .modelLoadFailed(path): return "Couldn't load the model at \(path)."
        case .tooLong: return "The text is too long for the model's context window."
        case .modelCorrupted: return "The model file doesn't match its published checksum and wasn't loaded. Delete it in Settings › Show in Finder and download it again."
        case let .decodeFailed(code): return "The model failed while generating (llama_decode returned \(code))."
        }
    }
}

/// The official Hy-MT2 GGUF quantizations; smaller files use less memory at some cost in quality.
enum ModelQuant: String, CaseIterable, Identifiable {
    case q4 = "Q4_K_M", q6 = "Q6_K", q8 = "Q8_0"

    var id: String { rawValue }
    var bytes: Int64 {
        switch self {
        case .q4: return 1_133_080_448
        case .q6: return 1_474_785_120
        case .q8: return 1_908_528_192
        }
    }
    /// SHA-256 published by Hugging Face for tencent/Hy-MT2-1.8B-GGUF; downloads must match it.
    var sha256: String {
        switch self {
        case .q4: return "dc5f44fcf1fa496ee7ad725982c0c8c553a4de00259b53af84c4b89fb0c06699"
        case .q6: return "d98fe604dec1f28f58f80d7d560f7177e584d3b8e5835862687660e5ff97cb40"
        case .q8: return "5c3fe0b1408a5ceb0143184ef247b11b579c525f4b02b060e6c851bb76fef1a4"
        }
    }
    var label: String {
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        switch self {
        case .q4: return "Small · \(size) · fastest"
        case .q6: return "Medium · \(size)"
        case .q8: return "Large · \(size) · best quality"
        }
    }
}

/// Where the GGUF model lives and where it is downloaded from.
enum ModelStore {
    static let quantKey = "modelQuant"

    static var quant: ModelQuant {
        ModelQuant(rawValue: UserDefaults.standard.string(forKey: quantKey) ?? "") ?? .q4
    }
    static var fileName: String { "Hy-MT2-1.8B-\(quant.rawValue).gguf" }
    static var remoteURL: URL { URL(string: "https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/main/\(fileName)")! }
    static var expectedBytes: Int64 { quant.bytes }

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.ou.Reword/Models", isDirectory: true)
    }
    static var localURL: URL { directory.appendingPathComponent(fileName) }
    static var isInstalled: Bool { FileManager.default.fileExists(atPath: localURL.path) }

    /// Creates the model folder readable only by this user.
    static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    // A verified file is remembered by size and modification time; any change forces a full re-hash.
    static func url(for quant: ModelQuant) -> URL { directory.appendingPathComponent("Hy-MT2-1.8B-\(quant.rawValue).gguf") }

    private static func fingerprint(_ quant: ModelQuant) -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url(for: quant).path),
              let size = attrs[.size] as? Int64, let date = attrs[.modificationDate] as? Date else { return nil }
        return "\(quant.sha256):\(size):\(date.timeIntervalSince1970)"
    }

    static var isVerified: Bool {
        guard let current = fingerprint(quant) else { return false }
        return UserDefaults.standard.string(forKey: "verified.\(quant.rawValue)") == current
    }

    static func markVerified(_ quant: ModelQuant = quant) {
        UserDefaults.standard.set(fingerprint(quant), forKey: "verified.\(quant.rawValue)")
    }

    /// Streams a file through SHA-256 and compares it with an expected hex digest.
    nonisolated static func matches(_ url: URL, sha256 expected: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            if Task.isCancelled { return false }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined() == expected
    }

    static var sizeOnDisk: String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64) ?? 0
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Builds Hy-MT2 prompts as documented on the model card: the Chinese template when Chinese is
/// on either side, the English template otherwise, with full language names in the prompt's language.
enum HyMTPrompt {
    /// chat_template.jinja: no system prompt, one user turn, generation prompt.
    static let prefix = "<｜hy_begin▁of▁sentence｜><｜hy_User｜>"
    static let suffix = "<｜hy_Assistant｜>"

    /// The user turn: the instruction plus the text. It is tokenized as plain text, so control markers
    /// inside the text being translated can't act as real special tokens.
    static func body(_ text: String, from source: String, to target: String) -> String {
        let chinese = isChinese(source) || isChinese(target)
        let body: String
        if chinese {
            let name = Locale(identifier: "zh-Hans").localizedString(forIdentifier: target) ?? target
            body = "将以下文本翻译为\(name)，注意只需要输出翻译后的结果，不要额外解释：\n\n\(text)"
        } else {
            let name = Locale(identifier: "en").localizedString(forIdentifier: target) ?? target
            body = "Translate the following text into \(name). Note that you should only output the translated result without any additional explanation:\n\n\(text)"
        }
        return body
    }

    private static func isChinese(_ id: String) -> Bool {
        Locale.Language(identifier: id).languageCode?.identifier == "zh"
    }
}

/// tencent/Hy-MT2-1.8B running in-process through llama.cpp (Metal). Loaded once, kept in memory.
actor HyMTEngine: TranslationEngine {
    nonisolated let id = "hy-mt2"
    nonisolated let name = "Hy-MT2 Translate"
    nonisolated var detail: String { "on-device" }

    static let shared = HyMTEngine()

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private let contextSize: UInt32 = 4096
    private var backendReady = false
    private var loadedPath: String?
    private var unloadTask: Task<Void, Never>?

    /// Readable without waiting for the actor, which may be busy loading the model.
    private nonisolated let loaded = Mutex(false)
    nonisolated var isLoaded: Bool { loaded.withLock { $0 } }

    private init() {}

    func translate(_ text: String, from source: String, to target: String,
                   onPartial: @escaping @Sendable (String) -> Void) async throws -> String {
        try Task.checkCancellation()                 // a superseded request skips the expensive prefill
        unloadTask?.cancel()
        defer { scheduleUnload() }
        try loadIfNeeded()
        guard let model, let context else { throw EngineError.modelLoadFailed(ModelStore.localURL.path) }
        let vocab = llama_model_get_vocab(model)

        let textTokens = tokenize(HyMTPrompt.body(text, from: source, to: target), vocab: vocab, special: false)
        var tokens = tokenize(HyMTPrompt.prefix, vocab: vocab, special: true) + textTokens
            + tokenize(HyMTPrompt.suffix, vocab: vocab, special: true)
        // Room for the translation: generous for scripts that need more tokens, but bounded so a
        // repetition loop can't run to the end of the context.
        let budget = min(Int(contextSize) - tokens.count, 3 * textTokens.count + 128)
        guard budget >= 128 else { throw EngineError.tooLong }
        try Task.checkCancellation()

        llama_memory_clear(llama_get_memory(context), true)
        let sampler = makeSampler(vocab: vocab)
        defer { llama_sampler_free(sampler) }

        var status = tokens.withUnsafeMutableBufferPointer { buf in
            llama_decode(context, llama_batch_get_one(buf.baseAddress, Int32(buf.count)))
        }
        guard status == 0 else { throw EngineError.decodeFailed(status) }

        var output: [UInt8] = []
        var piece = [CChar](repeating: 0, count: 256)
        var finished = false
        var lastEmit = ContinuousClock.now
        for _ in 0..<budget {
            try Task.checkCancellation()
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { finished = true; break }
            let n = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if n > 0 { output.append(contentsOf: piece[0..<Int(n)].map { UInt8(bitPattern: $0) }) }
            // Stream at most ~20 updates a second; decoding the whole buffer per token would be O(n²).
            if ContinuousClock.now - lastEmit > .milliseconds(50) {
                lastEmit = .now
                onPartial(Self.decode(output).trimmingCharacters(in: CharacterSet(charactersIn: "\u{FFFD}")))
            }
            status = llama_decode(context, llama_batch_get_one(&token, 1))
            guard status == 0 else { throw EngineError.decodeFailed(status) }
        }
        let result = Self.decode(output).trimmingCharacters(in: .whitespacesAndNewlines)
        return finished ? result : result + " …\n\n(The translation was cut off: the text is too long. Try a shorter passage.)"
    }

    /// Loads the model ahead of the first translation so the popup feels instant.
    func warmUp() {
        try? loadIfNeeded()
        scheduleUnload()
    }

    /// The GPU shaders compile on the first generation after installing a new build (~8 s), and macOS caches
    /// them afterwards. Pay that once in the background with a throwaway translation.
    func compileShadersIfNeeded() async {
        let key = "shadersCompiledFor"
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            + "-" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
        guard ModelStore.isInstalled, UserDefaults.standard.string(forKey: key) != build else { return }
        let start = ContinuousClock.now
        if (try? await translate("Hello", from: "en", to: "uk") { _ in }) != nil {
            UserDefaults.standard.set(build, forKey: key)
            Logger(subsystem: "com.ou.Reword", category: "engine")
                .info("shader warm-up took \(ContinuousClock.now - start, privacy: .public)")
        }
    }

    /// Frees the model after the idle timeout from Settings (0 = keep loaded).
    private func scheduleUnload() {
        unloadTask?.cancel()
        let seconds = UserDefaults.standard.integer(forKey: Prefs.idleUnloadSeconds)
        guard seconds > 0, context != nil else { return }
        unloadTask = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self.unload()
        }
    }

    /// Releases the model and context (about 2 GB); the next translation loads them again.
    func unload() {
        unloadTask?.cancel()
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        context = nil
        model = nil
        loadedPath = nil
        loaded.withLock { $0 = false }
    }

    /// Frees llama.cpp state; the Metal backend asserts at process exit if buffers are still alive.
    func shutdown() {
        unload()
        if backendReady { llama_backend_free() }
        backendReady = false
    }

    private func loadIfNeeded() throws {
        if context != nil, loadedPath == ModelStore.localURL.path { return }
        unload()                                     // a different quantization was selected
        guard ModelStore.isInstalled else { throw EngineError.modelMissing(ModelStore.localURL) }
        try? ModelStore.ensureDirectory()
        // Only load a file whose SHA-256 matches the published one (re-hashed if it changed since last check).
        if !ModelStore.isVerified {
            guard ModelStore.matches(ModelStore.localURL, sha256: ModelStore.quant.sha256) else { throw EngineError.modelCorrupted }
            ModelStore.markVerified()
        }
        if !backendReady {
            llama_log_set({ _, _, _ in }, nil)
            llama_backend_init()
            backendReady = true
        }

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 99
        guard let loaded = llama_model_load_from_file(ModelStore.localURL.path, modelParams) else {
            throw EngineError.modelLoadFailed(ModelStore.localURL.path)
        }
        var ctxParams = llama_context_default_params()
        ctxParams.n_ctx = contextSize
        ctxParams.n_batch = contextSize      // whole prompt in one decode call
        ctxParams.n_ubatch = 512
        guard let ctx = llama_init_from_model(loaded, ctxParams) else {
            llama_model_free(loaded)
            throw EngineError.modelLoadFailed(ModelStore.localURL.path)
        }
        model = loaded
        context = ctx
        loadedPath = ModelStore.localURL.path
        self.loaded.withLock { $0 = true }
    }

    /// `special` parses control markers such as the role tokens; it is only enabled for the template parts.
    private func tokenize(_ text: String, vocab: OpaquePointer?, special: Bool) -> [llama_token] {
        let utf8 = Array(text.utf8CString)
        let length = Int32(utf8.count - 1)
        var tokens = [llama_token](repeating: 0, count: utf8.count + 8)
        // BOS is part of the template prefix, so never add it automatically.
        var n = llama_tokenize(vocab, utf8, length, &tokens, Int32(tokens.count), false, special)
        if n < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-n))
            n = llama_tokenize(vocab, utf8, length, &tokens, Int32(tokens.count), false, special)
        }
        return Array(tokens.prefix(Int(max(n, 0))))
    }

    /// Sampling settings recommended on the model card for the 1.8B model.
    private func makeSampler(vocab: OpaquePointer?) -> UnsafeMutablePointer<llama_sampler> {
        let chain = llama_sampler_chain_init(llama_sampler_chain_default_params())!
        llama_sampler_chain_add(chain, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, 1.05, 0, 0))
        llama_sampler_chain_add(chain, llama_sampler_init_top_k(20))
        llama_sampler_chain_add(chain, llama_sampler_init_top_p(0.6, 1))
        llama_sampler_chain_add(chain, llama_sampler_init_temp(0.7))
        llama_sampler_chain_add(chain, llama_sampler_init_dist(UInt32.random(in: 0...UInt32.max)))
        return chain
    }

    private static func decode(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}

enum Engines {
    static let all: [any TranslationEngine] = [HyMTEngine.shared]
}
