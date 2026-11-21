import SwiftUI

private typealias GeneralSettingsState<Value> = SwiftUI.State<Value>

@MainActor
struct GeneralSettingsView: View {
    let permissions: Permissions
    var canRequestMicrophone = true
    var onRequestMicrophone: () async -> Void
    var onOpenSettings: (String) -> Void = Permissions.openSettings
    @GeneralSettingsState private var requestingMicrophone = false

    var body: some View {
        SettingsPage(title: "General", subtitle: "Manage the Mac permissions Voxa uses.") {
            Form {
                Section {
                    permissionRow("Microphone", detail: "Record dictation and spoken practice.",
                        actionTitle: microphoneActionTitle, action: openMicrophone)
                        .disabled(requestingMicrophone || (permissions.microphone == .notDetermined && !canRequestMicrophone))
                    permissionRow("Accessibility", detail: "Paste into other apps and read nearby text when you enable it.",
                        actionTitle: permissions.accessibility ? "Manage…" : "Open Settings…") {
                            onOpenSettings("Accessibility")
                        }
                    permissionRow("Input Monitoring", detail: "Use keyboard shortcuts while you’re in other apps.",
                        actionTitle: permissions.inputMonitoring ? "Manage…" : "Open Settings…") {
                            onOpenSettings("ListenEvent")
                        }
                } header: { Text("Permissions") } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Permission changes take effect when you return to Voxa.")
                        if permissions.microphone == .restricted {
                            Text("Microphone access is restricted by macOS. Your Mac’s administrator may need to enable it.")
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .voxaSettingsFormStyle()
        }
    }

    private var microphoneActionTitle: String {
        if requestingMicrophone { return "Waiting…" }
        switch permissions.microphone {
        case .notDetermined: return "Allow…"
        case .authorized: return "Manage…"
        default: return "Open Settings…"
        }
    }

    private func openMicrophone() {
        guard permissions.microphone == .notDetermined else {
            onOpenSettings("Microphone")
            return
        }
        guard canRequestMicrophone, !requestingMicrophone else { return }
        requestingMicrophone = true
        Task {
            await onRequestMicrophone()
            requestingMicrophone = false
        }
    }

    private func permissionRow(_ title: String, detail: String, actionTitle: String,
                               action: @escaping () -> Void) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(actionTitle, action: action)
                .foregroundStyle(.primary).fixedSize()
                .accessibilityLabel("\(actionTitle) \(title) permission")
        }
        .padding(.vertical, 4)
    }
}
