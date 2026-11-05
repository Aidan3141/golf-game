import SwiftUI
import SwingKit

struct ContentView: View {
    @Environment(PhoneConnectivity.self) private var connectivity
    @Environment(RecordingStore.self) private var store

    var body: some View {
        NavigationStack {
            List {
                Section("connections") {
                    Label("Watch", systemImage: "applewatch")
                        .badge(watchStatus)
                    // real status in M5
                    Label("Vision Pro", systemImage: "visionpro")
                        .badge("—")
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
