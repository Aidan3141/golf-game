import SwiftUI
import SwingKit

struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "figure.golf")
                .font(.largeTitle)
                .foregroundStyle(.green)
            Text("Ready")
                .font(.title2.bold())
            Text("swingkit \(SwingKit.version)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    ContentView()
}
