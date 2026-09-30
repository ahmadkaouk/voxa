import AppKit
import SwiftUI

@main
@MainActor
struct VoxaApp: App {
    @NSApplicationDelegateAdaptor(VoxaAppDelegate.self) private var appDelegate

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            VoxaMenuView(controller: appDelegate.controller)
        } label: {
            MenuBarLabel(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.menu)

        Window("Voxa Settings", id: "settings") {
            VoxaSettingsView(controller: appDelegate.controller)
        }
        .windowResizability(.contentSize)

        Window("English Learning", id: "english-lessons") {
            SavedCorrectionsView(controller: appDelegate.controller.feedback)
        }
    }
}

@MainActor
private struct MenuBarLabel: View {
    @ObservedObject var controller: AppController
    var body: some View { Label("Voxa", systemImage: controller.menuBarSymbol) }
}

@MainActor
struct VoxaMenuView: View {
    @ObservedObject var controller: AppController
    @Environment(\.openWindow) private var openWindow

    // AppController forwards state and preference changes. Observing the session
    // directly also rebuilds native menus for every audio-level sample, which
    // interrupts submenu tracking and makes the selection highlight flicker.
    private var session: DictationSession { controller.session }

    var body: some View {
        Section {
            Button(action: performPrimaryAction) {
                Label(primaryActionTitle, systemImage: primaryActionSymbol)
            }
            .disabled(primaryActionDisabled)
            .accessibilityHint(primaryActionAccessibilityHint)
        } header: {
            Text(statusMenuTitle)
        }

        if let error = controller.errorMessage, !error.isEmpty {
            Button("View Error…") { showSettings() }
                .help(error)
        }

        Divider()

        Menu {
            nextRecordingNotice
            Picker("Model", selection: Binding(get: { controller.model }, set: { controller.setModel($0) })) {
                ForEach(ModelOption.allCases) { model in
                    Text(model.label).tag(model)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label("Model", systemImage: "waveform")
                .labelStyle(.titleAndIcon)
        }
        .disabled(!controller.canEditDictationSettings)

        Menu {
            nextRecordingNotice
            Picker("Output", selection: Binding(get: { controller.outputMode }, set: { controller.setOutputMode($0) })) {
                ForEach(OutputModeOption.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Button("Copy Last Transcript") { controller.copyLastTranscript() }
                .disabled(session.lastTranscript == nil)
        } label: {
            Label("Output", systemImage: "text.bubble")
                .labelStyle(.titleAndIcon)
        }
        .disabled(!controller.canEditDictationSettings)

        Menu {
            nextRecordingNotice
            Picker("Max Recording", selection: Binding(
                get: { controller.maxRecordingSeconds }, set: { controller.setMaxRecordingSeconds($0) }
            )) {
                ForEach(maxRecordingOptions, id: \.self) { seconds in
                    Text(formattedRecordingDuration(seconds)).tag(seconds)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label("Max Recording", systemImage: "timer")
                .labelStyle(.titleAndIcon)
        }
        .disabled(!controller.canEditDictationSettings)

        Divider()
        Menu {
            Toggle("English feedback", isOn: Binding(
                get: { controller.preferences.englishFeedbackEnabled },
                set: { controller.setEnglishFeedbackEnabled($0) }))
                .disabled(!controller.canEditDictationSettings)
            if controller.feedback.isAnalyzing { Text("Reviewing your English…") }
            if let status = controller.feedback.status { Text(status) }
            Button("Show Latest Feedback") { controller.feedback.showLatest() }
                .disabled(!controller.feedback.hasReview || session.state.context != nil)
            Button("Lessons & Progress…") {
                openWindow(id: "english-lessons")
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        } label: {
            Label("English Learning", systemImage: "text.bubble")
        }

        Divider()
        if controller.permissions.microphone == .denied || controller.permissions.microphone == .restricted {
            Button("Enable Microphone…") { Permissions.openSettings("Microphone") }
        }
        if !controller.permissions.accessibility {
            Button("Enable Accessibility…") { Permissions.openSettings("Accessibility") }
        }
        if !controller.permissions.inputMonitoring {
            Button("Enable Input Monitoring…") { Permissions.openSettings("ListenEvent") }
        }
        Button { showSettings() } label: {
            Label("Voxa Settings…", systemImage: "gearshape")
        }
        .keyboardShortcut(",")
        Button("Quit Voxa") { controller.quit() }
            .keyboardShortcut("q")
    }

    private func showSettings() {
        openWindow(id: "settings")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    @ViewBuilder
    private var nextRecordingNotice: some View {
        if session.state.isBusy {
            Text("Changes apply to the next recording")
            Divider()
        }
    }

    private var statusMenuTitle: String {
        if controller.isSettingUp { return "Voxa is starting" }
        if !controller.isReady { return "Voxa needs attention" }
        switch session.state {
        case .idle, .restoringClipboard: return controller.isAPIKeySet ? "Voxa is ready" : "Set up Voxa"
        case .starting: return "Preparing microphone"
        case .recording: return "Voxa is recording"
        case .finishing: return "Finishing recording"
        case .transcribing: return "Voxa is transcribing"
        case .delivering: return "Delivering transcript"
        case .failed: return "Voxa needs attention"
        }
    }

    private enum PrimaryAction { case addAPIKey, setup, start, stop, retry, working }
    private var primaryActionKind: PrimaryAction {
        if controller.isSettingUp || controller.isSavingKey { return .working }
        if !controller.isReady { return .setup }
        switch session.state {
        case .starting(_, nil), .recording: return .stop
        case .starting, .finishing, .transcribing, .delivering: return .working
        case .idle, .restoringClipboard: return controller.isAPIKeySet ? .start : .addAPIKey
        case .failed: return controller.isAPIKeySet ? .retry : .addAPIKey
        }
    }
    private var primaryActionTitle: String {
        switch primaryActionKind {
        case .addAPIKey: return "Add API Key…"
        case .setup: return "Check Setup"
        case .start: return "Start Recording"
        case .stop: return "Stop Recording"
        case .retry: return "Try Again"
        case .working: return "Working…"
        }
    }
    private var primaryActionSymbol: String {
        switch primaryActionKind {
        case .addAPIKey: return "key.fill"
        case .setup, .retry: return "arrow.clockwise"
        case .start: return "mic.fill"
        case .stop: return "stop.fill"
        case .working: return "hourglass"
        }
    }
    private var primaryActionDisabled: Bool { primaryActionKind == .working }
    private var primaryActionAccessibilityHint: String {
        switch primaryActionKind {
        case .addAPIKey: return "Opens the secure API key editor"
        case .setup: return "Reloads settings and checks access"
        case .start, .retry: return "Starts a new dictation"
        case .stop: return "Stops recording and begins transcription"
        case .working: return "Voxa is processing the current operation"
        }
    }

    private func performPrimaryAction() {
        switch primaryActionKind {
        case .addAPIKey: showSettings()
        case .setup: controller.retrySetup()
        case .stop: session.stop()
        case .start, .retry: controller.startRecording()
        case .working: break
        }
    }

    private var maxRecordingOptions: [UInt64] {
        Array(Set([30, 60, 120, 300, 600, 900, 1800, 3600, controller.maxRecordingSeconds])).sorted()
    }

    private func formattedRecordingDuration(_ seconds: UInt64) -> String {
        if seconds < 60 {
            return "\(seconds)s"
        }

        if seconds % 60 == 0 {
            let minutes = seconds / 60
            return minutes == 1 ? "1 min" : "\(minutes) min"
        }

        return "\(seconds)s"
    }
}

@MainActor
struct VoxaSettingsView: View {
    @ObservedObject var controller: AppController
    @StateObject private var hotkeyRecorder = HotkeyRecorder()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Hotkeys") {
                    hotkeyRow("Toggle Recording", current: controller.toggleHotkey, target: .toggle)
                    hotkeyRow("Hold to Record", current: controller.holdHotkey, target: .hold)
                    if hotkeyRecorder.target != nil {
                        Text("Hold the full combination, then release it to save. Press Esc to cancel.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(controller.isBusy || !controller.isReady)

                Section("English Learning") {
                    LabeledContent("Save lessons", value: FeedbackShortcut.saveLabel)
                        .help("Press S to save all lessons and close the review. Press D to close without saving lessons. Progress is tracked automatically. S and D act on visible feedback instead of typing in the focused app. Requires Accessibility access for global use.")
                    LabeledContent("Close review", value: FeedbackShortcut.discardLabel)
                    Toggle("Feedback after dictation", isOn: Binding(
                        get: { controller.preferences.englishFeedbackEnabled },
                        set: { controller.setEnglishFeedbackEnabled($0) }))
                        .disabled(!controller.canEditDictationSettings)
                    Text("Get English corrections and clearer, more natural ways to express your ideas without changing your inserted text. Enabling applies to your next recording; disabling stops pending feedback.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Sends transcript text to OpenAI using your API key, with additional API usage. Saved lessons keep their excerpts. Progress automatically keeps score bands and pattern counts for up to 200 reviews, without dictated text. Manage both in Lessons & Progress. Practice answers stay in memory.")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("OpenAI data retention details", destination: URL(string: "https://developers.openai.com/api/docs/guides/your-data")!)
                        .font(.caption)
                }

                Section("OpenAI API Key") {
                    LabeledContent("API key") {
                        if controller.isAPIKeySet {
                            Text("••••••••")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(.primary)
                                .accessibilityLabel("API key configured")
                        } else {
                            Text("Not configured")
                        }
                    }
                    LabeledContent("Storage", value: controller.apiKeySource.replacingOccurrences(of: "_", with: " ").capitalized)
                    SecureField(controller.isAPIKeySet ? "Replace API key" : "API key", text: $controller.apiKeyInput)
                        .disabled(controller.isBusy)
                        .accessibilityLabel("OpenAI API key")
                        .accessibilityHint(controller.isAPIKeySet ? "A key is saved. Enter a new key to replace it." : "Enter your API key.")
                    if let error = controller.apiKeyError, !error.isEmpty {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button(controller.isSavingKey ? "Saving…" : (controller.isAPIKeySet ? "Replace Key" : "Save Key")) {
                        controller.saveAPIKey()
                    }
                        .disabled(controller.isBusy || controller.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let error = controller.errorMessage, !error.isEmpty {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Try Again") { controller.retrySetup() }
                            .disabled(controller.isBusy)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding([.horizontal, .bottom])
        }
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onExitCommand {
            if hotkeyRecorder.target != nil {
                hotkeyRecorder.stop()
            } else {
                dismiss()
            }
        }
        .onAppear { configureHotkeyRecorder() }
        .onDisappear {
            hotkeyRecorder.stop()
            controller.apiKeyInput = ""
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            hotkeyRecorder.stop()
        }
    }

    private func hotkeyRow(_ title: String, current: HotkeyOption, target: HotkeyRecordingTarget) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(hotkeyRecorder.target == target ? (hotkeyRecorder.preview?.label ?? "Press a shortcut") : current.label)
                .foregroundStyle(.secondary)
            if hotkeyRecorder.target == target {
                Button("Cancel") { hotkeyRecorder.stop() }
                    .accessibilityLabel("Cancel recording \(title.lowercased()) shortcut")
            } else {
                Button("Record…") { hotkeyRecorder.start(target: target, current: current) }
                    .accessibilityLabel("Record \(title.lowercased()) shortcut")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func configureHotkeyRecorder() {
        hotkeyRecorder.onCommit = { target, hotkey in
            switch target {
            case .toggle: controller.setToggleHotkey(hotkey)
            case .hold: controller.setHoldHotkey(hotkey)
            }
        }
        hotkeyRecorder.onCaptureStateChanged = { controller.setHotkeyCaptureEnabled($0) }
    }
}

private enum HotkeyRecordingTarget: Equatable {
    case toggle
    case hold
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
