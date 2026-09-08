import Foundation

/// One optional trace per recording. Never includes audio, text, credentials, or error messages.
@MainActor
final class DictationTiming {
    enum Event: String {
        case stopRequested, finalizationStarted, finalizationFinished
        case transcriptionStarted, transcriptionFinished, deliveryStarted, pasteRead, outputFinished
    }

    enum Outcome: String, Codable { case completed, failed, cancelled }

    struct Report: Codable, Sendable {
        let recordingID: UUID
        let outcome: Outcome
        let uptime: [String: TimeInterval]
        let milliseconds: [String: Double]
        let transcription: TranscriptionTiming.Report?
    }

    private let id: UUID
    private let now: () -> TimeInterval
    private var events: [Event: TimeInterval] = [:]
    let transcription = TranscriptionTiming()

    init(id: UUID, now: @escaping () -> TimeInterval) {
        self.id = id
        self.now = now
    }

    func mark(_ event: Event) {
        // Repeated Stop commands or late callbacks must not move the original timestamp.
        if events[event] == nil { events[event] = now() }
    }

    func report(outcome: Outcome) -> Report? {
        guard events[.stopRequested] != nil else { return nil }
        let intervals: [(String, Event, Event)] = [
            ("stop_dispatch", .stopRequested, .finalizationStarted),
            ("audio_finalization", .finalizationStarted, .finalizationFinished),
            ("transcription_setup", .finalizationFinished, .transcriptionStarted),
            ("transcription_request", .transcriptionStarted, .transcriptionFinished),
            ("output_setup", .transcriptionFinished, .deliveryStarted),
            ("paste_read", .deliveryStarted, .pasteRead),
            ("clipboard_cleanup", .pasteRead, .outputFinished),
            ("stop_to_paste_read", .stopRequested, .pasteRead),
            ("stop_to_output_finished", .stopRequested, .outputFinished),
        ]
        var milliseconds: [String: Double] = [:]
        for (name, from, to) in intervals {
            if let start = events[from], let end = events[to], end >= start {
                milliseconds[name] = (end - start) * 1000
            }
        }
        return Report(recordingID: id, outcome: outcome,
                      uptime: Dictionary(uniqueKeysWithValues: events.map { ($0.key.rawValue, $0.value) }),
                      milliseconds: milliseconds, transcription: transcription.report())
    }
}

/// The request delegate and session actor access this trace on different queues.
/// Only scalar measurements leave the delegate; requests, headers and addresses are never retained.
final class TranscriptionTiming: @unchecked Sendable {
    struct Report: Codable, Sendable {
        let audioBytes: Int
        let multipartBytes: Int
        var transactions: [Transaction]?
    }

    struct Transaction: Codable, Sendable {
        let milliseconds: [String: Double]
        let reusedConnection: Bool
        let proxyConnection: Bool
        let networkProtocol: String?
        let status: Int?
        let bodyBytesBeforeEncoding: Int64
        let bodyBytesSent: Int64

        init(_ metrics: URLSessionTaskTransactionMetrics) {
            let intervals: [(String, Date?, Date?)] = [
                ("pre_request", metrics.fetchStartDate, metrics.requestStartDate),
                ("dns", metrics.domainLookupStartDate, metrics.domainLookupEndDate),
                // TLS is a subset of connect; these must not be added together.
                ("connect_including_tls", metrics.connectStartDate, metrics.connectEndDate),
                ("tls", metrics.secureConnectionStartDate, metrics.secureConnectionEndDate),
                ("request_sending", metrics.requestStartDate, metrics.requestEndDate),
                ("waiting_for_response", metrics.requestEndDate, metrics.responseStartDate),
                ("response_receiving", metrics.responseStartDate, metrics.responseEndDate),
                ("total", metrics.fetchStartDate, metrics.responseEndDate),
            ]
            var durations: [String: Double] = [:]
            for (name, start, end) in intervals {
                if let start, let end, end >= start {
                    durations[name] = end.timeIntervalSince(start) * 1000
                }
            }
            milliseconds = durations
            reusedConnection = metrics.isReusedConnection
            proxyConnection = metrics.isProxyConnection
            networkProtocol = metrics.networkProtocolName.map {
                ["h3", "h2", "http/1.1", "http/1.0"].contains($0) ? $0 : "other"
            }
            status = (metrics.response as? HTTPURLResponse)?.statusCode
            bodyBytesBeforeEncoding = metrics.countOfRequestBodyBytesBeforeEncoding
            bodyBytesSent = metrics.countOfRequestBodyBytesSent
        }
    }

    private let lock = NSLock()
    private var value: Report?

    func prepare(audioBytes: Int, multipartBytes: Int) {
        lock.lock()
        defer { lock.unlock() }
        value = Report(audioBytes: audioBytes, multipartBytes: multipartBytes)
    }

    func collect(_ metrics: URLSessionTaskMetrics) {
        let transactions = metrics.transactionMetrics.map(Transaction.init)
        lock.lock()
        defer { lock.unlock() }
        value?.transactions = transactions
    }

    func report() -> Report? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

/// File work runs after delivery, on its own queue, outside every measured interval.
final class DictationTimingLog: Sendable {
    static let defaultsKey = "VoxaTimingLogPath"
    private let url: URL
    private let queue = DispatchQueue(label: "com.voxa.dictation-timing", qos: .utility)

    init(url: URL) { self.url = url }

    static func configured(defaults: UserDefaults = .standard) -> DictationTimingLog? {
        guard let path = defaults.string(forKey: defaultsKey), path.hasPrefix("/") else { return nil }
        return DictationTimingLog(url: URL(fileURLWithPath: path))
    }

    func append(_ report: DictationTiming.Report) {
        queue.async { [url] in
            do {
                var data = try JSONEncoder().encode(report)
                data.append(0x0A)
                let files = FileManager.default
                try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !files.fileExists(atPath: url.path) {
                    guard files.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                // Diagnostics must never fail or delay dictation, or expose data in an error.
                NSLog("Voxa could not write the optional timing log.")
            }
        }
    }

    func drain() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
}
