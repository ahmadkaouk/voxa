import AppKit
import SwiftUI

@main
struct VoxaMenuBarApp: App {
    @StateObject private var controller = AppController()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra("Voxa", systemImage: controller.menuBarSymbol) {
            VoxaPopoverView(controller: controller)
        }
        .menuBarExtraStyle(.window)
    }
}

enum PopoverPrimaryAction: Equatable {
    case addAPIKey
    case reconnect
    case connecting
    case startRecording
    case stopRecording
    case retry
    case working

    static func resolve(
        isAPIKeySet: Bool,
        connectionStatus: ConnectionStatus,
        runtimeState: RuntimeStateKind
    ) -> PopoverPrimaryAction {
        switch connectionStatus {
        case .connecting:
            return .connecting
        case .disconnected:
            return .reconnect
        case .connected:
            switch runtimeState {
            case .idle:
                return isAPIKeySet ? .startRecording : .addAPIKey
            case .recording:
                return .stopRecording
            case .error:
                return isAPIKeySet ? .retry : .addAPIKey
            case .transcribing, .outputting:
                return .working
            }
        }
    }
}

struct VoxaPopoverView: View {
    @ObservedObject var controller: AppController
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

            if let lastError = controller.lastErrorCode, !lastError.isEmpty {
                Divider()
                sectionGroup {
                    statusMessageRow(
                        title: "Last error",
                        value: humanizeErrorCode(lastError),
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
                .disabled(controller.lastTranscript == nil)
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
        .disabled(controller.isBusy || controller.runtimeState != .idle)
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
        .disabled(controller.isBusy || controller.runtimeState != .idle)
    }

    private var accountSection: some View {
        sectionGroup("OpenAI") {
            apiKeyStatusRow

            menuActionRow(
                controller.isAPIKeySet ? "Update API Key…" : "Add API Key…",
                systemImage: "key",
                tint: .primary
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
            if !controller.hasAccessibilityPermission {
                menuActionRow("Enable Input Permissions…", systemImage: "hand.raised.fill") {
                    controller.requestInputPermissions()
                }
            }

            menuActionRow("Reconnect", systemImage: "arrow.clockwise") {
                controller.reconnectNow()
            }
            .disabled(controller.isBusy)

            menuActionRow("Quit", systemImage: "power") {
                controller.quit()
            }
        }
    }

    private var statusTitle: String {
        switch controller.connectionStatus {
        case .disconnected:
            return "Needs Attention"
        case .connecting:
            return "Starting"
        case .connected:
            switch controller.runtimeState {
            case .idle:
                return "Connected"
            case .recording:
                return "Recording"
            case .transcribing:
                return "Transcribing"
            case .outputting:
                return "Outputting"
            case .error:
                return "Error"
            }
        }
    }

    private var statusMenuTitle: String {
        switch controller.connectionStatus {
        case .disconnected:
            return "Voxa needs attention"
        case .connecting:
            return "Voxa is starting"
        case .connected:
            switch controller.runtimeState {
            case .idle:
                return "Voxa is ready"
            case .recording:
                return "Voxa is recording"
            case .transcribing:
                return "Voxa is transcribing"
            case .outputting:
                return "Voxa is outputting"
            case .error:
                return "Voxa has an error"
            }
        }
    }

    private var statusTint: Color {
        switch controller.connectionStatus {
        case .disconnected:
            return Color(nsColor: .systemRed)
        case .connecting:
            return Color(nsColor: .systemOrange)
        case .connected:
            switch controller.runtimeState {
            case .idle:
                return Color(nsColor: .systemGreen)
            case .recording, .transcribing:
                return Color(nsColor: .controlAccentColor)
            case .outputting:
                return Color(nsColor: .systemBlue)
            case .error:
                return Color(nsColor: .systemRed)
            }
        }
    }

    private var statusSubtitle: String {
        switch controller.connectionStatus {
        case .disconnected:
            return controller.statusMessage
        case .connecting:
            return controller.statusMessage
        case .connected:
            switch controller.runtimeState {
            case .idle:
                if !controller.hasAccessibilityPermission {
                    return "Enable input permissions for hotkeys and autopaste"
                }
                return controller.isAPIKeySet ? "Ready when you are" : "Add an API key to start transcribing"
            case .recording:
                return "Listening for your transcript"
            case .transcribing:
                return "Turning speech into text"
            case .outputting:
                return "Sending transcript to the selected output"
            case .error:
                return controller.statusMessage
            }
        }
    }

    private var primaryActionTitle: String {
        switch primaryActionKind {
        case .addAPIKey:
            return "Add API Key"
        case .reconnect:
            return "Reconnect to Voxa"
        case .connecting:
            return "Starting…"
        case .startRecording:
            return "Start Recording"
        case .stopRecording:
            return "Stop Recording"
        case .retry:
            return "Try Again"
        case .working:
            return "Working…"
        }
    }

    private var primaryActionSymbol: String {
        switch primaryActionKind {
        case .addAPIKey:
            return "key.fill"
        case .reconnect, .retry:
            return "arrow.clockwise"
        case .connecting:
            return "bolt.horizontal.circle"
        case .startRecording:
            return "mic.fill"
        case .stopRecording:
            return "stop.fill"
        case .working:
            return "hourglass"
        }
    }

    private var primaryActionTint: Color {
        switch primaryActionKind {
        case .stopRecording:
            return Color(nsColor: .systemRed)
        case .reconnect, .retry:
            return Color(nsColor: .systemOrange)
        case .connecting, .working:
            return Color(nsColor: .systemGray)
        case .addAPIKey, .startRecording:
            return Color(nsColor: .controlAccentColor)
        }
    }

    private var primaryActionDisabled: Bool {
        controller.isBusy || primaryActionKind == .connecting || primaryActionKind == .working
    }

    private var primaryActionAccessibilityHint: String {
        switch primaryActionKind {
        case .addAPIKey:
            return "Opens the secure API key editor"
        case .reconnect:
            return "Attempts to reconnect to the local Voxa service"
        case .connecting:
            return "Voxa is connecting to its local service"
        case .startRecording, .retry:
            return "Starts a new dictation"
        case .stopRecording:
            return "Stops recording and begins transcription"
        case .working:
            return "Voxa is processing the current dictation"
        }
    }

    private var primaryActionKind: PopoverPrimaryAction {
        PopoverPrimaryAction.resolve(
            isAPIKeySet: controller.isAPIKeySet,
            connectionStatus: controller.connectionStatus,
            runtimeState: controller.runtimeState
        )
    }

    private var apiKeyStatusText: String {
        guard controller.isAPIKeySet else {
            return "Not set"
        }

        if let hint = controller.apiKeyHint, !hint.isEmpty {
            return "\(hint) · \(controller.apiKeySource)"
        }

        return "Set · \(controller.apiKeySource)"
    }

    private var apiKeyStatusTitle: String {
        controller.isAPIKeySet ? "Configured" : "Missing"
    }

    private var apiKeyStatusDetail: String {
        guard controller.isAPIKeySet else {
            return "Add an OpenAI API key to enable transcription"
        }

        if let hint = controller.apiKeyHint, !hint.isEmpty {
            return "Using \(hint)"
        }

        return "Stored and ready to use"
    }

    private var apiKeySourceLabel: String {
        controller.apiKeySource.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func performPrimaryAction() {
        switch primaryActionKind {
        case .addAPIKey:
            showsAPIKeyEditor = true
        case .reconnect:
            controller.reconnectNow()
        case .stopRecording:
            controller.stopRecording()
        case .startRecording, .retry:
            controller.startRecording()
        case .connecting, .working:
            break
        }
    }

    private func humanizeErrorCode(_ code: String) -> String {
        code
            .split(separator: "_")
            .map { segment in
                segment.prefix(1).uppercased() + segment.dropFirst().lowercased()
            }
            .joined(separator: " ")
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
        systemImage: String? = nil,
        value: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                toggleExpandedMenu(menu)
            } label: {
                MenuRowChrome { _ in
                    HStack(alignment: .center, spacing: 8) {
                        if let systemImage {
                            Image(systemName: systemImage)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 14)
                        }

                        Text(title)
                            .font(.system(size: 13))

                        Spacer(minLength: 8)

                        if let value {
                            Text(value)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

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
                    .compactMap { $0 }
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
        systemImage: String? = nil,
        tint: Color = .secondary,
        monospaced: Bool = false
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 14)
            }

            Text(title)
                .font(.system(size: 13))

            Spacer(minLength: 8)

            Text(value)
                .font(monospaced ? .caption.monospaced() : .system(size: 12))
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
        systemImage: String? = nil,
        tint: Color = .primary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            MenuRowChrome { _ in
                HStack(alignment: .center, spacing: 8) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(tint)
                            .frame(width: 14)
                    }

                    Text(title)
                        .font(.system(size: 13))
                        .foregroundStyle(tint)

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
            MenuRowChrome { _ in
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

        let hotkey = HotkeyOption.recorded(
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

    let content: (Bool) -> Content
    @State private var isHovered = false

    var body: some View {
        let isHighlighted = isEnabled && isHovered

        content(isHighlighted)
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
