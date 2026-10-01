import AppKit
import ApplicationServices
import Carbon

struct ContextExcludedApp: Codable, Equatable, Identifiable {
    let bundleID: String
    let name: String
    var id: String { bundleID }
}

/// Ephemeral input, deliberately not Codable: it never belongs in lessons or progress history.
struct FeedbackTextContext: Equatable, Sendable {
    static let maximumLength = 2_400 // UTF-16 units, shared by extraction and request construction.
    enum Source: String, Sendable { case editor, nearbyText }
    let appName: String
    let source: Source
    let text: String

    init?(appName: String, source: Source, text: String) {
        let text = Self.clean(text, limit: Self.maximumLength)
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        self.appName = Self.clean(appName, limit: 80)
        self.source = source
        self.text = text
    }

    static func clean(_ text: String, limit: Int) -> String {
        // NSString ranges from Accessibility use UTF-16, not Swift character offsets.
        var units = Array(text.utf16.prefix(max(0, limit)))
        if let last = units.last, (0xD800...0xDBFF).contains(last) { units.removeLast() }
        let prefix = String(decoding: units, as: UTF16.self)
        return String(prefix.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
        }).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A capture may finish while recording, but the session never waits for it.
@MainActor
final class TextContextCapture {
    private var task: Task<Void, Never>?
    private(set) var result: FeedbackTextContext?

    init(operation: @escaping @MainActor () async -> FeedbackTextContext?) {
        task = Task { [weak self] in
            let result = await operation()
            guard !Task.isCancelled else { return }
            self?.result = result
            self?.task = nil
        }
    }

    func take() -> FeedbackTextContext? {
        defer { cancel() }
        return result
    }

    func cancel() { task?.cancel(); task = nil; result = nil }
    deinit { task?.cancel() }
}

@MainActor
protocol TextContextCapturing {
    func start(excluding bundleIDs: Set<String>) -> TextContextCapture?
}

struct AccessibilityTextContext: TextContextCapturing {
    static let protectedApps: Set<String> = [
        "com.apple.keychainaccess", "com.apple.Passwords", "com.agilebits.onepassword7",
        "com.1password.1password", "com.bitwarden.desktop", "com.dashlane.Dashlane",
    ]

    @MainActor
    func start(excluding bundleIDs: Set<String>) -> TextContextCapture? {
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(),
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid(), let bundleID = app.bundleIdentifier,
              !bundleIDs.contains(bundleID), !Self.protectedApps.contains(bundleID) else { return nil }
        // Freeze the app before VOXA's overlay is updated. No AX IPC runs on the main thread.
        let pid = app.processIdentifier, name = app.localizedName ?? "Current app"
        return TextContextCapture {
            let worker = Task.detached(priority: .utility) { () -> FeedbackTextContext? in
                let reader = AXContextReader()
                let application = AXUIElementCreateApplication(pid)
                return ContextTextExtractor(reader: reader).capture(application: application, appName: name)
            }
            return await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() })
        }
    }
}

/// A narrow read-only AX boundary, also exercised by synthetic editor/conversation trees.
protocol ContextAccessibilityReading {
    associatedtype Element: Equatable
    var canRead: Bool { get }
    func string(_ node: Element, _ attribute: String) -> String?
    func number(_ node: Element, _ attribute: String) -> Int?
    func flag(_ node: Element, _ attribute: String) -> Bool?
    func element(_ node: Element, _ attribute: String) -> Element?
    func children(_ node: Element, limit: Int) -> [Element]
    func frame(_ node: Element) -> CGRect?
    func range(_ node: Element, _ attribute: String) -> CFRange?
    func text(_ node: Element, range: CFRange) -> String?
}

struct ContextTextExtractor<Reader: ContextAccessibilityReading> {
    let reader: Reader
    private let ignoredRoles: Set<String> = [kAXMenuRole, kAXMenuBarRole, kAXToolbarRole,
        kAXButtonRole, kAXPopUpButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXImageRole]

    func capture(application: Reader.Element, appName: String) -> FeedbackTextContext? {
        guard reader.flag(application, kAXFrontmostAttribute) == true,
              let focused = reader.element(application, kAXFocusedUIElementAttribute),
              let window = reader.element(application, kAXFocusedWindowAttribute) else { return nil }
        let snapshot = extract(focused: focused, window: window, appName: appName)
        // Switching apps, fields or windows during the read invalidates the snapshot.
        guard reader.canRead, reader.flag(application, kAXFrontmostAttribute) == true,
              reader.element(application, kAXFocusedWindowAttribute) == window,
              reader.element(application, kAXFocusedUIElementAttribute) == focused else { return nil }
        return snapshot
    }

