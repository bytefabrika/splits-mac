import Foundation

enum GarminError: LocalizedError {
    case noKey
    case badKey
    case rateLimited
    case http(Int, String)
    case unexpected(String, String)

    var errorDescription: String? {
        switch self {
        case .noKey: "Add your Personal API key first."
        case .badKey: "The key wasn't accepted. It may have expired or been deleted. Create a new one in Garmin Connect."
        case .rateLimited: "The server asked us to slow down. Try again in a few minutes."
        case .http(let code, let body): "The server answered \(code): \(body.prefix(200))"
        case .unexpected(let path, let detail): "Unexpected answer from \(path): \(detail)"
        }
    }
}

/// Talks to Garmin's Connect Personal API, directly from this Mac.
/// Requests go one at a time with a short gap between them: Garmin has rate limits it doesn't publish.
actor GarminClient {
    static let base = URL(string: "https://personal.connectapi.garmin.com")!
    static let tokenPath = "/personalapitoken-service/personal-api/personal-api-key/token"
    /// Tokens last 24 hours; renew a little early.
    static let tokenLifetime: TimeInterval = 23 * 3600
    static let gap: TimeInterval = 0.35

    private let key: () -> String?
    private let session: URLSession
    private var token: (value: String, expires: Date)?
    private var lastRequest = Date.distantPast

    /// The app's client. One instance, so its gap between requests applies to everything.
    static let shared: GarminClient = {
        #if DEBUG
        // Debug command-line tests pass the key in the environment instead of reading the keychain.
        if let key = ProcessInfo.processInfo.environment["SPLITS_KEY"] { return GarminClient(key: { key }) }
        #endif
        return GarminClient()
    }()

    init(key: @escaping () -> String? = Keychain.readKey, session: URLSession = .shared) {
        self.key = key
        self.session = session
    }

    /// Exchanges the key for a bearer token. Garmin answers with the token as plain text.
    func authenticate(force: Bool = false) async throws -> String {
        if !force, let token, token.expires > Date() { return token.value }
        guard let key = key()?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { throw GarminError.noKey }
        var request = URLRequest(url: Self.base.appendingPathComponent(Self.tokenPath))
        request.httpMethod = "POST"
        request.setValue("ApiKey \(key)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await send(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if status == 401 || status == 403 { throw GarminError.badKey }
            throw GarminError.http(status, String(decoding: data, as: UTF8.self))
        }
        var value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // Be lenient in case Garmin ever wraps it in JSON.
        if value.hasPrefix("{"), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            value = (json["access_token"] ?? json["accessToken"] ?? json["token"]) as? String ?? value
        }
        token = (value, Date().addingTimeInterval(Self.tokenLifetime))
        return value
    }

    /// GET a path (with query) and decode JSON. Renews the token once on 401, waits and retries on 429.
    func get<T: Decodable>(_ path: String, query: [String: String] = [:], as type: T.Type = T.self) async throws -> T {
        let data = try await getData(path, query: query, accept: "application/json")
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch let error as DecodingError {
            throw GarminError.unexpected(path, Self.describe(error))
        }
    }

    func getData(_ path: String, query: [String: String] = [:], accept: String) async throws -> Data {
        var components = URLComponents(url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var renewed = false
        for attempt in 0..<4 {
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(try await authenticate())", forHTTPHeaderField: "Authorization")
            request.setValue(accept, forHTTPHeaderField: "Accept")
            let (data, response) = try await send(request)
            switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200: return data
            case 204: return Data("null".utf8)
            case 401 where !renewed:
                renewed = true
                _ = try await authenticate(force: true)
            case 401, 403: throw GarminError.badKey
            case 429:
                if attempt == 3 { throw GarminError.rateLimited }
                try await Task.sleep(for: .seconds(15 * (attempt + 1)))
            case let code: throw GarminError.http(code, String(decoding: data, as: UTF8.self))
            }
        }
        throw GarminError.rateLimited
    }

    static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context): return "missing \(key.stringValue) at \(path(context))"
        case .typeMismatch(let type, let context): return "\(type) expected at \(path(context))"
        case .valueNotFound(let type, let context): return "no \(type) at \(path(context))"
        case .dataCorrupted(let context): return "corrupted at \(path(context)): \(context.debugDescription)"
        @unknown default: return error.localizedDescription
        }
    }

    /// The original file the watch recorded, as Garmin stores it (a ZIP with one FIT file).
    /// Note: Garmin answers 406 to "Accept: application/octet-stream" alone; "*/*" works.
    func activityFile(_ id: Int64) async throws -> Data {
        try await getData("/download-service/files/activity/\(id)", accept: "*/*")
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let wait = Self.gap - Date().timeIntervalSince(lastRequest)
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        lastRequest = Date()
        return try await session.data(for: request)
    }
}
