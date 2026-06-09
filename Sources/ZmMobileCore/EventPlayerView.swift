#if canImport(AVKit) && canImport(SwiftUI)
import SwiftUI
@preconcurrency import AVFoundation

/// Plays a recorded event. Completed events use the direct `/events/{id}/stream/video.mp4` route — a
/// single Range-served `video/mp4` that AVPlayer streams with native byte-range seeking. In-progress
/// events have no finalized MP4 yet, so they play via the EVENT-type HLS `playlist.m3u8` through the
/// `AuthenticatedHLSLoader` (segments need `?token=` auth, like live). Events are stored un-rotated,
/// so display rotation is applied by `CameraLayerPlayer`.
@MainActor
public final class EventPlayerModel: ObservableObject {
    @Published public private(set) var player: AVPlayer?
    @Published public private(set) var error: String?
    @Published public var currentTime: Double = 0
    @Published public var duration: Double = 0
    @Published public private(set) var isPlaying = false

    private let api: ZmApiClient
    private let eventID: Int
    private let useHLS: Bool
    private var started = false
    private var timeObserver: Any?
    private var loader: AuthenticatedHLSLoader?
    private let delegateQueue = DispatchQueue(label: "com.zoneminder.hls.event")

    public init(api: ZmApiClient, eventID: Int, useHLS: Bool = false) {
        self.api = api
        self.eventID = eventID
        self.useHLS = useHLS
    }

    public func start() async {
        guard !started else { return }
        started = true
        do {
            let token = try await api.currentAccessToken()
            let item: AVPlayerItem
            if useHLS {
                // In-progress (or HEVC) event → authenticated HLS, same path as live.
                let realURL = await api.eventPlaylistURL(eventID: eventID)
                let api = self.api
                let loader = AuthenticatedHLSLoader { try await api.currentAccessToken() }
                self.loader = loader
                let asset = AVURLAsset(url: loader.assetURL(for: realURL))
                asset.resourceLoader.setDelegate(loader, queue: delegateQueue)
                item = AVPlayerItem(asset: asset)
            } else {
                let url = await api.eventVideoURL(eventID: eventID, token: token)
                item = AVPlayerItem(asset: AVURLAsset(url: url))
            }
            let player = AVPlayer(playerItem: item)
            addTimeObserver(to: player)
            player.play()
            self.player = player
            self.isPlaying = true
        } catch {
            self.error = error.localizedDescription
            started = false
        }
    }

    private func addTimeObserver(to player: AVPlayer) {
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.currentTime = time.seconds.isFinite ? time.seconds : 0
                if let dur = player.currentItem?.duration.seconds, dur.isFinite, dur > 0 {
                    self.duration = dur
                }
                self.isPlaying = player.rate > 0
            }
        }
    }

    public func togglePlayPause() {
        guard let player else { return }
        if player.rate > 0 { player.pause() } else { player.play() }
        isPlaying = player.rate > 0
    }

    /// Seek to an absolute time in seconds.
    public func seek(to seconds: Double) {
        guard let player, duration > 0 else { return }
        let clamped = max(0, min(seconds, duration))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
    }

    public func stop() {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
        loader = nil
        started = false
        isPlaying = false
    }
}

/// Drop-in SwiftUI view that plays one event's recorded video with upright transport controls.
/// The video content is rotated per the camera's orientation (via `CameraLayerPlayer`) while the
/// control bar stays upright — rotation never turns the controls sideways. Works on iOS and tvOS.
public struct EventPlayerView: View {
    @StateObject private var model: EventPlayerModel
    private let rotationDegrees: Double

    public init(api: ZmApiClient, eventID: Int, rotationDegrees: Double = 0, useHLS: Bool = false) {
        self.rotationDegrees = rotationDegrees
        _model = StateObject(wrappedValue: EventPlayerModel(api: api, eventID: eventID, useHLS: useHLS))
    }

    private var quarterTurned: Bool { rotationDegrees.truncatingRemainder(dividingBy: 180) != 0 }

    public var body: some View {
        // Box aspect follows the camera rotation (portrait for 90/270) so rotated footage keeps
        // correct proportions; the player fills it via overlay and the controls sit on top, upright.
        Color.clear
            .aspectRatio(quarterTurned ? 9.0 / 16.0 : 16.0 / 9.0, contentMode: .fit)
            .overlay {
                ZStack {
                    Color.black
                    if let player = model.player {
                        // Recorded MP4s carry a rotation transform that AVPlayer honors automatically,
                        // so we pass 0 here (applying rotationDegrees too would double-rotate). The box
                        // aspect above still follows the camera rotation so the frame is framed right.
                        CameraLayerPlayer(player: player, rotationDegrees: 0)
                        #if os(iOS)
                        EventControlBar(model: model)
                        #endif
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
            }
            .clipped()
            .task { await model.start() }
            .onDisappear { model.stop() }
    }
}

#if os(iOS)
/// Upright transport controls (play/pause + scrubber + time) overlaid on event playback. Because
/// this is a sibling of the rotated video — not a child of any rotation — it stays upright on
/// rotated cameras, unlike the system `VideoPlayer` chrome.
private struct EventControlBar: View {
    @ObservedObject var model: EventPlayerModel
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0

    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 12) {
                Button {
                    model.togglePlayPause()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                }

                Text(timeLabel(scrubbing ? scrubValue : model.currentTime))
                    .font(.caption.monospaced())
                    .foregroundStyle(.white)

                Slider(
                    value: Binding(
                        get: { scrubbing ? scrubValue : model.currentTime },
                        set: { scrubValue = $0 }
                    ),
                    in: 0...max(model.duration, 0.1),
                    onEditingChanged: { editing in
                        scrubbing = editing
                        if !editing { model.seek(to: scrubValue) }
                    }
                )
                .tint(.cyan)

                Text(timeLabel(model.duration))
                    .font(.caption.monospaced())
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.black.opacity(0.45))
        }
    }

    private func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
#endif
#endif
