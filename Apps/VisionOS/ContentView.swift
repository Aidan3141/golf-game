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
                Section("connection") {
                    LabeledContent("iPhone", value: appModel.network.state.label)
                    if let ms = appModel.network.lastLatency {
                        LabeledContent("Last swing", value: String(format: "%.0f ms from phone · %d total", ms * 1000, appModel.network.received))
                    }
                }

                Section {
                    Button(appModel.rangeState == .open ? "Leave Range" : "Go to Range") {
                        Task { await toggleRange() }
                    }
                    .disabled(appModel.rangeState == .opening)
                }

                Section("settings") {
                    Picker("View", selection: $appModel.viewMode) {
                        ForEach(AppModel.ViewMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Flip left/right", isOn: $appModel.flipCurve)
                    SliderRow("Curve strength", value: $appModel.curveStrength, in: 0...2, format: "%.1fx")
                    if appModel.network.clubUpdates > 0 {
                        LabeledContent("Live club", value: "\(appModel.network.clubUpdates) updates")
                    }
                }

                Section {
                    Toggle("Tempo trainer", isOn: $appModel.tempoTrainerOn)
                    if appModel.tempoTrainerOn {
                        SliderRow("Backswing", value: $appModel.trainerBackswing, in: 0.6...1.4, format: "%.2f s")
                        Text("swing back on tick 1-2-3, hit on the tock. thats a perfect 3:1")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("practice")
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

                if !appModel.session.isEmpty {
                    let st = appModel.stats
                    Section {
                        LabeledContent("Shots", value: "\(st.shots)")
                        LabeledContent("Avg tempo", value: String(format: "%.1f : 1", st.averageTempo))
                        LabeledContent("Consistency", value: String(format: "%@ (±%.1f)", st.consistencyLabel, st.tempoSpread))
                        LabeledContent("Avg carry", value: yards(st.averageCarry))
                        if let best = appModel.bestShot {
                            LabeledContent("Best", value: String(format: "%@ · tempo %.1f", yards(best.flight.carry), best.swing.tempoRatio))
                        }
                        Button("New Session", systemImage: "arrow.counterclockwise") {
                            appModel.newSession()
                        }
                    } header: {
                        Text("session")
                    }
                }

                if let shot = appModel.lastShot {
                    Section("last shot") {
                        Text(shot.tip.title).font(.headline)
                        Text(shot.tip.detail).foregroundStyle(.secondary)
                        LabeledContent("Carry", value: yards(shot.flight.carry))
                        LabeledContent("Total", value: yards(shot.flight.total))
                        LabeledContent("Offline", value: offline(shot.flight.offline))
                        LabeledContent("Apex", value: yards(shot.flight.apex))
                        if let face = shot.swing.faceAngle {
                            LabeledContent("Wrist roll", value: String(format: "%+.0f° → %@", face, curveText(shot.swing.pathBias)))
                        }
                    }
                }
            }
            .navigationTitle("Golf Game")
        }
        // real swing w/ range closed -> open it, RangeView plays the shot once loaded
        .onChange(of: appModel.lastShot) { _, shot in
            if shot?.live == true && appModel.rangeState == .closed {
                Task { await toggleRange() }
            }
        }
        #if DEBUG
        // `-autoShot` launch arg: open range + hit, for sim testing w/o clicking
        // `-openRange` just opens it
        .task {
            let args = ProcessInfo.processInfo.arguments
            guard args.contains("-autoShot") || args.contains("-openRange") else { return }
            try? await Task.sleep(for: .seconds(2))
            if args.contains("-autoShot") {
                await hit(appModel.testSwing)
            } else {
                await toggleRange()
            }
            if args.contains("-hideWindow") {
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

    private func curveText(_ path: Double) -> String {
        if abs(path) < 0.1 { return "straight" }
        return path < 0 ? "slice" : "hook"
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
