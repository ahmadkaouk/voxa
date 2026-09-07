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

    static func completeTOMLImport() throws {
        let custom = HotkeyOption(keyCodes: [0, 1], modifiers: [.command, .shift], keyDisplays: ["A", "S"])
        let document = """
        # Quoted keys, literal/multiline strings, Unicode, integer separators, and an unrelated table.
        "toggle_hotkey" = '''\(custom.persistedValue)'''
        hold_hotkey = "fn_space"
        model = "gpt-4o-mini-transcribe"
        output_mode = "clipboard_only"
        max_recording_seconds = 1_800
        api_key_source = 'env'
        revision = 42
        [unrelated]
        """ + "\nnote = " + "\"\"\"\nbonjour 🌍\nsecond line\"\"\"\n"
        let value = try Preferences.importing(document)
        try unitEqual(HotkeyOption.fromRaw(value.toggleHotkey), custom)
        try unitEqual(HotkeyOption.fromRaw(value.holdHotkey), .functionSpace)
        try unitEqual(value.model, "gpt-transcribe")
        try unitEqual(value.outputMode, "clipboard_only")
        try unitEqual(value.maxRecordingSeconds, 1800)
        try unitEqual(value.apiKeySource, "env")
        try unitEqual(try Preferences.importing("model='gpt-4o-transcribe'").model, "gpt-transcribe")
        try unitEqual(try Preferences.importing("api_key_source='legacy-custom'").apiKeySource, "keychain")
        try unitEqual(try Preferences.importing(""), Preferences())
    }

    static func rejectsInvalidDocuments() throws {
        for document in ["model='unknown'", "model='gpt-transcribe'\nmodel='gpt-transcribe'",
                         "toggle_hotkey='unknown'", "toggle_hotkey='fn'\nhold_hotkey='fn'",
                         "output_mode='unknown'", "max_recording_seconds=0", "max_recording_seconds=3601",
                         "max_recording_seconds=-1", "max_recording_seconds=2.5", "max_recording_seconds='60'",
                         "api_key_source=true", "revision=-1", "[broken"] {
            try rejected { _ = try Preferences.importing(document) }
        }
        // Semantically identical shortcuts must also be rejected when their encodings differ.
        let same = HotkeyOption.defaultToggle.persistedValue
        try rejected { _ = try Preferences.importing("toggle_hotkey='option_f'\nhold_hotkey='\(same)'") }
    }

    private static func withStore(_ run: (UserDefaults, URL) throws -> Void) throws {
        let name = "com.voxa.tests.preferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: name)
            _ = defaults.synchronize()
            try? FileManager.default.removeItem(at: folder)
        }
        try run(defaults, folder.appendingPathComponent("config.toml"))
    }

    static func oneTimePersistenceAndRollback() throws {
        try withStore { defaults, url in
            let original = Data("output_mode='none'\nmax_recording_seconds=120\n".utf8)
            try original.write(to: url)
            let first = PreferencesStore(defaults: defaults, legacyURL: url)
            var value = try first.load()
            try unitEqual(value.outputMode, "none")
            try unitEqual(value.maxRecordingSeconds, 120)
            try unitEqual(try Data(contentsOf: url), original)
            value.maxRecordingSeconds = 60
            try first.save(value)
            // A later legacy run or malformed legacy file cannot overwrite the native values.
            try Data("broken TOML".utf8).write(to: url)
            let relaunched = PreferencesStore(defaults: defaults, legacyURL: url)
            try unitEqual(try relaunched.load(), value)
            let stored = defaults.data(forKey: PreferencesStore.storageKey)!
            try unitExpect(!String(decoding: stored, as: UTF8.self).contains("OPENAI_API_KEY"))
            defaults.set(Data("corrupt".utf8), forKey: PreferencesStore.storageKey)
            try rejected { _ = try relaunched.load() }
        }
    }

    static func recoverableImportAndSaveFailures() throws {
        try withStore { defaults, url in
            try Data("max_recording_seconds=0".utf8).write(to: url)
            let store = PreferencesStore(defaults: defaults, legacyURL: url)
            try rejected { _ = try store.load() }
            try unitExpect(defaults.object(forKey: PreferencesStore.storageKey) == nil)
            try Data("max_recording_seconds=30".utf8).write(to: url)
            let failing = PreferencesStore(defaults: defaults, legacyURL: url, flush: { false })
            try rejected { _ = try failing.load() }
            try unitExpect(defaults.object(forKey: PreferencesStore.storageKey) == nil)
            let value = try store.load()
            try unitEqual(value.maxRecordingSeconds, 30)
            var update = value
            update.maxRecordingSeconds = 60
            try rejected { try failing.save(update) }
            try unitEqual(try store.load(), value)
            update.holdHotkey = update.toggleHotkey
            try rejected { try store.save(update) }
            try unitEqual(try store.load(), value)
        }
        try withStore { defaults, url in
            // A clean install has no config file and must still persist valid defaults.
            try unitEqual(try PreferencesStore(defaults: defaults, legacyURL: url).load(), Preferences())
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
        ("setup: full TOML import and model/hotkey migration", completeTOMLImport),
        ("setup: invalid configuration rejected as a whole", rejectsInvalidDocuments),
        ("setup: one-time persistence, relaunch and preserved rollback", oneTimePersistenceAndRollback),
        ("setup: import/save failure recovery and clean install", recoverableImportAndSaveFailures),
        ("setup: credential sources, denied access and worker isolation", credentialSourcesAndErrors),
        ("setup: native Keychain add/read/update with disposable item", nativeKeychainRoundTrip),
    ]
}

#if !VOXA_STANDALONE_TESTS
final class NativeSetupTests: XCTestCase {
    func testCompleteTOMLImport() async throws { try await NativeSetupChecks.completeTOMLImport() }
    func testRejectsInvalidDocuments() async throws { try await NativeSetupChecks.rejectsInvalidDocuments() }
    func testOneTimePersistenceAndRollback() async throws { try await NativeSetupChecks.oneTimePersistenceAndRollback() }
    func testRecoverableImportAndSaveFailures() async throws { try await NativeSetupChecks.recoverableImportAndSaveFailures() }
    func testCredentialSourcesAndErrors() async throws { try await NativeSetupChecks.credentialSourcesAndErrors() }
    func testNativeKeychainRoundTrip() async throws { try await NativeSetupChecks.nativeKeychainRoundTrip() }
}
#endif
#endif
