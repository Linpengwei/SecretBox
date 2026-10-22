import Foundation

enum SecretBoxAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Server URL is invalid."
        case .invalidResponse:
            return "Server response was invalid."
        case let .serverError(message):
            return message
        }
    }
}

struct SecretBoxAPI {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    func fetchProviderSettings(baseURL: String) async throws -> ProviderSettingsViewData {
        try await request(baseURL: baseURL, path: "/api/provider", method: "GET", payload: Optional<String>.none)
    }

    func fetchAIStatus(baseURL: String) async throws -> AIGatewayStatusData {
        try await request(baseURL: baseURL, path: "/api/ai/status", method: "GET", payload: Optional<String>.none)
    }

    func saveProviderSettings(baseURL: String, payload: ProviderSettingsPayload) async throws -> ProviderSettingsViewData {
        try await request(baseURL: baseURL, path: "/api/provider", method: "PUT", payload: payload)
    }

    func saveRecord(baseURL: String, payload: VaultItemCreateRequest) async throws -> VaultRecord {
        try await request(baseURL: baseURL, path: "/api/records", method: "POST", payload: payload)
    }

    func updateRecord(baseURL: String, recordID: String, payload: VaultItemCreateRequest) async throws -> VaultRecord {
        try await request(baseURL: baseURL, path: "/api/records/\(recordID)", method: "PUT", payload: payload)
    }

    func search(baseURL: String, payload: PasswordSearchRequest) async throws -> PasswordSearchResponse {
        try await request(baseURL: baseURL, path: "/api/search", method: "POST", payload: payload)
    }

    private func request<Response: Decodable, Payload: Encodable>(
        baseURL: String,
        path: String,
        method: String,
        payload: Payload?
    ) async throws -> Response {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines) + path) else {
            throw SecretBoxAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let payload {
            request.httpBody = try encoder.encode(payload)
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SecretBoxAPIError.invalidResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "Request failed."
            throw SecretBoxAPIError.serverError(message)
        }

        return try decoder.decode(Response.self, from: data)
    }
}
