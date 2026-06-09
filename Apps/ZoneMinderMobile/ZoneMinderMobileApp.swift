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

/// Per-monitor wall framing: letterbox (fit) by default, or crop-to-fill centred on a focal point.
struct MonitorFraming: Codable, Equatable {
    var crop: Bool = false
    var focusX: Double = 0.5
    var focusY: Double = 0.5
    var focalPoint: CGPoint { CGPoint(x: focusX, y: focusY) }
}

/// How the console arranges monitors. Auto = justified rows (derived from aspect); custom = a
/// hand-built layout of equal-height rows, each split into equal-width cells.
enum WallMode: String, Codable { case auto, custom }

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
    /// Per-monitor wall framing, keyed by monitor id; persisted in UserDefaults.
    var framing: [Int: MonitorFraming] = [:]
    /// Whether wall tiles show their toolbar strip (vs a clean, pure-video wall). Persisted.
    var showTileChrome: Bool = true {
        didSet { UserDefaults.standard.set(showTileChrome, forKey: chromeKey) }
    }
    /// Console layout mode (auto justified vs custom splits). Persisted.
    var wallMode: WallMode = .auto {
        didSet { UserDefaults.standard.set(wallMode.rawValue, forKey: wallModeKey) }
    }
    /// Custom layout: rows of monitor ids (equal-height rows, equal-width cells). Persisted.
    var customRows: [[Int]] = [] {
        didSet {
            if let data = try? JSONEncoder().encode(customRows) {
                UserDefaults.standard.set(data, forKey: customRowsKey)
            }
        }
    }

    private let framingKey = "monitorFraming"
    private let chromeKey = "showTileChrome"
    private let wallModeKey = "wallMode"
    private let customRowsKey = "customRows"

    init() {
        let base = URL(string: "http://zoneminder.local:8080")!
        self.baseURL = base
        self.api = ZmApiClient(baseURL: base)
        self.coordinator = StreamCoordinator(api: api)
        if let data = UserDefaults.standard.data(forKey: framingKey),
           let decoded = try? JSONDecoder().decode([Int: MonitorFraming].self, from: data) {
            framing = decoded
        }
        if UserDefaults.standard.object(forKey: chromeKey) != nil {
            showTileChrome = UserDefaults.standard.bool(forKey: chromeKey)
        }
        if let raw = UserDefaults.standard.string(forKey: wallModeKey), let m = WallMode(rawValue: raw) {
            wallMode = m
        }
        if let data = UserDefaults.standard.data(forKey: customRowsKey),
           let decoded = try? JSONDecoder().decode([[Int]].self, from: data) {
            customRows = decoded
        }
    }

    /// A custom layout to start editing from: existing saved one, else the current monitors chunked
    /// two-per-row as a sensible seed.
    func seededCustomRows() -> [[Int]] {
        if !customRows.isEmpty { return customRows }
        return stride(from: 0, to: monitors.count, by: 2).map { start in
            Array(monitors[start..<min(start + 2, monitors.count)]).map { $0.id }
        }
    }

    func framing(for id: Int) -> MonitorFraming { framing[id] ?? MonitorFraming() }

    func setFraming(_ value: MonitorFraming, for id: Int) {
        framing[id] = value
        if let data = try? JSONEncoder().encode(framing) {
            UserDefaults.standard.set(data, forKey: framingKey)
        }
    }

    func toggleCrop(for id: Int) {
        var f = framing(for: id)
        f.crop.toggle()
        setFraming(f, for: id)
    }

    func restore() {
        Task {
            do {
                isAuthenticated = try await api.restore()
                if isAuthenticated { try await refresh() }
            } catch {
                // A persisted session whose tokens have expired can't be refreshed: drop it and
                // show the login screen rather than stranding the user on an empty console.
                if isAuthExpiry(error) {
                    logout()
                } else {
                    self.error = friendly(error)
                }
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

    func reload() {
        Task {
            do { try await refresh() }
            catch { if isAuthExpiry(error) { logout() } else { self.error = friendly(error) } }
        }
    }

    /// True when an error means the stored session is no longer usable (expired/invalid tokens),
    /// so the right response is to sign out rather than show a transient error.
    private func isAuthExpiry(_ error: Error) -> Bool {
        if case ZmApiError.unauthenticated = error { return true }
        if case ZmApiError.http(401, _) = error { return true }
        return false
    }

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
    @State private var editingLayout = false

    private var liveCount: Int { model.monitors.filter { $0.isCapturing }.count }
    private let gap: CGFloat = 6
    private var chromeHeight: CGFloat { model.showTileChrome ? 30 : 0 }

    private func aspect(_ m: Monitor) -> CGFloat {
        m.rotationDegrees.truncatingRemainder(dividingBy: 180) != 0 ? 9.0 / 16.0 : 16.0 / 9.0
    }

    var body: some View {
        NavigationStack {
            ZStack {
                VoidBackground()
                VStack(spacing: 0) {
                    CommandBar(
                        section: "Console",
                        status: "\(liveCount)/\(model.monitors.count) LIVE",
                        busy: model.loading && model.monitors.isEmpty
                    ) {
                        layoutMenu
                        Button { model.showTileChrome.toggle() } label: {
                            Image(systemName: model.showTileChrome ? "tag.fill" : "tag")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(model.showTileChrome ? ZM.cyan : ZM.muted)
                        }
                        .buttonStyle(.plain)
                    }

                    if model.monitors.isEmpty {
                        EmptyState(icon: "video.slash", text: model.loading ? "Loading monitors…" : "No monitors")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        GeometryReader { geo in
                            switch model.wallMode {
                            case .auto:  autoWall(in: geo.size)
                            case .custom: customWall(in: geo.size)
                            }
                        }
                        .padding(6)
                    }
                }
            }
            .navigationDestination(for: Monitor.self) { MonitorDetailView(monitor: $0) }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $editingLayout) { CustomLayoutEditor() }
        }
    }

    private var layoutMenu: some View {
        Menu {
            Picker("Layout", selection: Binding(get: { model.wallMode }, set: { model.wallMode = $0 })) {
                Label("Auto", systemImage: "rectangle.3.group").tag(WallMode.auto)
                Label("Custom", systemImage: "square.grid.3x3").tag(WallMode.custom)
            }
            Button { model.customRows = model.seededCustomRows(); editingLayout = true } label: {
                Label("Edit custom layout…", systemImage: "slider.horizontal.3")
            }
        } label: {
            Image(systemName: "rectangle.3.group")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(model.wallMode == .custom ? ZM.cyan : ZM.muted)
        }
    }

    /// Auto wall: a 2D slicing-tree optimizer places each camera in an absolute rect so a tall
    /// portrait can sit beside a stacked column, etc. — filling the screen better than flat rows
    /// while keeping true aspects.
    private func autoWall(in size: CGSize) -> some View {
        let placements = WallLayout.optimal(aspects: model.monitors.map(aspect), in: size, gap: gap)
        return ZStack(alignment: .topLeading) {
            ForEach(placements, id: \.index) { p in
                let monitor = model.monitors[p.index]
                NavigationLink(value: monitor) { MonitorTile(monitor: monitor) }
                    .buttonStyle(.plain)
                    .frame(width: p.rect.width, height: p.rect.height)
                    .offset(x: p.rect.minX, y: p.rect.minY)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    /// Custom splits: equal-height rows, each split into equal-width cells, filling the screen.
    private func customWall(in size: CGSize) -> some View {
        let source = model.customRows.isEmpty ? model.seededCustomRows() : model.customRows
        let rows = source.map { $0.filter { id in model.monitors.contains { $0.id == id } } }
                         .filter { !$0.isEmpty }
        let r = max(rows.count, 1)
        let rowH = (size.height - gap * CGFloat(r - 1)) / CGFloat(r)
        return VStack(spacing: gap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                let cols = max(row.count, 1)
                let cellW = (size.width - gap * CGFloat(cols - 1)) / CGFloat(cols)
                HStack(spacing: gap) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, id in
                        if let monitor = model.monitors.first(where: { $0.id == id }) {
                            NavigationLink(value: monitor) { MonitorTile(monitor: monitor) }
                                .buttonStyle(.plain)
                                .frame(width: cellW, height: rowH)
                        }
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Editor for the custom wall layout: rows of equal-width cells, each assigned a camera. Mirrors
/// the zm-dash "split" model — add rows, set how many cells per row, pick the camera for each.
struct CustomLayoutEditor: View {
    @Environment(OperatorModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private var rows: [[Int]] { model.customRows }

    var body: some View {
        NavigationStack {
            ZStack {
                VoidBackground()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // Live shape preview (names only — light, and clearer for arranging).
                        preview
                            .frame(height: 150)
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                        SectionHeader(title: "Rows")
                        ForEach(Array(rows.enumerated()), id: \.offset) { rIdx, row in
                            rowEditor(rIdx, row)
                        }

                        Button {
                            let first = model.monitors.first?.id
                            model.customRows.append(first.map { [$0] } ?? [])
                        } label: {
                            Label("Add row", systemImage: "plus.rectangle")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(ZM.cyan)
                        }
                        .padding(.top, 4)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Custom layout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(ZM.cyan)
                }
            }
        }
    }

    private var preview: some View {
        GeometryReader { geo in
            let r = max(rows.count, 1)
            let g: CGFloat = 3
            let rowH = (geo.size.height - g * CGFloat(r - 1)) / CGFloat(r)
            VStack(spacing: g) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    let cols = max(row.count, 1)
                    HStack(spacing: g) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, id in
                            RoundedRectangle(cornerRadius: 4)
                                .fill(ZM.surfaceHi)
                                .overlay {
                                    Text(model.monitorName(id).map(shortName) ?? "—")
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(ZM.muted)
                                        .lineLimit(1).padding(2)
                                }
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: rowH)
                }
            }
        }
        .background(ZM.void)
    }

    private func rowEditor(_ rIdx: Int, _ row: [Int]) -> some View {
        CardSurface {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Row \(rIdx + 1)").font(.subheadline.weight(.semibold)).foregroundStyle(ZM.text)
                    Spacer()
                    Stepper("\(row.count) col\(row.count == 1 ? "" : "s")", value: Binding(
                        get: { row.count },
                        set: { newCount in setColumnCount(rIdx, newCount) }
                    ), in: 1...6)
                    .fixedSize()
                    Button(role: .destructive) { model.customRows.remove(at: rIdx) } label: {
                        Image(systemName: "trash").foregroundStyle(ZM.crimson)
                    }
                    .padding(.leading, 8)
                }
                // Per-cell camera pickers.
                ForEach(Array(row.enumerated()), id: \.offset) { cIdx, id in
                    Menu {
                        ForEach(model.monitors) { m in
                            Button(m.name) { model.customRows[rIdx][cIdx] = m.id }
                        }
                    } label: {
                        HStack {
                            Text("Cell \(cIdx + 1)").font(ZM.monoSmall).foregroundStyle(ZM.faint)
                            Spacer()
                            Text(model.monitorName(id) ?? "Unassigned").font(ZM.mono).foregroundStyle(ZM.text).lineLimit(1)
                            Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(ZM.faint)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(ZM.voidHi, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .padding(12)
        }
    }

    private func setColumnCount(_ rIdx: Int, _ count: Int) {
        var row = model.customRows[rIdx]
        if count > row.count {
            let fill = model.monitors.first?.id ?? 0
            row.append(contentsOf: Array(repeating: fill, count: count - row.count))
        } else if count < row.count {
            row = Array(row.prefix(count))
        }
        model.customRows[rIdx] = row
    }

    private func shortName(_ s: String) -> String { String(s.prefix(10)) }
}

/// Compact wall tile: a live HLS stream with name + status overlays. Tap → full live view.
/// (Uses the full-res HLS rendition for now — once the backend exposes a low-res substream we'll
/// point the wall tiles at it to lighten the multi-decode load.)
struct MonitorTile: View {
    @Environment(OperatorModel.self) private var model
    let monitor: Monitor

    private var framing: MonitorFraming { model.framing(for: monitor.id) }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar strip — chrome lives here, never over the video. Hidden globally for a clean wall.
            if model.showTileChrome {
                HStack(spacing: 6) {
                    // Indicator dot replaces the "LIVE" label: cyan = capturing, record color otherwise.
                    StatusDot(color: monitor.isCapturing ? ZM.cyan : ZM.faint, pulsing: monitor.isCapturing)
                    Text(monitor.name)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(ZM.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if monitor.hasPTZ {
                        Image(systemName: "dpad.fill").font(.system(size: 11)).foregroundStyle(ZM.cyan)
                    }
                    Button {
                        model.toggleCrop(for: monitor.id)
                    } label: {
                        Image(systemName: framing.crop ? "rectangle.arrowtriangle.2.inward" : "rectangle.arrowtriangle.2.outward")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(framing.crop ? ZM.cyan : ZM.muted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(ZM.voidHi)
            }

            // Clean video — fills the remaining cell space, no overlays. Letterboxed (fit) by
            // default, or cropped to the chosen focal point when this camera is set to fill.
            LivePlayerView(
                api: model.api, coordinator: model.coordinator, monitorID: monitor.id,
                rotationDegrees: monitor.rotationDegrees,
                fillsFrame: true, crop: framing.crop, focalPoint: framing.focalPoint
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .clipped()
            .allowsHitTesting(false)
        }
        .background(ZM.surface)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
    @State private var framing = MonitorFraming()

    private var quarterTurned: Bool { monitor.rotationDegrees.truncatingRemainder(dividingBy: 180) != 0 }
    private var videoAspect: CGFloat { quarterTurned ? 9.0 / 16.0 : 16.0 / 9.0 }

    var body: some View {
        ZStack {
            VoidBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // The full image always shows here (fit), so the operator can see the whole scene
                    // while choosing the crop focus. The reticle marks the point the wall tile crops
                    // around; the tile (not this view) applies the crop.
                    Color.clear
                        .aspectRatio(videoAspect, contentMode: .fit)
                        .overlay {
                            GeometryReader { geo in
                                ZStack {
                                    LivePlayerView(
                                        api: model.api, coordinator: model.coordinator, monitorID: monitor.id,
                                        rotationDegrees: monitor.rotationDegrees, fillsFrame: true
                                    )
                                    if framing.crop {
                                        FocusReticle()
                                            .position(x: framing.focusX * geo.size.width,
                                                      y: framing.focusY * geo.size.height)
                                            .allowsHitTesting(false)
                                    }
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { loc in
                                    guard framing.crop else { return }
                                    var f = framing
                                    f.focusX = min(1, max(0, Double(loc.x / geo.size.width)))
                                    f.focusY = min(1, max(0, Double(loc.y / geo.size.height)))
                                    framing = f
                                    model.setFraming(f, for: monitor.id)
                                }
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(ZM.hairline, lineWidth: 1))

                    // Wall framing control.
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Wall framing")
                        Picker("Wall framing", selection: Binding(
                            get: { framing.crop },
                            set: { newValue in
                                var f = framing; f.crop = newValue; framing = f
                                model.setFraming(f, for: monitor.id)
                            }
                        )) {
                            Text("Fit").tag(false)
                            Text("Crop").tag(true)
                        }
                        .pickerStyle(.segmented)
                        Text(framing.crop ? "Tap the image to set the area to keep when cropping."
                                          : "The wall tile shows the whole image, letterboxed.")
                            .font(ZM.monoSmall).foregroundStyle(ZM.faint)
                    }

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
        .onAppear { framing = model.framing(for: monitor.id) }
    }
}

/// Crosshair marking the crop focal point on the framing editor.
struct FocusReticle: View {
    var body: some View {
        ZStack {
            Circle().stroke(ZM.cyan, lineWidth: 2).frame(width: 44, height: 44)
            Circle().fill(ZM.cyan).frame(width: 5, height: 5)
            Rectangle().fill(ZM.cyan).frame(width: 1, height: 14)
            Rectangle().fill(ZM.cyan).frame(width: 14, height: 1)
        }
        .shadow(color: .black.opacity(0.6), radius: 2)
    }
}

// MARK: - Events

struct EventsView: View {
    @Environment(OperatorModel.self) private var model

    var body: some View {
        NavigationStack {
            ZStack {
                VoidBackground()
                VStack(spacing: 0) {
                    CommandBar(
                        section: "Events",
                        status: model.events.isEmpty ? nil : "\(model.events.count) EVENTS",
                        statusColor: ZM.muted,
                        busy: model.loading && model.events.isEmpty
                    )
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
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

struct EventCard: View {
    @Environment(OperatorModel.self) private var model
    let event: Event

    var body: some View {
        CardSurface {
            HStack(spacing: 12) {
                // Uniform square thumbnail, rotated upright (raw JPEG has no EXIF) with a centre-crop.
                LiveSnapshot(url: model.thumbnailURL(event), icon: "film", rotation: event.rotationDegrees)
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text(event.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(ZM.text).lineLimit(1)
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

    /// Prefer the event's own recorded orientation; fall back to the monitor's current rotation.
    private var eventRotation: Double {
        if event.rotationDegrees != 0 { return event.rotationDegrees }
        return model.monitors.first { $0.id == event.monitorId }?.rotationDegrees ?? 0
    }

    /// In-progress events (no end time) have no finalized MP4 yet — play them via EVENT-type HLS.
    private var inProgress: Bool { event.endDateTime == nil }

    var body: some View {
        ZStack {
            VoidBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    EventPlayerView(api: model.api, eventID: event.id, rotationDegrees: eventRotation, useHLS: inProgress)
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
        .navigationTitle(event.displayName)
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
            // Only a spinner while actively refreshing; nothing when idle (the always-on dot was
            // noise — it conveyed "connected" but that's the default expectation).
            if model.loading {
                ProgressView().controlSize(.small)
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
