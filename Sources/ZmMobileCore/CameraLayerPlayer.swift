#if canImport(UIKit) && canImport(AVFoundation)
import SwiftUI
import UIKit
@preconcurrency import AVFoundation

/// A UIView whose backing layer is an `AVPlayerLayer`, rendering *only* the video (no transport
/// controls). Camera rotation is applied to the video layer itself, so it never touches any UI
/// chrome — the fix for rotated cameras where rotating the whole `VideoPlayer` also turned its
/// controls sideways.
public final class PlayerContainerView: UIView {
    public let playerLayer = AVPlayerLayer()
    public var rotationDegrees: CGFloat = 0 { didSet { setNeedsLayout() } }

    /// `.resizeAspect` letterboxes (full image, black bars); `.resizeAspectFill` crops to fill the
    /// cell with no bars — used for the TV video wall to maximize screen usage.
    public var videoGravity: AVLayerVideoGravity {
        get { playerLayer.videoGravity }
        set { playerLayer.videoGravity = newValue; setNeedsLayout() }
    }

    /// Normalized point of interest (0...1) the crop should centre on. Only affects `.resizeAspectFill`.
    /// Clamped so the visible frame stays fully covered (no empty edges).
    public var focalPoint: CGPoint = CGPoint(x: 0.5, y: 0.5) { didSet { setNeedsLayout() } }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        playerLayer.videoGravity = .resizeAspect
        layer.addSublayer(playerLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // For quarter turns, give the layer landscape-shaped bounds (swap w/h) so that after a 90°
        // rotation the 16:9 video fills the portrait box uprightly; aspect is preserved by gravity.
        let quarter = Int(rotationDegrees.rounded()) % 180 != 0
        playerLayer.bounds = CGRect(
            x: 0, y: 0,
            width: quarter ? bounds.height : bounds.width,
            height: quarter ? bounds.width : bounds.height
        )

        // When cropping to fill, bias the layer so the focal point shows (clamped to stay covered).
        // The offset is computed in the *displayed* (post-rotation) tile space, then mapped through
        // the rotation so it lands correctly on the pre-rotation layer.
        var center = CGPoint(x: bounds.midX, y: bounds.midY)
        if playerLayer.videoGravity == .resizeAspectFill, let overflow = coverOverflow() {
            // dx/dy in tile space: positive focal beyond 0.5 shifts content the other way.
            let dxTile = (0.5 - focalPoint.x) * overflow.width
            let dyTile = (0.5 - focalPoint.y) * overflow.height
            let clampedX = max(-overflow.width / 2, min(overflow.width / 2, dxTile))
            let clampedY = max(-overflow.height / 2, min(overflow.height / 2, dyTile))
            center.x += clampedX
            center.y += clampedY
        }
        playerLayer.position = center
        playerLayer.setAffineTransform(CGAffineTransform(rotationAngle: rotationDegrees * .pi / 180))
        CATransaction.commit()
    }

    /// How much the cover-scaled video overflows the tile, in *displayed* tile dimensions, or nil
    /// if the video size isn't known yet. Used to clamp the focal-point offset.
    private func coverOverflow() -> CGSize? {
        let vid = playerLayer.player?.currentItem?.presentationSize ?? .zero
        guard vid.width > 0, vid.height > 0, bounds.width > 0, bounds.height > 0 else { return nil }
        // Displayed video aspect accounts for quarter-turn rotation.
        let quarter = Int(rotationDegrees.rounded()) % 180 != 0
        let dispW = quarter ? vid.height : vid.width
        let dispH = quarter ? vid.width : vid.height
        let scale = max(bounds.width / dispW, bounds.height / dispH)  // cover
        let scaledW = dispW * scale, scaledH = dispH * scale
        return CGSize(width: max(0, scaledW - bounds.width), height: max(0, scaledH - bounds.height))
    }
}

/// SwiftUI wrapper for `PlayerContainerView`. Shows the player's video, rotated per the camera's
/// orientation, with no built-in controls (callers overlay their own upright controls if needed).
public struct CameraLayerPlayer: UIViewRepresentable {
    private let player: AVPlayer
    private let rotationDegrees: Double
    private let fill: Bool
    private let focalPoint: CGPoint

    public init(player: AVPlayer, rotationDegrees: Double = 0, fill: Bool = false, focalPoint: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        self.player = player
        self.rotationDegrees = rotationDegrees
        self.fill = fill
        self.focalPoint = focalPoint
    }

    public func makeUIView(context: Context) -> PlayerContainerView {
        let view = PlayerContainerView()
        view.playerLayer.player = player
        view.rotationDegrees = CGFloat(rotationDegrees)
        view.focalPoint = focalPoint
        view.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        return view
    }

    public func updateUIView(_ view: PlayerContainerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.rotationDegrees = CGFloat(rotationDegrees)
        view.focalPoint = focalPoint
        view.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }
}
#endif
