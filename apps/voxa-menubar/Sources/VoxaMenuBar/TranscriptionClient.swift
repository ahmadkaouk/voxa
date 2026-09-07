import Foundation

enum TranscriptionError: LocalizedError, Equatable {
    case authentication, rateLimited, request(status: Int), network, timeout
    case invalidResponse, emptyTranscript, invalidAudio, invalidEndpoint

    var errorDescription: String? {
        switch self {
        case .authentication: return "Check your transcription API key."
        case .rateLimited: return "Transcription is rate limited. Try again later."
        case .request(let status): return "Transcription request failed (HTTP \(status))."
        case .network: return "Could not connect to the transcription service."
        case .timeout: return "The transcription request timed out."
        case .invalidResponse: return "The transcription service returned an invalid response."
        case .emptyTranscript: return "No speech was detected."
        case .invalidAudio: return "There is no recorded audio to transcribe."
        case .invalidEndpoint: return "The transcription service address is invalid."
        }
    }
}

/// Nonisolated async work: multipart assembly and decoding do not run on the UI actor.
/// The key is passed for each request, never persisted or included in error messages.
struct TranscriptionClient: Sendable {
    static let defaultEndpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    static let timeout: TimeInterval = 60
    private let endpoint: URL?
    private let session: URLSession

    init(endpoint: URL? = Self.defaultEndpoint, session: URLSession? = nil) {
        self.endpoint = endpoint
        self.session = session ?? URLSession(configuration: Self.configuration())
    }

    static func configuredEndpoint(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let raw = environment["VOXA_OPENAI_TRANSCRIPTIONS_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return defaultEndpoint }
        return URL(string: raw)
    }

    static func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.waitsForConnectivity = false
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        return config
    }

    func transcribe(_ audio: Data, model: ModelOption, apiKey: String) async throws -> String {
        try Task.checkCancellation()
        guard !audio.isEmpty else { throw TranscriptionError.invalidAudio }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.utf8.contains(13), !key.utf8.contains(10) else { throw TranscriptionError.authentication }
        guard let endpoint, ["https", "http"].contains(endpoint.scheme), endpoint.host != nil else {
            throw TranscriptionError.invalidEndpoint
        }
        let boundary = "Voxa-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\n\(model.rawValue)\r\n".utf8)
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            // A redirect must not silently send this audio to a different destination.
            (data, response) = try await session.data(for: request, delegate: NoTranscriptionRedirects())
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if (error as? URLError)?.code == .timedOut { throw TranscriptionError.timeout }
            throw TranscriptionError.network
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw TranscriptionError.invalidResponse }
        switch http.statusCode {
        case 200..<300: break
        case 401, 403: throw TranscriptionError.authentication
        case 429: throw TranscriptionError.rateLimited
        default: throw TranscriptionError.request(status: http.statusCode)
        }
        struct Response: Decodable { let text: String }
        guard let parsed = try? JSONDecoder().decode(Response.self, from: data) else {
            throw TranscriptionError.invalidResponse
        }
        let text = parsed.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TranscriptionError.emptyTranscript }
        return text
    }
}

private final class NoTranscriptionRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
