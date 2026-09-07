#if canImport(XCTest) || VOXA_STANDALONE_TESTS
import Foundation
#if !VOXA_STANDALONE_TESTS
import XCTest
@testable import VoxaMenuBar
#endif

@MainActor
enum LegacyLaunchAgentChecks {
    private static func withHome(_ run: (URL, URL) throws -> Void) throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("voxa-upgrade-\(UUID().uuidString)")
        let file = home.appendingPathComponent("Library/LaunchAgents/com.voxa.daemon.plist")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try run(home, file)
    }
    private static func plist(_ overrides: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = ["Label": "com.voxa.daemon", "ProgramArguments": ["/Applications/Voxa.app/Contents/Resources/bin/voxa-daemon"], "RunAtLoad": true]
        value.merge(overrides) { _, new in new }
        return try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }
    private static func rejected(_ run: () throws -> Void) throws {
        var failed = false
        do { try run() } catch { failed = true }
        try unitExpect(failed)
    }

    static func retirementAndRelaunch() throws {
        try withHome { home, file in
            let original = try plist()
            try original.write(to: file)
            let config = home.appendingPathComponent("Library/LaunchAgents/unrelated.plist")
            try Data("unrelated".utf8).write(to: config)
            var loaded = true
            var commands: [String] = []
            var inspections = 0
            try LegacyLaunchAgent.retire(home: home, checkStopped: { inspections += 1 }) { path, args in
                try unitEqual(path, "/bin/launchctl")
                try unitEqual(args.count, 2)
                try unitEqual(args[1], "gui/\(getuid())/com.voxa.daemon")
                commands.append(args[0])
                if args[0] == "bootout" { loaded = false; return 0 }
                return loaded ? 0 : 113
            }
            try unitEqual(commands, ["print", "bootout", "print"])
            try unitEqual(inspections, 3)
            try unitExpect(!FileManager.default.fileExists(atPath: file.path))
            let archive = home.appendingPathComponent("Library/Application Support/voxa/migration")
            let files = try FileManager.default.contentsOfDirectory(at: archive, includingPropertiesForKeys: nil)
            try unitEqual(files.count, 1)
            try unitEqual(try Data(contentsOf: files[0]), original)
            try unitEqual(try String(contentsOf: config), "unrelated")
            // Repeated native startup is a no-op; a legacy rollback may recreate the plist.
            try LegacyLaunchAgent.retire(home: home, checkStopped: {}) { _, args in
                try unitEqual(args[0], "print"); return 113
            }
            try original.write(to: file)
            try LegacyLaunchAgent.retire(home: home, checkStopped: {}) { _, args in
                try unitEqual(args[0], "print"); return 113
            }
            try unitEqual(try FileManager.default.contentsOfDirectory(atPath: archive.path).count, 2)
        }
    }

    static func refusesActiveAndUnknownServices() throws {
        try withHome { home, file in
            let original = try plist()
            try original.write(to: file)
            try rejected {
                try LegacyLaunchAgent.retire(home: home, checkStopped: { throw CocoaError(.userCancelled) }) { _, _ in
                    try unitExpect(false); return 0
                }
            }
            try unitEqual(try Data(contentsOf: file), original)
            for invalid in [try plist(["Label": "unrelated"]), try plist(["Program": "/bin/sh"]),
                            try plist(["ProgramArguments": ["/bin/sh", "-c", "echo nope"]]),
                            try plist(["ProgramArguments": ["/unrelated/voxa-daemon"]]), Data("not a plist".utf8)] {
                try invalid.write(to: file)
                try rejected {
                    try LegacyLaunchAgent.retire(home: home, checkStopped: {}) { _, _ in
                        try unitExpect(false); return 0
                    }
                }
                try unitEqual(try Data(contentsOf: file), invalid)
            }
            try original.write(to: file)
            try rejected {
                try LegacyLaunchAgent.retire(home: home, uid: getuid() + 1, checkStopped: {}) { _, _ in
                    try unitExpect(false); return 0
                }
            }
            let target = file.deletingLastPathComponent().appendingPathComponent("preserve.plist")
            try FileManager.default.moveItem(at: file, to: target)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
            try rejected { try LegacyLaunchAgent.retire(home: home, checkStopped: {}) { _, _ in 0 } }
            try unitEqual(try Data(contentsOf: target), original)
        }
        try withHome { home, _ in
            // No ownership evidence for an already loaded job: leave it alone and fail setup.
            try rejected { try LegacyLaunchAgent.retire(home: home, checkStopped: {}) { _, _ in 0 } }
            try LegacyLaunchAgent.retire(home: home, checkStopped: {}) { _, _ in 113 }
        }
    }

    static func failuresAndConcurrentChanges() throws {
        try withHome { home, file in
            let original = try plist()
            for failAt in [0, 1, 2] {
                try original.write(to: file)
                var index = 0
                try rejected {
                    try LegacyLaunchAgent.retire(home: home, checkStopped: {}) { _, _ in
                        defer { index += 1 }
                        return index == failAt ? 1 : 0
                    }
                }
                try unitEqual(try Data(contentsOf: file), original)
            }
            try original.write(to: file)
            let changed = try plist(["RunAtLoad": false])
            var calls = 0
            try rejected {
                try LegacyLaunchAgent.retire(home: home, checkStopped: {}) { _, _ in
                    calls += 1
                    if calls == 2 { try changed.write(to: file) }
                    return 113
                }
            }
            try unitEqual(try Data(contentsOf: file), changed)
            try original.write(to: file)
            var checks = 0
            try rejected {
                try LegacyLaunchAgent.retire(home: home, checkStopped: {
                    checks += 1
                    if checks == 2 { throw CocoaError(.userCancelled) }
                }) { _, args in
                    try unitEqual(args[0], "print"); return 0
                }
            }
            try unitEqual(try Data(contentsOf: file), original)
        }
    }

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("upgrade: owned LaunchAgent retirement, archive and relaunch", retirementAndRelaunch),
        ("upgrade: active recorder, unknown services and symlinks preserved", refusesActiveAndUnknownServices),
        ("upgrade: unregister failures and concurrent changes block capture", failuresAndConcurrentChanges),
    ]
}
#if !VOXA_STANDALONE_TESTS
final class LegacyLaunchAgentTests: XCTestCase {
    func testRetirementAndRelaunch() async throws { try await LegacyLaunchAgentChecks.retirementAndRelaunch() }
    func testRefusesActiveAndUnknownServices() async throws { try await LegacyLaunchAgentChecks.refusesActiveAndUnknownServices() }
    func testFailuresAndConcurrentChanges() async throws { try await LegacyLaunchAgentChecks.failuresAndConcurrentChanges() }
}
#endif
#endif
