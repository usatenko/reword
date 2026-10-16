import AppKit
import SwiftUI

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0" }
    static var versionLine: String { "Version \(version) (\(build))" }
    static let repository = URL(string: "https://github.com/usatenko/reword")!

    /// Licenses of bundled third-party code, shipped in the app's Resources.
    static var notices: String {
        Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "Third-party notices are missing from this build."
    }
}

@MainActor
enum AboutWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let host = NSHostingController(rootView: AboutView())
            host.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: host)
            window.title = "About Reword"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            self.window = window
        }
        if window?.isVisible != true { window?.center() }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }
}

struct AboutView: View {
    @State private var showNotices = false

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: MenuBarIcon.current)
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.tint)
                .padding(.top, 6)
            Text("Reword").font(.title2.weight(.semibold))
            Text(AppInfo.versionLine).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Text("A very simple offline translator.\nText, selections and screenshots, translated on your Mac.")
                .font(.callout)
                .multilineTextAlignment(.center)
            VStack(spacing: 2) {
                Text("Translation model: Hy-MT2 1.8B by Tencent (Apache-2.0)")
                Text("Runtime: llama.cpp and ggml (MIT)")
                Text("OCR and language detection: Apple Vision, NaturalLanguage")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Link("GitHub", destination: AppInfo.repository)
                Button(showNotices ? "Hide Acknowledgements" : "Acknowledgements") {
                    withAnimation(.snappy) { showNotices.toggle() }
                }
                .buttonStyle(.link)
            }
            .font(.callout)
            if showNotices {
                ScrollView {
                    Text(AppInfo.notices)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 220)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            Text("© 2026 Oleksii Usatenko · MIT License").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(20)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
