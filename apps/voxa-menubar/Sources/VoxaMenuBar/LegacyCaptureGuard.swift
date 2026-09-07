import AppKit
import Foundation

/// The migration candidate never starts, kills, or takes over an existing capture process.
/// Owned LaunchAgent retirement follows in candidate validation after the signed native test.
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
        try await Task.detached {
            for bundle in ["com.voxa.menubar", "com.voxa.recorder-preview"] {
                guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundle)
                    .contains(where: { $0.processIdentifier != getpid() }) else { throw GuardError.running }
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-x", "-u", String(getuid()), "voxa-daemon"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { throw GuardError.inspectionFailed }
            process.waitUntilExit()
            guard process.terminationStatus == 1 else {
                throw process.terminationStatus == 0 ? GuardError.running : .inspectionFailed
            }
        }.value
        try Task.checkCancellation()
    }
}
