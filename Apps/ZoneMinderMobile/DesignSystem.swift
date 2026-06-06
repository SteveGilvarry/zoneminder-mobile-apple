import SwiftUI

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

extension View {
    /// Reliable full-width 16:9 media box (VideoPlayer/AsyncImage size poorly on their own).
    func mediaAspect() -> some View {
        self.aspectRatio(16.0/9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
    }
}
