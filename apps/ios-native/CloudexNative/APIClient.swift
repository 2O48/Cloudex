import Foundation

enum APIClientError: LocalizedError {
    case invalidServerURL
    case invalidResponse
    case server(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            return "服务器地址无效"
        case .invalidResponse:
            return "服务器返回了无法识别的响应"
        case let .server(status, message):
            return message.isEmpty ? "HTTP \(status)" : message
        }
    }
}

struct APIClient {
    let serverURL: String
    let token: String

    private var normalizedBaseURL: String {
        serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    func makeURL(path: String, queryItems: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(string: normalizedBaseURL + path) else {
            throw APIClientError.invalidServerURL
        }
        if !queryItems.isEmpty { components.queryItems = queryItems }
        guard let url = components.url else { throw APIClientError.invalidServerURL }
        return url
    }

    func threadPath(_ threadID: String, action: String? = nil) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let encoded = threadID.addingPercentEncoding(withAllowedCharacters: allowed) ?? threadID
        return "/api/threads/\(encoded)" + (action.map { "/\($0)" } ?? "")
    }

    func threadTurnPath(_ threadID: String, turnID: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let encodedTurnID = turnID.addingPercentEncoding(withAllowedCharacters: allowed) ?? turnID
        return threadPath(threadID, action: "turns/\(encodedTurnID)")
    }

    func approvalPath(_ approvalID: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let encoded = approvalID.addingPercentEncoding(withAllowedCharacters: allowed) ?? approvalID
        return "/api/approvals/\(encoded)/respond"
    }

    func get<T: Decodable>(_ path: String, queryItems: [URLQueryItem] = []) async throws -> T {
        var request = URLRequest(url: try makeURL(path: path, queryItems: queryItems))
        request.httpMethod = "GET"
        return try await send(request)
    }

    func post<T: Decodable>(_ path: String, json: [String: Any] = [:]) async throws -> T {
        var request = URLRequest(url: try makeURL(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        return try await send(request)
    }

    private func send<T: Decodable>(_ requestValue: URLRequest) async throws -> T {
        var request = requestValue
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = object?["error"] as? String ?? String(data: data, encoding: .utf8) ?? ""
            throw APIClientError.server(status: http.statusCode, message: message)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIClientError.invalidResponse
        }
    }
}
