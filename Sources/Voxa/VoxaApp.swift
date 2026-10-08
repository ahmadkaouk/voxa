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

        Window("Settings", id: "settings") {
            VoxaSettingsView(controller: appDelegate.controller)
        }
        .defaultSize(width: 820, height: 620)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)

        Window("English Learning", id: "english-lessons") {
            VoxaLearningView(controller: appDelegate.controller)
        }
        .defaultSize(width: 1060, height: 680)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
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
                .help("Corrections, natural phrasing and practice after dictation. Feedback stays open until you close it, save it, or record again. Uses additional API requests.")
            Toggle("Use Nearby Text Automatically", isOn: Binding(
                get: { controller.preferences.automaticContextEnabled },
                set: { controller.setAutomaticContextEnabled($0) }))
                .disabled(!controller.canEditDictationSettings || !controller.preferences.englishFeedbackEnabled)
                .help("Sends a short text excerpt from the active app to your feedback service. No screenshots; excerpts aren’t saved locally. Manage excluded apps in Settings → Privacy.")
            if controller.feedback.isAnalyzing { Text("Reviewing your English…") }
            if let status = controller.feedback.status { Text(status) }
            Button("Show Latest Feedback") { controller.feedback.showLatest() }
                .disabled(!controller.feedback.hasReview || session.state.context != nil || controller.practice.isPresented)
            Button("One-minute Review…") { controller.startShortReview() }
                .disabled(!controller.canOpenPractice || !controller.practice.history.ready || controller.practice.history.isSaving || controller.practice.history.error != nil)
            if let error = controller.practice.history.error {
                Text(error)
                Button("Retry Review History") { controller.practice.history.retry() }.disabled(controller.practice.history.isSaving)
            }
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
            Label("Settings…", systemImage: "gearshape")
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
        if controller.practice.isPresented || controller.practice.isBusy { return "Voxa is practising English" }
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

    private enum PrimaryAction { case addAPIKey, setup, start, stop, retry, working, practice }
    private var primaryActionKind: PrimaryAction {
        if controller.isSettingUp || controller.isSavingKey { return .working }
        if !controller.isReady { return .setup }
        if controller.practice.isPresented { return .practice }
        if controller.practice.isBusy { return .working }
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
        case .practice: return "Return to Practice…"
        }
    }
    private var primaryActionSymbol: String {
        switch primaryActionKind {
        case .addAPIKey: return "key.fill"
        case .setup, .retry: return "arrow.clockwise"
        case .start: return "mic.fill"
        case .stop: return "stop.fill"
        case .working: return "hourglass"
        case .practice: return "text.bubble"
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
        case .practice: return "Opens your practice window; close it to resume dictation"
        }
    }

    private func performPrimaryAction() {
        switch primaryActionKind {
        case .addAPIKey: showSettings()
        case .setup: controller.retrySetup()
        case .stop: session.stop()
        case .start, .retry: controller.startRecording()
        case .working: break
        case .practice: controller.showPractice()
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
