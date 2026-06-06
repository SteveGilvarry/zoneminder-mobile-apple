import SwiftUI
import ZmMobileCore

@main
struct ZoneMinderMobileApp: App {
    @State private var model = OperatorModel()

    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .environment(model)
                .tint(ZM.cyan)
        }
    }
}

@Observable
final class OperatorModel {
    let baseURL: URL
    let api: ZmApiClient
    let coordinator: StreamCoordinator
    var monitors: [Monitor] = []
    var events: [Event] = []
    var isAuthenticated = false
    var loading = false
    var error: String?
    /// Current access token for media URLs handed to AsyncImage/AVPlayer (which can't set headers).
    var mediaToken: String?

    init() {
        let base = URL(string: "http://zoneminder.local:8080")!
        self.baseURL = base
        self.api = ZmApiClient(baseURL: base)
        self.coordinator = StreamCoordinator(api: api)
    }

    func restore() {
        Task {
            do {
                isAuthenticated = try await api.restore()
                if isAuthenticated { try await refresh() }
            } catch {
                self.error = friendly(error)
            }
        }
    }

    func login(username: String, password: String) {
        Task {
            loading = true; error = nil
            do {
                try await api.login(username: username, password: password)
                isAuthenticated = true
                try await refresh()
            } catch {
                self.error = friendly(error)
            }
            loading = false
        }
    }

    func logout() {
        try? api.logoutSync()
        monitors = []; events = []; mediaToken = nil; isAuthenticated = false
    }

    func refresh() async throws {
        loading = true
        defer { loading = false }
        async let monitors = api.monitors()
        async let events = api.events()
        self.monitors = try await monitors
        self.events = try await events
        self.mediaToken = try? await api.currentAccessToken()
    }

    func reload() { Task { do { try await refresh() } catch { self.error = friendly(error) } } }

    func snapshotURL(_ monitor: Monitor) -> URL? {
        guard let t = mediaToken else { return nil }
        return URL(string: "\(baseURL.absoluteString)/api/v3/monitors/\(monitor.id)/snapshot?token=\(t)")
    }

    func thumbnailURL(_ event: Event) -> URL? {
        guard let t = mediaToken else { return nil }
        return URL(string: "\(baseURL.absoluteString)/api/v3/events/\(event.id)/thumbnail?token=\(t)")
    }

    func monitorName(_ id: Int) -> String? { monitors.first { $0.id == id }?.name }

    private func friendly(_ error: Error) -> String {
        if case ZmApiError.http(let code, _) = error { return "Server error (\(code))" }
        if case ZmApiError.unauthenticated = error { return "Sign-in failed — check credentials" }
        return "Network error — is the server reachable?"
    }
}

// Small helper so logout from the @MainActor model doesn't need an await ceremony.
extension ZmApiClient {
    nonisolated func logoutSync() throws { Task { try? await logout() } }
}

// MARK: - Root

struct MobileRootView: View {
    @Environment(OperatorModel.self) private var model

