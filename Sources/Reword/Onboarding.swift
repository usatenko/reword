import AppKit
import ServiceManagement
import SwiftUI

/// First-launch welcome: where Reword lives, its shortcuts, and a live setup checklist.
@MainActor
enum OnboardingWindow {
    static let shownKey = "onboardingShownForInstall"
    private static var window: NSWindow?
    static var current: NSWindow? { window }

    /// Settings survive deleting the app, so "first run" is tracked per installed copy: every copy of Reword.app
    /// into Applications gets a new file identity (device + inode), and the welcome window shows once for it.
    private static var installID: String {
        var info = stat()
        guard stat(Bundle.main.bundlePath, &info) == 0 else { return "unknown" }
        return "\(info.st_dev):\(info.st_ino)"
    }

    static var shouldShowOnLaunch: Bool { UserDefaults.standard.string(forKey: shownKey) != installID }

    static func show(delegate: NSWindowDelegate?, tryIt: @escaping () -> Void) {
        if window == nil {
            let host = NSHostingController(rootView: OnboardingView(tryIt: tryIt, close: { Self.window?.performClose(nil) }))
            host.sizingOptions = [.preferredContentSize]
            let newWindow = NSWindow(contentViewController: host)
            newWindow.title = "Welcome to Reword"
            newWindow.styleMask = [.titled, .closable]
            newWindow.isReleasedWhenClosed = false
            window = newWindow
        }
        window?.delegate = delegate
        if window?.isVisible != true { window?.center() }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    /// Dropped on close so its permission polling stops.
    /// Marked as seen only when dismissed (Done, Try It or the close button), not when it opens: if Reword
    /// restarts while it's open (e.g. for Screen Recording), it comes back.
    /// Reword has no Dock icon, so once System Settings comes forward this window is stuck behind it. When a
    /// permission changes there, bring the welcome window back so the user sees the step tick off.
    static func bringBack() {
        NSApp.activate()
        window?.orderFrontRegardless()
    }

    static func closed(dismissed: Bool) {
        if dismissed { UserDefaults.standard.set(installID, forKey: shownKey) }
        window = nil
    }
}

struct OnboardingView: View {
    var tryIt: () -> Void
    var close: () -> Void

