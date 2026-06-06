#if canImport(AVKit) && canImport(SwiftUI)
import SwiftUI
import OSLog
import AVKit

private let liveLog = Logger(subsystem: "com.zoneminder.mobile", category: "live")

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

            let assetURL = loader.assetURL(for: realMaster)
            let asset = AVURLAsset(url: assetURL)
            asset.resourceLoader.setDelegate(loader, queue: delegateQueue)
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.play()
            self.player = player
        } catch {
            liveLog.error("start failed monitor \(self.monitorID): \(error.localizedDescription, privacy: .public)")
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
    private let rotationDegrees: Double

    public init(api: ZmApiClient, coordinator: StreamCoordinator, monitorID: Int, rotationDegrees: Double = 0, stopBackendOnRelease: Bool = true) {
        self.rotationDegrees = rotationDegrees
        _model = StateObject(wrappedValue: LivePlayerModel(
            api: api,
            coordinator: coordinator,
            monitorID: monitorID,
            stopBackendOnRelease: stopBackendOnRelease
        ))
    }

    private var quarterTurned: Bool { rotationDegrees.truncatingRemainder(dividingBy: 180) != 0 }

    public var body: some View {
        // Box aspect follows the camera rotation (portrait for 90/270) so the rotated video keeps
        // correct proportions. Color.clear sizes the box reliably; the player fills it via overlay.
        Color.clear
            .aspectRatio(quarterTurned ? 9.0 / 16.0 : 16.0 / 9.0, contentMode: .fit)
            .overlay {
                ZStack {
                    Color.black
                    if let player = model.player {
                        GeometryReader { geo in
                            VideoPlayer(player: player)
                                .frame(width: quarterTurned ? geo.size.height : geo.size.width,
                                       height: quarterTurned ? geo.size.width : geo.size.height)
                                .rotationEffect(.degrees(rotationDegrees))
                                .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        }
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
            }
            .clipped()
            .task { await model.start() }
            .onDisappear { Task { await model.stop() } }
    }
}
#endif
