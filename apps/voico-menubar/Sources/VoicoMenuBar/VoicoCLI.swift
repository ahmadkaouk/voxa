import Foundation

enum VoicoCLIError: Error {
    case voicoBinaryMissing
    case voicoBinaryIncompatible(path: String)
    case commandFailed(command: String, code: Int32, stderr: String)
    case parseFailed(context: String)

    var message: String {
        switch self {
        case .voicoBinaryMissing:
            return "voico binary not found. Run ./scripts/install.sh or set VOICO_BIN to an absolute path."
        case let .voicoBinaryIncompatible(path):
            return "voico binary is incompatible at \(path). Reinstall voico from this repo with ./scripts/install.sh."
        case let .commandFailed(command, code, stderr):
            if stderr.isEmpty {
                return "Command failed (\(code)): \(command)"
            }
            return "Command failed (\(code)): \(command)\n\(stderr)"
        case let .parseFailed(context):
            return "Failed to parse command output: \(context)"
        }
    }
}

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

struct VoicoCLI {
    private static let preferredVoicoPaths = [
        "~/.cargo/bin/voico",
        "/opt/homebrew/bin/voico",
        "/usr/local/bin/voico",
    ]

    func snapshot() throws -> AppSnapshot {
        AppSnapshot(
            service: try serviceStatus(),
            settings: try configShow(),
            apiKeySet: try apiKeyIsSet()
        )
    }

    func ensureServiceInstalledAndRunning() throws {
        let status = try serviceStatus()
        if status.loaded {
            try restartService()
            return
        }

        try installService()
    }

    func serviceStatus() throws -> ServiceStatus {
        let output = try runVoico(["service", "status"]).stdout
        let values = parseKeyValueLines(output)

        guard let plistPresentRaw = values["plist_present"],
              let loadedRaw = values["loaded"]
        else {
            throw VoicoCLIError.parseFailed(context: "service status")
        }

        guard let plistPresent = parseBool(plistPresentRaw),
              let loaded = parseBool(loadedRaw)
        else {
            throw VoicoCLIError.parseFailed(context: "service status booleans")
        }

        return ServiceStatus(plistPresent: plistPresent, loaded: loaded)
    }

    func installService() throws {
        _ = try runVoico(["service", "install"])
    }

    func uninstallService() throws {
        _ = try runVoico(["service", "uninstall"])
    }

    func restartService() throws {
        try installService()
    }

    func configShow() throws -> DaemonSettings {
        let output = try runVoico(["config", "show"]).stdout
        let values = parseKeyValueLines(output)

        guard let toggleHotkeyRaw = values["toggle_hotkey"],
              let holdHotkeyRaw = values["hold_hotkey"],
              let toggleHotkey = VoicoHotkey(rawValue: toggleHotkeyRaw),
              let holdHotkey = VoicoHotkey(rawValue: holdHotkeyRaw)
        else {
            throw VoicoCLIError.parseFailed(context: "config show")
        }

        return DaemonSettings(toggleHotkey: toggleHotkey, holdHotkey: holdHotkey)
    }

    func setToggleHotkey(_ value: VoicoHotkey) throws {
        _ = try runVoico(["config", "set", "toggle-hotkey", value.rawValue])
    }

    func setHoldHotkey(_ value: VoicoHotkey) throws {
        _ = try runVoico(["config", "set", "hold-hotkey", value.rawValue])
    }

    func apiKeyIsSet() throws -> Bool {
        let result = try run(
            executable: "/bin/launchctl",
            args: ["getenv", "OPENAI_API_KEY"],
            allowFailure: true
        )

        if result.status != 0 {
            return false
        }

        return !result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func setAPIKey(_ value: String) throws {
        _ = try run(
            executable: "/bin/launchctl",
            args: ["setenv", "OPENAI_API_KEY", value]
        )
    }

    private func runVoico(_ args: [String]) throws -> CommandResult {
        let voicoPath = try resolveVoicoPath()
        return try run(executable: voicoPath, args: args)
    }

    private func resolveVoicoPath() throws -> String {
        let environment = ProcessInfo.processInfo.environment
        var incompatiblePath: String?

        if let override = environment["VOICO_BIN"],
           let path = normalizedExecutablePath(override)
        {
            guard supportsDualHotkeyConfig(path: path) else {
                throw VoicoCLIError.voicoBinaryIncompatible(path: path)
            }
            return path
        }

        for candidate in voicoCandidates(pathEnv: environment["PATH"]) {
            if let path = normalizedExecutablePath(candidate) {
                if !supportsDualHotkeyConfig(path: path) {
                    if incompatiblePath == nil {
                        incompatiblePath = path
                    }
                    continue
                }
                return path
            }
        }

        if let incompatiblePath {
            throw VoicoCLIError.voicoBinaryIncompatible(path: incompatiblePath)
        }

        throw VoicoCLIError.voicoBinaryMissing
    }

    private func voicoCandidates(pathEnv: String?) -> [String] {
        var candidates = Self.preferredVoicoPaths

        if let pathEnv {
            for directory in pathEnv.split(separator: ":") {
                let directoryPath = String(directory).trimmingCharacters(in: .whitespacesAndNewlines)
                if !directoryPath.isEmpty {
                    candidates.append("\(directoryPath)/voico")
                }
            }
        }

        return candidates
    }

    private func normalizedExecutablePath(_ raw: String) -> String? {
        let expanded = NSString(string: raw.trimmingCharacters(in: .whitespacesAndNewlines))
            .expandingTildeInPath

        guard !expanded.isEmpty,
              expanded.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: expanded)
        else {
            return nil
        }

        return expanded
    }

    private func supportsDualHotkeyConfig(path: String) -> Bool {
        guard let result = try? run(
            executable: path,
            args: ["config", "show"],
            allowFailure: true
        ) else {
            return false
        }

        guard result.status == 0 else {
            return false
        }

        return result.stdout.contains("toggle_hotkey =")
            && result.stdout.contains("hold_hotkey =")
    }

    private func run(
        executable: String,
        args: [String],
        allowFailure: Bool = false
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            let command = ([executable] + args).joined(separator: " ")
            throw VoicoCLIError.commandFailed(command: command, code: -1, stderr: error.localizedDescription)
        }

        process.waitUntilExit()

        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        let result = CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
        if !allowFailure && result.status != 0 {
            let command = ([executable] + args).joined(separator: " ")
            throw VoicoCLIError.commandFailed(command: command, code: result.status, stderr: result.stderr)
        }

        return result
    }

    private func parseKeyValueLines(_ text: String) -> [String: String] {
        var values: [String: String] = [:]

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            guard let equalsIndex = line.firstIndex(of: "=") else {
                continue
            }

            let key = line[..<equalsIndex].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equalsIndex)...]
                .trimmingCharacters(in: .whitespaces)

            if !key.isEmpty {
                values[key] = value
            }
        }

        return values
    }

    private func parseBool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true":
            return true
        case "false":
            return false
        default:
            return nil
        }
    }
}
