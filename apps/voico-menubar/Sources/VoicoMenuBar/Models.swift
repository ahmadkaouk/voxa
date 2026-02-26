import Foundation

enum ServiceState: String {
    case checking
    case running
    case stopped
    case error

    var label: String {
        switch self {
        case .checking:
            return "Checking"
        case .running:
            return "Running"
        case .stopped:
            return "Stopped"
        case .error:
            return "Error"
        }
    }

    var iconName: String {
        switch self {
        case .checking:
            return "hourglass"
        case .running:
            return "waveform.badge.mic"
        case .stopped:
            return "mic.slash"
        case .error:
            return "exclamationmark.triangle"
        }
    }
}

enum VoicoHotkey: String, CaseIterable, Identifiable {
    case rightOption = "right_option"
    case cmdSpace = "cmd_space"
    case functionKey = "fn"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rightOption:
            return "Right Option"
        case .cmdSpace:
            return "Cmd+Space"
        case .functionKey:
            return "Fn"
        }
    }
}

enum VoicoOutput: String, CaseIterable, Identifiable {
    case clipboard = "clipboard"
    case autopaste = "autopaste"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .clipboard:
            return "Clipboard"
        case .autopaste:
            return "Autopaste"
        }
    }
}

enum VoicoInputMode: String, CaseIterable, Identifiable {
    case toggle = "toggle"
    case hold = "hold"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .toggle:
            return "Toggle"
        case .hold:
            return "Hold"
        }
    }
}

struct ServiceStatus {
    let plistPresent: Bool
    let loaded: Bool
}

struct DaemonSettings {
    let hotkey: VoicoHotkey
    let mode: VoicoInputMode
    let output: VoicoOutput
}

struct AppSnapshot {
    let service: ServiceStatus
    let settings: DaemonSettings
    let apiKeySet: Bool
}
