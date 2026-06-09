import SwiftUI
import ZmMobileCore

@main
struct ZoneMinderTVApp: App {
    @State private var model = TVOperatorModel()

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environment(model)
                .preferredColorScheme(.dark)
        }
    }
}

@Observable
final class TVOperatorModel {
    let api = ZmApiClient()
    let coordinator: StreamCoordinator
    var monitors: [Monitor] = []
    var isAuthenticated = false
    var error: String?

    init() {
        coordinator = StreamCoordinator(api: api)
    }

    func restore() {
        Task {
            guard (try? await api.restore()) == true else { isAuthenticated = false; return }
            // A restored session can still be dead (expired tokens, no saved credentials to
            // re-auth). Only stay "authenticated" if monitors actually load; otherwise show login.
            do {
                try await loadMonitors()
                isAuthenticated = true
            } catch {
                if isAuthExpiry(error) {
                    try? await api.logout()
                    isAuthenticated = false
                } else {
                    isAuthenticated = true   // reachable session, transient load error
                    self.error = friendly(error)
                }
            }
        }
    }

    func login(username: String, password: String) {
        Task {
            do {
                try await api.login(username: username, password: password)
                try await loadMonitors()
                isAuthenticated = true
                error = nil
            } catch {
                self.error = friendly(error)
            }
        }
    }

    func loadMonitors() async throws {
        monitors = try await api.monitors()
    }

    func refresh() {
        Task {
            do { try await loadMonitors() } catch {
                if isAuthExpiry(error) { try? await api.logout(); isAuthenticated = false }
                else { self.error = friendly(error) }
            }
        }
    }

    private func isAuthExpiry(_ error: Error) -> Bool {
        if case ZmApiError.unauthenticated = error { return true }
        if case ZmApiError.http(401, _) = error { return true }
        return false
    }

    private func friendly(_ error: Error) -> String {
        if case ZmApiError.http(let code, _) = error { return "Server error (\(code))" }
        if case ZmApiError.unauthenticated = error { return "Sign-in failed — check credentials" }
        return "Network error — is the server reachable?"
    }
}

struct TVRootView: View {
    @Environment(TVOperatorModel.self) private var model

    var body: some View {
        Group {
            if model.isAuthenticated {
                LiveWallView()
            } else {
                TVLoginView()
            }
        }
        .task { model.restore() }
    }
}

struct TVLoginView: View {
    @Environment(TVOperatorModel.self) private var model
    @State private var username = "admin"
    @State private var password = ""

    var body: some View {
        VStack(spacing: 28) {
            Text("ZoneMinder")
                .font(.system(size: 72, weight: .bold))
                .foregroundStyle(.cyan)
            Text("Live Wall")
                .font(.title2)
                .foregroundStyle(.secondary)
            TextField("Username", text: $username)
                .textContentType(.username)
                .frame(width: 600)
            SecureField("Password", text: $password)
                .textContentType(.password)
                .frame(width: 600)
            Button("Connect") { model.login(username: username, password: password) }
                .buttonStyle(.borderedProminent)
            if let error = model.error {
                Text(error)
                    .font(.caption.monospaced())
                    .foregroundStyle(.orange)
            }
        }
        .padding(80)
    }
}

/// Focus-driven live wall: a focusable grid of real monitors. The currently focused tile shows a
/// live HLS stream through the shared `LivePlayerView`; selecting a tile opens a full-screen detail.
struct LiveWallView: View {
    @Environment(TVOperatorModel.self) private var model
    @FocusState private var focusedMonitor: Int?
    @State private var selectedMonitor: Monitor?

    private let gap: CGFloat = 6

    private func aspect(_ m: Monitor) -> CGFloat {
        m.rotationDegrees.truncatingRemainder(dividingBy: 180) != 0 ? 9.0 / 16.0 : 16.0 / 9.0
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if model.monitors.isEmpty {
                    ContentUnavailableView(
                        "No monitors",
                        systemImage: "video.slash",
                        description: Text("No monitors were returned from the backend.")
                    )
                } else {
                    // 2D slicing-tree wall: places a tall portrait beside a stacked column, etc., to
                    // fill the wide screen far better than flat rows — each tile whole at true aspect.
                    GeometryReader { geo in
                        let placements = WallLayout.optimal(aspects: model.monitors.map(aspect), in: geo.size, gap: gap)
                        ZStack(alignment: .topLeading) {
                            ForEach(placements, id: \.index) { p in
                                let monitor = model.monitors[p.index]
                                MonitorTile(
                                    monitor: monitor,
                                    isFocused: focusedMonitor == monitor.id,
                                    api: model.api,
                                    coordinator: model.coordinator
                                )
                                .frame(width: p.rect.width, height: p.rect.height)
                                .focused($focusedMonitor, equals: monitor.id)
                                .onTapGesture { selectedMonitor = monitor }
                                .offset(x: p.rect.minX, y: p.rect.minY)
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                    }
                }
            }
            .navigationDestination(item: $selectedMonitor) { monitor in
                MonitorDetailView(monitor: monitor, api: model.api, coordinator: model.coordinator)
            }
            .onAppear {
                if focusedMonitor == nil { focusedMonitor = model.monitors.first?.id }
            }
        }
    }
}

/// A single wall tile: live video filling the whole cell (cropped, no black bars), rotated per the
/// camera's orientation, with a minimal name overlay. The focused tile gets a cyan border. All
/// tiles stream live so the wall is "all video" — on an always-powered Apple TV that's acceptable;
/// a low-res substream will lighten the multi-4K-decode load when the backend exposes one.
struct MonitorTile: View {
    let monitor: Monitor
    let isFocused: Bool
    let api: ZmApiClient
    let coordinator: StreamCoordinator

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LivePlayerView(
                api: api,
                coordinator: coordinator,
                monitorID: monitor.id,
                rotationDegrees: monitor.rotationDegrees,
                fillsFrame: true,
                crop: false
            )
            LinearGradient(
                colors: [.black.opacity(0.7), .clear],
                startPoint: .bottom,
                endPoint: .center
            )
            .allowsHitTesting(false)
            HStack {
                Circle()
                    .fill(monitor.isCapturing ? .green : .gray)
                    .frame(width: 14, height: 14)
                Text(monitor.name)
                    .font(.callout.monospaced().bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(16)
        }
        .clipped()
        .overlay(Rectangle().stroke(isFocused ? Color.cyan : .clear, lineWidth: 5))
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        .focusable()
    }
}

struct MonitorDetailView: View {
    let monitor: Monitor
    let api: ZmApiClient
    let coordinator: StreamCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            LivePlayerView(api: api, coordinator: coordinator, monitorID: monitor.id,
                           rotationDegrees: monitor.rotationDegrees)
                .ignoresSafeArea()
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(monitor.name)
                        .font(.largeTitle.bold())
                        .foregroundStyle(.white)
                    Text("\(monitor.capturing) / \(monitor.recording)")
                        .font(.headline.monospaced())
                        .foregroundStyle(.cyan)
                }
                Spacer()
                // Visible, focusable way back — not just the remote's Menu button.
                Button { dismiss() } label: {
                    Label("Back", systemImage: "chevron.left")
                }
            }
            .padding(60)
        }
        // Menu/back button on the remote also returns.
    }
}
