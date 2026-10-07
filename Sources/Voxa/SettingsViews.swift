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
        case .general: return "slider.horizontal.3"
        case .shortcuts: return "keyboard"
        case .learning: return "text.book.closed"
        case .apiKey: return "key"
        }
    }
}

struct SettingsSidebarLayout<Content: View>: View {
    @Binding var selection: SettingsPane?
    @ViewBuilder var content: Content

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $selection) { pane in
                Label(pane.title, systemImage: pane.symbol)
                    .padding(.vertical, 5).tag(pane)
            }
            .listStyle(.sidebar)
            .navigationTitle("Voxa Settings")
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                .navigationTitle((selection ?? .general).title)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 760, idealWidth: 820, minHeight: 560, idealHeight: 620)
    }
}

struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 8)
            content
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
                    }
                    Picker("Output", selection: $output) {
                        ForEach(OutputModeOption.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Recording limit", selection: $duration) {
                        ForEach(Array(Set([30, 60, 120, 300, 600, 1800, 3600, duration])).sorted(), id: \.self) { seconds in
                            Text(seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds) sec").tag(seconds)
                        }
                    }
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
            }.formStyle(.grouped)
        }
    }

    private func permission(_ title: String, detail: String, enabled: Bool, pane: String) -> some View {
        HStack {
            SettingsControlLabel(title: title, detail: detail)
            Spacer(minLength: 12)
            if enabled {
                Label("Allowed", systemImage: "checkmark.circle")
                    .font(.callout).foregroundStyle(.secondary)
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
                Section("OpenAI") {
                    LabeledContent("Status") {
                        Label(configured ? "Configured" : "Not configured", systemImage: configured ? "checkmark.circle" : "key")
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Storage", value: source == "keychain" ? "macOS Keychain" : "Environment")
                    SecureField(configured ? "Replace API key" : "API key", text: $input)
                        .disabled(busy)
                        .accessibilityLabel("OpenAI API key")
                        .accessibilityHint(configured ? "A key is saved. Enter a new key to replace it." : "Enter your API key.")
                    if let error, !error.isEmpty {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Spacer()
                        Button(saving ? "Saving…" : (configured ? "Replace Key" : "Save Key"), action: onSave)
                            .disabled(busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }.formStyle(.grouped)
        }
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
            SettingsPage(title: "Shortcuts", subtitle: "Keep dictation close, wherever you’re working.") {
                Form {
                    Section("Dictation") {
                        hotkeyRow("Start / Stop", detail: "Press again to finish and paste.",
                                  current: controller.toggleHotkey, target: .toggle)
                        hotkeyRow("Finish & Send", detail: "Paste and press Return while recording.",
                                  current: controller.finishAndSubmitHotkey, target: .finishAndSubmit)
                        if controller.outputMode != .clipboardAutopaste {
                            Label("Finish & Send requires Autopaste.", systemImage: "info.circle")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if hotkeyRecorder.target != nil {
                            Text("Hold the full combination, then release it to save. Press Esc to cancel.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }.disabled(controller.isBusy || !controller.isReady)
                    Section("While recording or reviewing feedback") {
                        LabeledContent("Cancel dictation or close feedback", value: "Esc")
                        LabeledContent("Save feedback", value: "⌘S")
                    }
                }.formStyle(.grouped)
            }
        case .learning:
            SettingsPage(title: "English Learning", subtitle: "Turn everyday dictation into a little practice.") {
                EnglishLearningSettingsView(feedbackEnabled: Binding(
                    get: { controller.preferences.englishFeedbackEnabled }, set: { controller.setEnglishFeedbackEnabled($0) }),
                    contextEnabled: Binding(get: { controller.preferences.automaticContextEnabled },
                                            set: { controller.setAutomaticContextEnabled($0) }),
                    excludedApps: controller.preferences.contextExcludedApps,
                    hasAccessibility: controller.permissions.accessibility,
                    canEdit: controller.canEditDictationSettings,
                    onExclude: controller.excludeContextApp, onAllow: controller.allowContextApp,
                    onOpenLessons: { openWindow(id: "english-lessons") })
            }
        case .apiKey:
            APIKeySettingsView(configured: controller.isAPIKeySet, source: controller.apiKeySource,
                input: $controller.apiKeyInput, busy: controller.isBusy, saving: controller.isSavingKey,
                error: controller.apiKeyError, onSave: controller.saveAPIKey)
        }
    }

    private func hotkeyRow(_ title: String, detail: String, current: HotkeyOption, target: HotkeyRecordingTarget) -> some View {
        SettingsShortcutRow(title: title, detail: detail,
            shortcut: hotkeyRecorder.target == target ? (hotkeyRecorder.preview?.label ?? "Press keys") : current.label,
            recording: hotkeyRecorder.target == target,
            onRecord: { hotkeyRecorder.start(target: target, current: current) },
            onCancel: { hotkeyRecorder.stop() })
    }

    private func configureHotkeyRecorder() {
        hotkeyRecorder.onCommit = { target, hotkey in
            switch target {
            case .toggle: controller.setToggleHotkey(hotkey)
            case .finishAndSubmit: controller.setFinishAndSubmitHotkey(hotkey)
            }
        }
        hotkeyRecorder.onCaptureStateChanged = { controller.setHotkeyCaptureEnabled($0) }
    }
}

private enum HotkeyRecordingTarget: Equatable {
    case toggle
    case finishAndSubmit
}

private final class HotkeyRecorder: ObservableObject {
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
        preview = current
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
            if event.keyCode == KeyCode.escape {
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
