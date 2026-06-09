import SwiftUI
import UIKit

// MARK: - Mission Control design tokens
// A native operations-console aesthetic: dark void surfaces, cyan live affordances,
// status semantics (emerald/amber/crimson), restrained glow, monospaced telemetry.

enum ZM {
    // Surfaces
    static let void = Color(red: 0.02, green: 0.027, blue: 0.047)        // #05070C
    static let voidHi = Color(red: 0.04, green: 0.06, blue: 0.087)       // #0A0F16
    static let surface = Color(red: 0.055, green: 0.078, blue: 0.11)     // #0E141C
    static let surfaceHi = Color(red: 0.08, green: 0.11, blue: 0.15)
    static let hairline = Color(red: 0.11, green: 0.155, blue: 0.2)      // #1C2733

    // Text
    static let text = Color(red: 0.92, green: 0.95, blue: 0.98)
    static let muted = Color(red: 0.576, green: 0.643, blue: 0.722)      // #93A4B8
    static let faint = Color(red: 0.36, green: 0.42, blue: 0.5)

    // Accents / status
    static let cyan = Color(red: 0.0, green: 0.85, blue: 1.0)            // #00D9FF live
    static let emerald = Color(red: 0.2, green: 0.83, blue: 0.6)         // ok / recording
    static let amber = Color(red: 0.98, green: 0.69, blue: 0.13)         // warn
    static let crimson = Color(red: 1.0, green: 0.3, blue: 0.37)         // alarm

    static let mono = Font.system(.caption, design: .monospaced)
    static let monoSmall = Font.system(.caption2, design: .monospaced)
}

// MARK: - Background

struct VoidBackground: View {
    var body: some View {
        ZStack {
            ZM.void
            // subtle top glow so the void isn't flat
            RadialGradient(
                colors: [ZM.cyan.opacity(0.06), .clear],
                center: .top, startRadius: 0, endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Reusable components

/// Pulsing status dot, colored by semantic state.
struct StatusDot: View {
    var color: Color
    var pulsing: Bool = false
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.9), radius: on && pulsing ? 6 : 3)
            .scaleEffect(on && pulsing ? 1.25 : 1.0)
            .animation(pulsing ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default, value: on)
            .onAppear { on = true }
    }
}

/// Slim operator command bar that replaces the generic nav title. Carries telemetry an operator
/// actually wants — section identity, a live-status readout, and a running clock — instead of a
/// redundant noun label. Sits flush under the status bar to reclaim the wasted title space.
struct CommandBar<Trailing: View>: View {
    let section: String       // e.g. "CONSOLE" / "EVENTS"
    var status: String? = nil // e.g. "4 LIVE" / "23 EVENTS"
    var statusColor: Color = ZM.cyan
    var busy: Bool = false
    @ViewBuilder var trailing: () -> Trailing

    init(section: String, status: String? = nil, statusColor: Color = ZM.cyan, busy: Bool = false,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.section = section
        self.status = status
        self.statusColor = statusColor
        self.busy = busy
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: ZM.cyan)
            Text("ZONEMINDER")
                .font(.system(size: 14, weight: .heavy))
                .tracking(1.5)
                .foregroundStyle(ZM.text)
                .lineLimit(1)
                .fixedSize()
            Text(section.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(ZM.faint)
                .lineLimit(1)
                .fixedSize()

            Spacer(minLength: 8)

            if busy {
                ProgressView().controlSize(.mini).tint(ZM.cyan)
            } else if let status {
                Text(status)
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
                    .fixedSize()
            }
            trailing()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(ZM.voidHi)
        .overlay(alignment: .bottom) { Rectangle().fill(ZM.hairline).frame(height: 1) }
    }
}

/// Uppercase, letter-spaced section header — operator-console feel.
struct SectionHeader: View {
    let title: String
    var trailing: String? = nil
    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(2)
                .foregroundStyle(ZM.muted)
            Rectangle().fill(ZM.hairline).frame(height: 1)
            if let trailing {
                Text(trailing)
                    .font(ZM.monoSmall)
                    .foregroundStyle(ZM.faint)
            }
        }
    }
}

/// Small status chip.
struct Chip: View {
    let text: String
    var color: Color = ZM.muted
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .tracking(0.5)
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.35), lineWidth: 1))
    }
}

/// Card surface with hairline border.
struct CardSurface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .background(ZM.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(ZM.hairline, lineWidth: 1)
            )
    }
}

/// Snapshot/thumbnail view that loads via URLSession, keeps the last good frame (no flicker),
/// retries transient backend failures, and optionally re-fetches on an interval for a live-updating
/// wall. The ZoneMinder snapshot endpoint intermittently 404s ("keyframe capture timed out"), so a
/// plain AsyncImage leaves tiles blank — this loop self-heals.
struct LiveSnapshot: View {
    let url: URL?
    var icon: String = "video"
    var rotation: Double = 0
    var refresh: Double = 0   // seconds between refetches; 0 = load once (still retries failures)
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            ZM.voidHi
            if let image {
                Image(uiImage: image).resizable().scaledToFill().cameraRotation(rotation)
            } else {
                Image(systemName: icon).foregroundStyle(ZM.faint)
            }
        }
        .task(id: url) {
            image = nil
            guard let url else { return }
            var attempt = 0
            while !Task.isCancelled {
                if let img = await Self.fetch(url) {
                    image = img
                    attempt = 0
                    if refresh <= 0 { break }
                    try? await Task.sleep(nanoseconds: UInt64(refresh * 1_000_000_000))
                } else {
                    // backoff retry for transient 404s, capped at 5s
                    attempt += 1
                    let delay = min(Double(attempt) * 1.0, 5.0)
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
    }

    private static func fetch(_ url: URL) async -> UIImage? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let img = UIImage(data: data) else { return nil }
        return img
    }
}

// MARK: - Status semantics

enum MonitorState {
    static func captureColor(_ s: String) -> Color { s == "None" ? ZM.faint : ZM.cyan }
    static func recordColor(_ s: String) -> Color {
        switch s {
        case "None": return ZM.faint
        case "Always", "Mocord", "Modect", "Record": return ZM.emerald
        default: return ZM.amber
        }
    }
}

/// Display aspect ratio accounting for camera rotation: portrait for 90/270, else 16:9.
func zmMediaAspect(_ degrees: Double) -> CGFloat {
    degrees.truncatingRemainder(dividingBy: 180) != 0 ? 9.0 / 16.0 : 16.0 / 9.0
}

extension View {
    /// Full-width media box whose aspect follows the camera rotation (portrait for 90/270).
    func mediaAspect(rotation: Double = 0) -> some View {
        self.aspectRatio(zmMediaAspect(rotation), contentMode: .fit)
            .frame(maxWidth: .infinity)
    }

    /// Rotate media (a snapshot/thumbnail) by a monitor's orientation, sizing so a 90/270 image
    /// fits the box with correct aspect.
    @ViewBuilder
    func cameraRotation(_ degrees: Double) -> some View {
        if degrees == 0 {
            self
        } else {
            GeometryReader { geo in
                let quarter = degrees.truncatingRemainder(dividingBy: 180) != 0
                self
                    .frame(width: quarter ? geo.size.height : geo.size.width,
                           height: quarter ? geo.size.width : geo.size.height)
                    .rotationEffect(.degrees(degrees))
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
    }
}
