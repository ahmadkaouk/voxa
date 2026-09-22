#if canImport(XCTest) || VOXA_STANDALONE_TESTS
import Foundation
import Security
#if !VOXA_STANDALONE_TESTS
import XCTest
@testable import Voxa
#endif

@MainActor
enum NativeSetupChecks {
    private static func rejected(_ operation: () throws -> Void) throws {
        var failed = false
        do { try operation() } catch { failed = true }
        try unitExpect(failed)
    }

    static func duplicateAppProtection() throws {
        var running: [pid_t] = []
        let inspect = { try CaptureGuard.check(currentPID: 42, runningProcessIDs: { running }) }
        try inspect()
        running = [42]
        try inspect()
        // A second copy starting during a prompt must be caught by the next check.
        running.append(99)
        do { try inspect(); try unitExpect(false) }
        catch is CaptureGuard.AnotherCopyRunning { }
        running = [99]
        do { try inspect(); try unitExpect(false) }
        catch is CaptureGuard.AnotherCopyRunning { }
        running = [42]
        try inspect()
    }

    private static func withStore(_ run: (UserDefaults) throws -> Void) throws {
        let name = "com.voxa.tests.preferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer {
            defaults.removePersistentDomain(forName: name)
            _ = defaults.synchronize()
        }
        try run(defaults)
    }

    // The shipped v1 shape, including a saved single-key binding and environment mode.
    private static let savedPreferences: [String: Any] = [
        "toggleHotkey": #"{"keyCode":79,"modifiers":["control","shift"],"keyDisplay":"F18"}"#,
        "holdHotkey": "fn_space", "model": "gpt-transcribe", "outputMode": "none",
        "maxRecordingSeconds": 120, "apiKeySource": "env",
    ]

    static func savedSettingsSurviveRelaunch() throws {
        try withStore { defaults in
            let original = try JSONSerialization.data(withJSONObject: ["version": 1, "preferences": savedPreferences])
            defaults.set(original, forKey: PreferencesStore.storageKey)
            let store = PreferencesStore(defaults: defaults)
            var value = try store.load()
            try unitEqual(value.toggleHotkey, savedPreferences["toggleHotkey"] as? String)
            try unitEqual(HotkeyOption.fromRaw(value.toggleHotkey),
                          HotkeyOption(keyCodes: [79], modifiers: [.control, .shift], keyDisplays: ["F18"]))
            try unitEqual(HotkeyOption.fromRaw(value.toggleHotkey)?.label, "Ctrl+Shift+F18")
            try unitEqual(value.holdHotkey, "fn_space")
            try unitEqual(value.model, "gpt-transcribe")
            try unitEqual(value.outputMode, "none")
            try unitEqual(value.maxRecordingSeconds, 120)
            try unitEqual(value.apiKeySource, "env")
            try unitEqual(defaults.data(forKey: PreferencesStore.storageKey), original)
            value.maxRecordingSeconds = 60
            try store.save(value)
            try unitEqual(try PreferencesStore(defaults: defaults).load(), value)
        }
    }

    static func rejectsInvalidSettings() throws {
        try withStore { defaults in
            let store = PreferencesStore(defaults: defaults)
            let corruptRecords: [Any] = ["not data", Data("corrupt".utf8),
                try JSONSerialization.data(withJSONObject: ["version": 2, "preferences": savedPreferences])]
            for record in corruptRecords {
                defaults.set(record, forKey: PreferencesStore.storageKey)
                try rejected { _ = try store.load() }
            }
            for (key, value) in [("toggleHotkey", "unknown"), ("holdHotkey", savedPreferences["toggleHotkey"]!),
                                 ("model", "unknown"), ("outputMode", "unknown"), ("apiKeySource", "unknown"),
                                 ("maxRecordingSeconds", 0), ("maxRecordingSeconds", 3601),
                                 ("maxRecordingSeconds", "60")] as [(String, Any)] {
                var invalid = savedPreferences
                invalid[key] = value
                let data = try JSONSerialization.data(withJSONObject: ["version": 1, "preferences": invalid])
                defaults.set(data, forKey: PreferencesStore.storageKey)
                try rejected { _ = try store.load() }
                try unitEqual(defaults.data(forKey: PreferencesStore.storageKey), data)
            }
        }
    }

    static func saveFailureRecovery() throws {
        try withStore { defaults in
            let failing = PreferencesStore(defaults: defaults, flush: { false })
            try rejected { _ = try failing.load() }
            try unitExpect(defaults.object(forKey: PreferencesStore.storageKey) == nil)
            let store = PreferencesStore(defaults: defaults)
            let value = try store.load()
            try unitEqual(value, Preferences())
            var update = value
            update.maxRecordingSeconds = 60
            try rejected { try failing.save(update) }
            try unitEqual(try store.load(), value)
            try store.save(update)
            try unitEqual(try store.load(), update)
            update.holdHotkey = update.toggleHotkey
            try rejected { try store.save(update) }
            try unitEqual(try store.load().maxRecordingSeconds, 60)
        }
    }

    static func credentialSourcesAndErrors() async throws {
        try unitEqual(TranscriptionClient.configuredEndpoint(environment: [:]), TranscriptionClient.defaultEndpoint)
        try unitEqual(TranscriptionClient.configuredEndpoint(environment: ["VOXA_OPENAI_TRANSCRIPTIONS_URL": " \n"]),
                      TranscriptionClient.defaultEndpoint)
        try unitEqual(TranscriptionClient.configuredEndpoint(environment: ["VOXA_OPENAI_TRANSCRIPTIONS_URL": " http://localhost:8765/transcribe "]),
                      URL(string: "http://localhost:8765/transcribe"))
        do {
            _ = try await TranscriptionClient(endpoint: nil).transcribe(Data([1]), model: .gptTranscribe, apiKey: "fixture")
            try unitExpect(false)
        } catch TranscriptionError.invalidEndpoint { }
        let environment = Keychain(read: { throw KeychainError.access(errSecAuthFailed) },
                                   write: { _ in throw KeychainError.invalidKey }, environment: { " fixture-env " })
        try unitEqual(try await environment.value(source: "env"), "fixture-env")
        do { _ = try await environment.value(source: "keychain"); try unitExpect(false) }
        catch KeychainError.access { }
        do { try await environment.save("fixture", source: "env"); try unitExpect(false) }
        catch KeychainError.environmentReadOnly { }
        for missing in [nil, "", " \n"] as [String?] {
            let store = Keychain(read: { missing }, environment: { "fixture-fallback" })
            try unitEqual(try await store.value(source: "keychain"), "fixture-fallback")
        }
        let stored = Keychain(read: { try unitExpect(!Thread.isMainThread); return " fixture-stored " },
                              write: { key in try unitExpect(!Thread.isMainThread); try unitEqual(key, "fixture-new") },
                              environment: { "fixture-env" })
        try unitEqual(try await stored.value(source: "keychain"), "fixture-stored")
        try await stored.save(" fixture-new ", source: "keychain")
        for invalid in ["", " \n", "fixture\r\nkey"] {
            do { try await stored.save(invalid, source: "keychain"); try unitExpect(false) }
            catch KeychainError.invalidKey { }
        }
    }

    static func nativeKeychainRoundTrip() async throws {
        // Exercise Security itself using a unique, disposable item. Never touch the Voxa key.
        let service = "com.voxa.tests.\(UUID().uuidString)"
        let account = "fixture"
        let store = Keychain(service: service, account: account, environment: { nil })
        defer {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
        }
        let absent = try await store.value(source: "keychain")
        try unitExpect(absent == nil)
        try await store.save("fixture-one", source: "keychain")
        try unitEqual(try await store.value(source: "keychain"), "fixture-one")
        try await store.save("fixture-two", source: "keychain")
        try unitEqual(try await store.value(source: "keychain"), "fixture-two")
    }

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("setup: duplicate app protection before and after prompts", duplicateAppProtection),
        ("setup: invalid saved configuration rejected without overwriting it", rejectsInvalidSettings),
        ("setup: existing v1 settings and relaunch preserved", savedSettingsSurviveRelaunch),
        ("setup: save failure recovery and clean install", saveFailureRecovery),
        ("setup: credential sources, denied access and worker isolation", credentialSourcesAndErrors),
        ("setup: native Keychain add/read/update with disposable item", nativeKeychainRoundTrip),
    ]
}

#if !VOXA_STANDALONE_TESTS
final class NativeSetupTests: XCTestCase {
    func testDuplicateAppProtection() async throws { try await NativeSetupChecks.duplicateAppProtection() }
    func testRejectsInvalidSettings() async throws { try await NativeSetupChecks.rejectsInvalidSettings() }
    func testSavedSettingsSurviveRelaunch() async throws { try await NativeSetupChecks.savedSettingsSurviveRelaunch() }
    func testSaveFailureRecovery() async throws { try await NativeSetupChecks.saveFailureRecovery() }
    func testCredentialSourcesAndErrors() async throws { try await NativeSetupChecks.credentialSourcesAndErrors() }
    func testNativeKeychainRoundTrip() async throws { try await NativeSetupChecks.nativeKeychainRoundTrip() }
}
#endif
#endif
