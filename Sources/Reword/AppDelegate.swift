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
    let model = TranslatorModel()
    lazy var panel = makePanel()
    var settingsWindow: NSWindow?
    private var menuItems: [ShortcutAction: NSMenuItem] = [:]
    /// Debug-only README capture: keeps the unpinned window visible while other windows take focus.
    var capturingShots = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.registerDefaults()
        setUpStatusItem()
        setUpEditMenu()
        // First run (or the model file was removed): fetch the selected model right away so Reword is ready.
        if !ModelStore.isInstalled { ModelDownloader.shared.start() }
        // Compile the OCR model in the background so the first screenshot reads quickly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            ScreenOCR.prewarm()
            Task.detached(priority: .utility) { await HyMTEngine.shared.compileShadersIfNeeded() }
        }

        Hotkeys.handlers = [
            .inputTranslate: { [weak self] in self?.showInputTranslation() },
            .selectionTranslate: { [weak self] in Task { await self?.translateSelection() } },
            .screenshotTranslate: { [weak self] in Task { await self?.translateScreenshot() } },
        ]
        Hotkeys.apply()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "w", let window = NSApp.keyWindow else { return event }
            if window === self?.panel { window.orderOut(nil) } else { window.performClose(nil) }
            return nil
        }

        if CommandLine.arguments.contains("--show") { showInputTranslation() }   // used by scripted UI tests
        else if OnboardingWindow.shouldShowOnLaunch { openOnboarding() }
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "--readme-shots"), CommandLine.arguments.indices.contains(i + 1) {
            let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            Task { await self.captureReadmeShots(to: dir) }
        }
        #endif
    }

    private var terminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminating = true                           // windows closed by quitting aren't "dismissed by the user"
        model.cancelAll()                            // stop generating so the engine can be freed right away
        // Free the model off the main thread and reply through the run loop: if terminate() was called from a
        // main-queue job, the main queue stays blocked until it returns, so a MainActor reply would deadlock.
        Task.detached {
            await HyMTEngine.shared.shutdown()
            RunLoop.main.perform(inModes: [.common, .modalPanel]) {
                MainActor.assumeIsolated { NSApp.reply(toApplicationShouldTerminate: true) }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        return .terminateLater
    }

    /// A menu bar app has no visible main menu, but the standard editing shortcuts (⌘A, ⌘C, ⌘V, ⌘X, ⌘Z)
    /// are dispatched through the Edit menu's key equivalents, so install one that is never shown.
    private func setUpEditMenu() {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(NSMenuItem(title: "Reword", action: nil, keyEquivalent: ""))   // app menu slot
        main.addItem(editItem)
        NSApp.mainMenu = main
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
        menuItems[.inputTranslate] = menu.addItem(withTitle: "Open Reword", action: #selector(menuInputTranslation), keyEquivalent: "")
        menuItems[.selectionTranslate] = menu.addItem(withTitle: "Translate Selection", action: #selector(menuTranslateSelection), keyEquivalent: "")
        menuItems[.screenshotTranslate] = menu.addItem(withTitle: "Translate Screenshot", action: #selector(menuTranslateScreenshot), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "Onboarding…", action: #selector(openOnboarding), keyEquivalent: "")
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
        let image = MenuBarIcon.image(name)
        image.accessibilityDescription = name
        statusItem.button?.image = image
    }

    /// Shows each action's current shortcut as the item's key equivalent, right-aligned like ⌘Q.
    func menuNeedsUpdate(_ menu: NSMenu) {
        for (action, item) in menuItems {
            let shortcut = Shortcut.current(action)
            item.keyEquivalent = shortcut?.menuKeyEquivalent ?? ""
            item.keyEquivalentModifierMask = shortcut?.modifierFlags ?? []
        }
    }

    @objc private func menuTranslateSelection() { Task { await translateSelection() } }
    @objc private func menuInputTranslation() { showInputTranslation() }
    @objc private func menuTranslateScreenshot() { Task { await translateScreenshot() } }

    // MARK: Actions

    private var readingSelection = false

    private func translateSelection() async {
        // One read at a time: overlapping reads would save each other's ⌘C as the "original" clipboard.
        guard !readingSelection else { return }
        readingSelection = true
        defer { readingSelection = false }
        let text = await SelectionReader.selectedText() ?? ""
        showPanel()
        if text.isEmpty {
            model.clear()
            let shortcut = Shortcut.current(.selectionTranslate)?.display ?? "the shortcut"
            if SelectionReader.isTrusted {
                model.notice = "No text selected. Select text in any app, then press \(shortcut)."
            } else {
                model.notice = "Reword needs Accessibility access to read selected text. Allow it in System Settings, then press \(shortcut) again."
                PrivacyPane.accessibility.request()
            }
        } else {
            model.load(text)
        }
    }

    private func showInputTranslation() {
        model.clear()
        showPanel()
        model.focusInput()
    }

    private func translateScreenshot() async {
        // Load the translation model while the user drags the selection, not at the same time as OCR.
        Task { await HyMTEngine.shared.warmUp() }
        do {
            let text = try await ScreenOCR.captureAndRecognize(
                onSelected: {
                    // Keep the window out of the capture, then show it before the overlay closes so Reword keeps focus.
                    self.panel.sharingType = .none
                    self.model.clear()
                    self.model.inputStatus = "Reading text from screenshot…"
                    self.showPanel()
                },
                onCaptured: { self.panel.sharingType = .readOnly })
            model.load(text)
        } catch ScreenOCR.Failure.cancelled {
            panel.sharingType = .readOnly
        } catch {
            panel.sharingType = .readOnly
            showPanel()
            model.clear()
            model.notice = error.localizedDescription
        }
    }

    func showPanel() {
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

    /// Settings is rebuilt on each open, so its permission polling stops while it's closed.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window !== panel else { return }
        if window === settingsWindow { settingsWindow = nil }
        if window === OnboardingWindow.current { OnboardingWindow.closed(dismissed: !terminating) }
        // Once Settings, About and the welcome window are all closed, the panel floats again.
        let otherOpen = [settingsWindow, AboutWindow.current, OnboardingWindow.current]
            .contains { $0 != nil && $0 !== window && $0!.isVisible }
        if !otherOpen { panel.level = .floating }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel, !model.pinned, !capturingShots else { return }
        // Keep the panel while the system language-download sheet or our settings window is in front.
        if panel.attachedSheet != nil || settingsWindow?.isKeyWindow == true { return }
        panel.orderOut(nil)
    }

    @objc private func openOnboarding() {
        stepPanelAside()
        OnboardingWindow.show(delegate: self, tryIt: { [weak self] in self?.showInputTranslation() })
    }

    @objc private func openAbout() {
        stepPanelAside()
        AboutWindow.show(delegate: self)
    }

    /// The floating panel would cover Settings and About: hide it, or if pinned, drop it to normal level
    /// until those windows close.
    private func stepPanelAside() {
        guard panel.isVisible else { return }
        if model.pinned { panel.level = .normal } else { panel.orderOut(nil) }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView())
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = "Reword Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            settingsWindow = window
        }
        stepPanelAside()
        if settingsWindow?.isVisible != true { settingsWindow?.center() }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
        settingsWindow?.orderFrontRegardless()      // accessory apps aren't always allowed to activate
    }
}

#if DEBUG
import ScreenCaptureKit

/// Debug-only: renders the windows shown in the README (`Reword --readme-shots <dir>`), then quits.
extension AppDelegate {
    func captureReadmeShots(to dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Show the default (unpinned, "Auto-hide") look; auto-hide is paused while capturing instead.
        capturingShots = true

        model.clear()
        showPanel()
        panel.setContentSize(NSSize(width: 420, height: 440))
        panel.center()
        model.load("What is the internal rate of return, and how do you use it to decide whether a project is worth the investment?")
        for _ in 0..<120 {                                          // wait up to 60 s for the translation
            if case .done = model.results.first?.state { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        try? await Task.sleep(for: .milliseconds(600))
        await snapshot(panel, to: dir.appendingPathComponent("window.png"))

        openSettings()
        try? await Task.sleep(for: .seconds(1))
        if let settingsWindow { await snapshot(settingsWindow, to: dir.appendingPathComponent("settings.png")) }
        settingsWindow?.close()

        AboutWindow.show(delegate: self)
        try? await Task.sleep(for: .seconds(1))
        if let about = AboutWindow.current { await snapshot(about, to: dir.appendingPathComponent("about.png")) }
        AboutWindow.current?.close()

        openOnboarding()
        try? await Task.sleep(for: .seconds(1))
        if let welcome = OnboardingWindow.current { await snapshot(welcome, to: dir.appendingPathComponent("welcome.png")) }
        OnboardingWindow.current?.close()
        NSApp.terminate(nil)
    }

    private func snapshot(_ window: NSWindow, to url: URL) async {
        do {
            let content = try await SCShareableContent.current
            guard let scWindow = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
                FileHandle.standardError.write(Data("readme-shots: window not shareable: \(window.title)\n".utf8)); return
            }
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            config.width = Int(filter.contentRect.width * CGFloat(filter.pointPixelScale))
            config.height = Int(filter.contentRect.height * CGFloat(filter.pointPixelScale))
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = false                 // keep the native window shadow
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
            FileHandle.standardError.write(Data("readme-shots: wrote \(url.path) (\(image.width)x\(image.height))\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("readme-shots: \(window.title): \(error.localizedDescription)\n".utf8))
        }
    }
}
#endif