    var body: some View {
        Group {
            if model.isAuthenticated {
                TabView {
                    ConsoleView()
                        .tabItem { Label("Console", systemImage: "square.grid.2x2.fill") }
                    EventsView()
                        .tabItem { Label("Events", systemImage: "film.stack.fill") }
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                }
            } else {
                LoginView()
            }
        }
        .task { model.restore() }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Login

struct LoginView: View {
    @Environment(OperatorModel.self) private var model
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        ZStack {
            VoidBackground()
            VStack(spacing: 0) {
                Spacer()
                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        StatusDot(color: ZM.cyan, pulsing: true)
                        Text("ZONEMINDER")
                            .font(.system(size: 34, weight: .heavy, design: .rounded))
                            .tracking(2)
                            .foregroundStyle(ZM.text)
                    }
                    Text("NATIVE OPERATOR CONSOLE")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .tracking(3)
                        .foregroundStyle(ZM.cyan.opacity(0.8))
                }
                .padding(.bottom, 40)

                CardSurface {
                    VStack(spacing: 14) {
                        Field(icon: "person.fill", placeholder: "Username", text: $username, secure: false)
                        Field(icon: "lock.fill", placeholder: "Password", text: $password, secure: true)
                        Button(action: connect) {
                            HStack {
                                if model.loading { ProgressView().tint(ZM.void) }
                                Text(model.loading ? "Connecting…" : "Connect")
                                    .font(.headline)
                            }
                            .frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(ZM.cyan)
                        .disabled(model.loading)

                        if let error = model.error {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(ZM.monoSmall).foregroundStyle(ZM.amber)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .padding(18)
                }
                .padding(.horizontal, 28)

                Text(model.baseURL.absoluteString)
                    .font(ZM.monoSmall).foregroundStyle(ZM.faint)
                    .padding(.top, 18)
                Spacer(); Spacer()
            }
        }
    }

    private func connect() { model.login(username: username, password: password) }

    struct Field: View {
        let icon: String
        let placeholder: String
        @Binding var text: String
        let secure: Bool
        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: icon).foregroundStyle(ZM.faint).frame(width: 18)
                Group {
                    if secure { SecureField(placeholder, text: $text) }
                    else { TextField(placeholder, text: $text) }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(ZM.text)
            }
            .padding(.horizontal, 12).padding(.vertical, 12)
            .background(ZM.voidHi, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(ZM.hairline, lineWidth: 1))
        }
    }
}

// MARK: - Console

