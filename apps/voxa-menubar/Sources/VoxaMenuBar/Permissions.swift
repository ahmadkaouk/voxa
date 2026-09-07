import AppKit
import AVFoundation
import ApplicationServices

struct Permissions: Equatable {
    var microphone: AVAuthorizationStatus
    var accessibility: Bool
    var inputMonitoring: Bool

    static func current() -> Permissions {
        Permissions(microphone: AVCaptureDevice.authorizationStatus(for: .audio),
                    accessibility: AXIsProcessTrusted(), inputMonitoring: CGPreflightListenEventAccess())
    }

    @MainActor
    static func requestMicrophone() async throws {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AudioRecorderError.microphonePermission
        }
    }

    @MainActor
    static func openSettings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
