import Foundation

enum OllamaClientError: Error, LocalizedError {
    case invalidResponse
    case httpStatus(Int, String)
    case decodingFailed(String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from the server."
        case .httpStatus(let code, let body):
            return "HTTP \(code): \(body)"
        case .decodingFailed(let body):
            if let body, !body.isEmpty {
                return "Failed to decode response from the server. Body: \(body)"
            } else {
                return "Failed to decode response from the server."
            }
        }
    }
}

struct OllamaGenerateRequest: Encodable {
    let model: String
    let prompt: String
    let stream: Bool
    let images: [String]
}

struct OllamaGenerateResponse: Decodable {
    let response: String
}

final class OllamaClient {
    let baseURL: URL
    let model: String

    init(baseURL: URL = URL(string: "http://127.0.0.1:11434")!, model: String) {
        self.baseURL = baseURL
        self.model = model
    }

    func healthCheck() async throws {
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OllamaClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OllamaClientError.httpStatus(http.statusCode, body)
        }
    }

    func listModels() async throws -> [String] {
        let url = baseURL.appendingPathComponent("api/tags")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OllamaClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OllamaClientError.httpStatus(http.statusCode, body)
        }

        struct TagsResponse: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }

        do {
            let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
            return decoded.models.map { $0.name }
        } catch {
            let body = String(data: data, encoding: .utf8)
            throw OllamaClientError.decodingFailed(body)
        }
    }

    func describeImage(data: Data, prompt: String, model overrideModel: String? = nil) async throws -> String {
        let url = baseURL.appendingPathComponent("api/generate")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Optional: warn if the payload is very large (base64 increases size ~33%)
        let base64 = data.base64EncodedString()
        if base64.utf8.count > 10_000_000 { // ~10 MB JSON field
            #if DEBUG
            print("[OllamaClient] Warning: base64 image payload is large (\(base64.utf8.count) bytes). Consider compressing the image.")
            #endif
        }

        let payload = OllamaGenerateRequest(model: overrideModel ?? model, prompt: prompt, stream: false, images: [base64])
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw OllamaClientError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OllamaClientError.httpStatus(http.statusCode, body)
        }

        do {
            let decoded = try JSONDecoder().decode(OllamaGenerateResponse.self, from: data)
            return decoded.response.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            let body = String(data: data, encoding: .utf8)
            throw OllamaClientError.decodingFailed(body)
        }
    }
}
