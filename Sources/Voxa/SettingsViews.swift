import AppKit
import SwiftUI

private typealias SettingsState<Value> = SwiftUI.State<Value>

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, shortcuts, privacy, apiKey
    var id: Self { self }
    var title: String {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .privacy: return "Privacy"
        case .apiKey: return "API Keys"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
        case .privacy: return "hand.raised"
        case .apiKey: return "key.horizontal"
        }
    }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let keywords: String
        switch self {
        case .general: keywords = "permissions microphone accessibility input monitoring access system settings"
        case .shortcuts: keywords = "keyboard start stop finish send save feedback cancel close escape"
        case .privacy: keywords = "English feedback practice nearby text context excluded apps data storage retention"
        case .apiKey: keywords = "OpenAI Mistral Voxtral API key connection credentials storage Keychain"
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
                sidebarSection("Settings", panes: [.general, .shortcuts, .privacy])
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

struct SettingsShortcutRow: View {
    let title: String
    let detail: String
    let shortcut: String
    var recording = false
    var onRecord: () -> Void
    var onCancel: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body).foregroundStyle(.primary)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            Button(action: recording ? onCancel : onRecord) {
                Text(shortcut).font(.body)
                    .frame(minWidth: 74)
                    .fixedSize()
            }.buttonStyle(.bordered).foregroundStyle(.primary)
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(recording ? Color.accentColor : Color.clear, lineWidth: 2))
                .accessibilityLabel("\(title) shortcut")
                .accessibilityValue(recording ? "Recording shortcut" : shortcut)
                .accessibilityHint(recording ? "Press your new shortcut, or click to cancel." : "Click to change this shortcut.")
                .help(recording ? "Press your new shortcut. Click here to cancel." : "Click the key combination to change it")
        }.padding(.vertical, 3).accessibilityElement(children: .contain)
    }
}

/// One key per transcription service. English feedback and practice checks always use OpenAI.
struct APIKeySettingsView: View {
    let source: String
    let selectedProvider: TranscriptionProvider
    let configured: (TranscriptionProvider) -> Bool
    @Binding var openAIInput: String
    @Binding var mistralInput: String
    var busy = false
    var saving = false
    var errors: [TranscriptionProvider: String] = [:]
    var onSave: (TranscriptionProvider) -> Void

    var body: some View {
        SettingsPage(title: "API Keys", subtitle: "Connect the services used for dictation and English feedback.") {
            Form {
                keySection(.openAI, input: $openAIInput,
                           use: "Used for English feedback and practice checks, and for dictation with GPT models.")
                keySection(.mistral, input: $mistralInput,
                           use: "Used only for dictation with Voxtral. English feedback still needs an OpenAI key.")
            }.voxaSettingsFormStyle()
        }
    }

    private func keySection(_ provider: TranscriptionProvider, input: Binding<String>, use: String) -> some View {
        let configured = configured(provider)
        let canSave = !busy && source != "env" && !input.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return Section {
            LabeledContent("Status") {
                Label(configured ? "Configured" : "Not configured", systemImage: configured ? "checkmark.circle" : "key")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Storage") {
                Text(source == "keychain" ? "macOS Keychain" : "Environment").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(configured ? "Replace API key" : "API key")
                SecureField("Paste your \(provider.name) API key", text: input)
                    .labelsHidden().textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(busy || source == "env")
                    .accessibilityLabel("\(provider.name) API key")
                    .accessibilityHint(configured ? "A key is saved. Enter a new key to replace it." : "Enter your API key.")
                    .onSubmit { if canSave { onSave(provider) } }
            }.padding(.vertical, 4)
            if let error = errors[provider], !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(saving ? "Saving…" : (configured ? "Replace Key" : "Save Key")) { onSave(provider) }
                    .foregroundStyle(.primary).disabled(!canSave)
            }
        } header: {
            Text(provider == selectedProvider ? "\(provider.name) · current dictation model" : provider.name)
        } footer: {
            Text(source == "env"
                 ? "\(use) This key comes from \(provider.environmentVariable). Update it in the environment, then restart Voxa."
                 : "\(use) Your saved key stays private in macOS Keychain.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ShortcutsSettingsView: View {
    @ObservedObject var recorder: HotkeyRecorder
    let toggle: HotkeyOption
    let finishAndSubmit: HotkeyOption
    let saveFeedback: HotkeyOption
    let cancel: HotkeyOption
    var compareFeedback = HotkeyOption.defaultCompareFeedback
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
                    row("Save feedback", detail: "Save the fixes as lessons and close feedback.", current: saveFeedback, target: .saveFeedback)
                    row("Compare", detail: "Show or hide your sentences next to the natural version.", current: compareFeedback, target: .compareFeedback)
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
            controller.refreshPermissions()
            if controller.isReady && !controller.isAPIKeySet { selection = .apiKey }
        }
        .onChange(of: selection) { _ in hotkeyRecorder.stop(); controller.apiKeyInput = ""; controller.mistralKeyInput = "" }
        .onDisappear { hotkeyRecorder.stop(); controller.apiKeyInput = ""; controller.mistralKeyInput = "" }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            hotkeyRecorder.stop()
        }
    }

    @ViewBuilder private var page: some View {
        switch selection ?? .general {
        case .general:
            GeneralSettingsView(permissions: controller.permissions, canRequestMicrophone: !controller.isBusy,
                onRequestMicrophone: controller.requestMicrophonePermission)
        case .shortcuts:
            ShortcutsSettingsView(recorder: hotkeyRecorder, toggle: controller.toggleHotkey,
                finishAndSubmit: controller.finishAndSubmitHotkey, saveFeedback: controller.saveFeedbackHotkey,
                cancel: controller.cancelHotkey, compareFeedback: controller.compareFeedbackHotkey,
                canEdit: !controller.isBusy && controller.isReady,
                canSubmit: controller.outputMode == .clipboardAutopaste)
        case .privacy:
            PrivacySettingsView(excludedApps: controller.preferences.contextExcludedApps,
                transcriptionProvider: controller.model.provider,
                canEdit: controller.canEditDictationSettings,
                onExclude: controller.excludeContextApp, onAllow: controller.allowContextApp)
        case .apiKey:
            APIKeySettingsView(source: controller.apiKeySource, selectedProvider: controller.model.provider,
                configured: controller.isKeySet, openAIInput: $controller.apiKeyInput,
                mistralInput: $controller.mistralKeyInput, busy: controller.isBusy, saving: controller.isSavingKey,
                errors: controller.apiKeyErrors, onSave: controller.saveAPIKey(for:))
        }
    }

    private func configureHotkeyRecorder() {
        hotkeyRecorder.onCommit = { target, hotkey in
            switch target {
            case .toggle: controller.setToggleHotkey(hotkey)
            case .finishAndSubmit: controller.setFinishAndSubmitHotkey(hotkey)
            case .saveFeedback: controller.setSaveFeedbackHotkey(hotkey)
            case .cancel: controller.setCancelHotkey(hotkey)
            case .compareFeedback: controller.setCompareFeedbackHotkey(hotkey)
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
    case compareFeedback
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
