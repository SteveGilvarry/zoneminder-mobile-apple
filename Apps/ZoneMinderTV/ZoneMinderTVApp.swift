import SwiftUI
import ZmMobileCore

@main
struct ZoneMinderTVApp: App {
    var body: some Scene {
        WindowGroup {
            TVRootView()
                .preferredColorScheme(.dark)
        }
    }
}

struct TVRootView: View {
    private let placeholderMonitors = ["Front Door", "Driveway", "Garage", "Back Yard"]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 28) {
                Text("ZoneMinder Live Wall")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.cyan)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 24), count: 2), spacing: 24) {
                    ForEach(placeholderMonitors, id: \.self) { name in
                        Button {
                        } label: {
                            ZStack(alignment: .bottomLeading) {
                                Rectangle().fill(.black)
                                Text(name)
                                    .font(.title3.monospaced().bold())
                                    .padding()
                            }
                            .aspectRatio(16/9, contentMode: .fit)
                        }
                        .buttonStyle(.card)
                    }
                }
                Text("Event review and authenticated HLS playback are wired through ZmMobileCore.")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .padding(60)
        }
    }
}
