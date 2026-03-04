import AppKit
import SwiftUI

@main
struct VoicoMenuBarApp: App {
    @StateObject private var controller = AppController()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra("Voico", systemImage: controller.menuBarSymbol) {
            VoicoPopoverView(controller: controller)
        }
        .menuBarExtraStyle(.window)
    }
}

struct VoicoPopoverView: View {
    @ObservedObject var controller: AppController
    @State private var expandedMenu: ExpandedMenu?
    @State private var showsAPIKeyEditor = false

    private enum ExpandedMenu: Hashable {
        case model
        case output
        case maxRecording
        case toggle
        case hold
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusSection
            Divider()

            if let lastError = controller.lastErrorCode, !lastError.isEmpty {
                sectionGroup {
                    statusMessageRow(
                        title: "Last error",
                        value: humanizeErrorCode(lastError),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                }
                Divider()
            }

            actionSection
            Divider()
            generalSection
            Divider()
            hotkeysSection
            Divider()
            accountSection
            Divider()
            footerActions
        }
        .padding(.vertical, 4)
        .frame(width: 278)
        .animation(.easeInOut(duration: 0.14), value: expandedMenu)
        .onChange(of: controller.apiKeySaveCount) { _ in
            showsAPIKeyEditor = false
        }
    }

    private var statusSection: some View {
        sectionGroup {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusTint)
                    .frame(width: 7, height: 7)

                Text(statusMenuTitle)
                    .font(.system(size: 13, weight: .medium))

                Spacer()
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 4)

            Text(statusSubtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .padding(.horizontal, 26)
                .padding(.top, 1)
                .padding(.bottom, 2)
        }
    }

    private var actionSection: some View {
        sectionGroup {
            menuActionRow(
                primaryActionTitle,
                systemImage: primaryActionSymbol,
                tint: primaryActionTint
            ) {
                performPrimaryAction()
            }
            .disabled(primaryActionDisabled)
        }
    }

    private var generalSection: some View {
        sectionGroup("General") {
            expandableRow(.model, title: "Model", systemImage: "waveform") {
                ForEach(ModelOption.allCases) { model in
                    optionButton(
                        title: model.label,
                        isSelected: controller.model == model
                    ) {
                        controller.setModel(model)
                    }
                }
            }

            expandableRow(.output, title: "Output", systemImage: "square.and.arrow.up") {
                ForEach(OutputModeOption.allCases) { mode in
                    optionButton(
                        title: mode.label,
                        isSelected: controller.outputMode == mode
                    ) {
                        controller.setOutputMode(mode)
                    }
                }
            }

            expandableRow(.maxRecording, title: "Max Recording", systemImage: "timer") {
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
        .disabled(controller.isBusy)
    }

    private var hotkeysSection: some View {
        sectionGroup("Hotkeys") {
            expandableRow(.toggle, title: "Toggle", systemImage: "switch.2") {
                ForEach(HotkeyOption.allCases) { hotkey in
                    optionButton(
                        title: hotkey.label,
                        isSelected: controller.toggleHotkey == hotkey
                    ) {
                        controller.setToggleHotkey(hotkey)
                    }
                }
            }

            expandableRow(.hold, title: "Hold", systemImage: "hand.raised") {
                ForEach(HotkeyOption.allCases) { hotkey in
                    optionButton(
                        title: hotkey.label,
                        isSelected: controller.holdHotkey == hotkey
                    ) {
                        controller.setHoldHotkey(hotkey)
                    }
                }
            }
        }
        .disabled(controller.isBusy)
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

            if showsAPIKeyEditor || !controller.isAPIKeySet {
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
            return "Voico needs attention"
        case .connecting:
            return "Voico is starting"
        case .connected:
            switch controller.runtimeState {
            case .idle:
                return "Voico is ready"
            case .recording:
                return "Voico is recording"
            case .transcribing:
                return "Voico is transcribing"
            case .outputting:
                return "Voico is outputting"
            case .error:
                return "Voico has an error"
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
        switch controller.runtimeState {
        case .recording:
            return "Stop Recording"
        case .error:
            return "Try Again"
        case .transcribing, .outputting:
            return "Working…"
        case .idle:
            return "Start Recording"
        }
    }

    private var primaryActionSymbol: String {
        switch controller.runtimeState {
        case .recording:
            return "stop.fill"
        case .error:
            return "arrow.clockwise"
        case .transcribing, .outputting:
            return "hourglass"
        case .idle:
            return "mic.fill"
        }
    }

    private var primaryActionTint: Color {
        switch controller.runtimeState {
        case .recording:
            return Color(nsColor: .systemRed)
        case .error:
            return Color(nsColor: .systemOrange)
        default:
            return Color(nsColor: .secondaryLabelColor)
        }
    }

    private var primaryActionDisabled: Bool {
        controller.isBusy
            || !controller.connectionStatus.isConnected
            || controller.runtimeState == .transcribing
            || controller.runtimeState == .outputting
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
        if controller.runtimeState == .recording {
            controller.stopRecording()
        } else {
            controller.startRecording()
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

                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                            .rotationEffect(.degrees(expandedMenu == menu ? 90 : 0))
                    }
                }
            }
            .buttonStyle(.plain)

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

            HStack(spacing: 8) {
                Button("Save Key") {
                    controller.saveAPIKey()
                }
                .disabled(controller.isBusy || controller.apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if controller.isAPIKeySet {
                    Button("Cancel") {
                        showsAPIKeyEditor = false
                        controller.apiKeyInput = ""
                    }
                    .disabled(controller.isBusy)
                }

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

enum ActivityOverlayPhase: Equatable {
    case recording
}

struct ActivityOverlayView: View {
    let phase: ActivityOverlayPhase
    let onDismiss: () -> Void
    let onStop: () -> Void

    var body: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 0.05)) { timeline in
                waveform(time: timeline.date.timeIntervalSinceReferenceDate)
            }

            HStack(spacing: 0) {
                leadingControl
                Spacer(minLength: 0)
                trailingControl
            }
            .padding(.horizontal, 6)
        }
        .frame(width: 96, height: 28)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.96))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.16), radius: 7, y: 3)
    }

    private var leadingControl: some View {
        Button(action: onDismiss) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: 18, height: 18)

                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .black))
                    .foregroundStyle(Color.white.opacity(0.92))
            }
        }
        .buttonStyle(.plain)
    }

    private var trailingControl: some View {
        Button(action: onStop) {
            ZStack {
                Circle()
                    .fill(Color(red: 0.95, green: 0.52, blue: 0.50))
                    .frame(width: 18, height: 18)

                RoundedRectangle(cornerRadius: 2.2, style: .continuous)
                    .fill(Color.white)
                    .frame(width: 8, height: 8)
            }
        }
        .buttonStyle(.plain)
    }

    private func waveform(time: TimeInterval) -> some View {
        HStack(alignment: .center, spacing: 2.2) {
            ForEach(0..<7, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.9))
                    .frame(width: 2, height: barHeight(index: index, time: time))
            }
        }
        .frame(width: 20, height: 10)
    }

    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        let primary = sin((time * 10) + Double(index) * 0.72)
        let secondary = sin((time * 5.1) + Double(index) * 1.05)
        return 2.5 + (abs((primary * 0.7) + (secondary * 0.3)) * 4.2)
    }
}
