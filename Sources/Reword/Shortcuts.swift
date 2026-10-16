import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The global actions that can be bound to a key combination.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case inputTranslate, selectionTranslate, screenshotTranslate

    var id: String { rawValue }
    var title: String {
        switch self {
        case .inputTranslate: return "Show translation window"
        case .selectionTranslate: return "Translate selected text"
        case .screenshotTranslate: return "Screenshot translate (OCR)"
        }
    }
    var defaultsKey: String { "shortcut.\(rawValue)" }
    var fallback: Shortcut {
        switch self {
        case .inputTranslate: return Shortcut(keyCode: kVK_ANSI_X, carbonModifiers: cmdKey | shiftKey, key: "X")
        case .selectionTranslate: return Shortcut(keyCode: kVK_ANSI_C, carbonModifiers: cmdKey | shiftKey, key: "C")
        case .screenshotTranslate: return Shortcut(keyCode: kVK_ANSI_S, carbonModifiers: cmdKey | shiftKey, key: "S")
        }
    }
}

struct Shortcut: Equatable {
    var keyCode: Int
    var carbonModifiers: Int
    var key: String              // printable key name captured when recording, e.g. "A", "Space", "F5"

    var display: String {
        var s = ""
        if carbonModifiers & controlKey != 0 { s += "⌃" }
        if carbonModifiers & optionKey != 0 { s += "⌥" }
        if carbonModifiers & shiftKey != 0 { s += "⇧" }
        if carbonModifiers & cmdKey != 0 { s += "⌘" }
        return s + key
    }

    /// Stored as "keyCode:modifiers:key"; an empty string means the action is unbound.
    var stored: String { "\(keyCode):\(carbonModifiers):\(key)" }

    init(keyCode: Int, carbonModifiers: Int, key: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.key = key
    }

    init?(stored: String) {
        let parts = stored.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let code = Int(parts[0]), let mods = Int(parts[1]) else { return nil }
        self.init(keyCode: code, carbonModifiers: mods, key: String(parts[2]))
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.subtracting(.shift).isEmpty else { return nil }   // need ⌘, ⌥ or ⌃
        var mods = 0
        if flags.contains(.command) { mods |= cmdKey }
        if flags.contains(.option) { mods |= optionKey }
        if flags.contains(.control) { mods |= controlKey }
        if flags.contains(.shift) { mods |= shiftKey }
        let code = Int(event.keyCode)
        self.init(keyCode: code, carbonModifiers: mods,
                  key: Self.specialKeys[code] ?? (event.charactersIgnoringModifiers ?? "?").uppercased())
    }

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    static func current(_ action: ShortcutAction) -> Shortcut? {
        guard let value = UserDefaults.standard.string(forKey: action.defaultsKey) else { return action.fallback }
        return Shortcut(stored: value)
    }

    @MainActor static func save(_ shortcut: Shortcut?, for action: ShortcutAction) {
        UserDefaults.standard.set(shortcut?.stored ?? "", forKey: action.defaultsKey)
        Hotkeys.apply()
    }
}

/// Binds the saved shortcuts to the app's handlers through Carbon hotkeys.
@MainActor
enum Hotkeys {
    static var handlers: [ShortcutAction: () -> Void] = [:]
    /// Actions whose shortcut couldn't be registered (taken by another app, or duplicated here).
    static private(set) var unavailable: Set<ShortcutAction> = []

    static func apply() {
        HotKeyCenter.shared.unregisterAll()
        unavailable = []
        var used: Set<String> = []
        for action in ShortcutAction.allCases {
            guard let shortcut = Shortcut.current(action), let handler = handlers[action] else { continue }
            let key = "\(shortcut.keyCode):\(shortcut.carbonModifiers)"
            if used.contains(key) || !HotKeyCenter.shared.register(keyCode: shortcut.keyCode, modifiers: shortcut.carbonModifiers, handler: handler) {
                unavailable.insert(action)
            }
            used.insert(key)
        }
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static let changed = Notification.Name("RewordHotkeysChanged")

    /// While recording a new shortcut, the old ones must not fire.
    static func suspend() { HotKeyCenter.shared.unregisterAll() }
}

struct ShortcutRecorder: View {
    let action: ShortcutAction
    @State private var shortcut: Shortcut?
    @State private var recording = false
    @State private var monitor: Any?
    @State private var unavailable = false
    private static let recordingStarted = Notification.Name("RewordShortcutRecordingStarted")

    var body: some View {
        HStack(spacing: 4) {
            if unavailable && !recording {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("This shortcut is taken by another app or used twice. Choose a different one.")
            }
            Button(action: { recording ? stop() : start() }) {
                Text(recording ? "Type shortcut…" : (shortcut?.display ?? "Not set"))
                    .monospaced()
                    .frame(minWidth: 96)
            }
            if shortcut != nil, !recording {
                Button { shortcut = nil; Shortcut.save(nil, for: action) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Remove shortcut")
            }
        }
        .onAppear {
            shortcut = Shortcut.current(action)
            unavailable = Hotkeys.unavailable.contains(action)
        }
        .onDisappear { if recording { stop() } }
        .onReceive(NotificationCenter.default.publisher(for: Hotkeys.changed)) { _ in
            unavailable = Hotkeys.unavailable.contains(action)
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.recordingStarted)) { note in
            // Only one recorder listens for keys at a time.
            if recording, (note.object as? String) != action.rawValue { stop() }
        }
    }

    private func start() {
        NotificationCenter.default.post(name: Self.recordingStarted, object: action.rawValue)
        recording = true
        Hotkeys.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            guard let recorded = Shortcut(event: event) else { NSSound.beep(); return nil }
            shortcut = recorded
            Shortcut.save(recorded, for: action)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        Hotkeys.apply()
    }
}

/// The SF Symbol used for the menu bar item, chosen in Settings.
enum MenuBarIcon {
    static let key = "menuBarIcon"
    static let fallback = "character.bubble"
    static let choices = ["character.bubble", "text.bubble", "translate", "globe", "a.magnify", "character.book.closed"]

    static var current: String {
        let name = UserDefaults.standard.string(forKey: key) ?? fallback
        return choices.contains(name) ? name : fallback
    }
}
