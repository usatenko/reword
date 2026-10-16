import Foundation
import SwiftUI

enum Prefs {
    /// Target languages the user has picked, most recent first — the way Google Translate remembers languages.
    static let recentTargets = "recentTargets"
    static let idleUnloadSeconds = "idleUnloadSeconds"
    private static let maxRecent = 5

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [Prefs.idleUnloadSeconds: 300])
        migrateLanguagePair()
    }

    /// Never empty. Until the user picks anything it's the Mac's language list with the first two swapped, so text
    /// in the Mac's main language goes into the second one and back (English + Ukrainian → Ukrainian, English).
    static var recents: [String] {
        if let saved = UserDefaults.standard.stringArray(forKey: recentTargets), !saved.isEmpty { return saved }
        var ids: [String] = []
        for id in Locale.preferredLanguages.compactMap(LanguageTools.appLanguageID) where !ids.contains(id) { ids.append(id) }
        if ids.isEmpty { ids = ["en"] }
        if ids.count == 1 { ids.append(ids[0] == "en" ? "zh-Hans" : "en") }
        ids.swapAt(0, 1)
        return ids
    }

    /// Auto target: the most recent language that isn't the text's own.
    static func autoTarget(for source: String) -> String {
        let list = recents
        return list.first { !LanguageTools.same($0, source) } ?? list[0]
    }

    /// A target the user picked moves to the front, so Auto uses it from now on.
    static func noteTarget(_ id: String) {
        var list = recents.filter { !LanguageTools.same($0, id) }
        list.insert(id, at: 0)
        UserDefaults.standard.set(Array(list.prefix(maxRecent)), forKey: recentTargets)
    }

    /// Versions up to 0.1.10 kept a primary/secondary pair; it becomes the two most recent targets.
    private static func migrateLanguagePair() {
        let defaults = UserDefaults.standard
        let pair = ["secondLanguage", "firstLanguage"].compactMap { defaults.string(forKey: $0) }
        guard defaults.stringArray(forKey: recentTargets) == nil, !pair.isEmpty else { return }
        var list = pair
        for id in recents where !list.contains(id) { list.append(id) }
        defaults.set(Array(list.prefix(maxRecent)), forKey: recentTargets)
        for key in ["firstLanguage", "secondLanguage", "otherLanguagesTarget"] { defaults.removeObject(forKey: key) }
    }
}

struct EngineResult: Identifiable {
    enum State { case loading, streaming(String), done(String), failed(String) }
    let id: String
    let name: String
    let detail: String
    var state: State
}

@MainActor
final class TranslatorModel: ObservableObject {
    static let auto = "auto"

    @Published var input = ""
    @Published var sourceChoice = TranslatorModel.auto { didSet { choicesChanged() } }
    @Published var targetChoice = TranslatorModel.auto { didSet { choicesChanged() } }
    @Published private(set) var detected: String?
    @Published private(set) var resolvedTarget: String?
    @Published private(set) var results: [EngineResult] = []
    /// Pinned: the window stays open and on top. Unpinned: it hides when you click another app.
    @Published var pinned = UserDefaults.standard.bool(forKey: "pinned") {
        didSet { UserDefaults.standard.set(pinned, forKey: "pinned") }
    }
    /// A one-line message shown above the results, e.g. an OCR problem.
    @Published var notice: String?
    /// Translation progress ("Loading the translation model…"), shown with a spinner in the translation box.
    @Published var status: String?
    /// Input progress ("Reading text from screenshot…"), shown with a spinner in the input box.
    @Published var inputStatus: String?
    /// Bumped to move keyboard focus into the input field.
    @Published private(set) var focusRequest = 0

    func focusInput() { focusRequest += 1 }

    private var task: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var lastRequest: String?
    private var run = 0
    private var pendingChoiceChange = false

    /// Several choice changes in one turn (e.g. swapping both languages) translate once.
    private func choicesChanged() {
        guard !pendingChoiceChange else { return }
        pendingChoiceChange = true
        Task { @MainActor in
            self.pendingChoiceChange = false
            guard !self.input.isEmpty, self.requestKey != self.lastRequest else { return }
            self.translate()
        }
    }

    /// Stops any translation in progress (used when quitting).
    func cancelAll() {
        debounce?.cancel()
        task?.cancel()
    }

