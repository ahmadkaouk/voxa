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
    @SettingsViewState private var showPrivacy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle(isOn: $feedbackEnabled) {
                SettingsControlLabel(title: "Feedback after dictation",
                    detail: "Corrections, natural phrasing and short practice.")
            }.disabled(!canEdit)

            VStack(alignment: .leading, spacing: 10) {
                Toggle(isOn: $contextEnabled) {
                    SettingsControlLabel(title: "Use nearby text automatically",
                        detail: "Helps feedback fit what you’re working on. Text only.")
                }.disabled(!canEdit || !feedbackEnabled)
                HStack {
                    Text(excludedApps.isEmpty ? "Available apps" : "\(excludedApps.count) excluded \(excludedApps.count == 1 ? "app" : "apps")")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Manage exclusions…") { showExcludedApps = true }
                        .buttonStyle(.link).font(.system(size: 12)).disabled(!canEdit)
                }
                if feedbackEnabled && contextEnabled && !hasAccessibility {
                    HStack(alignment: .top) {
                        Label("Needs Accessibility access", systemImage: "info.circle").font(.system(size: 12))
                        Spacer()
                        Button("Open Settings…") { Permissions.openSettings("Accessibility") }
                    }
                }
            }
            .padding(.leading, 16)
            .overlay(alignment: .leading) { Rectangle().fill(.primary.opacity(0.1)).frame(width: 2) }

            Text("Feedback and optional context are sent to your feedback service, with additional API usage.")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            HStack {
                Button("Lessons & Progress…", action: onOpenLessons).buttonStyle(.link)
                Spacer()
                HStack(spacing: 6) {
                    keycap(FeedbackShortcut.saveLabel); Text("Save")
                    keycap(FeedbackShortcut.discardLabel); Text("Close")
                }.font(.system(size: 11)).foregroundStyle(.secondary)
                    .help("These keys act only while feedback is visible. Save keeps every lesson; Close dismisses the review. Progress is recorded automatically.")
            }
            DisclosureGroup("Data & privacy", isExpanded: $showPrivacy) {
                VStack(alignment: .leading, spacing: 12) {
                    detail("Sent", "Your dictation, plus a short excerpt from the active app when context is on. No screenshots.")
                    detail("Kept on this Mac", "Saved lessons, level estimates, pattern counts and review dates. Full dictations and captured context aren’t saved.")
                    detail("Practice", "Spoken answers use transcription; typed answers send text only. Answers and audio aren’t saved on this Mac.")
                    detail("Your level", "Assessed from your own dictation, never from nearby text or practice answers.")
                    detail("Context controls", "Password fields and excluded apps are skipped. App support varies; dictation continues without context when needed. Turning context off cancels pending feedback that used it.")
                    Link("OpenAI data retention details", destination: URL(string: "https://developers.openai.com/api/docs/guides/your-data")!)
                        .font(.system(size: 12))
                }.padding(.top, 8)
            }.font(.system(size: 12))
        }
        .padding(.vertical, 5)
        .sheet(isPresented: $showExcludedApps) { exclusions }
    }

    private func keycap(_ key: String) -> some View {
        Text(key).font(.system(size: 10, weight: .medium, design: .monospaced))
            .frame(width: 20, height: 20)
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
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
