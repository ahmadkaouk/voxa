import AppKit
import Foundation

@MainActor
final class AppController: ObservableObject {
    @Published private(set) var serviceState: ServiceState = .checking
    @Published private(set) var hotkey: VoicoHotkey = .rightOption
    @Published private(set) var mode: VoicoInputMode = .toggle
    @Published private(set) var output: VoicoOutput = .clipboard
    @Published private(set) var apiKeySet = false
    @Published private(set) var isBusy = false
    @Published private(set) var statusMessage = "Starting..."
    @Published var apiKeyInput = ""

    private let cli = VoicoCLI()

    init() {
        startup()
    }

    func startup() {
        runRead(
            startMessage: "Initializing Voico service...",
            successMessage: "Voico ready"
        ) { cli in
            try cli.ensureServiceInstalledAndRunning()
            return try cli.snapshot()
        }
    }

    func refresh() {
        runRead(
            startMessage: "Refreshing status...",
            successMessage: "Voico ready"
        ) { cli in
            try cli.snapshot()
        }
    }

    func startOrRestartService() {
        runMutation(
            startMessage: "Starting service...",
            successMessage: "Service running"
        ) { cli in
            let status = try cli.serviceStatus()
            if status.loaded {
                try cli.restartService()
            } else {
                try cli.installService()
            }
        }
    }

    func stopService() {
        runMutation(
            startMessage: "Stopping service...",
            successMessage: "Service stopped"
        ) { cli in
            try cli.uninstallService()
        }
    }

    func reinstallService() {
        runMutation(
            startMessage: "Reinstalling service...",
            successMessage: "Service reinstalled"
        ) { cli in
            try cli.installService()
        }
    }

    func setHotkey(_ value: VoicoHotkey) {
        if value == hotkey {
            return
        }

        let previous = hotkey
        hotkey = value

        runMutation(
            startMessage: "Updating hotkey...",
            successMessage: "Hotkey updated",
            onFailure: { [weak self] in
                self?.hotkey = previous
            }
        ) { cli in
            try cli.setHotkey(value)
            try cli.restartService()
        }
    }

    func setOutput(_ value: VoicoOutput) {
        if value == output {
            return
        }

        let previous = output
        output = value

        runMutation(
            startMessage: "Updating output mode...",
            successMessage: "Output mode updated",
            onFailure: { [weak self] in
                self?.output = previous
            }
        ) { cli in
            try cli.setOutput(value)
        }
    }

    func setMode(_ value: VoicoInputMode) {
        if value == mode {
            return
        }

        let previous = mode
        mode = value

        runMutation(
            startMessage: "Updating input mode...",
            successMessage: "Input mode updated",
            onFailure: { [weak self] in
                self?.mode = previous
            }
        ) { cli in
            try cli.setMode(value)
            try cli.restartService()
        }
    }

    func saveAPIKey() {
        let trimmed = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            statusMessage = "API key cannot be empty"
            return
        }

        runMutation(
            startMessage: "Saving API key...",
            successMessage: "API key saved"
        ) { cli in
            try cli.setAPIKey(trimmed)
            try cli.restartService()
        }

        apiKeyInput = ""
    }

    func openStdoutLog() {
        openLogFile(named: "voico-daemon.out.log")
    }

    func openStderrLog() {
        openLogFile(named: "voico-daemon.err.log")
    }

    func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func openLogFile(named fileName: String) {
        let path = NSString(string: "~/Library/Logs/\(fileName)").expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.open(url)
    }

    private func runRead(
        startMessage: String,
        successMessage: String,
        work: @escaping (VoicoCLI) throws -> AppSnapshot
    ) {
        isBusy = true
        statusMessage = startMessage

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let snapshot = try work(self.cli)
                DispatchQueue.main.async {
                    self.apply(snapshot: snapshot)
                    self.statusMessage = successMessage
                    self.isBusy = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.serviceState = .error
                    self.statusMessage = self.displayMessage(for: error)
                    self.isBusy = false
                }
            }
        }
    }

    private func runMutation(
        startMessage: String,
        successMessage: String,
        onFailure: (() -> Void)? = nil,
        work: @escaping (VoicoCLI) throws -> Void
    ) {
        isBusy = true
        statusMessage = startMessage

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try work(self.cli)
                let snapshot = try self.cli.snapshot()
                DispatchQueue.main.async {
                    self.apply(snapshot: snapshot)
                    self.statusMessage = successMessage
                    self.isBusy = false
                }
            } catch {
                DispatchQueue.main.async {
                    onFailure?()
                    self.statusMessage = self.displayMessage(for: error)
                    self.isBusy = false
                }
            }
        }
    }

    private func apply(snapshot: AppSnapshot) {
        hotkey = snapshot.settings.hotkey
        mode = snapshot.settings.mode
        output = snapshot.settings.output
        apiKeySet = snapshot.apiKeySet
        serviceState = snapshot.service.loaded ? .running : .stopped
    }

    private func displayMessage(for error: Error) -> String {
        if let cliError = error as? VoicoCLIError {
            return cliError.message
        }

        return error.localizedDescription
    }
}
