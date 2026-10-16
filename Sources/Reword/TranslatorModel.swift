import Foundation
import SwiftUI

enum Prefs {
    static let first = "firstLanguage"
    static let second = "secondLanguage"
    /// Where text in a language other than the two goes: "primary" or "secondary".
    static let otherTarget = "otherLanguagesTarget"
    static let idleUnloadSeconds = "idleUnloadSeconds"

    /// The pair defaults to the first two languages in the Mac's language list that Reword supports.
    static func registerDefaults() {
        var ids: [String] = []
        for id in Locale.preferredLanguages.compactMap(LanguageTools.appLanguageID) where !ids.contains(id) { ids.append(id) }
        let first = ids.first ?? "en"
        UserDefaults.standard.register(defaults: [
            Prefs.first: first,
            Prefs.second: ids.dropFirst().first ?? (first == "en" ? "zh-Hans" : "en"),
            Prefs.otherTarget: "primary",
            Prefs.idleUnloadSeconds: 300,
        ])
    }

    /// Auto target: primary-language text goes to the secondary language, secondary-language text to the primary
    /// one, and anything else to whichever of the two was last picked for such text (the primary at first).
    static func autoTarget(for source: String) -> String {
        let defaults = UserDefaults.standard
        let first = defaults.string(forKey: Prefs.first) ?? "en"
        let second = defaults.string(forKey: Prefs.second) ?? "zh-Hans"
        if LanguageTools.same(source, first) { return second }
        if LanguageTools.same(source, second) { return first }
        return defaults.string(forKey: Prefs.otherTarget) == "secondary" ? second : first
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
        resolvedTarget ?? UserDefaults.standard.string(forKey: Prefs.second) ?? "en"
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


    /// A pick in the window is remembered where it fits the language pair, and the window stays on Auto:
    /// - for text in the primary language (or before there's text), it becomes the secondary language;
    /// - for text in a third language, picking the primary or secondary one sends all such text there from now on.
    /// Anything else (e.g. French for German text) is a one-off for this window and leaves the pair as it is.
    func chooseTarget(_ id: String) {
        lastRequest = nil                // staying on Auto can still change the result: translate again
        let defaults = UserDefaults.standard
        let first = defaults.string(forKey: Prefs.first) ?? "en"
        let second = defaults.string(forKey: Prefs.second) ?? "zh-Hans"
        guard id != Self.auto else { targetChoice = Self.auto; return }
        if detected.map({ LanguageTools.same($0, first) }) ?? true {
            if !LanguageTools.same(id, first) { defaults.set(id, forKey: Prefs.second) }
        } else if let source = detected, !LanguageTools.same(source, second) {
            if LanguageTools.same(id, first) { defaults.set("primary", forKey: Prefs.otherTarget) }
            if LanguageTools.same(id, second) { defaults.set("secondary", forKey: Prefs.otherTarget) }
        }
        // Stay on Auto when it now gives this language, or when it's the text's own language (nothing to do).
        let autoCovers = detected.map { LanguageTools.same(Prefs.autoTarget(for: $0), id) || LanguageTools.same($0, id) } ?? true
        targetChoice = autoCovers ? Self.auto : id
    }

    func swapLanguages() {
        guard let detected, let resolvedTarget else { return }
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
