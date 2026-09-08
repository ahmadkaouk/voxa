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
            VoxaPopoverView(controller: appDelegate.controller)
        } label: {
            MenuBarLabel(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
private struct MenuBarLabel: View {
    @ObservedObject var controller: AppController
    var body: some View { Label("Voxa", systemImage: controller.menuBarSymbol) }
}

@MainActor
struct VoxaPopoverView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var session: DictationSession

    init(controller: AppController) {
        self.controller = controller
        self.session = controller.session
    }
    @State private var expandedMenu: ExpandedMenu?
    @State private var showsAPIKeyEditor = false
    @StateObject private var hotkeyRecorder = HotkeyRecorder()

    enum ExpandedMenu: Hashable {
        case model
        case output
        case maxRecording
        case toggle
        case hold
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusSection

            if let lastError = controller.errorMessage, !lastError.isEmpty {
                Divider()
                sectionGroup {
                    statusMessageRow(
                        title: "Last error",
                        value: lastError,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                }
                Divider()
            }

            generalSection
            Divider()
            hotkeysSection
            Divider()
            accountSection
            Divider()
            footerActions
        }
        .padding(.vertical, 7)
        .frame(width: 324)
        .animation(.easeInOut(duration: 0.14), value: expandedMenu)
        .onChange(of: controller.apiKeySaveCount) { _ in
            showsAPIKeyEditor = false
        }
        .onChange(of: expandedMenu) { newValue in
            if hotkeyRecorder.target?.menu != newValue {
                hotkeyRecorder.stop()
            }
        }
        .onAppear {
            configureHotkeyRecorder()
        }
        .onDisappear {
            hotkeyRecorder.stop()
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(statusTint.opacity(0.14))
                        .frame(width: 30, height: 30)

                    Circle()
                        .fill(statusTint)
                        .frame(width: 9, height: 9)
                }
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(statusMenuTitle)
                        .font(.system(size: 14, weight: .semibold))

                    Text(statusSubtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)
            }

            Button(action: performPrimaryAction) {
                HStack(spacing: 8) {
                    Image(systemName: primaryActionSymbol)
                        .font(.system(size: 13, weight: .semibold))
                    Text(primaryActionTitle)
                        .font(.system(size: 13, weight: .semibold))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(primaryActionTint)
            .disabled(primaryActionDisabled)
            .accessibilityHint(primaryActionAccessibilityHint)
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 0.7)
        )
        .padding(.horizontal, 10)
        .padding(.bottom, 7)
        .accessibilityElement(children: .contain)
    }

    private var generalSection: some View {
        sectionGroup("General") {
            expandableRow(
                .model,
                title: "Model",
                systemImage: "waveform",
                value: controller.model.label
            ) {
                ForEach(ModelOption.allCases) { model in
                    optionButton(
                        title: model.label,
                        isSelected: controller.model == model
                    ) {
                        controller.setModel(model)
                    }
                }
            }

            expandableRow(
                .output,
                title: "Output",
                systemImage: "square.and.arrow.up",
                value: controller.outputMode.label
            ) {
                ForEach(OutputModeOption.allCases) { mode in
                    optionButton(
                        title: mode.label,
                        isSelected: controller.outputMode == mode
                    ) {
                        controller.setOutputMode(mode)
                    }
                }
                Divider()
                Button("Copy Last Transcript") {
                    controller.copyLastTranscript()
                }
                .disabled(session.lastTranscript == nil)
            }

            expandableRow(
                .maxRecording,
                title: "Max Recording",
                systemImage: "timer",
                value: formattedRecordingDuration(controller.maxRecordingSeconds)
            ) {
                ForEach(maxRecordingOptions, id: \.self) { seconds in
                    optionButton(
                        title: formattedRecordingDuration(seconds),
                        isSelected: controller.maxRecordingSeconds == seconds
                    ) {
                        controller.setMaxRecordingSeconds(seconds)
                    }
                }
            }
        }
        .disabled(controller.isBusy || !controller.isReady)
    }

    private var hotkeysSection: some View {
        sectionGroup("Hotkeys") {
            hotkeyEditor(
                .toggle,
                title: "Toggle",
                systemImage: "switch.2",
                current: controller.toggleHotkey,
                target: .toggle
            )

            hotkeyEditor(
                .hold,
                title: "Hold",
                systemImage: "hand.raised",
                current: controller.holdHotkey,
                target: .hold
            )
        }
        .disabled(controller.isBusy || !controller.isReady)
    }

    private var accountSection: some View {
        sectionGroup("OpenAI") {
            apiKeyStatusRow

            menuActionRow(
                controller.isAPIKeySet ? "Update API Key…" : "Add API Key…",
                systemImage: "key"
            ) {
                showsAPIKeyEditor.toggle()
            }

            if showsAPIKeyEditor {
                apiKeyEditor
            }
        }
    }

    private var footerActions: some View {
        sectionGroup {
            if controller.permissions.microphone == .denied || controller.permissions.microphone == .restricted {
                menuActionRow("Enable Microphone…", systemImage: "mic.fill") {
                    Permissions.openSettings("Microphone")
                }
            }
            if !controller.permissions.accessibility {
                menuActionRow("Enable Accessibility…", systemImage: "hand.raised.fill") {
                    Permissions.openSettings("Accessibility")
                }
            }
            if !controller.permissions.inputMonitoring {
                menuActionRow("Enable Input Monitoring…", systemImage: "keyboard") {
                    Permissions.openSettings("ListenEvent")
                }
            }
            menuActionRow("Retry Setup", systemImage: "arrow.clockwise") { controller.retrySetup() }
                .disabled(controller.isBusy)
            menuActionRow("Quit", systemImage: "power") { controller.quit() }
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

    private var statusTint: Color {
        if controller.errorMessage != nil { return Color(nsColor: .systemRed) }
        if controller.isSettingUp { return Color(nsColor: .systemOrange) }
        return session.state.isBusy ? Color(nsColor: .controlAccentColor) : Color(nsColor: .systemGreen)
    }

    private var statusSubtitle: String {
        if let error = controller.setupError { return error }
        if controller.isSettingUp { return "Loading settings and checking access…" }
        switch session.state {
        case .idle, .restoringClipboard:
            if !controller.isAPIKeySet { return "Add an API key to start transcribing" }
            if controller.permissions.microphone == .denied { return "Enable Microphone access in System Settings" }
            if !controller.permissions.accessibility || !controller.permissions.inputMonitoring {
                return "Enable input permissions for hotkeys and autopaste"
            }
            return controller.statusMessage
        case .starting: return "Checking microphone and Keychain access"
        case .recording: return "Listening for your transcript"
        case .finishing: return "Closing the microphone"
        case .transcribing: return "Turning speech into text"
        case .delivering: return "Sending transcript to the selected output"
        case .failed(_, let message): return message
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
        case .addAPIKey: return "Add API Key"
        case .setup: return "Retry Setup"
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
    private var primaryActionTint: Color {
        primaryActionKind == .stop ? Color(nsColor: .systemRed) : Color(nsColor: .controlAccentColor)
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

    private var apiKeyStatusTitle: String { controller.isAPIKeySet ? "Configured" : "Missing" }
    private var apiKeyStatusDetail: String {
        controller.isAPIKeySet ? "Ready to use" : "Add an OpenAI API key to enable transcription"
    }

    private var apiKeySourceLabel: String {
        controller.apiKeySource.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func performPrimaryAction() {
        switch primaryActionKind {
        case .addAPIKey: showsAPIKeyEditor = true
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

    private func toggleExpandedMenu(_ menu: ExpandedMenu) {
        expandedMenu = expandedMenu == menu ? nil : menu
    }

    private func configureHotkeyRecorder() {
        hotkeyRecorder.onCommit = { target, hotkey in
            switch target {
            case .toggle:
                controller.setToggleHotkey(hotkey)
            case .hold:
                controller.setHoldHotkey(hotkey)
            }
        }
        hotkeyRecorder.onCaptureStateChanged = { isRecording in
            controller.setHotkeyCaptureEnabled(isRecording)
        }
    }

    private func sectionGroup<Content: View>(_ title: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 11)
            }

            VStack(alignment: .leading, spacing: 2) {
                content()
            }
            .padding(.vertical, 1)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func expandableRow<Content: View>(
        _ menu: ExpandedMenu,
        title: String,
        systemImage: String,
        value: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                toggleExpandedMenu(menu)
            } label: {
                MenuRowChrome {
                    HStack(alignment: .center, spacing: 8) {
                        Image(systemName: systemImage)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)

                        Text(title)
                            .font(.system(size: 13))

                        Spacer(minLength: 8)

                        Text(value)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                            .rotationEffect(.degrees(expandedMenu == menu ? 90 : 0))
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(
                [value, expandedMenu == menu ? "Expanded" : "Collapsed"]
                    .joined(separator: ", ")
            )
            .accessibilityHint("Shows available \(title.lowercased()) options")

            if expandedMenu == menu {
                VStack(alignment: .leading, spacing: 0) {
                    content()
                }
                .padding(.leading, 16)
                .padding(.trailing, 5)
                .padding(.bottom, 3)
            }
        }
    }

    @ViewBuilder
    private func hotkeyEditor(
        _ menu: ExpandedMenu,
        title: String,
        systemImage: String,
        current: HotkeyOption,
        target: HotkeyRecordingTarget
    ) -> some View {
        expandableRow(menu, title: title, systemImage: systemImage, value: current.label) {
            menuValueRow("Current", value: current.label, systemImage: "keyboard")

            if hotkeyRecorder.target == target {
                menuInfoRow(hotkeyRecorder.preview?.label ?? "Press a shortcut")
                menuInfoRow("Hold the full combination, then release it to save. Press Esc to cancel.")

                menuActionRow("Cancel Recording", systemImage: "xmark") {
                    hotkeyRecorder.stop()
                }
            } else {
                menuActionRow("Record Shortcut…", systemImage: "keyboard") {
                    hotkeyRecorder.start(target: target, current: current)
                }
            }
        }
    }

    @ViewBuilder
    private func menuValueRow(
        _ title: String,
        value: String,
        systemImage: String
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            Text(title)
                .font(.system(size: 13))

            Spacer(minLength: 8)

            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private func menuInfoRow(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 15)
            .padding(.vertical, 6)
    }

    private var apiKeyStatusRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: controller.isAPIKeySet ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(
                    controller.isAPIKeySet
                        ? Color(nsColor: .systemGreen)
                        : Color(nsColor: .systemOrange)
                )
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(apiKeyStatusTitle)
                    .font(.system(size: 13, weight: .medium))

                Text(apiKeyStatusDetail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            Text(apiKeySourceLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 6)
    }

    private var apiKeyEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("OPENAI_API_KEY", text: $controller.apiKeyInput)
                .textFieldStyle(.roundedBorder)
                .disabled(controller.isBusy)
                .accessibilityLabel("OpenAI API key")
                .accessibilityHint("Enter the API key used for transcription")

            if let apiKeyError = controller.apiKeyError, !apiKeyError.isEmpty {
                Text(apiKeyError)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("Save Key") {
                    controller.saveAPIKey()
                }
                .disabled(controller.isBusy || controller.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Cancel") {
                    showsAPIKeyEditor = false
                    controller.apiKeyInput = ""
                }
                .disabled(controller.isBusy)

                Spacer()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 7)
    }

    private func menuActionRow(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            MenuRowChrome {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 14)

                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)

                    Spacer(minLength: 12)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func optionButton(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            expandedMenu = nil
        } label: {
            MenuRowChrome {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 12.5))

                    Spacer(minLength: 8)

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func statusMessageRow(title: String, value: String, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(title, systemImage: systemImage)
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            Text(value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
    }
}

private enum HotkeyRecordingTarget: Equatable {
    case toggle
    case hold

    var menu: VoxaPopoverView.ExpandedMenu {
        switch self {
        case .toggle:
            return .toggle
        case .hold:
            return .hold
        }
    }
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
            self?.handle(event) ?? event
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

private struct MenuRowChrome<Content: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    let content: () -> Content
    @State private var isHovered = false

    var body: some View {
        let isHighlighted = isEnabled && isHovered

        content()
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHighlighted ? hoverColor : .clear)
            )
            .padding(.horizontal, 5)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovering in
                isHovered = hovering
            }
    }

    private var hoverColor: Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.08)
        }

        return Color.black.opacity(0.05)
    }
}
