import Foundation

protocol CorrectionStoring: Sendable {
    func load() async throws -> [SavedCorrection]
    func save(_ corrections: [SavedCorrection]) async throws
}

/// Only explicit saves reach disk. Serial actor access and atomic replacement protect updates.
actor CorrectionStore: CorrectionStoring {
    private struct Document: Codable { let version: Int; let corrections: [SavedCorrection] }
    private let url: URL

    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Voxa", isDirectory: true).appendingPathComponent("corrections.json")) {
        self.url = url
    }

    func load() throws -> [SavedCorrection] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.version == 1,
              Set(document.corrections.map(\.id)).count == document.corrections.count,
              document.corrections.allSatisfy({ $0.feedback.isValid && $0.feedback.kind != .transcriptionIssue }) else {
            throw FeedbackError.invalidResponse
        }
        return document.corrections
    }

    func save(_ corrections: [SavedCorrection]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(version: 1, corrections: corrections))
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
