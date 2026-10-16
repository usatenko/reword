import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Global hotkeys through Carbon's RegisterEventHotKey, which needs no special permission.
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []

    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        handlers.removeAll()
    }
    private var nextID: UInt32 = 1
    private var installed = false

    @discardableResult
    func register(keyCode: Int, modifiers: Int, handler: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x52575244), id: id) // 'RWRD'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            NSLog("Reword: hotkey registration failed (%d) for key %d", Int(status), keyCode)
            return false
        }
        refs.append(ref)
        handlers[id] = handler
        return true
    }

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKeyCenter.shared.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Opens a System Settings privacy pane; the system prompts appear only once per app, so this is the reliable path.
enum PrivacyPane {
    case accessibility, screenRecording

    /// Asks for the permission and makes sure something visible happens, without stacking prompts. The request
    /// adds Reword to the list and may show macOS's own dialog. That dialog belongs to a system process, can take
    /// a second or two to appear and doesn't take activation from Reword, so watch for its window: if none shows
    /// up, macOS skipped it (it often does, e.g. after a reset) and the System Settings page opens instead.
    @MainActor func request() {
        let before = Self.otherAppPanels()
        switch self {
        case .accessibility: SelectionReader.promptForAccessibility()
        case .screenRecording: CGRequestScreenCaptureAccess()
        }
        Task { @MainActor in
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(250))
                if !Self.otherAppPanels().subtracting(before).isEmpty { return }   // macOS's dialog is up
            }
            self.open()
        }
    }

    /// On-screen windows above the normal level that belong to other processes, such as macOS's permission
    /// dialogs. Window numbers and levels are readable without Screen Recording.
    private static func otherAppPanels() -> Set<Int> {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return Set(windows.compactMap { window in
            guard (window[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  let layer = window[kCGWindowLayer as String] as? Int, layer > 0, layer < 1000 else { return nil }
            return window[kCGWindowNumber as String] as? Int
        })
    }

    @MainActor func open() {
        let anchor = self == .accessibility ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// What macOS currently allows Reword, as opposed to what this running process can use. A running app keeps
/// a cached answer (Screen Recording never applies before a restart), so the granted state is read by a short-lived
/// copy of Reword (`--permission-status`), which macOS answers fresh.
enum PermissionStatus {
    struct Snapshot: Equatable { var accessibility: Bool; var screenRecording: Bool }

    /// Whether this process started with Screen Recording, i.e. screenshots work without a restart.
    static let screenRecordingAtLaunch = CGPreflightScreenCaptureAccess()

    /// The `--permission-status` output for this process.
    static var commandLineOutput: String {
        "accessibility=\(AXIsProcessTrusted() ? 1 : 0) screenRecording=\(CGPreflightScreenCaptureAccess() ? 1 : 0)"
    }

    @MainActor private static var checking = false

    /// Runs off the main thread; nil if the helper couldn't run or a check is already running (it takes ~1 s, so
    /// once-a-second polling would otherwise pile up).
    @MainActor static func granted() async -> Snapshot? {
        guard !checking, let executable = Bundle.main.executablePath else { return nil }
        checking = true
        defer { checking = false }
        // Waits through the termination handler: waitUntilExit() needs a run loop and never returns off the main thread.
        return await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["--permission-status"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                guard process.terminationStatus == 0, output.contains("accessibility=") else {
                    return continuation.resume(returning: nil)
                }
                continuation.resume(returning: Snapshot(accessibility: output.contains("accessibility=1"),
                                                        screenRecording: output.contains("screenRecording=1")))
            }
            do { try process.run() } catch { return continuation.resume(returning: nil) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {     // never let a stuck check block later ones
                if process.isRunning { process.terminate() }
            }
        }
    }
}

/// Reads the text selected in the frontmost app.
enum SelectionReader {
    /// AXIsProcessTrusted() can keep answering "yes" in a running app after the permission is removed, so
    /// confirm with a real Accessibility call: macOS refuses it with .apiDisabled when access is gone.
    static var isTrusted: Bool {
        guard AXIsProcessTrusted() else { return false }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &value)
        return result != .apiDisabled
    }

    static func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Accessibility first; falls back to a simulated ⌘C with the clipboard restored afterwards.
    static func selectedText() async -> String? {
        if let text = axSelectedText(), !text.isEmpty { return text }
        return await copyViaPasteboard()
    }

    private static func axSelectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success
        else { return nil }
        return (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func copyViaPasteboard() async -> String? {
        guard isTrusted else { return nil }
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        let before = pasteboard.changeCount

        // The hotkey's modifiers (e.g. ⌘⇧) may still be held; a ⌘C sent now could arrive as ⌘⇧C.
        for _ in 0..<25 where !NSEvent.modifierFlags.intersection([.shift, .option, .control, .command]).isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        var text: String?
        var copiedChange: Int?
        for _ in 0..<10 {
            try? await Task.sleep(for: .milliseconds(30))
            if pasteboard.changeCount != before {
                text = pasteboard.string(forType: .string)
                copiedChange = pasteboard.changeCount
                break
            }
        }
        // Restore only if the clipboard still holds our ⌘C result; never overwrite something copied since.
        if let copiedChange, pasteboard.changeCount == copiedChange {
            pasteboard.clearContents()
            if !saved.isEmpty { pasteboard.writeObjects(saved) }
        }
        return text?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
