import AppKit
import Foundation

/// Refuse capture while another Voxa recorder is active. Retirement only runs during setup,
/// after the old app has quit and its daemon has stopped; no legacy IPC is needed.
enum LegacyCaptureGuard {
    private enum GuardError: LocalizedError {
        case running, inspectionFailed
        var errorDescription: String? {
            switch self {
            case .running: return "Quit the other Voxa app or Recorder Preview and stop the old Voxa daemon, then retry setup."
            case .inspectionFailed: return "Could not confirm that the old Voxa recorder is stopped. Retry setup before recording."
            }
        }
    }

    static func check() async throws {
        try await Task.detached { try inspectStopped() }.value
        try Task.checkCancellation()
    }

    static func retireLaunchAgent() async throws {
        try await Task.detached {
            try LegacyLaunchAgent.retire(checkStopped: inspectStopped, command: run)
        }.value
        try Task.checkCancellation()
    }

    private static func inspectStopped() throws {
        for bundle in ["com.voxa.menubar", "com.voxa.recorder-preview"] {
            guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
                .contains(where: { $0.processIdentifier != getpid() }) else { throw GuardError.running }
        }
        let status = try run("/usr/bin/pgrep", ["-x", "-u", String(getuid()), "voxa-daemon"])
        guard status == 1 else { throw status == 0 ? GuardError.running : .inspectionFailed }
    }

    private static func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { throw GuardError.inspectionFailed }
        guard finished.wait(timeout: .now() + 5) == .success else {
            process.terminate() // Only this helper process; never the daemon or another app.
            throw GuardError.inspectionFailed
        }
        return process.terminationStatus
    }
}

/// A narrowly scoped upgrade helper retained after Rust/IPC removal. Tests supply a temporary
/// home and command results; production only touches the current user's known Voxa LaunchAgent.
enum LegacyLaunchAgent {
    static let label = "com.voxa.daemon"
    private enum MigrationError: LocalizedError {
        case unrecognized, unregisterFailed, changed
        var errorDescription: String? {
            switch self {
            case .unrecognized:
                return "The old Voxa LaunchAgent could not be identified safely. Review ~/Library/LaunchAgents/com.voxa.daemon.plist, then retry setup."
            case .unregisterFailed:
                return "Could not unregister the old Voxa service. Quit the older Voxa app, then retry setup."
            case .changed:
                return "The old Voxa LaunchAgent changed during migration. Quit other Voxa copies, then retry setup."
            }
        }
    }

    static func retire(home: URL = FileManager.default.homeDirectoryForCurrentUser, uid: uid_t = getuid(),
                       checkStopped: () throws -> Void,
                       command: (String, [String]) throws -> Int32) throws {
        try checkStopped()
        let manager = FileManager.default
        let url = home.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        let target = "gui/\(uid)/\(label)"
        let attributes: [FileAttributeKey: Any]
        do { attributes = try manager.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            // A missing file is a clean install only when no registration remains.
            guard try command("/bin/launchctl", ["print", target]) == 113 else { throw MigrationError.unrecognized }
            return
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == uid,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 65_536 else {
            throw MigrationError.unrecognized
        }
        let original = try Data(contentsOf: url)
        guard let plist = try? PropertyListSerialization.propertyList(from: original, format: nil) as? [String: Any],
              plist["Label"] as? String == label, plist["Program"] == nil,
              let arguments = plist["ProgramArguments"] as? [String], arguments.count == 1,
              let executable = arguments.first, executable.hasPrefix("/"),
              executable.hasSuffix("/Voxa.app/Contents/Resources/bin/voxa-daemon")
                || executable == home.appendingPathComponent(".cargo/bin/voxa-daemon").path
                || executable.hasSuffix("/target/release/voxa-daemon")
                || executable.hasSuffix("/target/debug/voxa-daemon") else { throw MigrationError.unrecognized }

        let loaded = try command("/bin/launchctl", ["print", target])
        guard loaded == 0 || loaded == 113 else { throw MigrationError.unregisterFailed }
        try checkStopped()
        if loaded == 0 {
            let stopped = try command("/bin/launchctl", ["bootout", target])
            guard stopped == 0 || stopped == 3 else { throw MigrationError.unregisterFailed }
        }
        guard try command("/bin/launchctl", ["print", target]) == 113 else { throw MigrationError.unregisterFailed }
        try checkStopped()
        let current = try manager.attributesOfItem(atPath: url.path)
        guard current[.type] as? FileAttributeType == .typeRegular,
              current[.systemFileNumber] as? NSNumber == attributes[.systemFileNumber] as? NSNumber,
              try Data(contentsOf: url) == original else { throw MigrationError.changed }

        // Move out of LaunchAgents rather than destroy the previous registration file.
        let archive = home.appendingPathComponent("Library/Application Support/voxa/migration")
        try manager.createDirectory(at: archive, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try manager.moveItem(at: url, to: archive.appendingPathComponent("legacy-daemon-\(UUID().uuidString).plist"))
    }
}
