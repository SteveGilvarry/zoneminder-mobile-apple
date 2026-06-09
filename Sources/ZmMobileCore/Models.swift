import Foundation

public struct Paginated<Element: Decodable & Sendable>: Decodable, Sendable {
    public let items: [Element]
    public let total: Int
    public let perPage: Int
    public let currentPage: Int
    public let lastPage: Int

    enum CodingKeys: String, CodingKey {
        case items, total
        case perPage = "per_page"
        case currentPage = "current_page"
        case lastPage = "last_page"
    }
}

public struct TokenResponse: Decodable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let tokenType: String
    public let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case expireIn = "expire_in"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        refreshToken = try c.decode(String.self, forKey: .refreshToken)
        tokenType = try c.decodeIfPresent(String.self, forKey: .tokenType) ?? "Bearer"
        expiresIn = try c.decodeIfPresent(Int.self, forKey: .expiresIn)
            ?? c.decodeIfPresent(Int.self, forKey: .expireIn)
            ?? 0
    }

    public init(accessToken: String, refreshToken: String, tokenType: String = "Bearer", expiresIn: Int = 0) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.tokenType = tokenType
        self.expiresIn = expiresIn
    }
}

public struct Monitor: Codable, Identifiable, Equatable, Hashable, Sendable {
    public let id: Int
    public let name: String
    public let width: Int
    public let height: Int
    public let orientation: String
    public let capturing: String
    public let analysing: String
    public let recording: String
    public let enabled: Int?
    public let controllable: Int

    public var isCapturing: Bool { capturing != "None" }
    public var hasPTZ: Bool { controllable == 1 }
    public var isEnabled: Bool { (enabled ?? 1) == 1 }

    /// Display rotation in degrees from the monitor's `orientation` (e.g. "ROTATE_90" -> 90).
    public var rotationDegrees: Double {
        Double(orientation.filter(\.isNumber)) ?? 0
    }
}

public struct Event: Codable, Identifiable, Equatable, Sendable {
    public let id: Int
    public let monitorId: Int
    public let name: String
    public let cause: String?
    public let startDateTime: String?
    public let endDateTime: String?
    public let frames: Int
    public let alarmFrames: Int
    public let maxScore: Int?
    public let archived: Int
    /// Orientation at record time, e.g. "Rotate90"/"Rotate0" (events are stored un-rotated, so this
    /// drives display rotation). Optional so a missing value never breaks decoding the events list.
    public let orientation: String?

    /// Display rotation in degrees parsed from `orientation` (e.g. "Rotate90" -> 90).
    public var rotationDegrees: Double {
        Double((orientation ?? "").filter(\.isNumber)) ?? 0
    }

    /// Useful label: ZoneMinder names many events "New Event" — fall back to the id then.
    public var displayName: String {
        (name.isEmpty || name == "New Event") ? "Event \(id)" : name
    }

    enum CodingKeys: String, CodingKey {
        case id, name, cause, frames, archived, orientation
        case monitorId = "monitor_id"
        case startDateTime = "start_date_time"
        case endDateTime = "end_date_time"
        case alarmFrames = "alarm_frames"
        case maxScore = "max_score"
    }
}

public struct StartLiveRequest: Encodable, Sendable {
    public let enableHLS: Bool
    public let enableWebRTC: Bool

    public init(enableHLS: Bool = true, enableWebRTC: Bool = false) {
        self.enableHLS = enableHLS
        self.enableWebRTC = enableWebRTC
    }

    enum CodingKeys: String, CodingKey {
        case enableHLS = "enable_hls"
        case enableWebRTC = "enable_webrtc"
    }
}

public struct StartLiveResponse: Decodable, Equatable, Sendable {
    public let monitorId: Int
    public let status: String
    public let hlsPlaylist: String?
    public let webrtcSignaling: String?

    enum CodingKeys: String, CodingKey {
        case monitorId = "monitor_id"
        case status
        case hlsPlaylist = "hls_playlist"
        case webrtcSignaling = "webrtc_signaling"
    }
}
