#if canImport(XCTest) || VOXA_STANDALONE_TESTS
import Foundation

private struct UnitCheckFailure: Error, CustomStringConvertible {
    let description: String
}

func unitExpect(_ condition: @autoclosure () -> Bool, file: StaticString = #fileID, line: UInt = #line) throws {
    guard condition() else {
        throw UnitCheckFailure(description: "\(file):\(line): expectation failed")
    }
}

func unitEqual<T: Equatable>(_ actual: T, _ expected: T, file: StaticString = #fileID, line: UInt = #line) throws {
    guard actual == expected else {
        throw UnitCheckFailure(description: "\(file):\(line): expected \(expected), got \(actual)")
    }
}

#if VOXA_UNIT_TEST_RUNNER
@main
private enum UnitChecksRunner {
    static func main() {
        let checks = HotkeyOptionChecks.all + IPCClientChecks.all + PopoverPrimaryActionChecks.all
        do {
            for (name, check) in checks {
                try check()
                print("PASS: \(name)")
            }
            print("All \(checks.count) Swift unit checks passed")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}
#endif
#endif
