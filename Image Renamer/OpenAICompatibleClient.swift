import Foundation

enum OpenAICompatibleClientError: Error, LocalizedError {
    case invalidResponse
    case httpStatus(Int, String)
    case decodingFailed(String?)
    case missingContent

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
        case .missingContent:
            return "The server response did not include any message content."
        }
    }
}

private struct OpenAIModelListResponse: Decodable {
    struct Model: Decodable {
        let id: String
    }

    let data: [Model]
}

private struct OpenAIChatCompletionsRequest: Encodable {
    struct Message: Encodable {
        struct ContentPart: Encodable {
            struct ImageURL: Encodable {
                let url: String
            }

            let type: String
            let text: String?
            let image_url: ImageURL?

            static func text(_ value: String) -> ContentPart {
                ContentPart(type: "text", text: value, image_url: nil)
            }

            static func imageDataURL(_ value: String) -> ContentPart {
                ContentPart(type: "image_url", text: nil, image_url: ImageURL(url: value))
            }
        }

        let role: String
        let content: [ContentPart]
    }

    let model: String
    let messages: [Message]
    let stream: Bool
}

private struct OpenAIChatCompletionsResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            enum Content: Decodable {
                struct Part: Decodable {
                    let type: String?
                    let text: String?
                }

                case string(String)
                case parts([Part])

                init(from decoder: Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if let value = try? container.decode(String.self) {
                        self = .string(value)
                    } else {
                        self = .parts(try container.decode([Part].self))
                    }
                }

                var textValue: String? {
                    switch self {
                    case .string(let value):
                        return value
                    case .parts(let parts):
                        let text = parts.compactMap(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                        return text.isEmpty ? nil : text
                    }
                }
            }

            let content: Content
        }

        let message: Message
    }

    let choices: [Choice]
}

final class OpenAICompatibleClient {
    let baseURL: URL
    let model: String

    init(baseURL: URL = URL(string: "http://localhost:8887")!, model: String) {
        self.baseURL = baseURL
        self.model = model
    }

    func healthCheck() async throws {
        _ = try await listModels()
    }

    func listModels() async throws -> [String] {
        let url = baseURL.appending(path: "v1/models")
        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAICompatibleClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenAICompatibleClientError.httpStatus(http.statusCode, body)
        }

        do {
            let decoded = try JSONDecoder().decode(OpenAIModelListResponse.self, from: data)
            return decoded.data.map(\.id)
        } catch {
            let body = String(data: data, encoding: .utf8)
            throw OpenAICompatibleClientError.decodingFailed(body)
        }
    }

    func describeImage(data: Data, imageURL: URL, prompt: String, model overrideModel: String? = nil) async throws -> String {
        let url = baseURL.appending(path: "v1/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let mimeType = Self.mimeType(for: imageURL)
        let imageDataURL = "data:\(mimeType);base64,\(data.base64EncodedString())"
        let payload = OpenAIChatCompletionsRequest(
            model: overrideModel ?? model,
            messages: [
                .init(
                    role: "user",
                    content: [
                        .text(prompt),
                        .imageDataURL(imageDataURL)
                    ]
                )
            ],
            stream: false
        )
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAICompatibleClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenAICompatibleClientError.httpStatus(http.statusCode, body)
        }

        do {
            let decoded = try JSONDecoder().decode(OpenAIChatCompletionsResponse.self, from: data)
            guard let text = decoded.choices.first?.message.content.textValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                throw OpenAICompatibleClientError.missingContent
            }
            return text
        } catch let error as OpenAICompatibleClientError {
            throw error
        } catch {
            let body = String(data: data, encoding: .utf8)
            throw OpenAICompatibleClientError.decodingFailed(body)
        }
    }

    private static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "png":
            return "image/png"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "heic", "heif":
            return "image/heic"
        case "bmp":
            return "image/bmp"
        case "tif", "tiff":
            return "image/tiff"
        default:
            return "application/octet-stream"
        }
    }
}
