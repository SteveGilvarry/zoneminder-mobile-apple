import SwiftUI
import ZmMobileCore

@main
struct ZoneMinderMobileApp: App {
    @State private var model = OperatorModel()

    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .environment(model)
        }
    }
}

@Observable
final class OperatorModel {
    let api = ZmApiClient()
    let coordinator: StreamCoordinator
    var monitors: [Monitor] = []
    var events: [Event] = []
    var isAuthenticated = false
    var error: String?

    init() {
        coordinator = StreamCoordinator(api: api)
    }

    func restore() {
        Task {
            do {
                isAuthenticated = try await api.restore()
                if isAuthenticated { try await refresh() }
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
                try await refresh()
            } catch {
                self.error = "login: \(error)"
            }
        }
    }

    func refresh() async throws {
        async let monitors = api.monitors()
        async let events = api.events()
        self.monitors = try await monitors
        self.events = try await events
    }
}

struct MobileRootView: View {
    @Environment(OperatorModel.self) private var model

    var body: some View {
        Group {
            if model.isAuthenticated {
                TabView {
                    MonitorListView()
                        .tabItem { Label("Console", systemImage: "rectangle.grid.2x2") }
                    EventListView()
                        .tabItem { Label("Events", systemImage: "film.stack") }
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gear") }
                }
            } else {
                LoginView()
            }
        }
        .task { model.restore() }
        .preferredColorScheme(.dark)
    }
}

struct LoginView: View {
    @Environment(OperatorModel.self) private var model
    @State private var username = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 18) {
            Text("ZoneMinder").font(.largeTitle.bold()).foregroundStyle(.cyan)
            Text("Native operator console").foregroundStyle(.secondary)
            TextField("Username", text: $username)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Connect") { model.login(username: username, password: password) }
                .buttonStyle(.borderedProminent)
            if let error = model.error { Text(error).foregroundStyle(.orange) }
        }
        .padding()
    }
}

struct MonitorListView: View {
    @Environment(OperatorModel.self) private var model

    var body: some View {
        NavigationStack {
            List(model.monitors) { monitor in
                NavigationLink(monitor.name) {
                    MonitorDetailView(monitor: monitor)
                }
            }
            .navigationTitle("Console")
            .toolbar {
                Button("Refresh") { Task { try? await model.refresh() } }
            }
        }
    }
}

struct MonitorDetailView: View {
    @Environment(OperatorModel.self) private var model
    let monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LivePlayerView(api: model.api, coordinator: model.coordinator, monitorID: monitor.id)
                .aspectRatio(16/9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(monitor.name).font(.title2.bold())
            Text("\(monitor.capturing) / \(monitor.recording)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            if monitor.hasPTZ {
                Text("PTZ controls")
                    .font(.headline)
                    .foregroundStyle(.cyan)
            }
            Spacer()
        }
        .padding()
        .navigationTitle(monitor.name)
    }
}

struct EventListView: View {
    @Environment(OperatorModel.self) private var model

    var body: some View {
        NavigationStack {
            List(model.events) { event in
                VStack(alignment: .leading) {
                    Text(event.name)
                    Text(event.startDateTime ?? "Unknown time")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Events")
        }
    }
}

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Text("Backend: http://zoneminder.local:8080")
                Text("Notifications deferred for v1")
                Text("Self-signed HTTPS requires explicit trust")
            }
            .navigationTitle("Settings")
        }
    }
}
