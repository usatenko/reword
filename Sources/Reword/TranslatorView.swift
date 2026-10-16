import ServiceManagement
import SwiftUI

private let cardShape = RoundedRectangle(cornerRadius: 10, style: .continuous)
private let bodyFont = Font.system(size: 13)

private extension View {
    func card(padding: CGFloat = 10) -> some View {
        self.padding(padding).background(Color.primary.opacity(0.07), in: cardShape)
    }
}

private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 18, height: 18).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

// MARK: - Popup

/// An AppKit view that moves the window when its empty background is dragged.
private struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Native vertical split between the input and the translation: a grip divider with the resize cursor,
/// minimum pane heights, and the position remembered across launches.
private struct InputOutputSplit<Top: View, Bottom: View>: NSViewRepresentable {
    let top: Top
    let bottom: Bottom

    final class GripSplitView: NSSplitView {
        override var dividerThickness: CGFloat { 10 }
        override var dividerColor: NSColor { .clear }

        override func drawDivider(in rect: NSRect) {
            let grip = NSRect(x: rect.midX - 18, y: rect.midY - 2, width: 36, height: 4)
            NSColor.tertiaryLabelColor.setFill()
            NSBezierPath(roundedRect: grip, xRadius: 2, yRadius: 2).fill()
        }
    }

    final class Coordinator: NSObject, NSSplitViewDelegate {
        var top: NSHostingView<Top>?
        var bottom: NSHostingView<Bottom>?
        var placed = false
        var lastWindowFrame: NSRect?
        let minTop: CGFloat = 70
        let minBottom: CGFloat = 60

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
            max(proposed, minTop)
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposed: CGFloat, ofSubviewAt index: Int) -> CGFloat {
            min(proposed, splitView.bounds.height - splitView.dividerThickness - minBottom)
        }

        /// Resizing the window changes the pane next to the dragged edge: the top edge resizes the input,
        /// the bottom edge (or a corner) resizes the translation.
        func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
            guard splitView.subviews.count == 2 else { splitView.adjustSubviews(); return }
            let height = splitView.bounds.height - splitView.dividerThickness
            var topHeight = splitView.subviews[0].frame.height
            let windowFrame = splitView.window?.frame
            if !placed {        // first layout: restore the saved input height, or 40% of the pane
                placed = true
                let saved = UserDefaults.standard.double(forKey: "splitTopHeight")
                topHeight = saved > 0 ? saved : height * 0.4
            } else if let last = lastWindowFrame, let frame = windowFrame,
                      abs(frame.maxY - last.maxY) > 0.5, abs(frame.minY - last.minY) < 0.5 {
                // Only the top edge moved: give the change to the input pane.
                topHeight += splitView.bounds.height - oldSize.height
                UserDefaults.standard.set(max(topHeight, minTop), forKey: "splitTopHeight")
            }
            lastWindowFrame = windowFrame
            // Only squeeze the input when the window gets too short for both panes.
            topHeight = min(max(topHeight, minTop), max(minTop, height - minBottom))
            let width = splitView.bounds.width
            splitView.subviews[0].frame = NSRect(x: 0, y: 0, width: width, height: topHeight)
            splitView.subviews[1].frame = NSRect(x: 0, y: topHeight + splitView.dividerThickness,
                                                 width: width, height: max(0, height - topHeight))
        }

        /// Remembers the input height when the user drags the divider (not when the window resizes).
        func splitViewDidResizeSubviews(_ notification: Notification) {
            guard placed, let split = notification.object as? NSSplitView, split.subviews.count == 2,
                  notification.userInfo?["NSSplitViewDividerIndex"] != nil else { return }
            UserDefaults.standard.set(split.subviews[0].frame.height, forKey: "splitTopHeight")
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Fill the space SwiftUI offers; an NSSplitView has no natural height and would otherwise report zero,
    /// which let Auto Layout collapse the whole window.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSplitView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 380, height: max(proposal.height ?? 300, Self.minimumHeight))
    }

    static var minimumHeight: CGFloat { 70 + 10 + 60 }

    func makeNSView(context: Context) -> NSSplitView {
        let split = GripSplitView()
        split.isVertical = false            // panes stacked top to bottom
        split.setContentHuggingPriority(.defaultLow, for: .vertical)
        split.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        split.delegate = context.coordinator
        let topHost = NSHostingView(rootView: top)
        let bottomHost = NSHostingView(rootView: bottom)
        for host in [topHost, bottomHost] as [NSView] {
            (host as? NSHostingView<Top>)?.sizingOptions = []
            (host as? NSHostingView<Bottom>)?.sizingOptions = []
            split.addArrangedSubview(host)
        }
        context.coordinator.top = topHost
        context.coordinator.bottom = bottomHost
        return split
    }

    func updateNSView(_ split: NSSplitView, context: Context) {
        context.coordinator.top?.rootView = top
        context.coordinator.bottom?.rootView = bottom
    }
}

