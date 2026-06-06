#if canImport(AVKit) && canImport(SwiftUI)
import SwiftUI
import AVKit

/// Plays a recorded event's video via the direct `/events/{id}/video` endpoint, which supports
/// HTTP Range. The backend authenticates either a `?token=` query or a `Bearer` header on this
/// endpoint, so we hand `AVPlayer` a token-query `AVURLAsset` and let it do native range requests
/// (streaming, not buffering the whole file into memory like the HLS resource loader would).
@MainActor
public final class EventPlayerModel: ObservableObject {
    @Published public private(set) var player: AVPlayer?
    @Published public private(set) var error: String?

    private let api: ZmApiClient
    private let eventID: Int
    private var started = false

    public init(api: ZmApiClient, eventID: Int) {
        self.api = api
        self.eventID = eventID
    }

    public func start() async {
        guard !started else { return }
        started = true
        do {
            let token = try await api.currentAccessToken()
            let url = await api.eventVideoURL(eventID: eventID, token: token)
            let asset = AVURLAsset(url: url)
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.play()
            self.player = player
        } catch {
            self.error = error.localizedDescription
            started = false
        }
    }

    public func stop() {
        player?.pause()
        player = nil
        started = false
    }
}

/// Drop-in SwiftUI view that plays one event's recorded video. Works on iOS and tvOS.
public struct EventPlayerView: View {
    @StateObject private var model: EventPlayerModel

    public init(api: ZmApiClient, eventID: Int) {
        _model = StateObject(wrappedValue: EventPlayerModel(api: api, eventID: eventID))
    }

    public var body: some View {
        ZStack {
            Color.black
            if let player = model.player {
                VideoPlayer(player: player)
            } else if let error = model.error {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.caption.monospaced())
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
                .padding()
            } else {
                ProgressView()
                    .tint(.cyan)
            }
        }
        .task { await model.start() }
        .onDisappear { model.stop() }
    }
}
#endif
