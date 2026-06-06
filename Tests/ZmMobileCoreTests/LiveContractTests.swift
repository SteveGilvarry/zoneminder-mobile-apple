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

private let liveBaseURL = URL(string: "http://zoneminder.local:8080")!

/// Returns false (and the test soft-passes) if the backend is unreachable, so headless CI
/// without LAN access does not produce false failures.
private func backendReachable() async -> Bool {
    var request = URLRequest(url: liveBaseURL.appending(path: "/api/v3/auth/login"))
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
    guard await backendReachable() else {
        // Soft-skip when the LAN backend is not reachable from this host.
        print("[contract] backend unreachable — skipping live contract test")
        return
    }

    let store = InMemoryTokenStore()
    let client = ZmApiClient(baseURL: liveBaseURL, session: .shared, tokenStore: store)

    // login should persist a session into the injected store.
    try await client.login(username: "admin", password: "ktx200")
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
