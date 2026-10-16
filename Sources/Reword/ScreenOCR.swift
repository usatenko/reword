import AppKit
import OSLog
import ScreenCaptureKit
import Vision

private let log = Logger(subsystem: "com.ou.Reword", category: "ocr")

/// Screenshot translation: Reword's own region picker, a ScreenCaptureKit capture of that region,
/// and on-device Vision OCR.
enum ScreenOCR {
    enum Failure: LocalizedError {
        case cancelled, noText, permission, capture(String)
        var errorDescription: String? {
            switch self {
            case .cancelled: return "Screenshot cancelled."
            case .noText: return "No text found in the screenshot."
            case .permission: return "Reword needs Screen Recording access: enable it in the System Settings pane that just opened, then quit and reopen Reword."
            case let .capture(message): return "Couldn't capture the screen: \(message)"
            }
        }
    }

    static var hasScreenAccess: Bool { CGPreflightScreenCaptureAccess() }

    /// Lets the user drag a region, then returns the recognized text.
    @MainActor
    /// `onSelected` runs while the selection overlay is still up, so the app can show its window and keep
    /// focus (otherwise macOS hands focus to the previous app when the overlay closes).
    static func captureAndRecognize(onSelected: () -> Void = {}, onCaptured: () -> Void = {}) async throws -> String {
        if !hasScreenAccess {
            CGRequestScreenCaptureAccess()
            PrivacyPane.screenRecording.open()
            throw Failure.permission
        }
        guard let region = await RegionSelector.select() else { throw Failure.cancelled }
        onSelected()
        RegionSelector.dismiss()
        try await Task.sleep(for: .milliseconds(120))          // let the overlay leave the screen
        let image = try await capture(region)
        onCaptured()                                            // the UI shows "Reading text…" from here
        do {
            return try await recognize(image)
        } catch {
            log.error("OCR failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// `rect` is in AppKit screen coordinates (bottom-left origin); ScreenCaptureKit wants display space (top-left).
    private static func capture(_ rect: NSRect) async throws -> CGImage {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let displayRect = CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        return try await withCheckedThrowingContinuation { cont in
            SCScreenshotManager.captureImage(in: displayRect) { image, error in
                if let image { cont.resume(returning: image) }
                else { cont.resume(throwing: Failure.capture(error?.localizedDescription ?? "unknown error")) }
            }
        }
    }

    static func recognize(_ image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: image).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            guard !lines.isEmpty else { throw Failure.noText }
            return lines.joined(separator: "\n")
        }.value
    }
}

/// Full-screen overlay on every display: drag a rectangle to select it, Esc or a click cancels.
@MainActor
final class RegionSelector {
    private static var active: RegionSelector?

    private var windows: [NSWindow] = []
    private var continuation: CheckedContinuation<NSRect?, Never>?

    static func select() async -> NSRect? {
        active?.finish(nil)
        active?.close()
        let selector = RegionSelector()
        active = selector
        return await withCheckedContinuation { cont in
            selector.continuation = cont
            selector.show()
        }
    }

    private func show() {
        for screen in NSScreen.screens {
            let window = OverlayWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.level = .screenSaver
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.onFinish = { [weak self, weak window] localRect in
                guard let self, let window, let localRect else { self?.finish(nil); return }
                self.finish(window.convertToScreen(localRect))
            }
            window.contentView = view
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
        }
        NSApp.activate()
        let mouse = NSEvent.mouseLocation
        let target = windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.first
        target?.makeKey()
        NSCursor.crosshair.push()
    }

    private func finish(_ rect: NSRect?) {
        guard let continuation else { return }
        self.continuation = nil
        NSCursor.pop()
        let selected = rect.flatMap { $0.width >= 4 && $0.height >= 4 ? $0 : nil }
        if selected == nil { close() }                          // on success the caller dismisses it
        continuation.resume(returning: selected)
    }

    private func close() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        if RegionSelector.active === self { RegionSelector.active = nil }
    }

    /// Removes the overlay after a successful selection.
    static func dismiss() { active?.close() }

    private final class OverlayWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private final class SelectionView: NSView {
        var onFinish: ((NSRect?) -> Void)?
        private var start: NSPoint?
        private var selection: NSRect?

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func viewDidMoveToWindow() { window?.makeFirstResponder(self) }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

        override func mouseDown(with event: NSEvent) {
            start = convert(event.locationInWindow, from: nil)
            selection = nil
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start else { return }
            let point = convert(event.locationInWindow, from: nil)
            selection = NSRect(x: min(start.x, point.x), y: min(start.y, point.y),
                               width: abs(point.x - start.x), height: abs(point.y - start.y))
            needsDisplay = true
        }

        override func mouseUp(with event: NSEvent) { onFinish?(selection) }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 53 { onFinish?(nil) } else { super.keyDown(with: event) }   // Esc
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.withAlphaComponent(0.25).setFill()
            bounds.fill()
            guard let selection else { return }
            NSColor.clear.setFill()
            selection.fill(using: .copy)
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()
        }
    }
}
