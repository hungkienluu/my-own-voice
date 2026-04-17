import Foundation

public enum OllamaServiceError: LocalizedError {
    case unexpectedStatusCode(Int)
    case emptyResponse
    case invalidJSONResponse

    public var errorDescription: String? {
        switch self {
        case .unexpectedStatusCode(let code):
            return "Ollama returned HTTP \(code)."
        case .emptyResponse:
            return "Ollama returned an empty response."
        case .invalidJSONResponse:
            return "Ollama returned a response that was not valid JSON."
        }
    }
}

public actor OllamaService {
    private struct TagsResponse: Decodable {
        let models: [ModelSummary]
    }

    private struct ModelSummary: Decodable {
        let name: String
    }

    private struct GenerateRequest: Encodable {
        let model: String
        let prompt: String
        let system: String?
        let stream: Bool
    }

    private struct GenerateResponse: Decodable {
        let response: String
    }

    private struct PullRequest: Encodable {
        let model: String
        let stream: Bool
    }

    private struct PullResponse: Decodable {
        let status: String
    }

    private let baseURL: URL
    private let session: URLSession

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    public func installedModelNames() async throws -> [String] {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.httpMethod = "GET"

        let (data, response) = try await session.data(for: request)
        try validate(response: response)

        let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
        return decoded.models.map(\.name)
    }

    public func generate(
        model: String,
        system: String? = nil,
        prompt: String
    ) async throws -> String {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            GenerateRequest(
                model: model,
                prompt: prompt,
                system: system,
                stream: false
            )
        )

        let (data, response) = try await session.data(for: request)
        try validate(response: response)

        let decoded = try JSONDecoder().decode(GenerateResponse.self, from: data)
        let trimmed = decoded.response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw OllamaServiceError.emptyResponse
        }

        return trimmed
    }

    public func generateJSON<T: Decodable>(
        model: String,
        system: String? = nil,
        prompt: String,
        as type: T.Type = T.self
    ) async throws -> T {
        let response = try await generate(
            model: model,
            system: system,
            prompt: prompt
        )
        return try decodeJSON(type, from: response)
    }

    public func pull(model: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            PullRequest(
                model: model,
                stream: false
            )
        )

        let (data, response) = try await session.data(for: request)
        try validate(response: response)

        _ = try JSONDecoder().decode(PullResponse.self, from: data)
    }

    private func validate(response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw OllamaServiceError.unexpectedStatusCode(httpResponse.statusCode)
        }
    }

    private func decodeJSON<T: Decodable>(
        _ type: T.Type,
        from response: String
    ) throws -> T {
        let decoder = JSONDecoder()

        if let directData = response.data(using: .utf8),
           let direct = try? decoder.decode(type, from: directData) {
            return direct
        }

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let candidates = [
            Self.extractJSONObject(from: trimmed),
            Self.extractJSONArray(from: trimmed)
        ].compactMap { $0 }

        for candidate in candidates {
            guard let data = candidate.data(using: .utf8) else { continue }
            if let decoded = try? decoder.decode(type, from: data) {
                return decoded
            }
        }

        throw OllamaServiceError.invalidJSONResponse
    }

    private static func extractJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else {
            return nil
        }

        return String(text[start...end])
    }

    private static func extractJSONArray(from text: String) -> String? {
        guard let start = text.firstIndex(of: "["),
              let end = text.lastIndex(of: "]") else {
            return nil
        }

        return String(text[start...end])
    }
}
