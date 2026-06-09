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
    /// When true, the view fills the caller-provided frame instead of imposing its own
    /// rotation-aware aspect box (e.g. a uniform grid tile or a full-bleed wall cell).
    private let fillsFrame: Bool
    /// When true, the video crops to fill (`resizeAspectFill`); otherwise it letterboxes (`resizeAspect`).
    private let crop: Bool
    /// Normalized focus (0...1) the crop centers on, clamped to keep the frame covered.
    private let focalPoint: CGPoint

    public init(api: ZmApiClient, coordinator: StreamCoordinator, monitorID: Int, rotationDegrees: Double = 0, fillsFrame: Bool = false, crop: Bool = false, focalPoint: CGPoint = CGPoint(x: 0.5, y: 0.5), stopBackendOnRelease: Bool = true) {
        self.rotationDegrees = rotationDegrees
        self.fillsFrame = fillsFrame
        self.crop = crop
        self.focalPoint = focalPoint
        _model = StateObject(wrappedValue: LivePlayerModel(
            api: api,
            coordinator: coordinator,
            monitorID: monitorID,
            stopBackendOnRelease: stopBackendOnRelease
        ))
    }

    private var quarterTurned: Bool { rotationDegrees.truncatingRemainder(dividingBy: 180) != 0 }

    @ViewBuilder private var content: some View {
        ZStack {
            Color.black
            if let player = model.player {
                CameraLayerPlayer(player: player, rotationDegrees: rotationDegrees, fill: crop, focalPoint: focalPoint)
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

    public var body: some View {
        Group {
            if fillsFrame {
                // Fill the caller-provided frame; gravity (crop) decides letterbox vs cover.
                content
            } else {
                // Box aspect follows the camera rotation (portrait for 90/270) so the rotated video
                // keeps correct proportions. The video content is rotated inside CameraLayerPlayer —
                // a live view has no controls, so nothing chrome-like can end up sideways.
                Color.clear
                    .aspectRatio(quarterTurned ? 9.0 / 16.0 : 16.0 / 9.0, contentMode: .fit)
                    .overlay { content }
            }
        }
        .clipped()
        .task { await model.start() }
        .onDisappear { Task { await model.stop() } }
    }
}
#endif
