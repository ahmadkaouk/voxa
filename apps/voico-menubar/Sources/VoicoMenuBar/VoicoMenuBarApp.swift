import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let cli = VoicoCLI()

    func applicationWillTerminate(_ notification: Notification) {
        // App-scoped behavior: stop daemon service when quitting the menu app.
        try? cli.uninstallService()
    }
}

@main
struct VoicoMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = AppController()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra("Voico", systemImage: controller.serviceState.iconName) {
            VoicoMenuView(controller: controller)
        }
        .menuBarExtraStyle(.window)
    }
}

struct VoicoMenuView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Voico")
                    .font(.headline)
                Spacer()
                Text(controller.serviceState.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if controller.isBusy {
                ProgressView()
                    .controlSize(.small)
            }

            Text(controller.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)

            Divider()

            Group {
                Button("Start/Restart Service") {
                    controller.startOrRestartService()
                }

                Button("Stop Service") {
                    controller.stopService()
                }

                Button("Reinstall Service") {
                    controller.reinstallService()
                }
            }
            .disabled(controller.isBusy)

            Divider()

            Picker(
                "Toggle Hotkey",
                selection: Binding(
                    get: { controller.toggleHotkey },
                    set: { controller.setToggleHotkey($0) }
                )
            ) {
                ForEach(VoicoHotkey.allCases) { hotkey in
                    Text(hotkey.label).tag(hotkey)
                }
            }
            .disabled(controller.isBusy)

            Picker(
                "Hold Hotkey",
                selection: Binding(
                    get: { controller.holdHotkey },
                    set: { controller.setHoldHotkey($0) }
                )
            ) {
                ForEach(VoicoHotkey.allCases) { hotkey in
                    Text(hotkey.label).tag(hotkey)
                }
            }
            .disabled(controller.isBusy)

            Divider()

            SecureField("OPENAI_API_KEY", text: $controller.apiKeyInput)
                .textFieldStyle(.roundedBorder)
                .disabled(controller.isBusy)

            HStack {
                Text(controller.apiKeySet ? "API key is set" : "API key is not set")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Save Key") {
                    controller.saveAPIKey()
                }
                .disabled(controller.isBusy)
            }

            Divider()

            Group {
                Button("Refresh") {
                    controller.refresh()
                }

                Button("Open Daemon Log") {
                    controller.openStdoutLog()
                }

                Button("Open Error Log") {
                    controller.openStderrLog()
                }

                Button("Quit and Stop Service") {
                    controller.quit()
                }
            }
        }
        .padding(12)
        .frame(width: 340)
    }
}