    /// Called on every edit: updates detection now and translates once typing pauses.
    func inputChanged() {
        updateDetection()
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled, self.requestKey != self.lastRequest else { return }
            self.translate()
        }
    }

    private var requestKey: String {
        "\(sourceChoice)|\(targetChoice)|\(input.trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    func translate() {
        debounce?.cancel()
        lastRequest = requestKey
        task?.cancel()
        notice = nil
        status = nil
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            results = []
            detected = nil
            resolvedTarget = nil
            return
        }
        let source = sourceChoice == Self.auto ? (LanguageTools.detect(text) ?? "en") : sourceChoice
        let target = target(for: source)
        detected = source
        resolvedTarget = target

        run += 1
        let run = run
        // Without the model, start downloading it; the popup shows its progress and translates when it's ready.
        guard ModelStore.isInstalled else {
            results = []
            ModelDownloader.shared.start()
            return
        }
        let engines = Engines.all
        results = engines.map { EngineResult(id: $0.id, name: $0.name, detail: $0.detail, state: .loading) }

        task = Task {
            if !HyMTEngine.shared.isLoaded, run == self.run { status = "Loading the translation model…" }
            for engine in engines {
                let id = engine.id
                let state: EngineResult.State
                if LanguageTools.same(source, target) {
                    state = .done(text)
                } else {
                    do {
                        let output = try await engine.translate(text, from: source, to: target) { partial in
                            Task { @MainActor in self.update(id, .streaming(partial), run: run) }
                        }
                        state = .done(output)
                    } catch is CancellationError {
                        return
                    } catch {
                        state = .failed(error.localizedDescription)
                    }
                }
                guard !Task.isCancelled else { return }
                update(id, state, run: run)
            }
        }
    }

    private func update(_ id: String, _ state: EngineResult.State, run: Int) {
        guard run == self.run, let index = results.firstIndex(where: { $0.id == id }) else { return }
        status = nil                                     // output has started (or failed): the progress line goes
        // A late streaming chunk must not overwrite the final result or a longer chunk that arrived first.
        if case .streaming = state, case .done = results[index].state { return }
        if case .streaming = state, case .failed = results[index].state { return }
        if case let .streaming(new) = state, case let .streaming(old) = results[index].state, new.count < old.count { return }
        results[index].state = state
    }

    /// Target shown in the language bar: the resolved one, or the default (second language) before any text.
    var displayTarget: String {
        resolvedTarget ?? Prefs.recents[0]
    }

    /// Live detection while typing, so the language bar shows real languages before translating.
    func updateDetection() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { detected = nil; resolvedTarget = nil; return }
        let source = sourceChoice == Self.auto ? (LanguageTools.detect(text) ?? "en") : sourceChoice
        detected = source
        resolvedTarget = target(for: source)
    }

    /// Auto (see Prefs.autoTarget), unless a target was picked in the window, which wins unless it's the language
    /// of the text itself.
    private func target(for source: String) -> String {
        if targetChoice != Self.auto, !LanguageTools.same(targetChoice, source) { return targetChoice }
        return Prefs.autoTarget(for: source)
    }


    /// A pick is remembered as the most recent target, and the window stays on Auto, which now resolves to it
    /// (or, when it's the text's own language, to the next recent one).
    func chooseTarget(_ id: String) {
        lastRequest = nil                // staying on Auto can still change the result: translate again
        if id != Self.auto { Prefs.noteTarget(id) }
        targetChoice = Self.auto
    }

    func swapLanguages() {
        guard let detected, let resolvedTarget else { return }
        Prefs.noteTarget(detected)       // a language you translate into is one you use
        sourceChoice = resolvedTarget
        targetChoice = detected          // choicesChanged() translates once
    }

    func load(_ text: String) {
        inputStatus = nil
        input = text
        sourceChoice = Self.auto
        targetChoice = Self.auto
        translate()
    }

    func clear() {
        debounce?.cancel()
        lastRequest = nil
        task?.cancel()
        notice = nil
        status = nil
        inputStatus = nil
        run += 1
        input = ""
        results = []
        detected = nil
        resolvedTarget = nil
        lastRequest = requestKey         // the empty input must not trigger a debounced translate (it would clear a notice)
    }
}