struct TranslatorView: View {
    @ObservedObject var model: TranslatorModel
    var openSettings: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            topBar
            languageCard
            if let line = model.inputStatus ?? model.status {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(line).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)
                .transition(.opacity)
            }
            // Input above, translation below; the divider between them can be dragged.
            InputOutputSplit(top: InputPane(model: model), bottom: OutputPane(model: model))
                .frame(minHeight: InputOutputSplit<InputPane, OutputPane>.minimumHeight, maxHeight: .infinity)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WindowDragArea())                 // empty space anywhere drags the window
        .ignoresSafeArea()                            // use the transparent title bar area, no empty strip
        .onChange(of: model.input) { model.inputChanged() }
    }

    private var topBar: some View {
        HStack {
            Button { model.pinned.toggle() } label: {
                HStack(spacing: 4) {
                    Image(systemName: model.pinned ? "pin.fill" : "pin.slash")
                    Text(model.pinned ? "Pinned" : "Auto-hide")
                }
                .font(.system(size: 11))
                .foregroundStyle(model.pinned ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(model.pinned ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(Color.primary.opacity(0.07)), in: Capsule())
            }
            .help(model.pinned
                  ? "Pinned: the window stays open. Click to auto-hide it when you switch to another app."
                  : "Auto-hide: the window closes when you switch to another app. Click to keep it open.")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Reword")
                .font(.system(size: 13, weight: .semibold))
                .allowsHitTesting(false)                 // dragging the title moves the window
            Button(action: openSettings) { Image(systemName: "gearshape").font(.system(size: 12)).foregroundStyle(.secondary) }
                .help("Settings")
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 2)
    }

    private var languageCard: some View {
        HStack(spacing: 4) {
            LanguageMenu(selection: $model.sourceChoice,
                         autoTitle: model.detected.map { _ in "Auto" } ?? "Auto detect",
                         autoFlag: model.detected.map(LanguageTools.flag))
                .frame(maxWidth: .infinity)
            Button(action: model.swapLanguages) {
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(model.detected == nil)
            .help("Swap languages")
            LanguageMenu(selection: $model.targetChoice,
                         autoTitle: LanguageTools.displayName(model.displayTarget),
                         autoFlag: LanguageTools.flag(model.displayTarget))
                .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(Color.primary.opacity(0.07), in: cardShape)
        .frame(maxWidth: .infinity)
    }
}


/// The text being translated (top pane).
private struct InputPane: View {
    @ObservedObject var model: TranslatorModel
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $model.input)
                    .font(bodyFont)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .focused($inputFocused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) || press.modifiers.contains(.option) { return .ignored }
                        model.translate()      // Return translates now; Shift- or Option-Return inserts a new line
                        return .handled
                    }
                if model.input.isEmpty {
                    Text("Type or paste text…")
                        .font(bodyFont)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxHeight: .infinity)
            HStack(spacing: 6) {
                IconButton(symbol: "speaker.wave.2", help: "Speak") { Speech.speak(model.input, language: model.detected) }
                IconButton(symbol: "doc.on.doc", help: "Copy") { copyToPasteboard(model.input) }
                if let detected = model.detected {
                    HStack(spacing: 3) {
                        Text("Detected").foregroundStyle(.secondary)
                        Text(LanguageTools.displayName(detected)).foregroundStyle(.tint)
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: Capsule())
                }
                Spacer()
                if !model.input.isEmpty {
                    Button { model.clear(); inputFocused = true } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear")
                }
            }
        }
        .card(padding: 8)
        .padding(.bottom, 2)
        .onAppear { inputFocused = true }
        .onChange(of: model.focusRequest) { inputFocused = true }
    }
}

/// The translation results (bottom pane).
private struct OutputPane: View {
    @ObservedObject var model: TranslatorModel
    @ObservedObject var downloader = ModelDownloader.shared

