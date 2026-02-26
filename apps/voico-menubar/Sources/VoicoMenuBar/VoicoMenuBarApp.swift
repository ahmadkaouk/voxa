import AppKit
import SwiftUI

@main
struct VoicoMenuBarApp: App {
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
                "Hotkey",
                selection: Binding(
                    get: { controller.hotkey },
                    set: { controller.setHotkey($0) }
                )
            ) {
                ForEach(VoicoHotkey.allCases) { hotkey in
                    Text(hotkey.label).tag(hotkey)
                }
            }
            .disabled(controller.isBusy)

            Picker(
                "Output",
                selection: Binding(
                    get: { controller.output },
                    set: { controller.setOutput($0) }
                )
            ) {
                ForEach(VoicoOutput.allCases) { output in
                    Text(output.label).tag(output)
                }
            }
            .disabled(controller.isBusy)

            Picker(
                "Mode",
                selection: Binding(
                    get: { controller.mode },
                    set: { controller.setMode($0) }
                )
            ) {
                ForEach(VoicoInputMode.allCases) { mode in
                    Text(mode.label).tag(mode)
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

                Button("Quit") {
                    controller.quit()
                }
            }
        }
        .padding(12)
        .frame(width: 340)
    }
}
