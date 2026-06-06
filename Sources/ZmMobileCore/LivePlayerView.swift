#if canImport(AVKit) && canImport(SwiftUI)
import SwiftUI
import AVKit

/// Owns the lifecycle of a single live HLS stream: acquires the backend session through the
/// `StreamCoordinator`, builds an authenticated `AVPlayer`, and releases on teardown.
@MainActor
public final class LivePlayerModel: ObservableObject {
    @Published public private(set) var player: AVPlayer?
    @Published public private(set) var error: String?

    private let api: ZmApiClient
    private let coordinator: StreamCoordinator
    private let monitorID: Int
    private let stopBackendOnRelease: Bool
    private var loader: AuthenticatedHLSLoader?
    private let delegateQueue = DispatchQueue(label: "com.zoneminder.hls.loader")
    private var started = false

    public init(
        api: ZmApiClient,
        coordinator: StreamCoordinator,
        monitorID: Int,
        stopBackendOnRelease: Bool = true
    ) {
        self.api = api
        self.coordinator = coordinator
        self.monitorID = monitorID
        self.stopBackendOnRelease = stopBackendOnRelease
    }

    public func start() async {
        guard !started else { return }
        started = true
        do {
            let realMaster = try await coordinator.acquire(monitorID: monitorID)
            let api = self.api
            let loader = AuthenticatedHLSLoader { try await api.currentAccessToken() }
            self.loader = loader

            let asset = AVURLAsset(url: loader.assetURL(for: realMaster))
            asset.resourceLoader.setDelegate(loader, queue: delegateQueue)
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.play()
            self.player = player
        } catch {
            self.error = error.localizedDescription
            started = false
        }
    }

    public func stop() async {
        player?.pause()
        player = nil
        loader = nil
        started = false
        try? await coordinator.release(monitorID: monitorID, stopBackendSession: stopBackendOnRelease)
    }
}

/// Drop-in SwiftUI live view for one monitor. Works on iOS and tvOS.
public struct LivePlayerView: View {
    @StateObject private var model: LivePlayerModel

    public init(api: ZmApiClient, coordinator: StreamCoordinator, monitorID: Int, stopBackendOnRelease: Bool = true) {
        _model = StateObject(wrappedValue: LivePlayerModel(
            api: api,
            coordinator: coordinator,
            monitorID: monitorID,
            stopBackendOnRelease: stopBackendOnRelease
        ))
    }

    public var body: some View {
        ZStack {
            Color.black
            if let player = model.player {
                VideoPlayer(player: player)
            } else if let error = model.error {
                Text(error)
                    .font(.caption.monospaced())
                    .foregroundStyle(.orange)
                    .padding()
            } else {
                ProgressView()
                    .tint(.cyan)
            }
        }
        .task { await model.start() }
        .onDisappear { Task { await model.stop() } }
    }
}
#endif
