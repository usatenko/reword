import Foundation
import SwiftUI

enum Prefs {
    static let first = "firstLanguage"
    static let second = "secondLanguage"
    static let idleUnloadSeconds = "idleUnloadSeconds"

    static func registerDefaults() {
        let system = Locale.preferredLanguages.first.map { Locale.Language(identifier: $0) }
        var first = "en"
        if let code = system?.languageCode?.identifier {
            first = code == "zh" ? (system?.script?.identifier == "Hant" ? "zh-Hant" : "zh-Hans") : code
        }
        UserDefaults.standard.register(defaults: [
            Prefs.first: first,
            Prefs.second: first == "en" ? "zh-Hans" : "en",
            Prefs.idleUnloadSeconds: 300,
        ])
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
    @Published var sourceChoice = TranslatorModel.auto
    @Published var targetChoice = TranslatorModel.auto
    @Published private(set) var detected: String?
    @Published private(set) var resolvedTarget: String?
    @Published private(set) var results: [EngineResult] = []
    /// Pinned: the window stays open and on top. Unpinned: it hides when you click another app.
    @Published var pinned = UserDefaults.standard.bool(forKey: "pinned") {
        didSet { UserDefaults.standard.set(pinned, forKey: "pinned") }
    }
    /// A one-line message shown above the results, e.g. an OCR problem.
    @Published var notice: String?
    /// Bumped to move keyboard focus into the input field.
    @Published private(set) var focusRequest = 0

    func focusInput() { focusRequest += 1 }

    private var task: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var lastRequest: String?
    private var run = 0

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
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            results = []
            detected = nil
            resolvedTarget = nil
            return
        }
        let defaults = UserDefaults.standard
        let first = defaults.string(forKey: Prefs.first) ?? "en"
        let second = defaults.string(forKey: Prefs.second) ?? "zh-Hans"

        let source = sourceChoice == Self.auto ? (LanguageTools.detect(text) ?? "en") : sourceChoice
        let target = targetChoice == Self.auto ? LanguageTools.target(for: source, first: first, second: second) : targetChoice
        detected = source
        resolvedTarget = target

        run += 1
        let run = run
        // Without the model the popup shows a single download row instead of a failing result card.
        guard ModelStore.isInstalled else {
            results = []
            return
        }
        let engines = Engines.all
        results = engines.map { EngineResult(id: $0.id, name: $0.name, detail: $0.detail, state: .loading) }

        task = Task {
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
        // A late streaming chunk must not overwrite the final result.
        if case .streaming = state, case .done = results[index].state { return }
        if case .streaming = state, case .failed = results[index].state { return }
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
        let defaults = UserDefaults.standard
        let source = sourceChoice == Self.auto ? (LanguageTools.detect(text) ?? "en") : sourceChoice
        detected = source
        resolvedTarget = targetChoice == Self.auto
            ? LanguageTools.target(for: source, first: defaults.string(forKey: Prefs.first) ?? "en",
                                   second: defaults.string(forKey: Prefs.second) ?? "zh-Hans")
            : targetChoice
    }

    func swapLanguages() {
        guard let detected, let resolvedTarget else { return }
        sourceChoice = resolvedTarget
        targetChoice = detected
        translate()
    }

    func load(_ text: String) {
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
        run += 1
        input = ""
        results = []
        detected = nil
        resolvedTarget = nil
    }
}
