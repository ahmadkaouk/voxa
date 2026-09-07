#if canImport(XCTest) || VOXA_STANDALONE_TESTS
import Foundation
import AVFoundation
#if !VOXA_STANDALONE_TESTS
import XCTest
@testable import Voxa
#endif

private final class HTTPFixture: @unchecked Sendable {
    enum Reply { case response(Int, Data), failure(URLError.Code), pending }
    let reply: Reply
    private let lock = NSLock()
    private var received: [(URLRequest, Data)] = []
    private var stopped = 0
    init(_ reply: Reply) { self.reply = reply }
    var requests: [(URLRequest, Data)] { lock.lock(); defer { lock.unlock() }; return received }
    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return stopped }
    func stop() { lock.lock(); stopped += 1; lock.unlock() }
    func record(_ request: URLRequest) {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                body.append(contentsOf: bytes.prefix(count))
            }
        }
        lock.lock(); received.append((request, body)); lock.unlock()
    }
}

private final class PipelineAudioDevice: AudioCaptureDevice {
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    func start(receive: @escaping (AVAudioPCMBuffer) -> Void, interrupted: @escaping () -> Void) throws {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800)!
        buffer.frameLength = 4800
        for channel in 0..<2 {
            for frame in 0..<4800 {
                buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 48_000) * 0.5)
            }
        }
        receive(buffer)
    }
    func stop() {}
}

/// Every URL is intercepted, including unexpected ones, so a missing fixture cannot reach a network.
private final class TranscriptionURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var fixtures: [String: HTTPFixture] = [:]
    static func register(_ fixture: HTTPFixture, host: String) {
        lock.lock(); fixtures[host] = fixture; lock.unlock()
    }
    static func remove(host: String) { lock.lock(); fixtures[host] = nil; lock.unlock() }
    private var fixture: HTTPFixture? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return Self.fixtures[request.url?.host ?? ""]
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let fixture else { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return }
        fixture.record(request)
        switch fixture.reply {
        case .response(let status, let data):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let code): client?.urlProtocol(self, didFailWithError: URLError(code))
        case .pending: break
        }
    }
    override func stopLoading() { fixture?.stop() }
}