    @ObservedObject private var downloader = ModelDownloader.shared
    @State private var axTrusted = SelectionReader.isTrusted
    @State private var screenAccess = ScreenOCR.hasScreenAccess
    @State private var loginStatus = SMAppService.mainApp.status

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to Reword").font(.title2.weight(.semibold))
                    Text("A very simple offline translator. Your text never leaves this Mac.")
                        .foregroundStyle(.secondary)
                }
            }

            GroupBox {
                HStack(alignment: .top, spacing: 10) {
                    Image(nsImage: MenuBarIcon.image(MenuBarIcon.current, size: 22))
                        .padding(6)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Reword lives in the menu bar").font(.headline)
                        Text("Look for this icon at the top right of your screen. There's no Dock icon: click it for the menu, Settings and Quit.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            GroupBox("Shortcuts") {
                VStack(spacing: 6) {
                    shortcutRow(.selectionTranslate, "Select text in any app, then press")
                    shortcutRow(.screenshotTranslate, "Drag over any part of the screen after pressing")
                    shortcutRow(.inputTranslate, "Open the window to type or paste")
                }
                .padding(4)
            }

            GroupBox("Set up") {
                VStack(spacing: 10) {
                    step(done: downloader.isInstalled, title: "Translation model", detail: modelDetail) {
                        if downloader.verifying {
                            ProgressView().controlSize(.small)
                        } else if let progress = downloader.progress {
                            ProgressView(value: progress).frame(width: 90)
                        } else if !downloader.isInstalled {
                            Button(downloader.error == nil ? "Download" : "Retry", action: downloader.start)
                        }
                    }
                    step(done: axTrusted, title: "Allow Accessibility",
                         detail: "Lets Reword read the text you select (\(display(.selectionTranslate))).") {
                        if axTrusted {
                            Button("Open Settings") { PrivacyPane.accessibility.open() }.buttonStyle(.link)
                        } else {
                            Button("Allow…") { PrivacyPane.accessibility.request() }
                        }
                    }
                    step(done: screenAccess && PermissionStatus.screenRecordingAtLaunch, title: "Allow Screen Recording",
                         detail: screenAccess && !PermissionStatus.screenRecordingAtLaunch
                            ? "Allowed. Restart Reword (or use Quit & Reopen in the macOS dialog) so it takes effect."
                            : "Lets Reword read text from screenshots (\(display(.screenshotTranslate))).") {
                        if !screenAccess {
                            Button("Allow…") { PrivacyPane.screenRecording.request() }
                        } else if !PermissionStatus.screenRecordingAtLaunch {
                            Button("Restart Reword", action: Self.relaunch)
                        } else {
                            Button("Open Settings") { PrivacyPane.screenRecording.open() }.buttonStyle(.link)
                        }
                    }
                    step(done: loginStatus == .enabled, title: "Launch at login",
                         detail: "Optional: keep Reword ready after you restart your Mac.") {
                        Toggle("", isOn: Binding(
                            get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                            set: { on in
                                try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                                loginStatus = SMAppService.mainApp.status
                            }))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                }
                .padding(4)
            }

            HStack {
                Text("You can reopen this from the menu: Onboarding…").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("Try It") { close(); tryIt() }
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        // A loop rather than a Timer publisher in body: download progress redraws this view several times a
        // second, and each redraw would restart such a timer before it ever fires.
        .task {
            while !Task.isCancelled {
                loginStatus = SMAppService.mainApp.status
                await refreshPermissions()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// Reads what macOS allows now; when a permission was just granted in System Settings, the window comes back.
    private func refreshPermissions() async {
        guard let status = await PermissionStatus.granted() else { return }
        let newlyGranted = (!axTrusted && status.accessibility) || (!screenAccess && status.screenRecording)
        axTrusted = status.accessibility
        screenAccess = status.screenRecording
        if newlyGranted { OnboardingWindow.bringBack() }
    }

    private var modelDetail: String {
        let size = ByteCountFormatter.string(fromByteCount: ModelStore.expectedBytes, countStyle: .file)
        if downloader.isInstalled { return "Hy-MT2 1.8B is ready. Translation works offline." }
        if downloader.verifying { return "Checking the download…" }
        if let progress = downloader.progress {
            return "Downloading automatically (\(size)), \(progress.formatted(.percent.precision(.fractionLength(0)))). One time; then it works offline."
        }
        if let error = downloader.error { return "Download failed: \(error)" }
        return "Not downloaded (Hy-MT2 1.8B, \(size)). It downloads automatically when Reword starts."
    }

    private func display(_ action: ShortcutAction) -> String {
        Shortcut.current(action)?.display ?? "no shortcut set"
    }

    private func shortcutRow(_ action: ShortcutAction, _ text: String) -> some View {
        HStack {
            Text(text).foregroundStyle(.secondary)
            Spacer()
            Text(display(action))
                .monospaced()
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
        }
        .font(.callout)
    }

    private func step<Accessory: View>(done: Bool, title: String, detail: String,
                                       @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
                .foregroundStyle(done ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            accessory()
        }
    }

    /// Screen Recording only takes effect in a new process. The new copy is launched by macOS before this one quits
    /// (a helper process of ours would be killed along with the app) and waits for this one to exit, so it can
    /// register the global shortcuts.
    private static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [Relaunch.waitFlag, String(ProcessInfo.processInfo.processIdentifier)]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard error == nil else { return }
            // Not from a main-queue job: quitting waits on work that needs the main queue (see applicationShouldTerminate).
            RunLoop.main.perform { MainActor.assumeIsolated { NSApp.terminate(nil) } }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }
}