    func extract(focused: Reader.Element, window: Reader.Element, appName: String) -> FeedbackTextContext? {
        guard reader.canRead, !protected(focused),
              let role = reader.string(focused, kAXRoleAttribute),
              role == kAXTextAreaRole || role == kAXTextFieldRole else { return nil }
        let draft = editorText(focused)
        // Single-line inputs (including searches) never trigger a window traversal.
        guard role == kAXTextAreaRole,
              let focusFrame = reader.frame(focused), usable(focusFrame),
              let windowFrame = reader.frame(window), usable(windowFrame) else {
            return FeedbackTextContext(appName: appName, source: .editor, text: draft)
        }
        // Long editor content is already a better signal than unrelated window text.
        if draft.utf16.count >= FeedbackTextContext.maximumLength / 2 {
            return FeedbackTextContext(appName: appName, source: .editor, text: draft)
        }
        let region = CGRect(x: focusFrame.minX, y: max(windowFrame.minY, focusFrame.minY - 700),
                            width: focusFrame.width, height: min(700, max(0, focusFrame.minY - windowFrame.minY)))
            .intersection(windowFrame)
        guard usable(region) else { return FeedbackTextContext(appName: appName, source: .editor, text: draft) }

        // Prefer a containing conversation pane over the whole window. Geometry then prunes
        // sidebars and text below the editor; no scrolling, focus changes or clipboard reads.
        var root = focused, ancestors: [Reader.Element] = [focused]
        for _ in 0..<8 {
            guard reader.canRead, let parent = reader.element(root, kAXParentAttribute), !ancestors.contains(parent) else { break }
            root = parent; ancestors.append(parent)
            if parent == window { break }
            if let rect = reader.frame(parent), rect.intersection(region).height >= 100 { break }
        }
        guard root != focused else { return FeedbackTextContext(appName: appName, source: .editor, text: draft) }
        var queue: [(Reader.Element, Int)] = [(root, 0)], visited: [Reader.Element] = []
        var excerpts: [(CGRect, Int, String)] = []
        var cursor = 0
        while cursor < queue.count, visited.count < 160, reader.canRead {
            let (node, depth) = queue[cursor]; cursor += 1
            guard node != focused, !visited.contains(node) else { continue }
            visited.append(node)
            guard !protected(node), let nodeRole = reader.string(node, kAXRoleAttribute),
                  !ignoredRoles.contains(nodeRole), nodeRole != kAXTextFieldRole else { continue }
            let rect = reader.frame(node)
            if let rect, usable(rect), !rect.intersects(region) { continue }
            if nodeRole == kAXStaticTextRole, let rect, usable(rect),
               rect.intersects(region), rect.midX >= region.minX, rect.midX <= region.maxX {
                let value = reader.string(node, kAXValueAttribute) ?? ""
                let text = FeedbackTextContext.clean(value, limit: 800)
                if !text.isEmpty { excerpts.append((rect, cursor, text)) }
                continue
            }
            // Other editor contents are never included by the nearby-message traversal.
            if nodeRole == kAXTextAreaRole { continue }
            guard depth < 14, queue.count < 200 else { continue }
            queue += reader.children(node, limit: min(80, 200 - queue.count)).map { ($0, depth + 1) }
        }
        // Closest visible messages win the budget, then return them in reading order.
        let available = max(0, FeedbackTextContext.maximumLength - draft.utf16.count - 40)
        var remaining = available, selected: [(CGRect, Int, String)] = [], seen = Set<String>()
        for item in excerpts.sorted(by: { $0.0.maxY == $1.0.maxY ? $0.1 > $1.1 : $0.0.maxY > $1.0.maxY }) {
            guard remaining > 0, seen.insert(item.2).inserted else { continue }
            let text = FeedbackTextContext.clean(item.2, limit: remaining)
            remaining -= text.utf16.count + 1
            selected.append((item.0, item.1, text))
        }
        let nearby = selected.sorted { $0.0.minY == $1.0.minY ? $0.1 < $1.1 : $0.0.minY < $1.0.minY }
            .map(\.2).joined(separator: "\n")
        let parts = [nearby.isEmpty ? nil : "Nearby visible text:\n" + nearby,
                     draft.isEmpty ? nil : "Text in the editor:\n" + draft].compactMap { $0 }
        return FeedbackTextContext(appName: appName, source: nearby.isEmpty ? .editor : .nearbyText,
                                   text: parts.joined(separator: "\n\n"))
    }

