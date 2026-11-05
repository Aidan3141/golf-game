import SwiftUI
import SwingKit

struct ContentView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("connections") {
                    // real status in M5
                    Label("Watch", systemImage: "applewatch")
                        .badge("—")
                    Label("Vision Pro", systemImage: "visionpro")
                        .badge("—")
                }
                Section("about") {
                    LabeledContent("swingkit", value: SwingKit.version)
                    LabeledContent("msg version", value: "\(MessageEnvelope.currentVersion)")
                }
            }
            .navigationTitle("Golf Game")
        }
    }
}

#Preview {
    ContentView()
}
