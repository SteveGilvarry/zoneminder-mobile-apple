import Foundation

public actor ZmApiClient {
    public var baseURL: URL
    private let session: URLSession
    private let tokenStore: TokenStore
    private var storedSession: StoredSession?

    public init(
        baseURL: URL = URL(string: "http://zoneminder.local:8080")!,
        session: URLSession = .shared,
        tokenStore: TokenStore = KeychainTokenStore()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.tokenStore = tokenStore
    }

    @discardableResult
    public func restore() throws -> Bool {
        storedSession = try tokenStore.load()
        if let restored = storedSession {
            baseURL = restored.baseURL
            return true
        }
        return false
    }

    public func login(username: String, password: String) async throws {
        let body = ["username": username, "password": password]
        let response: TokenResponse = try await send(path: "/api/v3/auth/login", method: "POST", body: body, token: nil)
        let next = StoredSession(baseURL: baseURL, accessToken: response.accessToken, refreshToken: response.refreshToken)
        storedSession = next
        try tokenStore.save(next)
    }

    public func logout() throws {
        storedSession = nil
        try tokenStore.clear()
    }

    public func currentAccessToken() async throws -> String {
        guard let token = try await validAccessToken() else {
            throw ZmApiError.unauthenticated
        }
        return token
    }

    public func monitors() async throws -> [Monitor] {
        let page: Paginated<Monitor> = try await authed(path: "/api/v3/monitors?page=1&page_size=100")
        return page.items
    }

    public func events(pageSize: Int = 30) async throws -> [Event] {
        let page: Paginated<Event> = try await authed(path: "/api/v3/events?page=1&page_size=\(pageSize)&sort=start_time&direction=desc")
        return page.items
    }

    public func startLive(monitorID: Int) async throws -> StartLiveResponse {
        try await authed(
            path: "/api/v3/live/\(monitorID)/start",
            method: "POST",
            body: StartLiveRequest(enableHLS: true, enableWebRTC: false)
        )
    }

    public func stopLive(monitorID: Int) async throws {
        let _: EmptyResponse = try await authed(path: "/api/v3/live/\(monitorID)/stop", method: "DELETE")
    }

    public func hlsMasterURL(monitorID: Int) -> URL {
        baseURL.appending(path: "/api/v3/live/\(monitorID)/hls/master.m3u8")
    }

    public func eventVideoURL(eventID: Int, token: String) -> URL {
        baseURL.appending(path: "/api/v3/events/\(eventID)/video").appending(queryItems: [.init(name: "token", value: token)])
    }

    private func authed<T: Decodable, B: Encodable>(path: String, method: String = "GET", body: B? = Optional<EmptyBody>.none) async throws -> T {
        guard let token = try await validAccessToken() else { throw ZmApiError.unauthenticated }
        do {
            return try await send(path: path, method: method, body: body, token: token)
        } catch ZmApiError.http(401, _) {
            guard let refreshed = try await refreshAccessToken() else { throw ZmApiError.unauthenticated }
            return try await send(path: path, method: method, body: body, token: refreshed)
        }
    }

    private func validAccessToken() async throws -> String? {
        if storedSession == nil {
            storedSession = try tokenStore.load()
        }
        guard let current = storedSession else { return nil }
        let exp = JWT.expirationEpochSeconds(current.accessToken)
        let due = exp == nil || Date(timeIntervalSince1970: TimeInterval(exp!)).timeIntervalSinceNow < 60
        return due ? try await refreshAccessToken() : current.accessToken
    }

    private func refreshAccessToken() async throws -> String? {
        guard let current = storedSession else { return nil }
        let response: TokenResponse = try await send(
            path: "/api/v3/auth/refresh",
            method: "POST",
            body: ["token": current.refreshToken],
            token: nil
        )
        let next = StoredSession(baseURL: baseURL, accessToken: response.accessToken, refreshToken: response.refreshToken)
        storedSession = next
        try tokenStore.save(next)
        return next.accessToken
    }

    private func send<T: Decodable, B: Encodable>(path: String, method: String, body: B?, token: String?) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ZmApiError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ZmApiError.http(http.statusCode, String(data: data, encoding: .utf8))
        }
        if T.self == EmptyResponse.self {
            return EmptyResponse() as! T
        }
        return try JSONDecoder.zm.decode(T.self, from: data)
    }
}

private struct EmptyBody: Encodable {}
private struct EmptyResponse: Decodable {}

public enum ZmApiError: Error, Equatable {
    case unauthenticated
    case invalidResponse
    case http(Int, String?)
}

extension JSONDecoder {
    static var zm: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .useDefaultKeys
        return decoder
    }
}

private extension URL {
    func appending(queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + queryItems
        return components.url!
    }
}
