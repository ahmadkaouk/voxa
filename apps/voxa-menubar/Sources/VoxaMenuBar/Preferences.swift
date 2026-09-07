import Foundation
import TOMLDecoder

struct Preferences: Codable, Equatable {
    var toggleHotkey = HotkeyOption.defaultToggle.persistedValue
    var holdHotkey = HotkeyOption.defaultHold.persistedValue
    var model = ModelOption.gptTranscribe.rawValue
    var outputMode = OutputModeOption.clipboardAutopaste.rawValue
    var maxRecordingSeconds: UInt64 = 300
    var apiKeySource = "keychain"

    func validated() throws -> Preferences {
        guard let toggle = HotkeyOption.fromRaw(toggleHotkey),
              let hold = HotkeyOption.fromRaw(holdHotkey), toggle != hold,
              ModelOption(rawValue: model) != nil, OutputModeOption(rawValue: outputMode) != nil,
              (1...3600).contains(maxRecordingSeconds), ["env", "keychain"].contains(apiKeySource)
        else { throw PreferencesError.invalidConfiguration }
        return self
    }

    var dictation: DictationSettings {
        DictationSettings(model: ModelOption.fromRawOrDefault(model),
                          outputMode: OutputModeOption.fromRawOrDefault(outputMode),
                          maxRecordingSeconds: TimeInterval(maxRecordingSeconds))
    }

    static func importing(_ text: String) throws -> Preferences {
        // Decode the complete document before applying any values. TOML syntax, escaping,
        // duplicate keys, and field types are checked by the parser, not a line reader.
        struct Legacy: Decodable {
            let toggle_hotkey: String?
            let hold_hotkey: String?
            let model: String?
            let output_mode: String?
            let max_recording_seconds: UInt64?
            let api_key_source: String?
            let revision: UInt64?
        }
        do {
            let old = try TOMLDecoder().decode(Legacy.self, from: text)
            var result = Preferences()
            if let value = old.toggle_hotkey { result.toggleHotkey = value }
            if let value = old.hold_hotkey { result.holdHotkey = value }
            if let value = old.model {
                result.model = ["gpt-4o-mini-transcribe", "gpt-4o-transcribe"].contains(value)
                    ? ModelOption.gptTranscribe.rawValue : value
            }
            if let value = old.output_mode { result.outputMode = value }
            if let value = old.max_recording_seconds { result.maxRecordingSeconds = value }
            // The legacy store selected environment only for this exact value.
            if let value = old.api_key_source { result.apiKeySource = value == "env" ? "env" : "keychain" }
            return try result.validated()
        } catch { throw PreferencesError.legacyImport }
    }
}

enum PreferencesError: LocalizedError {
    case invalidConfiguration, legacyImport, persistence
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Saved settings are invalid. Check Voxa’s preferences before retrying setup."
        case .legacyImport: return "Could not import config.toml from ~/Library/Application Support/voxa (or VOXA_CONFIG_PATH). Fix its settings, then retry setup. The original file has been preserved."
        case .persistence: return "Could not save Voxa’s settings. Check available disk space and retry."
        }
    }
}

/// One versioned value contains both settings and the completed-import marker. Never write the
/// legacy TOML: keeping it intact is what makes the preserved application usable for rollback.
@MainActor
final class PreferencesStore {
    static let storageKey = "nativePreferences.v1"
    static var legacyURL: URL {
        if let path = ProcessInfo.processInfo.environment["VOXA_CONFIG_PATH"] { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/voxa/config.toml")
    }
    private struct Saved: Codable { let version: Int; let preferences: Preferences }
    private let defaults: UserDefaults
    private let legacyURL: URL
    private let flush: () -> Bool

    init(defaults: UserDefaults = .standard, legacyURL: URL? = nil,
         flush: (() -> Bool)? = nil) {
        self.defaults = defaults
        self.legacyURL = legacyURL ?? Self.legacyURL
        self.flush = flush ?? { defaults.synchronize() }
    }

    func load() throws -> Preferences {
        if let saved = defaults.object(forKey: Self.storageKey) {
            guard let data = saved as? Data,
                  let record = try? JSONDecoder().decode(Saved.self, from: data), record.version == 1
            else { throw PreferencesError.invalidConfiguration }
            return try record.preferences.validated()
        }
        let preferences: Preferences
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: legacyURL.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= 1_048_576 else {
                throw PreferencesError.legacyImport
            }
            preferences = try Preferences.importing(String(contentsOf: legacyURL, encoding: .utf8))
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
            preferences = Preferences()
        } catch { throw PreferencesError.legacyImport }
        try save(preferences)
        return preferences
    }

    func save(_ preferences: Preferences) throws {
        let value = try preferences.validated()
        let data = try JSONEncoder().encode(Saved(version: 1, preferences: value))
        let previous = defaults.object(forKey: Self.storageKey)
        defaults.set(data, forKey: Self.storageKey)
        guard flush(), defaults.data(forKey: Self.storageKey) == data else {
            if let previous { defaults.set(previous, forKey: Self.storageKey) }
            else { defaults.removeObject(forKey: Self.storageKey) }
            _ = flush()
            throw PreferencesError.persistence
        }
    }
}
