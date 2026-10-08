#if canImport(XCTest) || VOXA_STANDALONE_TESTS
import Foundation
import Security
import CoreGraphics
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

    static func submitShortcutMigration() throws {
        for legacy in ["option_g", "right_option", "option_f",
                       HotkeyOption(keyCodes: [KeyCode.returnKey], modifiers: []).persistedValue] {
            var old = savedPreferences
            old["toggleHotkey"] = "option_f"; old["holdHotkey"] = legacy
            old["englishFeedbackEnabled"] = true; old["automaticContextEnabled"] = true
            let data = try JSONSerialization.data(withJSONObject: old)
            let migrated = try JSONDecoder().decode(Preferences.self, from: data).validated()
            let submit = HotkeyOption.fromRaw(migrated.finishAndSubmitHotkey)!
            try unitExpect(submit.isValidForSubmit && !submit.overlaps(.optionF))
            try unitExpect(migrated.englishFeedbackEnabled && migrated.automaticContextEnabled)
            try unitEqual(migrated.toggleHotkey, "option_f")
            let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(migrated)) as! [String: Any]
            try unitExpect(encoded["holdHotkey"] == nil && encoded["finishAndSubmitHotkey"] != nil)
            try unitEqual(try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(migrated)), migrated)
        }
    }

    static func globalShortcutRouting() async throws {
        let bridge = GlobalHotkeyBridge()
        var submits = 0, toggles = 0, canSubmit = false
        bridge.onFinishAndSubmit = { submits += 1; return canSubmit }
        bridge.onToggleActivated = { toggles += 1 }
        bridge.updateBindings(toggle: .optionF, finishAndSubmit: .optionG)
        func swallowed(_ key: UInt16, down: Bool = true, flags: CGEventFlags = [], repeated: Bool = false) -> Bool {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)!
            event.flags = flags
            event.setIntegerValueField(.keyboardEventAutorepeat, value: repeated ? 1 : 0)
            return bridge.handleTapEvent(type: down ? .keyDown : .keyUp, event: event) == nil
        }
        for key: UInt16 in [KeyCode.returnKey, 76] {
            try unitExpect(!swallowed(key)); try unitExpect(!swallowed(key, down: false))
        }
        var recording = false, review = false, cancelled = 0, discarded = 0, saved = 0
        bridge.onCancelDictation = {
            guard recording else { return false }
            cancelled += 1; recording = false; return true
        }
        bridge.onDiscardFeedback = {
            guard review else { return false }
            discarded += 1; review = false; return true
        }
        bridge.onSaveFeedback = {
            guard review else { return false }
            saved += 1; review = false; return true
        }
        try unitExpect(!swallowed(KeyCode.escape))
        _ = swallowed(KeyCode.escape, down: false)
        try unitExpect(!swallowed(KeyCode.s, flags: .maskCommand))
        _ = swallowed(KeyCode.s, down: false)
        recording = true; review = true
        try unitExpect(!swallowed(KeyCode.escape, flags: .maskCommand))
        _ = swallowed(KeyCode.escape, down: false)
        try unitExpect(swallowed(KeyCode.escape))
        try unitEqual(cancelled, 1); try unitEqual(discarded, 0) // Recording takes priority.
        try unitExpect(swallowed(KeyCode.escape, repeated: true))
        try unitExpect(swallowed(KeyCode.escape, down: false))
        try unitExpect(swallowed(KeyCode.escape))
        try unitEqual(discarded, 1)
        try unitExpect(swallowed(KeyCode.escape, down: false))
        review = true
        try unitExpect(!swallowed(KeyCode.s)); _ = swallowed(KeyCode.s, down: false)
        try unitExpect(!swallowed(KeyCode.d)); _ = swallowed(KeyCode.d, down: false)
        try unitExpect(swallowed(KeyCode.s, flags: .maskCommand))
        try unitExpect(swallowed(KeyCode.s, repeated: true))
        try unitExpect(swallowed(KeyCode.s, down: false))
        try unitEqual(saved, 1)
        try unitExpect(!swallowed(KeyCode.s, flags: .maskCommand))
        _ = swallowed(KeyCode.s, down: false)
        try unitEqual(submits, 0)
        try unitExpect(!swallowed(KeyCode.g, flags: .maskAlternate))
        try unitExpect(!swallowed(KeyCode.g, down: false))
        try unitEqual(submits, 1)
        await Task.yield(); try unitEqual(toggles, 0) // The retired hold binding cannot start recording.
        canSubmit = true
        try unitExpect(swallowed(KeyCode.g, flags: .maskAlternate))
        canSubmit = false
        try unitExpect(swallowed(KeyCode.g, repeated: true))
        try unitExpect(swallowed(KeyCode.g, down: false))
        try unitEqual(submits, 2)
        try unitExpect(swallowed(KeyCode.f, flags: .maskAlternate))
        _ = swallowed(KeyCode.f, down: false)
        try await eventually { toggles == 1 }
        let custom = HotkeyOption(keyCodes: [KeyCode.returnKey], modifiers: [.command, .control])
        bridge.updateBindings(toggle: .optionF, finishAndSubmit: custom)
        canSubmit = true
        try unitExpect(!swallowed(KeyCode.g, flags: .maskAlternate))
        _ = swallowed(KeyCode.g, down: false)
        try unitExpect(!swallowed(KeyCode.returnKey)); _ = swallowed(KeyCode.returnKey, down: false)
        try unitExpect(swallowed(KeyCode.returnKey, flags: [.maskCommand, .maskControl]))
        try unitExpect(swallowed(KeyCode.returnKey, down: false))
        try unitEqual(submits, 3)
        bridge.setEnabled(false)
        try unitExpect(!swallowed(KeyCode.returnKey, flags: [.maskCommand, .maskControl]))
        _ = swallowed(KeyCode.returnKey, down: false)
        try unitEqual(submits, 3)
        bridge.stop()
    }

    static func configurableFeedbackShortcuts() async throws {
        let bridge = GlobalHotkeyBridge()
        let save = HotkeyOption(keyCodes: [KeyCode.d], modifiers: [.command, .shift])
        let cancel = HotkeyOption(keyCodes: [KeyCode.escape], modifiers: .control)
        bridge.updateBindings(toggle: .optionF, finishAndSubmit: .optionG, saveFeedback: save, cancel: cancel)
        var review = true, recording = false, saves = 0, cancels = 0
        bridge.onSaveFeedback = { guard review else { return false }; saves += 1; review = false; return true }
        bridge.onCancelDictation = { guard recording else { return false }; cancels += 1; recording = false; return true }
        func swallowed(_ key: UInt16, down: Bool = true, flags: CGEventFlags = [], repeated: Bool = false) -> Bool {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)!
            event.flags = flags
            event.setIntegerValueField(.keyboardEventAutorepeat, value: repeated ? 1 : 0)
            return bridge.handleTapEvent(type: down ? .keyDown : .keyUp, event: event) == nil
        }
        for reset in [false, true] {
            if reset { bridge.resetForSystemInterruption(); bridge.stop() }
            review = true
            try unitExpect(!swallowed(KeyCode.s, flags: .maskCommand)); _ = swallowed(KeyCode.s, down: false)
            try unitExpect(!swallowed(KeyCode.d)); _ = swallowed(KeyCode.d, down: false)
            try unitExpect(swallowed(KeyCode.d, flags: [.maskCommand, .maskShift]))
            try unitExpect(swallowed(KeyCode.d, repeated: true))
            try unitExpect(swallowed(KeyCode.d, down: false))
            try unitExpect(!swallowed(KeyCode.d, flags: [.maskCommand, .maskShift]))
            _ = swallowed(KeyCode.d, down: false)
            recording = true
            try unitExpect(!swallowed(KeyCode.escape)); _ = swallowed(KeyCode.escape, down: false)
            try unitExpect(swallowed(KeyCode.escape, flags: .maskControl))
            try unitExpect(swallowed(KeyCode.escape, down: false))
        }
        try unitEqual(saves, 2); try unitEqual(cancels, 2)
        bridge.setEnabled(false) // Recording a replacement shortcut must pass through to the recorder.
        review = true
        try unitExpect(!swallowed(KeyCode.d, flags: [.maskCommand, .maskShift]))
        _ = swallowed(KeyCode.d, down: false)
        try unitEqual(saves, 2)
        bridge.stop()

        try withStore { defaults in
            var preferences = Preferences()
            preferences.saveFeedbackHotkey = save.persistedValue
            preferences.cancelHotkey = cancel.persistedValue
            let store = PreferencesStore(defaults: defaults)
            try store.save(preferences)
            try unitEqual(try PreferencesStore(defaults: defaults).load(), preferences)
            for invalid in [HotkeyOption(keyCodes: [KeyCode.d], modifiers: []), .defaultToggle, .rightOption, cancel] {
                var changed = preferences
                changed.saveFeedbackHotkey = invalid.persistedValue
                try rejected { try store.save(changed) }
                try unitEqual(try store.load(), preferences)
            }
            var changed = preferences
            changed.cancelHotkey = HotkeyOption(keyCodes: [KeyCode.d], modifiers: []).persistedValue
            try rejected { try store.save(changed) }
            changed.cancelHotkey = HotkeyOption.defaultCancel.persistedValue
            try store.save(changed)
        }
        // Legacy users who assigned Cmd-S or Esc to dictation keep those bindings.
        for existing in [HotkeyOption.defaultSaveFeedback, .defaultCancel, .rightOption] {
            var old = savedPreferences
            old["toggleHotkey"] = existing.persistedValue
            old["finishAndSubmitHotkey"] = HotkeyOption(keyCodes: [KeyCode.g], modifiers: .control).persistedValue
            let migrated = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: old)).validated()
            try unitEqual(HotkeyOption.fromRaw(migrated.toggleHotkey), existing)
            try unitExpect(!HotkeyOption.fromRaw(migrated.saveFeedbackHotkey)!.overlaps(existing))
            try unitExpect(!HotkeyOption.fromRaw(migrated.cancelHotkey)!.overlaps(existing))
        }
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
            try unitEqual(value.finishAndSubmitHotkey, "fn_space")
            try unitEqual(value.model, "gpt-transcribe")
            try unitEqual(value.outputMode, "none")
            try unitEqual(value.maxRecordingSeconds, 120)
            try unitEqual(value.apiKeySource, "env")
            try unitExpect(!value.englishFeedbackEnabled)
            try unitEqual(defaults.data(forKey: PreferencesStore.storageKey), original)
            value.maxRecordingSeconds = 60
            value.englishFeedbackEnabled = true
            try store.save(value)
            try unitEqual(try PreferencesStore(defaults: defaults).load(), value)
        }
    }

    static func legacyFeedbackTimerIsIgnored() throws {
        try withStore { defaults in
            var legacy = savedPreferences
            legacy["englishFeedbackEnabled"] = true
            legacy["automaticContextEnabled"] = true
            legacy["contextExcludedApps"] = [["bundleID": "example.private", "name": "Private workspace"]]
            let expected = try JSONDecoder().decode(Preferences.self,
                from: JSONSerialization.data(withJSONObject: legacy)).validated()
            let store = PreferencesStore(defaults: defaults)
            // The retired field is ignored regardless of its old duration or representation.
            for retiredValue: Any in [0, 5, 30, 300, -1, "retired", NSNull()] {
                legacy["feedbackAutoCloseSeconds"] = retiredValue
                let original = try JSONSerialization.data(withJSONObject: ["version": 1, "preferences": legacy])
                defaults.set(original, forKey: PreferencesStore.storageKey)
                let loaded = try store.load()
                try unitEqual(loaded, expected)
                try unitEqual(defaults.data(forKey: PreferencesStore.storageKey), original)
                try store.save(loaded)
                let upgraded = try JSONSerialization.jsonObject(with: defaults.data(forKey: PreferencesStore.storageKey)!) as? [String: Any]
                let upgradedPreferences = upgraded?["preferences"] as? [String: Any]
                try unitExpect(upgradedPreferences != nil)
                try unitExpect(upgradedPreferences?["feedbackAutoCloseSeconds"] == nil)
                try unitEqual(try PreferencesStore(defaults: defaults).load(), expected)
            }
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
            for (key, value) in [("toggleHotkey", "unknown"), ("finishAndSubmitHotkey", savedPreferences["toggleHotkey"]!),
                                 ("finishAndSubmitHotkey", "unknown"), ("finishAndSubmitHotkey", "right_option"),
                                 ("finishAndSubmitHotkey", HotkeyOption(keyCodes: [KeyCode.returnKey], modifiers: []).persistedValue),
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
            update.finishAndSubmitHotkey = update.toggleHotkey
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
        ("setup: legacy feedback timer is ignored and omitted on save", legacyFeedbackTimerIsIgnored),
        ("setup: retired hold shortcut migrates without losing enabled features", submitShortcutMigration),
        ("shortcuts: plain Enter passes through and Finish & Send is contextual", globalShortcutRouting),
        ("shortcuts: custom feedback bindings route, persist, and migrate without conflicts", configurableFeedbackShortcuts),
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
    func testLegacyFeedbackTimerIsIgnored() async throws { try await NativeSetupChecks.legacyFeedbackTimerIsIgnored() }
    func testSubmitShortcutMigration() async throws { try await NativeSetupChecks.submitShortcutMigration() }
    func testGlobalShortcutRouting() async throws { try await NativeSetupChecks.globalShortcutRouting() }
    func testConfigurableFeedbackShortcuts() async throws { try await NativeSetupChecks.configurableFeedbackShortcuts() }
    func testSaveFailureRecovery() async throws { try await NativeSetupChecks.saveFailureRecovery() }
    func testCredentialSourcesAndErrors() async throws { try await NativeSetupChecks.credentialSourcesAndErrors() }
    func testNativeKeychainRoundTrip() async throws { try await NativeSetupChecks.nativeKeychainRoundTrip() }
}
#endif
#endif
