import Foundation

public actor StreamCoordinator {
    private var refCounts: [Int: Int] = [:]
    private let api: ZmApiClient

    public init(api: ZmApiClient) {
        self.api = api
    }

    public func acquire(monitorID: Int) async throws -> URL {
        if refCounts[monitorID, default: 0] == 0 {
            _ = try await api.startLive(monitorID: monitorID)
        }
        refCounts[monitorID, default: 0] += 1
        return await api.hlsMasterURL(monitorID: monitorID)
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
