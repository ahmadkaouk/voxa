import AppKit

/// Refuse capture while another copy of Voxa is running.
@MainActor
enum CaptureGuard {
    struct AnotherCopyRunning: LocalizedError {
        var errorDescription: String? { "Quit the other copy of Voxa, then try again." }
    }

    static func check(currentPID: pid_t = getpid(), runningProcessIDs: () -> [pid_t] = {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.voxa.menubar")
            .map(\.processIdentifier)
    }) throws {
        guard !runningProcessIDs().contains(where: { $0 != currentPID }) else {
            throw AnotherCopyRunning()
        }
    }
}
