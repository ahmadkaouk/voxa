import AppKit
import SwiftUI
import UniformTypeIdentifiers

private typealias SettingsViewState<Value> = SwiftUI.State<Value>

struct SettingsControlLabel: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13, weight: .medium))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
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
            Text(shortcut).font(.system(size: 12, weight: .medium, design: .monospaced))
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                .fixedSize()
            Button(recording ? "Cancel" : "Change…", action: recording ? onCancel : onRecord)
                .accessibilityLabel(recording ? "Cancel changing \(title) shortcut" : "Change \(title) shortcut")
        }.padding(.vertical, 3).accessibilityElement(children: .contain)
    }
}

/// One coherent settings group: coaching, its optional context, then secondary details.
struct EnglishLearningSettingsView: View {
    @Binding var feedbackEnabled: Bool
    @Binding var contextEnabled: Bool
    let excludedApps: [ContextExcludedApp]
    let hasAccessibility: Bool
    var canEdit = true
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
                Text("Feedback appears for five seconds. Hover to keep reading, or pin it to keep it open.")
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
                LabeledContent("Save feedback", value: "⌘S")
                LabeledContent("Close feedback", value: "Esc")
            }

            Section("Data & privacy") {
                detail("Sent to your feedback service", "Your dictation and optional nearby text. No screenshots. Feedback uses additional API requests.")
                detail("Stored on this Mac", "Saved lessons, level estimates, pattern counts and review dates. Full dictations, captured context, practice answers and audio aren’t saved.")
                detail("Your level", "Estimated from your own dictation. Nearby text and practice answers don’t affect it.")
                Link("OpenAI data retention details", destination: URL(string: "https://developers.openai.com/api/docs/guides/your-data")!)
            }
        }
        .formStyle(.grouped)
        .toggleStyle(.switch)
        .sheet(isPresented: $showExcludedApps) { exclusions }
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
