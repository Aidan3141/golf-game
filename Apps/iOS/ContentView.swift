import SwiftUI
import SwingKit

struct ContentView: View {
    @Environment(PhoneConnectivity.self) private var connectivity
    @Environment(RecordingStore.self) private var store
    @Environment(NetworkSwingSender.self) private var sender
    @Environment(SwingFeed.self) private var feed

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Watch", systemImage: "applewatch")
                        .badge(watchStatus)
                    Label("Vision Pro", systemImage: "visionpro")
                        .badge(sender.state.label)
                    Button("Send Test Swing", systemImage: "paperplane") {
                        sender.send(SwingResult.sample.fresh())
                    }
                    .disabled(!sender.state.isConnected)
                } footer: {
                    Text("keep this app open while u play, it relays watch swings to the headset")
                }

                if !feed.entries.isEmpty {
                    Section("live swings") {
                        ForEach(feed.entries) { e in
                            HStack {
                                Text(String(format: "%.1f : 1", e.swing.tempoRatio))
                                    .font(.headline.monospacedDigit())
                                Spacer()
                                Text(String(format: "%.0f rad/s · %.0f ms", e.swing.peakWristAngularVelocity, e.watchLatency * 1000))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    if store.items.isEmpty {
                        Text("no swings yet. start a session on the watch + hit record")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.items) { item in
                        NavigationLink(value: item) {
                            RecordingRow(recording: item.recording)
                        }
                    }
                    .onDelete { idx in
                        idx.map { store.items[$0] }.forEach(store.delete)
                    }
                } header: {
                    Text("recordings (\(store.items.count))")
                }
            }
            .navigationTitle("Golf Game")
            .navigationDestination(for: RecordingStore.Item.self) { item in
                RecordingDetailView(item: item)
            }
            .toolbar {
                if !store.items.isEmpty {
                    ShareLink("Share All", items: store.items.map(\.url))
                }
            }
            .refreshable { store.reload() }
        }
        #if DEBUG
        // `-autoTestSwing`: send a sample once connected, for sim testing
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-autoTestSwing") else { return }
            while !sender.state.isConnected {
                try? await Task.sleep(for: .milliseconds(300))
            }
            try? await Task.sleep(for: .seconds(1))
            sender.send(SwingResult.sample.fresh())
        }
        #endif
    }

    private var watchStatus: String {
        if !connectivity.isPaired { return "not paired" }
        if !connectivity.isWatchAppInstalled { return "app not installed" }
        return connectivity.isReachable ? "✅ connected" : "paired"
    }
}

private struct RecordingRow: View {
    let recording: SwingRecording

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(recording.startedAt, format: .dateTime.month().day().hour().minute().second())
            if let note = recording.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            Text("\(Int(recording.measuredAccelHz.rounded())) Hz accel · \(Int(recording.measuredMotionHz.rounded())) Hz motion · \(recording.source)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
        .environment(PhoneConnectivity())
        .environment(RecordingStore())
}
