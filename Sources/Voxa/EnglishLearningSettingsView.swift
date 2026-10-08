import AppKit
import SwiftUI
import UniformTypeIdentifiers

private typealias SettingsViewState<Value> = SwiftUI.State<Value>

struct SettingsControlLabel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.body).foregroundStyle(.primary)
            Text(detail).font(.callout).foregroundStyle(.secondary)
                .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
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
            SettingsControlLabel(title: title, detail: detail)
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

/// One coherent settings group: coaching, its optional context, then secondary details.
struct EnglishLearningSettingsView: View {
    @Binding var feedbackEnabled: Bool
    @Binding var contextEnabled: Bool
    let excludedApps: [ContextExcludedApp]
    let hasAccessibility: Bool
    var saveShortcut = HotkeyOption.defaultSaveFeedback.symbolLabel
    var cancelShortcut = HotkeyOption.defaultCancel.symbolLabel
    var canEdit = true
    var recordingShortcut: HotkeyRecordingTarget?
    var shortcutPreview: String?
    var onEditShortcut: ((HotkeyRecordingTarget) -> Void)?
    var onExclude: (ContextExcludedApp) -> Void
    var onAllow: (String) -> Void
    var onOpenLessons: () -> Void
    @SettingsViewState private var showExcludedApps = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $feedbackEnabled) {
                    SettingsControlLabel(title: "Feedback after dictation",
                        detail: "Corrections, natural phrasing and short practice.")
                }.disabled(!canEdit)
                    .accessibilityLabel("Feedback after dictation")
                    .accessibilityHint("Corrections, natural phrasing and short practice.")
            } header: { Text("Feedback") } footer: {
                Text("Feedback stays open until you close it, save it, or start a new recording.")
            }

            Section {
                Toggle(isOn: $contextEnabled) {
                    SettingsControlLabel(title: "Use nearby text automatically",
                        detail: "Help feedback fit what you’re working on.")
                }.disabled(!canEdit || !feedbackEnabled)
                    .accessibilityLabel("Use nearby text automatically")
                    .accessibilityHint("Help feedback fit what you’re working on.")
                HStack {
                    LabeledContent("Excluded apps", value: excludedApps.isEmpty ? "None" : "\(excludedApps.count)")
                    Button("Manage…") { showExcludedApps = true }.disabled(!canEdit)
                        .accessibilityLabel("Manage excluded apps")
                }
                if feedbackEnabled && contextEnabled && !hasAccessibility {
                    HStack {
                        Label("Needs Accessibility access", systemImage: "info.circle")
                        Spacer()
                        Button("Open Settings…") { Permissions.openSettings("Accessibility") }
                    }.font(.callout)
                }
            } header: { Text("Context") } footer: {
                Text("Only a short text excerpt is sent. Password fields and excluded apps are skipped. Dictation continues when context is unavailable.")
            }

            Section("Your learning") {
                HStack {
                    SettingsControlLabel(title: "Lessons, practice and progress",
                        detail: "Revisit the patterns you’ve saved.")
                    Spacer()
                    Button("Open English Learning", action: onOpenLessons)
                }
                shortcut("Save feedback", detail: "Save the visible corrections and close feedback.",
                         value: saveShortcut, target: .saveFeedback)
                shortcut("Cancel / Close", detail: "Discard dictation or close feedback.",
                         value: cancelShortcut, target: .cancel)
            }
            if let recordingShortcut {
                Text(recordingShortcut == .cancel
                     ? "Release the keys to save. Click the shortcut again to cancel. Escape can be assigned here."
                     : "Release the keys to save. Press Esc or click the shortcut again to cancel.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Section("Data & privacy") {
                detail("Sent to your feedback service", "Your dictation and optional nearby text. No screenshots. Feedback uses additional API requests.")
                detail("Stored on this Mac", "Saved lessons, level estimates, pattern counts and review dates. Full dictations, captured context, practice answers and audio aren’t saved.")
                detail("Your level", "Estimated from your own dictation. Nearby text and practice answers don’t affect it.")
                Link("OpenAI data retention details", destination: URL(string: "https://developers.openai.com/api/docs/guides/your-data")!)
            }
        }
        .voxaSettingsFormStyle()
        .toggleStyle(.switch)
        .sheet(isPresented: $showExcludedApps) { exclusions }
    }

    private func shortcut(_ title: String, detail: String, value: String, target: HotkeyRecordingTarget) -> some View {
        SettingsShortcutRow(title: title, detail: detail,
            shortcut: recordingShortcut == target ? (shortcutPreview ?? "Type shortcut") : value,
            recording: recordingShortcut == target,
            onRecord: { onEditShortcut?(target) }, onCancel: { onEditShortcut?(target) })
            .disabled(!canEdit || onEditShortcut == nil)
    }

    private func detail(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).fontWeight(.medium)
            Text(text).foregroundStyle(.secondary).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var exclusions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Excluded apps").font(.system(size: 17, weight: .semibold))
            Text("VOXA won’t read context from these apps.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if excludedApps.isEmpty {
                Text("No apps excluded").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(excludedApps) { app in
                    HStack {
                        Text(app.name).lineLimit(1)
                        Spacer()
                        Button { onAllow(app.bundleID) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).accessibilityLabel("Allow context from \(app.name)")
                    }
                }
            }
            HStack {
                Button("Add App…", action: chooseApp)
                Spacer()
                Button("Done") { showExcludedApps = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 360, height: 300)
    }

    @MainActor private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "Exclude an app from automatic context"
        panel.prompt = "Exclude"
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.begin { response in
            guard response == .OK else { return }
            for url in panel.urls {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
                let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                onExclude(.init(bundleID: id, name: name))
            }
        }
    }
}
