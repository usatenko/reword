import AppKit

/// `Reword --translate "text" [--from xx] [--to yy]` translates on-device, prints the result and exits.
func runCommandLine(_ args: [String]) async -> Int32 {
    func value(_ flag: String) -> String? {
        args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
    }
    guard let text = value("--translate") else { return 2 }
    Prefs.registerDefaults()
    let defaults = UserDefaults.standard
    let source = value("--from") ?? LanguageTools.detect(text) ?? "en"
    let target = value("--to") ?? Prefs.autoTarget(for: source)
    print("\(source) → \(target)")
    var failures: Int32 = 0
    for engine in Engines.all {
        let start = Date()
        do {
            let output = try await engine.translate(text, from: source, to: target) { _ in }
            print("[\(engine.name), \(String(format: "%.2f", Date().timeIntervalSince(start)))s] \(output)")
        } catch {
            failures += 1
            print("[\(engine.name)] error: \(error.localizedDescription)")
        }
    }
    await HyMTEngine.shared.shutdown()
    return failures == 0 ? 0 : 1
}

/// `Reword --permission-status` prints what macOS allows Reword right now (the running app may have a stale answer).
if CommandLine.arguments.contains("--permission-status") {
    print(PermissionStatus.commandLineOutput)
    exit(0)
}

/// `Reword --ocr image.png` prints the text Vision recognizes (for testing screenshot translation).
if let i = CommandLine.arguments.firstIndex(of: "--ocr"), CommandLine.arguments.indices.contains(i + 1) {
    let url = URL(fileURLWithPath: CommandLine.arguments[i + 1])
    Task {
        guard let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { exit(2) }
        do { print(try await ScreenOCR.recognize(image)); exit(0) } catch { print("error: \(error.localizedDescription)"); exit(1) }
    }
    dispatchMain()
}

if CommandLine.arguments.contains("--translate") {
    Task {
        exit(await runCommandLine(CommandLine.arguments))
    }
    dispatchMain()
}

/// Launched by "Restart Reword": wait for the previous copy to quit first.
enum Relaunch {
    static let waitFlag = "--after-pid"

    static func waitForPreviousInstance() {
        guard let i = CommandLine.arguments.firstIndex(of: waitFlag), CommandLine.arguments.indices.contains(i + 1),
              let pid = pid_t(CommandLine.arguments[i + 1]) else { return }
        for _ in 0..<150 where kill(pid, 0) == 0 { usleep(100_000) }      // up to 15 s
    }
}

Relaunch.waitForPreviousInstance()

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
