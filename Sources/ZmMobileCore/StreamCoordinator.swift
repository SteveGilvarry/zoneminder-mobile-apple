import Foundation

public actor StreamCoordinator {
    private var refCounts: [Int: Int] = [:]
    private let api: ZmApiClient

    public init(api: ZmApiClient) {
        self.api = api
    }

    public func acquire(monitorID: Int) async throws -> URL {
        if refCounts[monitorID, default: 0] == 0 {
            do {
                _ = try await api.startLive(monitorID: monitorID)
            } catch {
                // Live sessions are monitor-global: another client (or our own prior session) may
                // already have the stream running, which the backend reports as a conflict
                // ("Live stream already exists"). That's not a failure — the HLS stream is
                // available either way. Only rethrow genuine errors.
                guard Self.isAlreadyRunning(error) else { throw error }
            }
        }
        refCounts[monitorID, default: 0] += 1
        return await api.hlsMasterURL(monitorID: monitorID)
    }

    static func isAlreadyRunning(_ error: Error) -> Bool {
        guard case ZmApiError.http(_, let body?) = error else { return false }
        let b = body.lowercased()
        return b.contains("already exists") || b.contains("conflict")
    }

    public func release(monitorID: Int, stopBackendSession: Bool = false) async throws {
        let next = max(0, refCounts[monitorID, default: 0] - 1)
        refCounts[monitorID] = next
        if next == 0 {
            refCounts.removeValue(forKey: monitorID)
            if stopBackendSession {
                try await api.stopLive(monitorID: monitorID)
            }
        }
    }
}
