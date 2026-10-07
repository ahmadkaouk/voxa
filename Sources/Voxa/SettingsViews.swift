import AppKit
import SwiftUI

private typealias SettingsState<Value> = SwiftUI.State<Value>

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, shortcuts, learning, apiKey
    var id: Self { self }
    var title: String {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .learning: return "English Learning"
        case .apiKey: return "API Key"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gear"
        case .shortcuts: return "keyboard"
        case .learning: return "globe"
        case .apiKey: return "key.horizontal"
        }
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let keywords: String
        switch self {
        case .general: keywords = "dictation transcription model output recording limit microphone accessibility input monitoring permissions"
        case .shortcuts: keywords = "keyboard start stop finish send save feedback cancel close escape"
        case .learning: keywords = "English feedback lessons corrections practice context excluded apps auto-close delay duration timer seconds never"
        case .apiKey: keywords = "OpenAI API key connection credentials storage Keychain"
        }
        return query.isEmpty || (title + " " + keywords).localizedStandardContains(query)
    }
}

struct SettingsSidebarLayout<Content: View>: View {
    @Binding var selection: SettingsPane?
    @SettingsState private var search = ""
    @ViewBuilder var content: Content

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                sidebarSection("Settings", panes: [.general, .shortcuts, .learning])
                sidebarSection("Connection", panes: [.apiKey])
            }
            .voxaSidebarStyle()
            .overlay {
                if !SettingsPane.allCases.contains(where: { $0.matches(search) }) {
                    Text("No settings found").font(.callout).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        } detail: {
            // Native forms must use the column's current bounds after a resize.
            GeometryReader { geometry in
                content.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle((selection ?? .general).title)
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $search, placement: .sidebar, prompt: "Search")
        .buttonStyle(.bordered)
        .frame(minWidth: 760, idealWidth: 820, minHeight: 560, idealHeight: 620, alignment: .topLeading)
    }

    @ViewBuilder
    private func sidebarSection(_ title: String, panes: [SettingsPane]) -> some View {
        let matching = panes.filter { $0.matches(search) }
        if !matching.isEmpty {
            Section(title) {
                ForEach(matching) { pane in
                    VoxaSidebarLabel(title: pane.title, symbol: pane.symbol,
                                     isSelected: (selection ?? .general) == pane).tag(pane)
                }
            }
        }
    }
}

struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(VoxaAppearance.pageTitle).foregroundStyle(.primary)
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, VoxaAppearance.contentPadding)
                .padding(.top, VoxaAppearance.contentPadding).padding(.bottom, 8)
                .fixedSize(horizontal: false, vertical: true)
            content.clipped()
        }
    }
}

struct GeneralSettingsView: View {
    @Binding var model: ModelOption
    @Binding var output: OutputModeOption
    @Binding var duration: UInt64
    let permissions: Permissions
    var canEdit = true

    var body: some View {
        SettingsPage(title: "General", subtitle: "Choose how Voxa records and delivers your words.") {
            Form {
                Section("Dictation") {
                    Picker("Transcription model", selection: $model) {
                        ForEach(ModelOption.allCases) { Text($0.label).tag($0) }
                    }.tint(.primary)
                    Picker("Output", selection: $output) {
                        ForEach(OutputModeOption.allCases) { Text($0.label).tag($0) }
                    }.tint(.primary)
                    Picker("Recording limit", selection: $duration) {
                        ForEach(Array(Set([30, 60, 120, 300, 600, 1800, 3600, duration])).sorted(), id: \.self) { seconds in
                            Text(seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds) sec").tag(seconds)
                        }
                    }.tint(.primary)
                }.disabled(!canEdit)
                Section {
                    permission("Microphone", detail: "Record your voice.",
                               enabled: permissions.microphone == .authorized, pane: "Microphone")
                    permission("Accessibility", detail: "Paste into apps and read optional context.",
                               enabled: permissions.accessibility, pane: "Accessibility")
                    permission("Input Monitoring", detail: "Use dictation shortcuts in any app.",
                               enabled: permissions.inputMonitoring, pane: "ListenEvent")
                } header: { Text("Permissions") } footer: {
                    Text("Manage access in macOS System Settings. Recording changes apply to your next dictation.")
                }
            }.voxaSettingsFormStyle()
        }
    }

