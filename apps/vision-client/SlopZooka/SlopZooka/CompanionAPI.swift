import Foundation
import Security

@MainActor
enum CompanionAPI {
    static func baseURL(host: String) -> URL? {
        let value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let url = URL(string: value.contains("://") ? value : "http://\(value)"),
            url.host != nil, url.scheme == "http" || url.scheme == "https"
        else { return nil }
        return url
    }

    static func authorized(_ request: URLRequest) -> URLRequest {
        var request = request
        if let url = request.url, let token = credential(for: url) {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await URLSession.shared.data(for: authorized(request))
    }

    static func request<T: Decodable>(
        _ type: T.Type, base: URL, path: String, method: String = "GET", body: Data? = nil, timeout: TimeInterval = 20
    ) async throws -> T {
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = timeout
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await perform(request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(response.statusCode) else {
            let error = try? JSONDecoder().decode(APIErrorResponse.self, from: data)
            throw CompanionError(
                message: error?.error ?? "Request failed (\(response.statusCode))", statusCode: response.statusCode)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid ISO date"))
        }
        return try decoder.decode(type, from: data)
    }

    static func pair(base: URL, code: String) async throws {
        struct PairResponse: Decodable {
            let token: String
            let hostId: String
        }
        let response = try await request(
            PairResponse.self, base: base, path: "/api/pair", method: "POST",
            body: JSONSerialization.data(withJSONObject: ["code": code]))
        let query = keychainQuery(base)
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(response.token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
            throw CompanionError(message: "Could not save pairing in Keychain")
        }
    }

    private static func credential(for url: URL) -> String? {
        var query = keychainQuery(url)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func keychainQuery(_ url: URL) -> [String: Any] {
        let origin = "\(url.scheme ?? "http")://\(url.host ?? ""):\(url.port ?? (url.scheme == "https" ? 443 : 80))"
        return [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "SlopZooka.Companion",
            kSecAttrAccount as String: origin,
        ]
    }
}

struct CompanionError: LocalizedError {
    let message: String
    var statusCode: Int? = nil
    var errorDescription: String? { message }
}

struct HostSession: Decodable, Identifiable {
    let id: String
    let workspaceId: String
    let profile: String?
    let title: String
    let cwd: String
    let status: String
}
struct HostSessionsResponse: Decodable { let sessions: [HostSession] }
struct CreatedSessionResponse: Decodable { let session: HostSession }
struct APIAcknowledgement: Decodable { let ok: Bool }
