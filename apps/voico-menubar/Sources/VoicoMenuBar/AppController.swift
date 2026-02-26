import AppKit
import Foundation

@MainActor
final class AppController: ObservableObject {
    @Published private(set) var serviceState: ServiceState = .checking
    @Published private(set) var toggleHotkey: VoicoHotkey = .rightOption
    @Published private(set) var holdHotkey: VoicoHotkey = .functionKey
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

    func setToggleHotkey(_ value: VoicoHotkey) {
        if value == toggleHotkey {
            return
        }

        let previous = toggleHotkey
        toggleHotkey = value

        runMutation(
            startMessage: "Updating toggle hotkey...",
            successMessage: "Toggle hotkey updated",
            onFailure: { [weak self] in
                self?.toggleHotkey = previous
            }
        ) { cli in
            try cli.setToggleHotkey(value)
            try cli.restartService()
        }
    }

    func setHoldHotkey(_ value: VoicoHotkey) {
        if value == holdHotkey {
            return
        }

        let previous = holdHotkey
        holdHotkey = value

        runMutation(
            startMessage: "Updating hold hotkey...",
            successMessage: "Hold hotkey updated",
            onFailure: { [weak self] in
                self?.holdHotkey = previous
            }
        ) { cli in
            try cli.setHoldHotkey(value)
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
        toggleHotkey = snapshot.settings.toggleHotkey
        holdHotkey = snapshot.settings.holdHotkey
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
