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
            do {
                isAuthenticated = try await api.restore()
                if isAuthenticated { try await loadMonitors() }
            } catch {
                self.error = "restore: \(error)"
            }
        }
    }

    func login(username: String, password: String) {
        Task {
            do {
                try await api.login(username: username, password: password)
                isAuthenticated = true
                try await loadMonitors()
            } catch {
                self.error = "login: \(error)"
            }
        }
    }

    func loadMonitors() async throws {
        monitors = try await api.monitors()
    }

    func refresh() {
        Task {
            do { try await loadMonitors() } catch { self.error = "refresh: \(error)" }
        }
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

    private var columns: [GridItem] {
        let count = model.monitors.count <= 1 ? 1 : (model.monitors.count <= 4 ? 2 : 3)
        return Array(repeating: GridItem(.flexible(), spacing: 40), count: count)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    HStack {
                        Text("Live Wall")
                            .font(.largeTitle.bold())
                            .foregroundStyle(.cyan)
                        Spacer()
                        Button("Refresh") { model.refresh() }
                    }
                    if model.monitors.isEmpty {
                        ContentUnavailableView(
                            "No monitors",
                            systemImage: "video.slash",
                            description: Text("No monitors were returned from the backend.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 400)
                    } else {
                        LazyVGrid(columns: columns, spacing: 40) {
                            ForEach(model.monitors) { monitor in
                                MonitorTile(
                                    monitor: monitor,
                                    isFocused: focusedMonitor == monitor.id,
                                    api: model.api,
                                    coordinator: model.coordinator
                                )
                                .focused($focusedMonitor, equals: monitor.id)
                                .onTapGesture { selectedMonitor = monitor }
                            }
                        }
                    }
                }
                .padding(60)
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

/// A single wall tile. The focused tile plays live; unfocused tiles show a lightweight static
/// placeholder so we don't spin up every decoder at once (capacity/thermal friendly per the plan).
struct MonitorTile: View {
    let monitor: Monitor
    let isFocused: Bool
    let api: ZmApiClient
    let coordinator: StreamCoordinator

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if isFocused {
                LivePlayerView(api: api, coordinator: coordinator, monitorID: monitor.id)
            } else {
                ZStack {
                    Color.black
                    Image(systemName: "video")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                }
            }
            LinearGradient(
                colors: [.black.opacity(0.7), .clear],
                startPoint: .bottom,
                endPoint: .center
            )
            HStack {
                Circle()
                    .fill(monitor.isCapturing ? .green : .gray)
                    .frame(width: 16, height: 16)
                Text(monitor.name)
                    .font(.title3.monospaced().bold())
                    .foregroundStyle(.white)
            }
            .padding(20)
        }
        .aspectRatio(16/9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isFocused ? .cyan : .clear, lineWidth: 4)
        )
        .scaleEffect(isFocused ? 1.05 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isFocused)
        .focusable()
    }
}

struct MonitorDetailView: View {
    let monitor: Monitor
    let api: ZmApiClient
    let coordinator: StreamCoordinator

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            LivePlayerView(api: api, coordinator: coordinator, monitorID: monitor.id)
                .ignoresSafeArea()
            VStack(alignment: .leading, spacing: 8) {
                Text(monitor.name)
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                Text("\(monitor.capturing) / \(monitor.recording)")
                    .font(.headline.monospaced())
                    .foregroundStyle(.cyan)
            }
            .padding(60)
        }
    }
}