    private func protected(_ node: Reader.Element) -> Bool {
        let subrole = reader.string(node, kAXSubroleAttribute)
        return subrole == kAXSecureTextFieldSubrole || subrole == kAXSearchFieldSubrole
    }

    private func usable(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.width > 0 && rect.height > 0
    }

    private func editorText(_ node: Reader.Element) -> String {
        let count = reader.number(node, kAXNumberOfCharactersAttribute)
        if let count, count > 0, let selection = reader.range(node, kAXSelectedTextRangeAttribute),
           selection.location >= 0, selection.location <= count {
            let start = max(0, selection.location - 1_600)
            let proposed = CFRange(location: start, length: min(FeedbackTextContext.maximumLength, count - start))
            var selected = NSRange(location: proposed.location, length: proposed.length)
            if let visible = reader.range(node, kAXVisibleCharacterRangeAttribute),
               visible.location >= 0, visible.length > 0, visible.location <= count,
               visible.length <= count - visible.location {
                selected = NSIntersectionRange(selected, NSRange(location: visible.location, length: visible.length))
            }
            if selected.length > 0,
               let text = reader.text(node, range: CFRange(location: selected.location, length: selected.length)) {
                return FeedbackTextContext.clean(text, limit: FeedbackTextContext.maximumLength)
            }
        }
        // Avoid requesting the complete contents of a large document when range reads fail.
        if let count, !(0...FeedbackTextContext.maximumLength).contains(count) { return "" }
        return FeedbackTextContext.clean(reader.string(node, kAXValueAttribute) ?? "", limit: FeedbackTextContext.maximumLength)
    }
}

/// All methods run on one detached worker. Every IPC has a timeout and the entire read has a budget.
final class AXContextReader: ContextAccessibilityReading {
    private let deadline = ProcessInfo.processInfo.systemUptime + 0.45
    private var reads = 0
    var canRead: Bool { !Task.isCancelled && reads < 650 && ProcessInfo.processInfo.systemUptime < deadline }

    private func prepare(_ node: AXUIElement) -> Bool {
        guard canRead else { return false }
        reads += 1
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return false }
        return AXUIElementSetMessagingTimeout(node, Float(min(0.035, remaining))) == .success
    }
    private func value(_ node: AXUIElement, _ attribute: String) -> CFTypeRef? {
        guard prepare(node) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, attribute as CFString, &value) == .success else { return nil }
        return value
    }
    func string(_ node: AXUIElement, _ attribute: String) -> String? { value(node, attribute) as? String }
    func number(_ node: AXUIElement, _ attribute: String) -> Int? { value(node, attribute) as? Int }
    func flag(_ node: AXUIElement, _ attribute: String) -> Bool? { value(node, attribute) as? Bool }
    func element(_ node: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let value = value(node, attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    func children(_ node: AXUIElement, limit: Int) -> [AXUIElement] {
        guard limit > 0 else { return [] }
        // Some providers expose only AXChildren. Geometry still filters those children locally.
        for attribute in [kAXVisibleChildrenAttribute, kAXChildrenAttribute] {
            guard prepare(node) else { return [] }
            var values: CFArray?
            if AXUIElementCopyAttributeValues(node, attribute as CFString, 0, limit, &values) == .success,
               let elements = values as? [AXUIElement], !elements.isEmpty { return elements }
        }
        return []
    }
    func frame(_ node: AXUIElement) -> CGRect? {
        guard let position = value(node, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = value(node, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point),
              AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }
    func range(_ node: AXUIElement, _ attribute: String) -> CFRange? {
        guard let value = value(node, attribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
    }
    func text(_ node: AXUIElement, range: CFRange) -> String? {
        guard prepare(node) else { return nil }
        var range = range, value: CFTypeRef?
        guard let parameter = AXValueCreate(.cfRange, &range),
              AXUIElementCopyParameterizedAttributeValue(node, kAXStringForRangeParameterizedAttribute as CFString,
                                                        parameter, &value) == .success else { return nil }
        return value as? String
    }
}
