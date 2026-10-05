import Foundation

struct ViewLiftError: LocalizedError {
    var code: String?
    var message: String
    var status: Int?

    var errorDescription: String? { message }
}

/// Thin client over the ViewLift REST and GraphQL endpoints used by altitudeplus.com.
///
/// ViewLift expects the raw JWT in `Authorization` (no "Bearer" prefix) plus the
/// site's public `x-api-key`.
struct ViewLiftClient {
    var session: URLSession = .shared

    func get(_ path: String, query: [String: String?] = [:], token: String?) async throws -> JSON {
        try await rest("GET", path, query: query, token: token)
    }

    func post(_ path: String, query: [String: String?] = [:], token: String?) async throws -> JSON {
        try await rest("POST", path, query: query, token: token)
    }

    private func rest(_ method: String, _ path: String, query: [String: String?], token: String?) async throws -> JSON {
        var components = URLComponents(url: AltitudeConfig.apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        if !items.isEmpty {
            components.queryItems = items.sorted { $0.name < $1.name }
        }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        applyHeaders(to: &request, token: token)
        return try await send(request)
    }

    /// Runs a GraphQL operation and returns its `data` object.
    func graphQL(_ query: String, variables: [String: Any], token: String?) async throws -> JSON {
        var request = URLRequest(url: AltitudeConfig.graphQL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyHeaders(to: &request, token: token)
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": query, "variables": variables])

        let body = try await send(request)
        if let first = body["errors"]?.array?.first {
            let code = first["extensions"]?["code"]?.string
            let message = first["message"]?.string ?? code ?? "Request failed"
            throw ViewLiftError(code: code, message: Self.friendlyGraphQLMessage(code: code, message: message))
        }
        guard let data = body["data"] else {
            throw ViewLiftError(message: "Empty response from Altitude+")
        }
        return data
    }

    private func applyHeaders(to request: inout URLRequest, token: String?) {
        request.setValue(AltitudeConfig.apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token {
            request.setValue(token, forHTTPHeaderField: "Authorization")
        }
    }

    private func send(_ request: URLRequest) async throws -> JSON {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONDecoder().decode(JSON.self, from: data)) ?? .null

        if (200..<300).contains(status) {
            return json
        }
        // Entitlement endpoints return 4xx with a JSON body describing why.
        // Hand that body back so callers can map `errorCode` themselves.
        if json["errorCode"] != nil || json["code"] != nil {
            return json
        }
        let message = json["errorMessage"]?.string ?? json["message"]?.string
            ?? HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        throw ViewLiftError(code: json["code"]?.string, message: message, status: status)
    }

    private static func friendlyGraphQLMessage(code: String?, message: String) -> String {
        switch code?.uppercased() {
        case "INVALID_OTP", "OTP_INVALID":
            return "That code didn't match. Check the latest email from Altitude+ and try again."
        case "OTP_EXPIRED":
            return "That code has expired. Request a new one."
        default:
            return message
        }
    }
}