struct ConsoleView: View {
    @Environment(OperatorModel.self) private var model
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ZStack {
                VoidBackground()
                ScrollView {
                    if model.monitors.isEmpty {
                        EmptyState(icon: "video.slash", text: model.loading ? "Loading monitors…" : "No monitors")
                            .padding(.top, 60)
                    } else {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(model.monitors) { monitor in
                                NavigationLink(value: monitor) {
                                    MonitorTile(monitor: monitor)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(16)
                    }
                }
                .refreshable { try? await model.refresh() }
            }
            .navigationDestination(for: Monitor.self) { MonitorDetailView(monitor: $0) }
            .navigationTitle("Monitors")
            .toolbar { ConnectionToolbar() }
            .toolbarBackground(ZM.voidHi, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}

/// Compact wall tile: a live snapshot with name + status overlays. Tap → full live view.
struct MonitorTile: View {
    @Environment(OperatorModel.self) private var model
    let monitor: Monitor

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            SnapshotImage(url: model.snapshotURL(monitor), rotation: monitor.rotationDegrees)
                .mediaAspect(rotation: monitor.rotationDegrees)
                .clipped()
            LinearGradient(colors: [.clear, ZM.void.opacity(0.9)], startPoint: .center, endPoint: .bottom)

            // top row: LIVE + PTZ
            HStack {
                if monitor.isCapturing {
                    HStack(spacing: 4) {
                        StatusDot(color: ZM.cyan, pulsing: true)
                        Text("LIVE").font(.system(size: 9, weight: .bold, design: .monospaced)).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.45), in: Capsule())
                }
                Spacer()
                if monitor.hasPTZ { Chip(text: "PTZ", color: ZM.cyan) }
            }
            .padding(8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            // bottom: name + record dot
            HStack(spacing: 6) {
                Circle().fill(MonitorState.recordColor(monitor.recording)).frame(width: 7, height: 7)
                Text(monitor.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .lineLimit(1).shadow(radius: 3)
            }
            .padding(10)
        }
        .background(ZM.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(ZM.hairline, lineWidth: 1))
    }
}

struct MonitorCard: View {
    @Environment(OperatorModel.self) private var model
    let monitor: Monitor

    var body: some View {
        CardSurface {
            VStack(spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    SnapshotImage(url: model.snapshotURL(monitor))
                        .mediaAspect()
                        .clipped()
                    LinearGradient(colors: [.clear, ZM.void.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                    HStack(alignment: .bottom) {
                        Text(monitor.name)
                            .font(.headline).foregroundStyle(.white)
                            .lineLimit(1).shadow(radius: 4)
                        Spacer()
                        if monitor.hasPTZ { Chip(text: "PTZ", color: ZM.cyan) }
                    }
                    .padding(12)
                    if monitor.isCapturing {
                        HStack(spacing: 5) {
                            StatusDot(color: ZM.cyan, pulsing: true)
                            Text("LIVE").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.white)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
                HStack(spacing: 8) {
                    Chip(text: "CAP \(monitor.capturing)", color: MonitorState.captureColor(monitor.capturing))
                    Chip(text: "REC \(monitor.recording)", color: MonitorState.recordColor(monitor.recording))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(ZM.faint)
                }
                .padding(12)
            }
        }
    }
}

// MARK: - Monitor detail (live)

struct MonitorDetailView: View {
    @Environment(OperatorModel.self) private var model
    let monitor: Monitor

    var body: some View {
        ZStack {
            VoidBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LivePlayerView(api: model.api, coordinator: model.coordinator, monitorID: monitor.id, rotationDegrees: monitor.rotationDegrees)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(ZM.hairline, lineWidth: 1))

                    HStack(spacing: 8) {
                        Chip(text: "CAP \(monitor.capturing)", color: MonitorState.captureColor(monitor.capturing))
                        Chip(text: "REC \(monitor.recording)", color: MonitorState.recordColor(monitor.recording))
                        if monitor.hasPTZ { Chip(text: "PTZ", color: ZM.cyan) }
                    }

                    CardSurface {
                        VStack(alignment: .leading, spacing: 8) {
                            DetailRow("Resolution", "\(monitor.width)×\(monitor.height)")
                            DetailRow("Orientation", monitor.orientation)
                            DetailRow("Monitor ID", "\(monitor.id)")
                        }.padding(14)
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle(monitor.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(ZM.voidHi, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

// MARK: - Events

struct EventsView: View {
    @Environment(OperatorModel.self) private var model

    var body: some View {
        NavigationStack {
            ZStack {
                VoidBackground()
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if model.events.isEmpty {
                            EmptyState(icon: "film.stack", text: model.loading ? "Loading events…" : "No events")
                        }
                        ForEach(model.events) { event in
                            NavigationLink { EventDetailView(event: event) } label: {
                                EventCard(event: event)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
                .refreshable { try? await model.refresh() }
            }
            .navigationTitle("Events")
            .toolbar { ConnectionToolbar() }
            .toolbarBackground(ZM.voidHi, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}

struct EventCard: View {
    @Environment(OperatorModel.self) private var model
    let event: Event

    var body: some View {
        CardSurface {
            HStack(spacing: 12) {
                SnapshotImage(url: model.thumbnailURL(event), icon: "film")
                    .frame(width: 112, height: 63)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text(event.name).font(.subheadline.weight(.semibold)).foregroundStyle(ZM.text).lineLimit(1)
                    Text(prettyTime(event.startDateTime)).font(ZM.monoSmall).foregroundStyle(ZM.muted)
                    HStack(spacing: 6) {
                        if let name = model.monitorName(event.monitorId) {
                            Chip(text: name, color: ZM.faint)
                        }
                        Chip(text: "\(event.frames)F", color: ZM.muted)
                        if event.alarmFrames > 0 { Chip(text: "ALARM \(event.alarmFrames)", color: ZM.crimson) }
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(ZM.faint)
            }
            .padding(10)
        }
    }
}

struct EventDetailView: View {
    @Environment(OperatorModel.self) private var model
    let event: Event

    var body: some View {
        ZStack {
            VoidBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    EventPlayerView(api: model.api, eventID: event.id, rotationDegrees: model.monitors.first { $0.id == event.monitorId }?.rotationDegrees ?? 0)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(ZM.hairline, lineWidth: 1))

                    HStack(spacing: 8) {
                        if let name = model.monitorName(event.monitorId) { Chip(text: name, color: ZM.cyan) }
                        if let cause = event.cause, !cause.isEmpty { Chip(text: cause, color: ZM.muted) }
                        if event.alarmFrames > 0 { Chip(text: "ALARM \(event.alarmFrames)", color: ZM.crimson) }
                    }

                    CardSurface {
                        VStack(alignment: .leading, spacing: 8) {
                            DetailRow("Start", prettyTime(event.startDateTime))
                            DetailRow("End", prettyTime(event.endDateTime))
                            DetailRow("Frames", "\(event.frames)  ·  alarm \(event.alarmFrames)")
                            if let score = event.maxScore { DetailRow("Max score", "\(score)") }
                        }.padding(14)
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle(event.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(ZM.voidHi, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(OperatorModel.self) private var model
    var body: some View {
        NavigationStack {
            ZStack {
                VoidBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        SectionHeader(title: "Connection")
                        CardSurface {
                            VStack(alignment: .leading, spacing: 8) {
                                DetailRow("Backend", model.baseURL.absoluteString)
                                DetailRow("Monitors", "\(model.monitors.count)")
                                DetailRow("Events", "\(model.events.count)")
                            }.padding(14)
                        }
                        Button(role: .destructive) { model.logout() } label: {
                            Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                                .frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        .buttonStyle(.bordered).tint(ZM.crimson)

                        Text("Notifications are deferred for v1. Self-signed HTTPS requires explicit trust.")
                            .font(ZM.monoSmall).foregroundStyle(ZM.faint)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Settings")
            .toolbarBackground(ZM.voidHi, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}

// MARK: - Shared bits

struct ConnectionToolbar: ToolbarContent {
    @Environment(OperatorModel.self) private var model
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            HStack(spacing: 6) {
                if model.loading { ProgressView().controlSize(.small) }
                else { StatusDot(color: ZM.emerald, pulsing: true) }
            }
        }
    }
}

struct DetailRow: View {
    let key: String, value: String
    init(_ key: String, _ value: String) { self.key = key; self.value = value }
    var body: some View {
        HStack {
            Text(key.uppercased()).font(.system(size: 11, weight: .semibold, design: .monospaced)).tracking(1).foregroundStyle(ZM.faint)
            Spacer()
            Text(value).font(ZM.mono).foregroundStyle(ZM.text).multilineTextAlignment(.trailing)
        }
    }
}

struct EmptyState: View {
    let icon: String, text: String
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(ZM.faint)
            Text(text).font(ZM.mono).foregroundStyle(ZM.muted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
    }
}

/// AsyncImage tuned for the dark theme, with a graceful placeholder for 404/loading (thumbnails
/// and snapshots frequently 404 when no frame/recording exists).
struct SnapshotImage: View {
    let url: URL?
    var icon: String = "video"
    var rotation: Double = 0
    var body: some View {
        ZStack {
            ZM.voidHi
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill().cameraRotation(rotation)
                    case .empty: ProgressView().controlSize(.small).tint(ZM.faint)
                    default: Image(systemName: icon).foregroundStyle(ZM.faint)
                    }
                }
            } else {
                Image(systemName: icon).foregroundStyle(ZM.faint)
            }
        }
    }
}

private func prettyTime(_ s: String?) -> String {
    guard let s, !s.isEmpty else { return "—" }
    // "2026-06-06T14:39:48Z" -> "06-06 14:39:48"
    let t = s.replacingOccurrences(of: "Z", with: "")
    let parts = t.split(separator: "T")
    guard parts.count == 2 else { return s }
    let date = parts[0].split(separator: "-").dropFirst().joined(separator: "-")
    return "\(date) \(parts[1])"
}