    private func permission(_ title: String, detail: String, enabled: Bool, pane: String) -> some View {
        HStack {
            SettingsControlLabel(title: title, detail: detail)
            Spacer(minLength: 12)
            if enabled {
                Label("Allowed", systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(Color(nsColor: .systemGreen))
                    .frame(width: 100, alignment: .leading).padding(.trailing, 8)
            } else {
                Button("Open Settings…") { Permissions.openSettings(pane) }
                    .accessibilityLabel("Allow \(title) in System Settings")
            }
        }.padding(.vertical, 3)
    }
}

struct APIKeySettingsView: View {
    let configured: Bool
    let source: String
    @Binding var input: String
    var busy = false
    var saving = false
    var error: String?
    var onSave: () -> Void

    var body: some View {
        SettingsPage(title: "API Key", subtitle: "Connect the service used for dictation and English feedback.") {
            Form {
                Section {
                    LabeledContent("Status") {
                        Label(configured ? "Configured" : "Not configured", systemImage: configured ? "checkmark.circle" : "key")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Storage") {
                        Text(source == "keychain" ? "macOS Keychain" : "Environment").foregroundStyle(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(configured ? "Replace API key" : "API key")
                        SecureField("Paste your API key", text: $input)
                            .labelsHidden().textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .disabled(busy || source == "env")
                            .accessibilityLabel("OpenAI API key")
                            .accessibilityHint(configured ? "A key is saved. Enter a new key to replace it." : "Enter your API key.")
                            .onSubmit { if canSave { onSave() } }
                    }.padding(.vertical, 4)
                    if let error, !error.isEmpty {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Spacer()
                        Button(saving ? "Saving…" : (configured ? "Replace Key" : "Save Key"), action: onSave)
                            .foregroundStyle(.primary).disabled(!canSave)
                    }
                } header: { Text("OpenAI") } footer: {
                    Text(source == "env"
                         ? "This key comes from OPENAI_API_KEY. Update it in the environment, then restart Voxa."
                         : "Paste a new key and choose Save or Replace Key. Your saved key stays private in macOS Keychain.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.voxaSettingsFormStyle()
        }
    }

    private var canSave: Bool {
        !busy && source != "env" && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct ShortcutsSettingsView: View {
    @ObservedObject var recorder: HotkeyRecorder
    let toggle: HotkeyOption
    let finishAndSubmit: HotkeyOption
    let saveFeedback: HotkeyOption
    let cancel: HotkeyOption
    var canEdit = true
    var canSubmit = true

    var body: some View {
        SettingsPage(title: "Shortcuts", subtitle: "Click a key combination, then press your new shortcut.") {
            Form {
                Section("Dictation") {
                    row("Start / Stop", detail: "Press again to finish and paste.", current: toggle, target: .toggle)
                    row("Finish & Send", detail: "Paste and press Return while recording.", current: finishAndSubmit, target: .finishAndSubmit)
                    if !canSubmit {
                        Label("Finish & Send requires Autopaste.", systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                Section("Recording and feedback") {
                    row("Cancel / Close", detail: "Discard dictation or close feedback.", current: cancel, target: .cancel)
                    row("Save feedback", detail: "Save the visible corrections and close feedback.", current: saveFeedback, target: .saveFeedback)
                }
                if let target = recorder.target {
                    Text(target == .cancel
                         ? "Release the keys to save. Click the shortcut again to cancel. Escape can be assigned here."
                         : "Release the keys to save. Press Esc or click the shortcut again to cancel.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }.voxaSettingsFormStyle().disabled(!canEdit)
        }
    }

    private func row(_ title: String, detail: String, current: HotkeyOption, target: HotkeyRecordingTarget) -> some View {
        SettingsShortcutRow(title: title, detail: detail,
            shortcut: recorder.target == target ? (recorder.preview?.symbolLabel ?? "Type shortcut") : current.symbolLabel,
            recording: recorder.target == target,
            onRecord: { recorder.start(target: target, current: current) }, onCancel: { recorder.stop() })
    }
}

@MainActor
struct VoxaSettingsView: View {
    @ObservedObject var controller: AppController
    @StateObject private var hotkeyRecorder = HotkeyRecorder()
    @SettingsState private var selection: SettingsPane? = .general
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SettingsSidebarLayout(selection: $selection) {
            VStack(spacing: 0) {
                page
                if let error = controller.errorMessage, !error.isEmpty {
                    Divider()
                    HStack {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Try Again") { controller.retrySetup() }.disabled(controller.isBusy)
                    }.padding(16)
                }
            }
        }
        .onExitCommand {
            if hotkeyRecorder.target != nil { hotkeyRecorder.stop() } else { dismiss() }
        }
        .onAppear {
            configureHotkeyRecorder()
            if controller.isReady && !controller.isAPIKeySet { selection = .apiKey }
        }
        .onChange(of: selection) { _ in hotkeyRecorder.stop(); controller.apiKeyInput = "" }
        .onDisappear { hotkeyRecorder.stop(); controller.apiKeyInput = "" }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            hotkeyRecorder.stop()
        }
    }

    @ViewBuilder private var page: some View {
        switch selection ?? .general {
        case .general:
            GeneralSettingsView(model: Binding(get: { controller.model }, set: { controller.setModel($0) }),
                output: Binding(get: { controller.outputMode }, set: { controller.setOutputMode($0) }),
                duration: Binding(get: { controller.maxRecordingSeconds }, set: { controller.setMaxRecordingSeconds($0) }),
                permissions: controller.permissions, canEdit: controller.canEditDictationSettings)
        case .shortcuts:
            ShortcutsSettingsView(recorder: hotkeyRecorder, toggle: controller.toggleHotkey,
                finishAndSubmit: controller.finishAndSubmitHotkey, saveFeedback: controller.saveFeedbackHotkey,
                cancel: controller.cancelHotkey, canEdit: !controller.isBusy && controller.isReady,
                canSubmit: controller.outputMode == .clipboardAutopaste)
        case .learning:
            SettingsPage(title: "English Learning", subtitle: "Turn everyday dictation into a little practice.") {
                EnglishLearningSettingsView(feedbackEnabled: Binding(
                    get: { controller.preferences.englishFeedbackEnabled }, set: { controller.setEnglishFeedbackEnabled($0) }),
                    contextEnabled: Binding(get: { controller.preferences.automaticContextEnabled },
                                            set: { controller.setAutomaticContextEnabled($0) }),
                    autoCloseSeconds: Binding(get: { controller.feedbackAutoCloseSeconds },
                                              set: { controller.setFeedbackAutoCloseSeconds($0) }),
                    excludedApps: controller.preferences.contextExcludedApps,
                    hasAccessibility: controller.permissions.accessibility,
                    saveShortcut: controller.saveFeedbackHotkey.symbolLabel, cancelShortcut: controller.cancelHotkey.symbolLabel,
                    canEdit: controller.canEditDictationSettings,
                    recordingShortcut: hotkeyRecorder.target, shortcutPreview: hotkeyRecorder.preview?.symbolLabel,
                    onEditShortcut: editShortcut,
                    onExclude: controller.excludeContextApp, onAllow: controller.allowContextApp,
                    onOpenLessons: { openWindow(id: "english-lessons") })
            }
        case .apiKey:
            APIKeySettingsView(configured: controller.isAPIKeySet, source: controller.apiKeySource,
                input: $controller.apiKeyInput, busy: controller.isBusy, saving: controller.isSavingKey,
                error: controller.apiKeyError, onSave: controller.saveAPIKey)
        }
    }

    private func editShortcut(_ target: HotkeyRecordingTarget) {
        if hotkeyRecorder.target == target { hotkeyRecorder.stop(); return }
        let current: HotkeyOption
        switch target {
        case .toggle: current = controller.toggleHotkey
        case .finishAndSubmit: current = controller.finishAndSubmitHotkey
        case .saveFeedback: current = controller.saveFeedbackHotkey
        case .cancel: current = controller.cancelHotkey
        }
        hotkeyRecorder.start(target: target, current: current)
    }

    private func configureHotkeyRecorder() {
        hotkeyRecorder.onCommit = { target, hotkey in
            switch target {
            case .toggle: controller.setToggleHotkey(hotkey)
            case .finishAndSubmit: controller.setFinishAndSubmitHotkey(hotkey)
            case .saveFeedback: controller.setSaveFeedbackHotkey(hotkey)
            case .cancel: controller.setCancelHotkey(hotkey)
            }
        }
        hotkeyRecorder.onCaptureStateChanged = { controller.setHotkeyCaptureEnabled($0) }
    }
}

enum HotkeyRecordingTarget: Equatable {
    case toggle
    case finishAndSubmit
    case saveFeedback
    case cancel
}

final class HotkeyRecorder: ObservableObject {
    @Published private(set) var target: HotkeyRecordingTarget?
    @Published private(set) var preview: HotkeyOption?

    var onCommit: ((HotkeyRecordingTarget, HotkeyOption) -> Void)?
    var onCaptureStateChanged: ((Bool) -> Void)?

    private var localMonitor: Any?
    private var recordedModifiers: HotkeyModifiers = []
    private var recordedKeyCodes: Set<UInt16> = []
    private var keyDisplayOverrides: [UInt16: String] = [:]
    private var pendingHotkey: HotkeyOption?

    func start(target: HotkeyRecordingTarget, current: HotkeyOption) {
        stop()

        self.target = target
        preview = nil
        onCaptureStateChanged?(true)

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            // A nil result consumes the event, including Escape; don't forward it
            // to the Settings window's cancel action or its focused text field.
            return self.handle(event)
        }
    }

    func stop() {
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }

        let wasRecording = target != nil
        target = nil
        preview = nil
        recordedModifiers = []
        recordedKeyCodes.removeAll()
        keyDisplayOverrides.removeAll()
        pendingHotkey = nil

        if wasRecording {
            onCaptureStateChanged?(false)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard target != nil else {
            return event
        }

        switch event.type {
        case .keyDown:
            if event.keyCode == KeyCode.escape && event.modifierFlags.intersection([.command, .control, .option, .shift, .function]).isEmpty
                && target != .cancel {
                stop()
                return nil
            }

            guard !event.isARepeat, !HotkeyOption.isModifierKeyCode(event.keyCode) else {
                return nil
            }

            recordedModifiers = HotkeyModifiers(eventFlags: event.modifierFlags)
            recordedKeyCodes.insert(event.keyCode)
            keyDisplayOverrides[event.keyCode] = HotkeyOption.displayName(
                forKeyCode: event.keyCode,
                characters: event.charactersIgnoringModifiers
            )
            updatePendingHotkey()
            return nil

        case .keyUp:
            guard !HotkeyOption.isModifierKeyCode(event.keyCode) else {
                return nil
            }

            recordedModifiers = HotkeyModifiers(eventFlags: event.modifierFlags)
            recordedKeyCodes.remove(event.keyCode)
            if recordedKeyCodes.isEmpty && recordedModifiers.isEmpty {
                commitPendingHotkey()
            }
            return nil

        case .flagsChanged:
            recordedModifiers = HotkeyModifiers(eventFlags: event.modifierFlags)
            if recordedKeyCodes.isEmpty && recordedModifiers.isEmpty {
                commitPendingHotkey()
            } else {
                updatePendingHotkey()
            }
            return nil

        default:
            return event
        }
    }

    private func updatePendingHotkey() {
        let sortedKeyCodes = recordedKeyCodes.sorted()
        if sortedKeyCodes.isEmpty {
            if let modifierOnly = HotkeyOption.modifierOnly(recordedModifiers) {
                preview = modifierOnly
                pendingHotkey = modifierOnly
            }
            return
        }

        let keyDisplays = sortedKeyCodes.map { keyCode in
            keyDisplayOverrides[keyCode] ?? HotkeyOption.displayName(forKeyCode: keyCode, characters: nil)
        }

        let hotkey = HotkeyOption(
            keyCodes: sortedKeyCodes,
            modifiers: recordedModifiers,
            keyDisplays: keyDisplays
        )
        preview = hotkey
        pendingHotkey = hotkey
    }

    private func commitPendingHotkey() {
        guard let pendingHotkey else {
            stop()
            return
        }

        commit(pendingHotkey)
    }

    private func commit(_ hotkey: HotkeyOption) {
        guard let target else {
            return
        }

        stop()
        onCommit?(target, hotkey)
    }
}
