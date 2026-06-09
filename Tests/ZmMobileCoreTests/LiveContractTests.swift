import Foundation
import Testing
@testable import ZmMobileCore

/// In-memory `TokenStore` so the contract test never touches the Keychain.
final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: StoredSession?

    init(_ initial: StoredSession? = nil) { session = initial }

    func load() throws -> StoredSession? {
        lock.lock(); defer { lock.unlock() }
        return session
    }

    func save(_ session: StoredSession) throws {
        lock.lock(); defer { lock.unlock() }
        self.session = session
    }

    func clear() throws {
        lock.lock(); defer { lock.unlock() }
        session = nil
    }
}

/// Live-backend credentials/URL come from the environment so no secrets live in the repo.
/// Set ZM_BASE_URL, ZM_USERNAME, ZM_PASSWORD (e.g. via a gitignored `.env` sourced before
/// `swift test`, or the Xcode scheme's environment variables). Missing values soft-skip the test.
private struct LiveCredentials {
    let baseURL: URL
    let username: String
    let password: String

    static func fromEnvironment() -> LiveCredentials? {
        let env = ProcessInfo.processInfo.environment
        guard let user = env["ZM_USERNAME"], !user.isEmpty,
              let pass = env["ZM_PASSWORD"], !pass.isEmpty else { return nil }
        let url = URL(string: env["ZM_BASE_URL"] ?? "http://zoneminder.local:8080")!
        return LiveCredentials(baseURL: url, username: user, password: pass)
    }
}

/// Returns false (and the test soft-passes) if the backend is unreachable, so headless CI
/// without LAN access does not produce false failures.
private func backendReachable(_ baseURL: URL) async -> Bool {
    var request = URLRequest(url: baseURL.appending(path: "/api/v3/auth/login"))
    request.httpMethod = "POST"
    request.timeoutInterval = 5
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data("{}".utf8)
    do {
        _ = try await URLSession.shared.data(for: request)
        return true
    } catch {
        return false
    }
}

@Test func liveLoginThenMonitorsThenEvents() async throws {
    guard let creds = LiveCredentials.fromEnvironment() else {
        // Soft-skip when credentials aren't supplied via the environment.
        print("[contract] ZM_USERNAME/ZM_PASSWORD not set — skipping live contract test")
        return
    }
    guard await backendReachable(creds.baseURL) else {
        // Soft-skip when the LAN backend is not reachable from this host.
        print("[contract] backend unreachable — skipping live contract test")
        return
    }

    let store = InMemoryTokenStore()
    let client = ZmApiClient(baseURL: creds.baseURL, session: .shared, tokenStore: store)

    // login should persist a session into the injected store.
    try await client.login(username: creds.username, password: creds.password)
    let saved = try store.load()
    #expect(saved != nil)
    #expect(saved?.accessToken.isEmpty == false)
    #expect(saved?.refreshToken.isEmpty == false)

    // A valid access token must be retrievable (exercises JWT exp parse + refresh gate).
    let token = try await client.currentAccessToken()
    #expect(token.isEmpty == false)

    // monitors() must decode the paginated envelope into real Monitor models.
    let monitors = try await client.monitors()
    #expect(monitors.allSatisfy { $0.id > 0 })

    // events() must decode with sort=start_time (snake_case dates, integer booleans).
    let events = try await client.events(pageSize: 5)
    #expect(events.allSatisfy { $0.id > 0 })

    print("[contract] login OK, monitors=\(monitors.count), events=\(events.count)")
}
