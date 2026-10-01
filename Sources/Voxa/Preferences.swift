import Foundation

struct Preferences: Codable, Equatable {
    var toggleHotkey = HotkeyOption.defaultToggle.persistedValue
    var finishAndSubmitHotkey = HotkeyOption.defaultFinishAndSubmit.persistedValue
    var model = ModelOption.gptTranscribe.rawValue
    var outputMode = OutputModeOption.clipboardAutopaste.rawValue
    var maxRecordingSeconds: UInt64 = 300
    var apiKeySource = "keychain"
    var englishFeedbackEnabled = false
    var automaticContextEnabled = false
    var contextExcludedApps: [ContextExcludedApp] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case toggleHotkey, finishAndSubmitHotkey, model, outputMode, maxRecordingSeconds, apiKeySource, englishFeedbackEnabled
        case automaticContextEnabled, contextExcludedApps
    }
    private enum LegacyKeys: String, CodingKey { case holdHotkey }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        toggleHotkey = try values.decode(String.self, forKey: .toggleHotkey)
        if let saved = try values.decodeIfPresent(String.self, forKey: .finishAndSubmitHotkey) {
            finishAndSubmitHotkey = saved
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(String.self, forKey: .holdHotkey)
            finishAndSubmitHotkey = HotkeyOption.migratedSubmit(legacy: legacy.flatMap(HotkeyOption.fromRaw),
                toggle: HotkeyOption.fromRawOrDefault(toggleHotkey)).persistedValue
        }
        model = try values.decode(String.self, forKey: .model)
        outputMode = try values.decode(String.self, forKey: .outputMode)
        maxRecordingSeconds = try values.decode(UInt64.self, forKey: .maxRecordingSeconds)
        apiKeySource = try values.decode(String.self, forKey: .apiKeySource)
        // Older v1 preferences remain valid and never opt users in implicitly.
        englishFeedbackEnabled = try values.decodeIfPresent(Bool.self, forKey: .englishFeedbackEnabled) ?? false
        automaticContextEnabled = try values.decodeIfPresent(Bool.self, forKey: .automaticContextEnabled) ?? false
        contextExcludedApps = try values.decodeIfPresent([ContextExcludedApp].self, forKey: .contextExcludedApps) ?? []
    }

    func validated() throws -> Preferences {
        guard let toggle = HotkeyOption.fromRaw(toggleHotkey),
              let submit = HotkeyOption.fromRaw(finishAndSubmitHotkey), submit.isValidForSubmit, !toggle.overlaps(submit),
              ModelOption(rawValue: model) != nil, OutputModeOption(rawValue: outputMode) != nil,
              (1...3600).contains(maxRecordingSeconds), ["env", "keychain"].contains(apiKeySource),
              contextExcludedApps.count <= 100,
              Set(contextExcludedApps.map(\.bundleID)).count == contextExcludedApps.count,
              contextExcludedApps.allSatisfy({ !$0.bundleID.isEmpty && $0.bundleID.utf8.count <= 255 &&
                  !$0.name.isEmpty && $0.name.utf8.count <= 255 })
        else { throw PreferencesError.invalidConfiguration }
        return self
    }

    var dictation: DictationSettings {
        DictationSettings(model: ModelOption.fromRawOrDefault(model),
                          outputMode: OutputModeOption.fromRawOrDefault(outputMode),
                          maxRecordingSeconds: TimeInterval(maxRecordingSeconds),
                          englishFeedbackEnabled: englishFeedbackEnabled,
                          automaticContextEnabled: automaticContextEnabled,
                          contextExcludedBundleIDs: Set(contextExcludedApps.map(\.bundleID)))
    }
}

enum PreferencesError: LocalizedError {
    case invalidConfiguration, persistence
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Saved settings are invalid. Check Voxa’s preferences before retrying setup."
        case .persistence: return "Could not save Voxa’s settings. Check available disk space and retry."
        }
    }
}

/// Persist validated settings as one versioned UserDefaults value.
@MainActor
final class PreferencesStore {
    static let storageKey = "nativePreferences.v1"
    private struct Saved: Codable { let version: Int; let preferences: Preferences }
    private let defaults: UserDefaults
    private let flush: () -> Bool

    init(defaults: UserDefaults = .standard, flush: (() -> Bool)? = nil) {
        self.defaults = defaults
        self.flush = flush ?? { defaults.synchronize() }
    }

    func load() throws -> Preferences {
        if let saved = defaults.object(forKey: Self.storageKey) {
            guard let data = saved as? Data,
                  let record = try? JSONDecoder().decode(Saved.self, from: data), record.version == 1
            else { throw PreferencesError.invalidConfiguration }
            return try record.preferences.validated()
        }
        let preferences = Preferences()
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