    var body: some View {
        content
            .padding(.top, 2)                    // small gap below the divider
            .onChange(of: downloader.isInstalled) { if downloader.isInstalled { model.translate() } }
    }

    @ViewBuilder private var content: some View {
        if model.results.isEmpty && model.notice == nil && downloader.isInstalled {
            Text("Translation")
                .font(bodyFont)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 5)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .card(padding: 8)
        } else {
            ScrollView {
                VStack(spacing: 6) {
                    if !downloader.isInstalled { ModelDownloadView(downloader: downloader, onInstalled: {}) }
                    if let notice = model.notice {
                        Text(notice).font(bodyFont).foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    }
                    ForEach(model.results) { ResultCard(result: $0, language: model.resolvedTarget) }
                }
            }
            .scrollIndicators(.automatic)
            .contentMargins(.vertical, 6, for: .scrollIndicators)   // keep the scrollbar off the edges
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.07), in: cardShape) // one card that always reaches the bottom
            .clipShape(cardShape)                                    // scrolled content stays inside rounded bounds
        }
    }
}

private struct LanguageMenu: View {
    @Binding var selection: String
    let autoTitle: String
    let autoFlag: String?

    var body: some View {
        Menu {
            Button("Auto") { selection = TranslatorModel.auto }
            Divider()
            ForEach(AppLanguage.all) { lang in
                Button("\(LanguageTools.flag(lang.id))  \(lang.name)") { selection = lang.id }
            }
        } label: {
            HStack(spacing: 4) {
                if selection == TranslatorModel.auto {
                    if let autoFlag { Text(autoFlag) }
                    Text(autoTitle)
                } else {
                    Text(LanguageTools.flag(selection))
                    Text(LanguageTools.displayName(selection))
                }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            .lineLimit(1)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

struct ResultCard: View {
    let result: EngineResult
    let language: String?
    @State private var collapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text(result.name).font(.system(size: 12, weight: .medium))
                Text(result.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                Spacer()
                if isWorking { ProgressView().controlSize(.mini) }
                Button { withAnimation(.snappy) { collapsed.toggle() } } label: {
                    Image(systemName: collapsed ? "chevron.left" : "chevron.down").font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            if !collapsed { content }
        }
        .padding(10)
    }

    private var isWorking: Bool {
        switch result.state {
        case .loading, .streaming: return true
        default: return false
        }
    }

    @ViewBuilder private var content: some View {
        switch result.state {
        case .loading:
            EmptyView()
        case let .streaming(text):
            resultText(text)
        case let .done(text):
            resultText(text)
            HStack(spacing: 6) {
                IconButton(symbol: "speaker.wave.2", help: "Speak") { Speech.speak(text, language: language) }
                IconButton(symbol: "doc.on.doc", help: "Copy") { copyToPasteboard(text) }
            }
        case let .failed(message):
            Text(message).font(bodyFont).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func resultText(_ text: String) -> some View {
        Text(text)
            .font(bodyFont)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ModelDownloadView: View {
    @ObservedObject var downloader: ModelDownloader
    var onInstalled: () -> Void

    private var size: String { ByteCountFormatter.string(fromByteCount: ModelStore.expectedBytes, countStyle: .file) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle").foregroundStyle(.tint)
                if downloader.verifying {
                    ProgressView().controlSize(.small)
                    Text("Verifying download…").foregroundStyle(.secondary)
                } else if let progress = downloader.progress {
                    ProgressView(value: progress).controlSize(.small)
                    Text(progress.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit().foregroundStyle(.secondary)
                    Button("Cancel", action: downloader.cancel).controlSize(.small)
                } else {
                    Text("Translation model not downloaded · \(size)")
                    Spacer()
                    Button("Download", action: downloader.start).controlSize(.small)
                }
            }
            if let error = downloader.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange)
            }
        }
        .font(bodyFont)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 8)
        .help("Hy-MT2 1.8B \(ModelStore.quant.rawValue) from huggingface.co/tencent. Downloaded once; translation then runs entirely on this Mac.")
        .onChange(of: downloader.isInstalled) { if downloader.isInstalled { onInstalled() } }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @AppStorage(Prefs.first) private var first = "en"
    @AppStorage(Prefs.second) private var second = "zh-Hans"
    @AppStorage(Prefs.idleUnloadSeconds) private var idleUnload = 300
    @AppStorage(ModelStore.quantKey) private var quant = ModelQuant.q4.rawValue
    @AppStorage(MenuBarIcon.key) private var menuIcon = MenuBarIcon.fallback
    @ObservedObject var downloader = ModelDownloader.shared
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    @State private var axTrusted = SelectionReader.isTrusted
    @State private var screenAccess = ScreenOCR.hasScreenAccess
    @State private var modelLoaded = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: setLaunchAtLogin))
                if loginStatus == .requiresApproval {
                    LabeledContent("Needs approval in Login Items") {
                        Button("Open…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    .foregroundStyle(.orange)
                }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.orange) }
                Picker("Menu bar icon", selection: $menuIcon) {
                    ForEach(MenuBarIcon.choices, id: \.self) { Image(nsImage: MenuBarIcon.image($0, size: 16)).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Picker("Primary language", selection: $first) {
                    ForEach(AppLanguage.all) { Text("\(LanguageTools.flag($0.id))  \($0.name)").tag($0.id) }
                }
                .help("Text in any other language is translated into this one.")
                Picker("Secondary language", selection: $second) {
                    ForEach(AppLanguage.all) { Text("\(LanguageTools.flag($0.id))  \($0.name)").tag($0.id) }
                }
                .help("Text in your primary language is translated into this one.")
            }

            Section {
                ForEach(ShortcutAction.allCases) { action in
                    LabeledContent(action.title) { ShortcutRecorder(action: action) }
                }
                LabeledContent("Permissions") {
                    HStack(spacing: 8) {
                        PermissionBadge(granted: axTrusted, title: "Accessibility") {
                            SelectionReader.promptForAccessibility()
                            PrivacyPane.accessibility.open()
                        }
                        .help("Needed to read the selected text (\(Shortcut.current(.selectionTranslate)?.display ?? "Translate selected text")).")
                        PermissionBadge(granted: screenAccess, title: "Screen Recording") {
                            CGRequestScreenCaptureAccess()
                            PrivacyPane.screenRecording.open()
                        }
                        .help("Needed for screenshot OCR. After enabling it, quit and reopen Reword.")
                    }
                }
            }

            Section {
                Picker("Model", selection: $quant) {
                    ForEach(ModelQuant.allCases) { Text("Hy-MT2 1.8B · \($0.label)").tag($0.rawValue) }
                }
                .onChange(of: quant) {
                    downloader.refresh()
                    Task { await HyMTEngine.shared.unload() }
                }
                .help("tencent/Hy-MT2-1.8B GGUF, run in-process with llama.cpp on Metal. Everything stays on this Mac; the only network request is the one-time model download.")
                if downloader.isInstalled {
                    LabeledContent("Status") {
                        HStack(spacing: 6) {
                            Text("\(modelLoaded ? "Loaded" : "Unloaded") · \(ModelStore.sizeOnDisk) on disk")
                                .foregroundStyle(.secondary)
                            Button { NSWorkspace.shared.activateFileViewerSelecting([ModelStore.localURL]) } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.borderless)
                            .help("Show the model file in Finder")
                        }
                    }
                } else {
                    ModelDownloadView(downloader: downloader, onInstalled: {})
                }
                Picker("Unload when idle", selection: $idleUnload) {
                    Text("1 min").tag(60)
                    Text("5 min").tag(300)
                    Text("15 min").tag(900)
                    Text("30 min").tag(1800)
                    Text("Never").tag(0)
                }
            }

            Section {
                LabeledContent("Version") {
                    HStack(spacing: 8) {
                        Text("\(AppInfo.version) (\(AppInfo.build))").foregroundStyle(.secondary).textSelection(.enabled)
                        Button("About…") { AboutWindow.show(delegate: NSApp.delegate as? NSWindowDelegate) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            axTrusted = SelectionReader.isTrusted
            screenAccess = ScreenOCR.hasScreenAccess
            loginStatus = SMAppService.mainApp.status
            modelLoaded = HyMTEngine.shared.isLoaded
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change the login item: \(error.localizedDescription)"
        }
        loginStatus = SMAppService.mainApp.status
    }
}

private struct PermissionBadge: View {
    let granted: Bool
    let title: String
    let request: () -> Void

    var body: some View {
        Button(action: request) {
            HStack(spacing: 4) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(granted ? .green : .orange)
                Text(title)
            }
        }
        .buttonStyle(.borderless)
        .disabled(granted)
    }
}
