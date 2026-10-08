import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings that need more room than the menu bar's quick controls.
struct PrivacySettingsView: View {
    let excludedApps: [ContextExcludedApp]
    var canEdit = true
    var onExclude: (ContextExcludedApp) -> Void
    var onAllow: (String) -> Void

    var body: some View {
        SettingsPage(title: "Privacy", subtitle: "Control nearby-text access and see how your data is handled.") {
            Form {
                Section {
                    if excludedApps.isEmpty {
                        Text("No apps excluded").foregroundStyle(.secondary)
                    } else {
                        ForEach(excludedApps) { app in
                            HStack {
                                Text(app.name).lineLimit(1)
                                Spacer()
                                Button { onAllow(app.bundleID) } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Allow nearby text from \(app.name)")
                                .help("Remove \(app.name) from exclusions")
                            }
                        }
                    }
                    Button("Add App…", action: chooseApp)
                } header: { Text("Excluded apps") } footer: {
                    Text("Voxa skips nearby text from these apps and from password fields. Turn nearby text on or off under English Learning in the menu bar.")
                }
                .disabled(!canEdit)

                Section("Data & privacy") {
                    detail("Sent to OpenAI", "Audio for transcription. English feedback also sends your dictation and optional nearby text. No screenshots. Coaching uses additional API requests.")
                    detail("Practice", "The selected lesson and your answer are sent for feedback. Spoken answers also use transcription.")
                    detail("Stored on this Mac", "Saved lessons, level estimates, pattern counts and review dates. Full dictations, captured context, practice answers and audio aren’t saved.")
                    detail("Your level", "Estimated from your own dictation. Nearby text and practice answers don’t affect it.")
                    Link("OpenAI data retention details", destination: URL(string: "https://developers.openai.com/api/docs/guides/your-data")!)
                }
            }
            .voxaSettingsFormStyle()
        }
    }

    private func detail(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).fontWeight(.medium)
            Text(text).foregroundStyle(.secondary).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
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
