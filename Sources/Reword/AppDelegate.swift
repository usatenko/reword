import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Floating panel that can take keyboard focus.
final class TranslatorPanel: NSPanel {

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func cancelOperation(_ sender: Any?) { orderOut(nil) }   // Esc closes
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let model = TranslatorModel()
    private lazy var panel = makePanel()
    private var settingsWindow: NSWindow?
    private var menuItems: [ShortcutAction: NSMenuItem] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        setUpStatusItem()
        Task { await HyMTEngine.shared.warmUp() }   // load the model now so the first popup is fast

        Hotkeys.handlers = [
            .inputTranslate: { [weak self] in self?.showInputTranslation() },
            .selectionTranslate: { [weak self] in Task { await self?.translateSelection() } },
            .screenshotTranslate: { [weak self] in Task { await self?.translateScreenshot() } },
        ]
        Hotkeys.apply()

        model.pinned = CommandLine.arguments.contains("--pin")
        if CommandLine.arguments.contains("--show") { showInputTranslation() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await HyMTEngine.shared.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusIcon() }
        }

        let menu = NSMenu()
        menu.delegate = self
        menuItems[.inputTranslate] = menu.addItem(withTitle: "Input Translation", action: #selector(menuInputTranslation), keyEquivalent: "")
        menuItems[.selectionTranslate] = menu.addItem(withTitle: "Translate Selection", action: #selector(menuTranslateSelection), keyEquivalent: "")
        menuItems[.screenshotTranslate] = menu.addItem(withTitle: "Screenshot Translate", action: #selector(menuTranslateScreenshot), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "About Reword", action: #selector(openAbout), keyEquivalent: "")
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Reword", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.items.filter { $0.target == nil && $0.action != nil }.forEach { $0.target = self }
        statusItem.menu = menu
    }

    private func updateStatusIcon() {
        let name = MenuBarIcon.current
        guard statusItem.button?.image?.accessibilityDescription != name else { return }
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: name)
    }

    /// Shows each action's current shortcut next to its menu item.
    func menuNeedsUpdate(_ menu: NSMenu) {
        for (action, item) in menuItems {
            let shortcut = Shortcut.current(action)
            let base = item.title.components(separatedBy: "\t")[0]
            item.title = shortcut.map { "\(base)\t\($0.display)" } ?? base
        }
    }

    @objc private func menuTranslateSelection() { Task { await translateSelection() } }
    @objc private func menuInputTranslation() { showInputTranslation() }
    @objc private func menuTranslateScreenshot() { Task { await translateScreenshot() } }

    // MARK: Actions

    private func translateSelection() async {
        let text = await SelectionReader.selectedText() ?? ""
        showPanel(nearMouse: true)
        if text.isEmpty {
            model.clear()
            if !SelectionReader.isTrusted { SelectionReader.promptForAccessibility() }
        } else {
            model.load(text)
        }
    }

    private func showInputTranslation() {
        model.clear()
        showPanel(nearMouse: false)
        model.focusInput()
    }

    private func translateScreenshot() async {
        if panel.isVisible && !model.pinned { panel.orderOut(nil) }
        do {
            let text = try await ScreenOCR.captureAndRecognize()
            showPanel(nearMouse: false)
            model.load(text)
        } catch ScreenOCR.Failure.cancelled {
            return
        } catch {
            showPanel(nearMouse: false)
            model.clear()
            model.notice = error.localizedDescription
        }
    }

    private func showPanel(nearMouse: Bool) {
        // The panel reopens where the user left it (frame autosave); first launch centers it.
        if !panel.isVisible, UserDefaults.standard.string(forKey: "NSWindow Frame TranslatorPanel") == nil {
            panel.center()
        }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        Task { await HyMTEngine.shared.warmUp() }   // reload in the background if it was unloaded while idle
    }

    private func makePanel() -> TranslatorPanel {
        let panel = TranslatorPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 380),
            styleMask: [.titled, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        // Never smaller than header + language bar + both panes at their minimum heights.
        panel.minSize = Self.panelMinimum
        panel.setContentSize(NSSize(width: 400, height: 420))
        panel.setFrameAutosaveName("TranslatorPanel")   // remembers position and size between launches
        if panel.frame.height < Self.panelMinimum.height || panel.frame.width < Self.panelMinimum.width {
            panel.setContentSize(NSSize(width: 400, height: 420))   // repair a collapsed saved frame
            panel.center()
        }
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        let host = NSHostingView(rootView: TranslatorView(model: model, openSettings: { [weak self] in self?.openSettings() }))
        host.sizingOptions = []          // the user sizes the window; content scrolls
        panel.contentView = host
        return panel
    }

    /// The SwiftUI host resets the panel's minSize, so the minimum is enforced here for every resize.
    static let panelMinimum = NSSize(width: 320, height: 260)

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        guard sender === panel else { return frameSize }
        return NSSize(width: max(frameSize.width, Self.panelMinimum.width), height: max(frameSize.height, Self.panelMinimum.height))
    }

    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel, !model.pinned else { return }
        // Keep the panel while the system language-download sheet or our settings window is in front.
        if panel.attachedSheet != nil || settingsWindow?.isKeyWindow == true { return }
        panel.orderOut(nil)
    }

    @objc private func openAbout() {
        if panel.isVisible, !model.pinned { panel.orderOut(nil) }
        AboutWindow.show()
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView())
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = "Reword Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        // The floating popup would cover Settings; step it aside unless the user pinned it.
        if panel.isVisible, !model.pinned { panel.orderOut(nil) }
        if settingsWindow?.isVisible != true { settingsWindow?.center() }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()      // accessory apps aren't always allowed to activate
    }
}
