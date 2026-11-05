import Foundation
import SwiftUI
import SwingKit

struct ContentView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        @Bindable var appModel = appModel
        NavigationStack {
            Form {
                Section {
                    Button(appModel.rangeState == .open ? "Leave Range" : "Go to Range") {
                        Task { await toggleRange() }
                    }
                    .disabled(appModel.rangeState == .opening)
                }

                Section("test swing") {
                    Picker("Hand", selection: $appModel.testSwing.handedness) {
                        Text("Right").tag(Handedness.right)
                        Text("Left").tag(Handedness.left)
                    }
                    .pickerStyle(.segmented)

                    SliderRow("Backswing", value: $appModel.testSwing.backswing, in: 0.4...1.5, format: "%.2f s")
                    SliderRow("Downswing", value: $appModel.testSwing.downswing, in: 0.15...0.6, format: "%.2f s")
                    LabeledContent("Tempo", value: String(format: "%.1f : 1  (goal 3 : 1)", appModel.testSwing.tempoRatio))
                    SliderRow("Wrist speed", value: $appModel.testSwing.wristSpeed, in: 8...35, format: "%.0f rad/s")
                    SliderRow("Smoothness", value: $appModel.testSwing.smoothness, in: 0...1, format: "%.2f")
                    SliderRow("Path", value: $appModel.testSwing.pathBias, in: -1...1, format: "%+.2f")
                    HStack {
                        Text("slice").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text("hook").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    Button("Hit Test Shot", systemImage: "figure.golf") {
                        Task { await hit(appModel.testSwing) }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Random Swing", systemImage: "dice") {
                        appModel.testSwing = .random()
                        Task { await hit(appModel.testSwing) }
                    }
                }

                if let shot = appModel.lastShot {
                    Section("last shot") {
                        LabeledContent("Carry", value: yards(shot.flight.carry))
                        LabeledContent("Total", value: yards(shot.flight.total))
                        LabeledContent("Offline", value: offline(shot.flight.offline))
                        LabeledContent("Apex", value: yards(shot.flight.apex))
                    }
                }
            }
            .navigationTitle("Golf Game")
        }
        #if DEBUG
        // `-autoShot` launch arg: open range + hit, for sim testing w/o clicking
        .task {
            guard ProcessInfo.processInfo.arguments.contains("-autoShot") else { return }
            try? await Task.sleep(for: .seconds(2))
            await hit(appModel.testSwing)
            if ProcessInfo.processInfo.arguments.contains("-hideWindow") {
                dismissWindow(id: GolfGameApp.mainWindowID)
            }
        }
        #endif
    }

    private func hit(_ settings: TestSwingSettings) async {
        if appModel.rangeState != .open {
            await toggleRange()
        }
        appModel.mockSource.send(settings.makeSwing())
    }

    private func toggleRange() async {
        switch appModel.rangeState {
        case .open:
            await dismissImmersiveSpace()
        case .closed:
            appModel.rangeState = .opening
            // flips to .open in onAppear, only handle fails here
            switch await openImmersiveSpace(id: AppModel.rangeSpaceID) {
            case .opened: break
            default: appModel.rangeState = .closed
            }
        case .opening:
            break
        }
    }

    private func yards(_ m: Double) -> String {
        String(format: "%.0f yd", Units.yards(m))
    }

    private func offline(_ m: Double) -> String {
        let yd = Units.yards(m)
        if abs(yd) < 1 { return "on line" }
        return String(format: "%.0f yd %@", abs(yd), yd > 0 ? "right" : "left")
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: String

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, format: String) {
        self.title = title
        self._value = value
        self.range = range
        self.format = format
    }

    var body: some View {
        VStack(alignment: .leading) {
            LabeledContent(title, value: String(format: format, value))
            Slider(value: $value, in: range)
        }
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
        .environment(AppModel())
}