@MainActor
enum TranscriptionClientChecks {
    private static func withClient(_ reply: HTTPFixture.Reply,
                                   body: (TranscriptionClient, HTTPFixture) async throws -> Void) async throws {
        let host = "\(UUID().uuidString.lowercased()).invalid"
        let fixture = HTTPFixture(reply)
        TranscriptionURLProtocol.register(fixture, host: host)
        let config = TranscriptionClient.configuration()
        config.protocolClasses = [TranscriptionURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); TranscriptionURLProtocol.remove(host: host) }
        try await body(TranscriptionClient(endpoint: URL(string: "https://\(host)/v1/audio/transcriptions")!, session: session), fixture)
    }

    static func multipartAndSuccess() async throws {
        let wav = Data([82, 73, 70, 70, 0, 255, 13, 10, 0, 128])
        try await withClient(.response(200, Data("{\"text\":\"  Bonjour 世界 🌍 \\n\",\"languages\":[\"fr\"]}".utf8))) { client, fixture in
            let text = try await client.transcribe(wav, model: .gptTranscribe, apiKey: "fixture-only-key")
            try unitEqual(text, "Bonjour 世界 🌍")
            try unitEqual(fixture.requests.count, 1)
            let (request, body) = fixture.requests[0]
            try unitEqual(request.httpMethod, "POST")
            try unitEqual(request.url?.path, "/v1/audio/transcriptions")
            try unitEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-only-key")
            try unitEqual(request.timeoutInterval, 60)
            let type = request.value(forHTTPHeaderField: "Content-Type")!
            try unitExpect(type.hasPrefix("multipart/form-data; boundary=Voxa-"))
            let boundary = String(type.split(separator: "=").last!)
            var expected = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\ngpt-transcribe\r\n".utf8)
            expected.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
            expected.append(wav)
            expected.append(Data("\r\n--\(boundary)--\r\n".utf8))
            try unitEqual(body, expected)
        }
        let config = TranscriptionClient.configuration()
        try unitEqual(config.timeoutIntervalForResource, 60)
        try unitExpect(config.urlCache == nil && config.urlCredentialStorage == nil && config.httpCookieStorage == nil)
        try unitExpect(!config.waitsForConnectivity)
    }

    static func responseErrors() async throws {
        let cases: [(Int, String, TranscriptionError)] = [
            (401, "secret body must not be shown", .authentication), (403, "", .authentication),
            (429, "", .rateLimited), (400, "", .request(status: 400)), (500, "", .request(status: 500)),
            (307, "", .request(status: 307)), (200, "not JSON", .invalidResponse),
            (200, "{}", .invalidResponse), (200, "{\"text\":23}", .invalidResponse),
            (200, "{\"text\":null}", .invalidResponse), (200, "{\"text\":\" \\n\"}", .emptyTranscript),
        ]
        for (status, data, expected) in cases {
            try await withClient(.response(status, Data(data.utf8))) { client, fixture in
                do { _ = try await client.transcribe(Data([1]), model: .gptTranscribe, apiKey: "fixture-key"); try unitExpect(false) }
                catch { try unitEqual(error as? TranscriptionError, expected) }
                try unitEqual(fixture.requests.count, 1) // no automatic retries
            }
        }
    }

    static func transportAndValidation() async throws {
        for (code, expected) in [(URLError.timedOut, TranscriptionError.timeout), (.notConnectedToInternet, .network), (.cannotConnectToHost, .network)] {
            try await withClient(.failure(code)) { client, fixture in
                do { _ = try await client.transcribe(Data([1]), model: .gptTranscribe, apiKey: "fixture-key"); try unitExpect(false) }
                catch { try unitEqual(error as? TranscriptionError, expected) }
                try unitEqual(fixture.requests.count, 1)
            }
        }
        try await withClient(.failure(.badURL)) { client, fixture in
            for key in ["", " \n", "bad\r\nheader"] {
                do { _ = try await client.transcribe(Data([1]), model: .gptTranscribe, apiKey: key); try unitExpect(false) }
                catch { try unitEqual(error as? TranscriptionError, .authentication) }
            }
            do { _ = try await client.transcribe(Data(), model: .gptTranscribe, apiKey: "fixture-key"); try unitExpect(false) }
            catch { try unitEqual(error as? TranscriptionError, .invalidAudio) }
            try unitEqual(fixture.requests.count, 0)
        }
        let invalid = TranscriptionClient(endpoint: URL(string: "file:///tmp/not-a-service")!)
        do { _ = try await invalid.transcribe(Data([1]), model: .gptTranscribe, apiKey: "fixture-key"); try unitExpect(false) }
        catch { try unitEqual(error as? TranscriptionError, .invalidEndpoint) }
    }

    static func cancellation() async throws {
        try await withClient(.pending) { client, fixture in
            let request = Task { try await client.transcribe(Data([1]), model: .gptTranscribe, apiKey: "fixture-key") }
            try await eventually { fixture.requests.count == 1 }
            request.cancel()
            do { _ = try await request.value; try unitExpect(false) }
            catch { try unitExpect(error is CancellationError) }
            try await eventually { fixture.stopCount == 1 }
        }
    }

    static func integratedPipeline() async throws {
        try await withClient(.response(200, Data("{\"text\":\"Fixture dictation\"}".utf8))) { client, fixture in
            let recorder = AudioRecorder(makeDevice: { PipelineAudioDevice() })
            var copied: String?
            let output = TranscriptOutput(copy: { copied = $0; return true })
            let session = DictationSession(settings: .init(outputMode: .clipboardOnly), recorder: recorder,
                                           transcriber: client, output: output)
            session.start(prepare: { "fixture-key" })
            try await eventually { if case .recording = session.state { return true }; return false }
            session.stop()
            try await eventually { !session.state.isBusy }
            try unitEqual(session.state, .idle)
            try unitEqual(session.lastOutcome, .copied)
            try unitEqual(copied, "Fixture dictation")
            try unitEqual(fixture.requests.count, 1)
            let body = fixture.requests[0].1
            let header = Data("Content-Type: audio/wav\r\n\r\n".utf8)
            guard let range = body.range(of: header) else { try unitExpect(false); return }
            let wav = body[range.upperBound..<(range.upperBound + 3244)]
            try unitEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
            try unitEqual(await recorder.snapshot().phase, .idle) // completed WAV cache was released
            await session.shutdown()
        }
    }

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("transcription: multipart bytes, Unicode response and request limits", multipartAndSuccess),
        ("transcription: HTTP, malformed and empty responses without retries", responseErrors),
        ("transcription: transport failures and input validation", transportAndValidation),
        ("transcription: URLSession cancellation", cancellation),
        ("pipeline: native recorder through URLSession and serialized output", integratedPipeline),
    ]
}

#if !VOXA_STANDALONE_TESTS
final class TranscriptionClientTests: XCTestCase {
    func testMultipartAndSuccess() async throws { try await TranscriptionClientChecks.multipartAndSuccess() }
    func testResponseErrors() async throws { try await TranscriptionClientChecks.responseErrors() }
    func testTransportAndValidation() async throws { try await TranscriptionClientChecks.transportAndValidation() }
    func testCancellation() async throws { try await TranscriptionClientChecks.cancellation() }
    func testIntegratedPipeline() async throws { try await TranscriptionClientChecks.integratedPipeline() }
}
#endif
#endif
